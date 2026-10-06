import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live state of the Mac/PC bridge, as shown under "Check Bridge".
public enum BridgeConnectionState: String, Sendable, Codable, Equatable {
    case notConfigured
    case unreachable
    case reachableUnpaired
    case paired
    case tokenInvalid
    case pairingFailed
    case error
}

public struct BridgeConnectionStatus: Sendable, Equatable {
    public var state: BridgeConnectionState
    /// Short label, e.g. "Paired" or "Unreachable".
    public var title: String
    /// Reason in plain words.
    public var detail: String
    /// Short next step for the user, when there is one.
    public var hint: String?
    public var health: MacBridgeHealth?
    /// Whether the bridge says it will accept a pairing code right now.
    public var pairingAvailable: Bool?
    /// Redacted token (never the full value) for display/diagnostics.
    public var redactedToken: String?

    public init(
        state: BridgeConnectionState,
        title: String,
        detail: String,
        hint: String? = nil,
        health: MacBridgeHealth? = nil,
        pairingAvailable: Bool? = nil,
        redactedToken: String? = nil
    ) {
        self.state = state
        self.title = title
        self.detail = detail
        self.hint = hint
        self.health = health
        self.pairingAvailable = pairingAvailable
        self.redactedToken = redactedToken
    }

    /// The UI should offer a pairing-code field in these states.
    public var needsPairingCode: Bool {
        switch state {
        case .reachableUnpaired, .tokenInvalid, .pairingFailed:
            return true
        default:
            return false
        }
    }

    public var summary: String {
        var parts = ["\(title): \(detail)"]
        if let hint, !hint.isEmpty { parts.append(hint) }
        return parts.joined(separator: "\n")
    }
}

/// Talks to `Bridge/mac_bridge_helper.py`: checks health, runs the
/// one-time pairing-code handshake, and keeps the bearer token in a
/// `CredentialStore` (the Keychain in the app).
public struct BridgeConnectionManager: Sendable {
    public let host: String
    public let port: Int
    private let transport: any HTTPTransport
    private let tokenStore: any CredentialStore
    private let timeout: TimeInterval

    public init(
        host: String,
        port: Int,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        tokenStore: any CredentialStore = CredentialStores.secure(),
        timeout: TimeInterval = 5
    ) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.transport = transport
        self.tokenStore = tokenStore
        self.timeout = timeout
    }

    public var baseURL: URL? { URL.httpBase(host: host, port: port) }
    public var tokenKey: String { CredentialKeys.bridgeToken(host: host, port: port) }
    private var address: String { "\(host):\(port)" }

    public func storedToken() -> String? {
        guard let token = tokenStore.string(forKey: tokenKey), !token.isEmpty else { return nil }
        return token
    }

    public func forgetToken() {
        tokenStore.removeValue(forKey: tokenKey)
    }

    /// Bridge client for Agent Mode, authenticated with the stored token.
    public func makeClient(urlSession: URLSession = .shared) -> LocalBridgeClient? {
        guard let baseURL else { return nil }
        return LocalBridgeClient(baseURL: baseURL, token: storedToken(), urlSession: urlSession)
    }

    // MARK: Status

    public func checkStatus() async -> BridgeConnectionStatus {
        guard let baseURL else {
            return BridgeConnectionStatus(
                state: .notConfigured,
                title: "Not configured",
                detail: "Enter the bridge computer's IP address and port.",
                hint: "Example: 192.168.12.141 and 8765."
            )
        }
        let token = storedToken()
        let request = HTTPJSON.request(baseURL.appending(path: "health"), bearer: token, timeout: timeout)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            return Self.unreachableStatus(host: host, port: port, failure: NetworkFailure.classify(error))
        }

        switch response.statusCode {
        case 200..<300:
            guard let health = try? JSONDecoder().decode(MacBridgeHealth.self, from: response.body) else {
                return BridgeConnectionStatus(
                    state: .error,
                    title: "Wrong service",
                    detail: "Something answered on \(address), but it is not the Str8ZeRO bridge.",
                    hint: "Check the port. The bridge listens on 8765 by default."
                )
            }
            let mode = health.mode.map { " Mode: \($0)." } ?? ""
            if token == nil {
                return BridgeConnectionStatus(
                    state: .paired,
                    title: "Connected",
                    detail: "\(address) is up and does not require a token.\(mode)",
                    health: health
                )
            }
            return BridgeConnectionStatus(
                state: .paired,
                title: "Paired",
                detail: "Connected to \(address) (\(health.status)).\(mode)",
                health: health,
                redactedToken: SecretRedactor.redact(token)
            )
        case 401, 403:
            let body = response.jsonObject() ?? [:]
            let pairing = body["pairing"] as? String
            let pairingAvailable: Bool? = pairing.map { $0 == "available" }
            if let token {
                // The bridge rejected our saved token: drop it so we re-pair cleanly.
                forgetToken()
                return BridgeConnectionStatus(
                    state: .tokenInvalid,
                    title: "Token invalid",
                    detail: "\(address) rejected the saved token (\(SecretRedactor.redact(token))). The bridge was reset or this is a different bridge.",
                    hint: Self.pairingHint(pairing: pairing),
                    pairingAvailable: pairingAvailable
                )
            }
            return BridgeConnectionStatus(
                state: .reachableUnpaired,
                title: "Reachable, not paired",
                detail: "\(address) is running and needs this iPhone to pair.",
                hint: Self.pairingHint(pairing: pairing),
                pairingAvailable: pairingAvailable
            )
        default:
            return BridgeConnectionStatus(
                state: .error,
                title: "Bridge error",
                detail: "\(address) answered HTTP \(response.statusCode).",
                hint: "Restart the bridge and try again."
            )
        }
    }

    // MARK: Pairing

    /// Accepts "123456", "123 456" or "123-456". Returns nil if it is not 6 digits.
    public static func normalizePairingCode(_ raw: String) -> String? {
        let digits = raw.filter { !$0.isWhitespace && $0 != "-" }
        guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return digits
    }

    /// POST /pair with the one-time code shown in the bridge window. On success
    /// the issued token goes to the credential store and health is re-checked.
    public func pair(code rawCode: String, deviceName: String = "Str8ZeRO iPhone") async -> BridgeConnectionStatus {
        guard let baseURL else { return await checkStatus() }
        guard let code = Self.normalizePairingCode(rawCode) else {
            return BridgeConnectionStatus(
                state: .pairingFailed,
                title: "Invalid code",
                detail: "The pairing code is the 6-digit number shown in the bridge window.",
                hint: "Type it exactly as shown, e.g. 482913."
            )
        }

        let request = HTTPJSON.request(
            baseURL.appending(path: "pair"),
            method: "POST",
            jsonBody: ["code": code, "deviceName": deviceName],
            timeout: timeout
        )
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            return Self.unreachableStatus(host: host, port: port, failure: NetworkFailure.classify(error))
        }

        let body = response.jsonObject() ?? [:]
        if response.isSuccess {
            guard let token = body["token"] as? String, !token.isEmpty else {
                return BridgeConnectionStatus(
                    state: .pairingFailed,
                    title: "Pairing failed",
                    detail: "The bridge accepted the code but returned no token.",
                    hint: "Update Bridge/mac_bridge_helper.py and try again."
                )
            }
            do {
                try tokenStore.set(token, forKey: tokenKey)
            } catch {
                return BridgeConnectionStatus(
                    state: .pairingFailed,
                    title: "Pairing failed",
                    detail: "Could not save the token to the Keychain (\(error)).",
                    hint: "Unlock the iPhone and try again."
                )
            }
            var status = await checkStatus()
            if status.state == .paired {
                status.detail = "Paired with \(address). " + status.detail
            }
            return status
        }

        let errorCode = body["error"] as? String ?? ""
        let attemptsRemaining = body["attemptsRemaining"] as? Int
        switch (response.statusCode, errorCode) {
        case (404, _):
            return BridgeConnectionStatus(
                state: .pairingFailed,
                title: "Pairing not supported",
                detail: "The bridge at \(address) is an older version without pairing.",
                hint: "Update the repo on the bridge computer and restart Bridge/mac_bridge_helper.py."
            )
        case (410, _), (_, "code_expired"):
            return BridgeConnectionStatus(
                state: .pairingFailed,
                title: "Code expired",
                detail: "That pairing code has expired.",
                hint: "Enter the new code now shown in the bridge window.",
                pairingAvailable: true
            )
        case (429, _), (_, "pairing_locked"):
            return BridgeConnectionStatus(
                state: .pairingFailed,
                title: "Pairing locked",
                detail: "Too many wrong codes. The bridge stopped accepting pairing attempts.",
                hint: "Restart the bridge to get a fresh code.",
                pairingAvailable: false
            )
        case (_, "pairing_disabled"):
            return BridgeConnectionStatus(
                state: .pairingFailed,
                title: "Pairing disabled",
                detail: "The bridge was started with --no-pairing.",
                hint: "Restart it without --no-pairing.",
                pairingAvailable: false
            )
        case (_, "invalid_code"), (403, _):
            let remaining = attemptsRemaining.map { " \($0) attempt(s) left for this code." } ?? ""
            return BridgeConnectionStatus(
                state: .pairingFailed,
                title: "Wrong code",
                detail: "The bridge rejected that code.\(remaining)",
                hint: "Check the code in the bridge window (it changes every few minutes).",
                pairingAvailable: true
            )
        default:
            return BridgeConnectionStatus(
                state: .pairingFailed,
                title: "Pairing failed",
                detail: "The bridge answered HTTP \(response.statusCode)\(errorCode.isEmpty ? "" : " (\(errorCode))").",
                hint: "Restart the bridge and try again."
            )
        }
    }

    // MARK: Hints

    static func pairingHint(pairing: String?) -> String {
        switch pairing {
        case "locked":
            return "Pairing is locked after too many wrong codes. Restart the bridge to get a fresh code."
        case "disabled":
            return "The bridge was started with --no-pairing. Restart it without that flag."
        default:
            return "Enter the 6-digit pairing code shown in the bridge window, then tap Pair."
        }
    }

    public static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "127.0.0.1" || lowered == "localhost" || lowered == "::1"
    }

    public static func unreachableStatus(host: String, port: Int, failure: NetworkFailure) -> BridgeConnectionStatus {
        let hint: String
        if isLoopback(host) {
            hint = "\(host) means this iPhone itself. Enter the LAN IP of the PC/Mac running the bridge."
        } else {
            switch failure.kind {
            case .connectionRefused:
                hint = "\(host) is up but nothing listens on port \(port). Start the bridge there: python Bridge/mac_bridge_helper.py (Windows: py Bridge\\mac_bridge_helper.py)."
            case .insecureConnectionBlocked:
                hint = "This build blocks local HTTP. Install a build with the local-network ATS exception."
            default:
                hint = "Check that the bridge is running on \(host), the PC/Mac is on the same Wi-Fi, its firewall allows TCP \(port), and Settings > Privacy & Security > Local Network > Str8ZeRO is on."
            }
        }
        return BridgeConnectionStatus(
            state: .unreachable,
            title: "Unreachable",
            detail: "Can't reach \(host):\(port): \(failure.message).",
            hint: hint
        )
    }
}
