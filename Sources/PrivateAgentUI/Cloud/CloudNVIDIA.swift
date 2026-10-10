import Foundation
import Security
import CryptoKit

/// Settings for the optional NVIDIA cloud backend.
/// The API key is stored in the Keychain only. It is never written to source,
/// UserDefaults, or logs.
enum CloudSettings {
    static let enabledKey = "cloudEnabled"
    static let modelKey = "cloudModel"
    static let defaultModel = "nvidia/nemotron-3-super-120b-a12b"
    static let baseURLKey = "cloudBaseURL"
    static let defaultBaseURL = "https://integrate.api.nvidia.com/v1"

    /// OpenAI-compatible base URL (ends in /v1). Defaults to NVIDIA. Point it at your own
    /// server (for example llama-server on a PC) to use a private model.
    static var baseURL: String {
        var u = (UserDefaults.standard.string(forKey: baseURLKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        return u.isEmpty ? defaultBaseURL : u
    }

    /// True while the server is NVIDIA's (an API key is required there).
    static var usesNVIDIA: Bool { baseURL.lowercased().contains("nvidia.com") }

    private static let service = "privateagent.nvidia.apikey"
    /// NVIDIA keeps the original Keychain slot. Every other server gets its own slot
    /// (by host), so switching servers never overwrites a key you already saved.
    private static var account: String {
        if usesNVIDIA { return "default" }
        return "server:" + (URL(string: baseURL)?.host ?? "custom")
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var model: String {
        let m = UserDefaults.standard.string(forKey: modelKey) ?? ""
        return m.trimmingCharacters(in: .whitespaces).isEmpty ? defaultModel : m.trimmingCharacters(in: .whitespaces)
    }

    static var isActive: Bool { isEnabled && (!usesNVIDIA || !(apiKey ?? "").isEmpty) }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static var apiKey: String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// One-time import. If Documents/nvidia_api_key.txt exists (copied over USB by
    /// push-nvidia-key.py), save it to the Keychain, delete the file, enable cloud.
    @discardableResult
    static func importKeyFromDocuments() -> Bool {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let file = docs.appendingPathComponent("nvidia_api_key.txt")
        guard let data = try? Data(contentsOf: file),
              let raw = String(data: data, encoding: .utf8) else { return false }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(at: file)
        guard key.hasPrefix("nvapi-"), key.count > 20 else { return false }
        setAPIKey(key)
        UserDefaults.standard.set(true, forKey: enabledKey)
        return true
    }

    /// Short, non-reversible code (first 4 bytes of SHA-256, as 8 hex chars) so you can
    /// confirm the PC and the iPhone hold the same key without showing the key.
    static var fingerprint: String? {
        guard let k = apiKey, !k.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(k.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Saves the key (empty string removes it).
    static func setAPIKey(_ key: String) {
        SecItemDelete(baseQuery() as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = baseQuery()
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct CloudMessage: Sendable {
    let role: String
    let content: String
}

enum CloudError: LocalizedError, Sendable {
    case badResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "Cloud server: unexpected response."
        case .http(let code, let body):
            switch code {
            case 401, 403: return "Cloud server: key rejected (HTTP \(code)). Check the API key in Settings."
            case 404: return "Cloud server: not found (HTTP 404). Check the server URL and model name in Settings."
            case 429: return "Cloud server: rate limit reached (HTTP 429). Wait a moment and retry."
            default: return "Cloud server error (HTTP \(code)). \(body)"
            }
        }
    }
}

extension NVIDIAClient {
    /// One tiny non-streaming request. Returns a short status string for the Settings screen.
    static func ping(model: String, apiKey: String) async -> String {
        guard let url = URL(string: endpoint) else { return "Bad URL" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Say hi"]],
            "max_tokens": 16,
            "stream": false
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return "Encode error" }
        req.httpBody = data
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return "No response" }
            return http.statusCode == 200 ? "OK (HTTP 200)" : "HTTP \(http.statusCode)"
        } catch {
            return "Network error: \(error.localizedDescription)"
        }
    }
}

/// Minimal streaming client for an OpenAI-compatible chat endpoint (NVIDIA by default).
enum NVIDIAClient {
    static var endpoint: String { CloudSettings.baseURL + "/chat/completions" }

    static func stream(
        messages: [CloudMessage],
        model: String,
        apiKey: String,
        temperature: Double,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: endpoint) else { throw CloudError.badResponse }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 300
                    if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    var wire: [[String: String]] = []
                    for m in messages { wire.append(["role": m.role, "content": m.content]) }
                    let body: [String: Any] = [
                        "model": model,
                        "messages": wire,
                        "temperature": temperature,
                        "max_tokens": maxTokens,
                        "stream": true
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw CloudError.badResponse }
                    guard (200...299).contains(http.statusCode) else {
                        var text = ""
                        for try await line in bytes.lines {
                            text += line
                            if text.count > 300 { break }
                        }
                        throw CloudError.http(http.statusCode, text)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let piece = delta["content"] as? String,
                              !piece.isEmpty else { continue }
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
