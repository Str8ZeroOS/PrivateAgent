import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What answered on the configured WDA host/port.
public enum WebDriverAgentKind: String, Sendable, Codable, Equatable {
    /// WebDriverAgentRunner itself (W3C WebDriver: /status, /session, ...).
    case direct
    /// `Bridge/wda_adapter.py`, which manages its own WDA session.
    case adapter
}

public enum WDAConnectionState: String, Sendable, Codable, Equatable {
    case notConfigured
    case unreachable
    case unauthorized
    case notReady
    case ready
    case sessionFailed
    case error
}

public struct WDAConnectionStatus: Sendable, Equatable {
    public var state: WDAConnectionState
    public var title: String
    public var detail: String
    public var hint: String?
    public var kind: WebDriverAgentKind?
    public var sessionId: String?
    /// True when an existing session was reused, false when one was created.
    public var sessionReused: Bool
    public var host: String
    public var port: Int

    public init(
        state: WDAConnectionState,
        title: String,
        detail: String,
        hint: String? = nil,
        kind: WebDriverAgentKind? = nil,
        sessionId: String? = nil,
        sessionReused: Bool = false,
        host: String,
        port: Int
    ) {
        self.state = state
        self.title = title
        self.detail = detail
        self.hint = hint
        self.kind = kind
        self.sessionId = sessionId
        self.sessionReused = sessionReused
        self.host = host
        self.port = port
    }

    public var summary: String {
        var parts = ["\(title): \(detail)"]
        if let hint, !hint.isEmpty { parts.append(hint) }
        return parts.joined(separator: "\n")
    }
}

public enum WebDriverAgentSessionError: Error, Sendable, Equatable {
    case unreachable(String)
    case notReady(String)
    case sessionCreationFailed(String)
    case adapterManagesSession
    case invalidConfiguration
}

/// Probes WebDriverAgent, then creates or reuses a WebDriver session and
/// remembers its id. A stored id is validated before reuse; if WDA says it
/// is gone (expired / runner restarted) a new session is created.
public actor WebDriverAgentSessionManager {
    public nonisolated let host: String
    public nonisolated let port: Int
    private let transport: any HTTPTransport
    private let sessionStore: any CredentialStore
    private let tokenStore: (any CredentialStore)?
    private let timeout: TimeInterval
    private let sessionCapabilities: [String: String]
    public private(set) var kind: WebDriverAgentKind?

    public init(
        host: String,
        port: Int,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        sessionStore: any CredentialStore = UserDefaultsCredentialStore(),
        tokenStore: (any CredentialStore)? = nil,
        timeout: TimeInterval = 5,
        sessionCapabilities: [String: String] = [:]
    ) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.transport = transport
        self.sessionStore = sessionStore
        self.tokenStore = tokenStore
        self.timeout = timeout
        self.sessionCapabilities = sessionCapabilities
    }

    public nonisolated var baseURL: URL? { URL.httpBase(host: host, port: port) }
    private var sessionKey: String { CredentialKeys.wdaSession(host: host, port: port) }
    private var address: String { "\(host):\(port)" }

    /// Optional adapter bearer token (only if the adapter was started with --token).
    private var bearer: String? {
        tokenStore?.string(forKey: CredentialKeys.wdaToken(host: host, port: port))
    }

    public func storedSessionId() -> String? {
        guard let id = sessionStore.string(forKey: sessionKey), !id.isEmpty else { return nil }
        return id
    }

    public func invalidateSession() {
        sessionStore.removeValue(forKey: sessionKey)
    }

    private func status(
        _ state: WDAConnectionState,
        _ title: String,
        _ detail: String,
        hint: String? = nil,
        sessionId: String? = nil,
        reused: Bool = false
    ) -> WDAConnectionStatus {
        WDAConnectionStatus(
            state: state, title: title, detail: detail, hint: hint, kind: kind,
            sessionId: sessionId, sessionReused: reused, host: host, port: port
        )
    }

    // MARK: Check

    public func check() async -> WDAConnectionStatus {
        guard let baseURL else {
            return status(.notConfigured, "Not configured", "Enter the WebDriverAgent host and port.")
        }

        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPJSON.request(baseURL.appending(path: "status"), bearer: bearer, timeout: timeout))
        } catch {
            let failure = NetworkFailure.classify(error)
            return status(
                .unreachable, "Unreachable",
                "Can't reach WebDriverAgent at \(address): \(failure.message).",
                hint: Self.unreachableHint(host: host, port: port, failure: failure)
            )
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            kind = .adapter
            return status(
                .unauthorized, "Adapter needs a token",
                "The WDA adapter at \(address) was started with --token.",
                hint: "Restart it without --token: python3 Bridge/wda_adapter.py --host 0.0.0.0"
            )
        }
        guard response.isSuccess, let json = response.jsonObject() else {
            return status(.error, "Not WebDriverAgent", "\(address) answered HTTP \(response.statusCode) without WDA status JSON.",
                          hint: "WebDriverAgentRunner listens on 8100; the Str8ZeRO adapter on 8101.")
        }

        if let value = json["value"] as? [String: Any] {
            kind = .direct
            let ready = (value["ready"] as? Bool) ?? ((value["state"] as? String) == "success")
            let message = (value["message"] as? String) ?? (ready ? "WebDriverAgent is ready" : "WebDriverAgent is not ready")
            guard ready else {
                return status(.notReady, "Not ready", message, hint: "Wait for WebDriverAgentRunner to finish launching, then check again.")
            }
            let advertised = (json["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            do {
                let (id, reused) = try await resolveDirectSession(advertised: advertised)
                return status(
                    .ready, "Ready",
                    "WebDriverAgent at \(address), session \(Self.shortId(id)) (\(reused ? "reused" : "new")).",
                    sessionId: id, reused: reused
                )
            } catch let error as WebDriverAgentSessionError {
                return status(.sessionFailed, "Session failed", Self.describe(error),
                              hint: "Unlock the iPhone and keep WebDriverAgentRunner running, then check again.")
            } catch {
                return status(.sessionFailed, "Session failed", error.localizedDescription)
            }
        }

        if let ready = json["ready"] as? Bool {
            kind = .adapter
            let message = (json["message"] as? String) ?? ""
            let id = (json["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let id { try? sessionStore.set(id, forKey: sessionKey) }
            guard ready else {
                return status(.notReady, "Adapter up, WDA not ready",
                              "The adapter at \(address) can't get a WDA session: \(message.isEmpty ? "unknown reason" : message)",
                              hint: "Check that WebDriverAgentRunner is running and the adapter's --wda-url is right.")
            }
            let sessionText = id.map { ", session \(Self.shortId($0))" } ?? ""
            return status(.ready, "Ready", "Str8ZeRO WDA adapter at \(address)\(sessionText).", sessionId: id, reused: id != nil)
        }

        return status(.error, "Not WebDriverAgent", "\(address) answered, but not with WebDriverAgent status JSON.")
    }

    // MARK: Sessions (direct WDA)

    /// Returns a usable session id for direct WDA, creating one if needed.
    public func ensureSession(forceNew: Bool = false) async throws -> String {
        if kind == nil { _ = await check() }
        guard kind != .adapter else { throw WebDriverAgentSessionError.adapterManagesSession }
        if forceNew { invalidateSession() }
        return try await resolveDirectSession(advertised: nil).id
    }

    private func resolveDirectSession(advertised: String?) async throws -> (id: String, reused: Bool) {
        if let stored = storedSessionId() {
            if try await sessionIsAlive(stored) { return (stored, true) }
            invalidateSession()
        }
        if let advertised, try await sessionIsAlive(advertised) {
            try? sessionStore.set(advertised, forKey: sessionKey)
            return (advertised, true)
        }
        let id = try await createSession()
        try? sessionStore.set(id, forKey: sessionKey)
        return (id, false)
    }

    private func sessionIsAlive(_ id: String) async throws -> Bool {
        guard let baseURL else { throw WebDriverAgentSessionError.invalidConfiguration }
        let request = HTTPJSON.request(baseURL.appending(path: "session").appending(path: id), bearer: bearer, timeout: timeout)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw WebDriverAgentSessionError.unreachable(NetworkFailure.classify(error).message)
        }
        if !response.isSuccess { return false }
        if let value = response.jsonObject()?["value"] as? [String: Any], value["error"] != nil {
            return false
        }
        return true
    }

    private func createSession() async throws -> String {
        guard let baseURL else { throw WebDriverAgentSessionError.invalidConfiguration }
        let body: [String: Any] = [
            "capabilities": [
                "alwaysMatch": sessionCapabilities,
                "firstMatch": [[String: String]()]
            ]
        ]
        let request = HTTPJSON.request(baseURL.appending(path: "session"), method: "POST", bearer: bearer, jsonBody: body, timeout: max(timeout, 30))
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw WebDriverAgentSessionError.unreachable(NetworkFailure.classify(error).message)
        }
        let json = response.jsonObject() ?? [:]
        let value = json["value"] as? [String: Any]
        if response.isSuccess, let id = (value?["sessionId"] as? String) ?? (json["sessionId"] as? String), !id.isEmpty {
            return id
        }
        let reason = (value?["message"] as? String) ?? (value?["error"] as? String) ?? "HTTP \(response.statusCode)"
        throw WebDriverAgentSessionError.sessionCreationFailed(reason)
    }

    /// True when a WDA response says the session no longer exists.
    public static func isInvalidSession(_ response: HTTPResponse) -> Bool {
        guard let json = response.jsonObject() else { return response.statusCode == 404 }
        let value = json["value"] as? [String: Any]
        let error = (value?["error"] as? String) ?? (json["error"] as? String) ?? ""
        return error == "invalid session id" || (response.statusCode == 404 && error.isEmpty)
    }

    // MARK: Hints

    static func shortId(_ id: String) -> String {
        id.count > 8 ? String(id.prefix(8)) + "…" : id
    }

    static func describe(_ error: WebDriverAgentSessionError) -> String {
        switch error {
        case .unreachable(let message): return "WebDriverAgent stopped responding: \(message)."
        case .notReady(let message): return message
        case .sessionCreationFailed(let message): return "WebDriverAgent refused to create a session: \(message)."
        case .adapterManagesSession: return "The adapter manages the WDA session."
        case .invalidConfiguration: return "Invalid WebDriverAgent host or port."
        }
    }

    public static func unreachableHint(host: String, port: Int, failure: NetworkFailure) -> String {
        if BridgeConnectionManager.isLoopback(host) {
            if port == WebDriverAgentProbe.directPort {
                return "Nothing on this iPhone's port 8100. WebDriverAgentRunner must be running on this iPhone (start it from Xcode on a Mac, or with go-ios from Windows)."
            }
            return "\(host):\(port) means this iPhone itself. WebDriverAgentRunner listens on 8100 on the iPhone; the Str8ZeRO adapter (8101) runs on a computer, so use that computer's LAN IP."
        }
        if failure.kind == .connectionRefused {
            return "\(host) is up but nothing listens on \(port). Start WebDriverAgentRunner (8100) or python3 Bridge/wda_adapter.py --host 0.0.0.0 (8101)."
        }
        return "Check that \(host) is on the same Wi-Fi, its firewall allows TCP \(port), and Local Network access is on for Str8ZeRO."
    }
}

/// Tries the configured endpoint first, then (for this iPhone's loopback
/// address) the standard on-device WebDriverAgent port 8100.
public enum WebDriverAgentProbe {
    public static let directPort = 8100
    public static let adapterPort = 8101

    public static func candidatePorts(host: String, port: Int) -> [Int] {
        var ports = [port]
        if BridgeConnectionManager.isLoopback(host), port != directPort {
            ports.append(directPort)
        }
        return ports
    }

    public static func check(
        host: String,
        port: Int,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        sessionStore: any CredentialStore = UserDefaultsCredentialStore(),
        tokenStore: (any CredentialStore)? = nil,
        timeout: TimeInterval = 5
    ) async -> (status: WDAConnectionStatus, manager: WebDriverAgentSessionManager) {
        var first: (WDAConnectionStatus, WebDriverAgentSessionManager)?
        for candidate in candidatePorts(host: host, port: port) {
            let manager = WebDriverAgentSessionManager(
                host: host, port: candidate, transport: transport,
                sessionStore: sessionStore, tokenStore: tokenStore, timeout: timeout
            )
            var result = await manager.check()
            if result.state != .unreachable {
                if candidate != port {
                    result.detail += " (Nothing on port \(port); found WebDriverAgent on \(candidate) and switched to it.)"
                }
                return (result, manager)
            }
            if first == nil { first = (result, manager) }
        }
        return first!
    }
}

/// `WebDriverAgentClient` that works with either the adapter or WDA
/// directly. For direct WDA it creates/reuses the session and transparently
/// recreates it once if WDA reports the session expired.
public struct ManagedWebDriverAgentClient: WebDriverAgentClient {
    public let manager: WebDriverAgentSessionManager
    private let transport: any HTTPTransport
    private let tokenStore: (any CredentialStore)?
    private let timeout: TimeInterval

    public init(
        manager: WebDriverAgentSessionManager,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        tokenStore: (any CredentialStore)? = nil,
        timeout: TimeInterval = 15
    ) {
        self.manager = manager
        self.transport = transport
        self.tokenStore = tokenStore
        self.timeout = timeout
    }

    private var bearer: String? {
        tokenStore?.string(forKey: CredentialKeys.wdaToken(host: manager.host, port: manager.port))
    }

    public func status() async throws -> WebDriverAgentStatus {
        let result = await manager.check()
        if result.state == .unreachable { throw WebDriverAgentClientError.invalidResponse }
        return WebDriverAgentStatus(ready: result.state == .ready, message: result.detail, sessionId: result.sessionId)
    }

    private func resolvedKind() async -> WebDriverAgentKind? {
        if let kind = await manager.kind { return kind }
        _ = await manager.check()
        return await manager.kind
    }

    public func requestObservation(_ request: WebDriverAgentObservationRequest) async throws -> WebDriverAgentResponse {
        switch await resolvedKind() {
        case .adapter:
            return try await adapterPost(request, path: "observation")
        case .direct:
            let response = try await withSession { id in
                try await send(path: "session/\(id)/source", method: "GET", body: nil)
            }
            let json = response.response.jsonObject() ?? [:]
            let source = (json["value"] as? String) ?? ""
            return WebDriverAgentResponse(
                status: .completed,
                message: "Captured developer-device UI.",
                observation: WebDriverAgentSourceParser.observation(goal: request.goal, source: source),
                wdaSessionId: response.sessionId
            )
        case nil:
            throw WebDriverAgentClientError.invalidResponse
        }
    }

    public func executeAction(_ request: WebDriverAgentActionRequest) async throws -> WebDriverAgentResponse {
        switch await resolvedKind() {
        case .adapter:
            return try await adapterPost(request, path: "action")
        case .direct:
            return try await executeDirect(request.action)
        case nil:
            throw WebDriverAgentClientError.invalidResponse
        }
    }

    // MARK: Direct WDA

    private func executeDirect(_ action: AgentAction) async throws -> WebDriverAgentResponse {
        switch action {
        case .wait(let seconds):
            let bounded = min(max(seconds, 0), 30)
            try await Task.sleep(nanoseconds: UInt64(bounded * 1_000_000_000))
            return WebDriverAgentResponse(status: .completed, message: "Waited \(bounded)s.")
        case .openURL(let url):
            let result = try await withSession { id in
                try await send(path: "session/\(id)/url", method: "POST", body: ["url": url])
            }
            return result.response.isSuccess
                ? WebDriverAgentResponse(status: .completed, message: "Opened URL via WDA: \(url)", wdaSessionId: result.sessionId)
                : WebDriverAgentResponse(status: .failed, message: "WDA could not open \(url).", wdaSessionId: result.sessionId)
        case .tap(let controlId):
            return try await withElement(controlId) { id, element in
                let response = try await send(path: "session/\(id)/element/\(element)/click", method: "POST", body: [:])
                return response.isSuccess
                    ? WebDriverAgentResponse(status: .completed, message: "Tapped \(controlId)", wdaSessionId: id)
                    : WebDriverAgentResponse(status: .failed, message: "Tap failed on \(controlId).", wdaSessionId: id)
            }
        case .type(let controlId, let text):
            return try await withElement(controlId) { id, element in
                let response = try await send(
                    path: "session/\(id)/element/\(element)/value", method: "POST",
                    body: ["value": text.map(String.init), "text": text]
                )
                return response.isSuccess
                    ? WebDriverAgentResponse(status: .completed, message: "Typed into \(controlId)", wdaSessionId: id)
                    : WebDriverAgentResponse(status: .failed, message: "Typing failed on \(controlId).", wdaSessionId: id)
            }
        case .handoff:
            return WebDriverAgentResponse(status: .completed, message: "WebDriverAgent handoff accepted.")
        case .scroll:
            return WebDriverAgentResponse(status: .skipped, message: "Scroll is not mapped for direct WDA yet; use tap/type.")
        case .answer, .askUser, .runShortcut, .invokeAppIntent:
            return WebDriverAgentResponse(status: .skipped, message: "WebDriverAgent does not handle this action.")
        }
    }

    private func withElement(
        _ controlId: String,
        _ body: @Sendable (String, String) async throws -> WebDriverAgentResponse
    ) async throws -> WebDriverAgentResponse {
        let found = try await withSession { id in
            let byAccessibility = try await send(path: "session/\(id)/element", method: "POST", body: ["using": "accessibility id", "value": controlId])
            if byAccessibility.isSuccess { return byAccessibility }
            if WebDriverAgentSessionManager.isInvalidSession(byAccessibility) { return byAccessibility }
            return try await send(path: "session/\(id)/element", method: "POST", body: ["using": "name", "value": controlId])
        }
        let value = found.response.jsonObject()?["value"] as? [String: Any]
        guard found.response.isSuccess,
              let element = (value?["ELEMENT"] as? String) ?? (value?["element-6066-11e4-a52e-4f735466cecf"] as? String) else {
            return WebDriverAgentResponse(status: .failed, message: "Control not found: \(controlId)", wdaSessionId: found.sessionId)
        }
        return try await body(found.sessionId, element)
    }

    /// Runs `operation` with a live session; if WDA says the session expired,
    /// creates a new one and retries once.
    private func withSession(
        _ operation: @Sendable (String) async throws -> HTTPResponse
    ) async throws -> (response: HTTPResponse, sessionId: String) {
        let id = try await manager.ensureSession()
        let response = try await operation(id)
        guard WebDriverAgentSessionManager.isInvalidSession(response) else { return (response, id) }
        let fresh = try await manager.ensureSession(forceNew: true)
        return (try await operation(fresh), fresh)
    }

    private func send(path: String, method: String, body: [String: Any]?) async throws -> HTTPResponse {
        guard let baseURL = manager.baseURL else { throw WebDriverAgentClientError.invalidResponse }
        return try await transport.send(
            HTTPJSON.request(baseURL.appending(path: path), method: method, bearer: bearer, jsonBody: body, timeout: timeout)
        )
    }

    // MARK: Adapter

    private func adapterPost<Body: Encodable>(_ body: Body, path: String) async throws -> WebDriverAgentResponse {
        guard let baseURL = manager.baseURL else { throw WebDriverAgentClientError.invalidResponse }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var request = HTTPJSON.request(baseURL.appending(path: path), method: "POST", bearer: bearer, timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let response = try await transport.send(request)
        guard response.isSuccess else { throw WebDriverAgentClientError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WebDriverAgentResponse.self, from: response.body)
    }
}

/// Turns a WDA XML page source into an `AgentObservation` (labels only).
public enum WebDriverAgentSourceParser {
    public static func observation(goal: String, source: String, maxControls: Int = 40) -> AgentObservation {
        var labels: [String] = []
        var remaining = Substring(source)
        while labels.count < maxControls, let start = remaining.range(of: "name=\"") {
            let afterStart = remaining[start.upperBound...]
            guard let end = afterStart.firstIndex(of: "\"") else { break }
            let label = afterStart[..<end].trimmingCharacters(in: .whitespaces)
            remaining = afterStart[afterStart.index(after: end)...]
            if !label.isEmpty, !labels.contains(label) { labels.append(label) }
        }
        let controls = labels.enumerated().map { index, label in
            AgentControl(id: label, label: label, role: .unknown, isEnabled: true, hint: "wda-\(index)")
        }
        return AgentObservation(
            source: .webDriverAgent,
            userGoal: goal,
            visibleText: labels.isEmpty ? ["WebDriverAgent connected"] : Array(labels.prefix(20)),
            controls: controls,
            appContext: "WebDriverAgent"
        )
    }
}
