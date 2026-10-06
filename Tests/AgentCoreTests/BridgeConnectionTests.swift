import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AgentCore

private let healthJSON = #"{"status":"ok","service":"PrivateAgent Mac Bridge","mode":"guarded-actions"}"#

@Suite("Bridge connection + pairing")
struct BridgeConnectionTests {
    private func manager(_ transport: StubHTTPTransport, store: InMemoryCredentialStore = InMemoryCredentialStore()) -> BridgeConnectionManager {
        BridgeConnectionManager(host: "192.168.12.141", port: 8765, transport: transport, tokenStore: store, timeout: 1)
    }

    @Test("unreachable host reports reason and a hint")
    func unreachable() async {
        let transport = StubHTTPTransport()
        transport.onAny(timedOut)
        let status = await manager(transport).checkStatus()
        #expect(status.state == .unreachable)
        #expect(status.detail.contains("timed out"))
        #expect(status.hint?.contains("Local Network") == true)
        #expect(!status.needsPairingCode)
    }

    @Test("connection refused tells the user to start the bridge")
    func refusedHint() async {
        let transport = StubHTTPTransport()
        transport.onAny(refused)
        let status = await manager(transport).checkStatus()
        #expect(status.state == .unreachable)
        #expect(status.hint?.contains("mac_bridge_helper.py") == true)
    }

    @Test("loopback bridge host explains 127.0.0.1 is the iPhone")
    func loopbackHint() async {
        let transport = StubHTTPTransport()
        transport.onAny(refused)
        let status = await BridgeConnectionManager(host: "127.0.0.1", port: 8765, transport: transport, tokenStore: InMemoryCredentialStore()).checkStatus()
        #expect(status.hint?.contains("this iPhone") == true)
    }

    @Test("invalid host/port is not configured")
    func notConfigured() async {
        let status = await BridgeConnectionManager(host: " ", port: 0, transport: StubHTTPTransport(), tokenStore: InMemoryCredentialStore()).checkStatus()
        #expect(status.state == .notConfigured)
    }

    @Test("401 without a token means reachable but unpaired")
    func reachableUnpaired() async {
        let transport = StubHTTPTransport()
        transport.on("GET /health", status: 401, json: #"{"error":"unauthorized","reason":"missing_token","pairing":"available"}"#)
        let status = await manager(transport).checkStatus()
        #expect(status.state == .reachableUnpaired)
        #expect(status.pairingAvailable == true)
        #expect(status.needsPairingCode)
        #expect(transport.recorded().first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("pairing locked is surfaced in the hint")
    func pairingLockedHint() async {
        let transport = StubHTTPTransport()
        transport.on("GET /health", status: 401, json: #"{"error":"unauthorized","pairing":"locked"}"#)
        let status = await manager(transport).checkStatus()
        #expect(status.pairingAvailable == false)
        #expect(status.hint?.contains("Restart the bridge") == true)
    }

    @Test("stored token is sent as bearer and yields paired")
    func pairedWithToken() async {
        let store = InMemoryCredentialStore()
        let token = "tok_0123456789abcdef0123456789abcdef"
        try? store.set(token, forKey: CredentialKeys.bridgeToken(host: "192.168.12.141", port: 8765))
        let transport = StubHTTPTransport()
        transport.on("GET /health") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            return HTTPResponse(statusCode: 200, body: Data(healthJSON.utf8))
        }
        let status = await manager(transport, store: store).checkStatus()
        #expect(status.state == .paired)
        #expect(status.health?.mode == "guarded-actions")
        #expect(status.redactedToken?.contains(token) == false)
        #expect(!status.summary.contains(token))
    }

    @Test("rejected token becomes token-invalid and is removed")
    func tokenInvalid() async {
        let store = InMemoryCredentialStore()
        let key = CredentialKeys.bridgeToken(host: "192.168.12.141", port: 8765)
        try? store.set("old-token-value-0000", forKey: key)
        let transport = StubHTTPTransport()
        transport.on("GET /health", status: 401, json: #"{"error":"unauthorized","reason":"invalid_token","pairing":"available"}"#)
        let status = await manager(transport, store: store).checkStatus()
        #expect(status.state == .tokenInvalid)
        #expect(status.needsPairingCode)
        #expect(!status.detail.contains("old-token-value-0000"))
        #expect(store.string(forKey: key) == nil)
    }

    @Test("non-bridge 200 response is reported as wrong service")
    func wrongService() async {
        let transport = StubHTTPTransport()
        transport.on("GET /health", status: 200, json: "<html></html>")
        let status = await manager(transport).checkStatus()
        #expect(status.state == .error)
    }

    @Test("pairing code normalization")
    func normalizeCode() {
        #expect(BridgeConnectionManager.normalizePairingCode("123456") == "123456")
        #expect(BridgeConnectionManager.normalizePairingCode(" 123 456 ") == "123456")
        #expect(BridgeConnectionManager.normalizePairingCode("123-456") == "123456")
        #expect(BridgeConnectionManager.normalizePairingCode("12345") == nil)
        #expect(BridgeConnectionManager.normalizePairingCode("12a456") == nil)
        #expect(BridgeConnectionManager.normalizePairingCode("１２３４５６") == nil)
    }

    @Test("successful pairing stores the token and verifies health")
    func pairSuccess() async {
        let store = InMemoryCredentialStore()
        let issued = "issued-token-abcdefghijklmnopqrstuvwxyz"
        let transport = StubHTTPTransport()
        transport.on("POST /pair") { request in
            let body = StubHTTPTransport.json(request)
            #expect(body["code"] as? String == "482913")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return HTTPResponse(statusCode: 200, body: Data(#"{"token":"\#(issued)","service":"PrivateAgent Mac Bridge"}"#.utf8))
        }
        transport.on("GET /health") { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(issued)" else {
                return HTTPResponse(statusCode: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
            }
            return HTTPResponse(statusCode: 200, body: Data(healthJSON.utf8))
        }
        let status = await manager(transport, store: store).pair(code: "482 913")
        #expect(status.state == .paired)
        #expect(status.detail.contains("Paired with 192.168.12.141:8765"))
        #expect(store.string(forKey: CredentialKeys.bridgeToken(host: "192.168.12.141", port: 8765)) == issued)
        #expect(!status.summary.contains(issued))
    }

    @Test("malformed code is rejected locally without a request")
    func pairInvalidLocal() async {
        let transport = StubHTTPTransport()
        let status = await manager(transport).pair(code: "12")
        #expect(status.state == .pairingFailed)
        #expect(transport.recorded().isEmpty)
    }

    @Test("wrong / expired / locked / old-bridge pairing responses")
    func pairFailures() async {
        let cases: [(Int, String, String)] = [
            (403, #"{"error":"invalid_code","attemptsRemaining":3}"#, "Wrong code"),
            (410, #"{"error":"code_expired"}"#, "Code expired"),
            (429, #"{"error":"pairing_locked"}"#, "Pairing locked"),
            (403, #"{"error":"pairing_disabled"}"#, "Pairing disabled"),
            (404, #"{"error":"not_found"}"#, "Pairing not supported"),
            (500, #"{}"#, "Pairing failed"),
        ]
        for (code, json, title) in cases {
            let store = InMemoryCredentialStore()
            let transport = StubHTTPTransport()
            transport.on("POST /pair", status: code, json: json)
            let status = await manager(transport, store: store).pair(code: "111111")
            #expect(status.state == .pairingFailed)
            #expect(status.title == title)
            #expect(store.allKeys.isEmpty)
        }
        let transport = StubHTTPTransport()
        transport.on("POST /pair", status: 403, json: #"{"error":"invalid_code","attemptsRemaining":3}"#)
        let status = await manager(transport).pair(code: "111111")
        #expect(status.detail.contains("3 attempt(s) left"))
    }

    @Test("pairing against an unreachable bridge reports unreachable")
    func pairUnreachable() async {
        let transport = StubHTTPTransport()
        transport.onAny(refused)
        let status = await manager(transport).pair(code: "111111")
        #expect(status.state == .unreachable)
    }

    @Test("tokens are scoped per host:port")
    func tokenScoping() async {
        let store = InMemoryCredentialStore()
        try? store.set("mac-token-000000000", forKey: CredentialKeys.bridgeToken(host: "192.168.12.110", port: 8765))
        let pc = BridgeConnectionManager(host: "192.168.12.141", port: 8765, transport: StubHTTPTransport(), tokenStore: store)
        #expect(pc.storedToken() == nil)
        let mac = BridgeConnectionManager(host: "192.168.12.110", port: 8765, transport: StubHTTPTransport(), tokenStore: store)
        #expect(mac.storedToken() == "mac-token-000000000")
        mac.forgetToken()
        #expect(mac.storedToken() == nil)
    }

    @Test("redactor never returns the full secret")
    func redaction() {
        let secret = "abcdefghijklmnopqrstuvwxyz012345"
        let redacted = SecretRedactor.redact(secret)
        #expect(!redacted.contains(secret))
        #expect(redacted.contains("2345"))
        #expect(!SecretRedactor.redact("short").contains("short"))
        #expect(SecretRedactor.redact(nil) == "<none>")
    }

    @Test("network failure classification")
    func classify() {
        #expect(NetworkFailure.classify(URLError(.timedOut)).kind == .timedOut)
        #expect(NetworkFailure.classify(URLError(.cannotConnectToHost)).kind == .connectionRefused)
        #expect(NetworkFailure.classify(URLError(.cannotFindHost)).kind == .hostNotFound)
        #expect(NetworkFailure.classify(URLError(.notConnectedToInternet)).kind == .offline)
        #expect(NetworkFailure.classify(NSError(domain: NSPOSIXErrorDomain, code: 61)).kind == .connectionRefused)
    }
}

@Suite("Pairing store + deep links")
struct BridgePairingStoreKeychainTests {
    @Test("code deep link parses without a token")
    func codeDeepLink() {
        let url = URL(string: "privateagent://pair?host=192.168.12.141&port=8765&code=482913")!
        #expect(BridgePairingLink.parse(url) == .code(host: "192.168.12.141", port: 8765, code: "482913"))
    }

    @Test("legacy token deep link still parses")
    func tokenDeepLink() {
        let url = URL(string: "privateagent://pair?host=10.0.0.2&token=legacy")!
        guard case .token(let pairing) = BridgePairingLink.parse(url) else {
            Issue.record("expected token link")
            return
        }
        #expect(pairing.port == 8765)
        #expect(BridgePairingLink.parse(URL(string: "privateagent://pair?host=10.0.0.2")!) == nil)
        #expect(BridgePairingLink.parse(URL(string: "https://example.com/pair?host=x&code=123456")!) == nil)
    }

    @Test("save keeps tokens out of UserDefaults")
    func saveUsesSecrets() {
        let suite = "PrivateAgent.KeychainStoreTests.save"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let secrets = InMemoryCredentialStore()
        BridgePairingStore.save(BridgePairing(host: "192.168.12.141", token: "tok-123456789", wdaToken: "wda-tok"), defaults: defaults, secrets: secrets)
        #expect(defaults.string(forKey: BridgePairingStore.tokenKey) == nil)
        #expect(defaults.string(forKey: BridgePairingStore.wdaTokenKey) == nil)
        #expect(secrets.string(forKey: CredentialKeys.bridgeToken(host: "192.168.12.141", port: 8765)) == "tok-123456789")
        #expect(secrets.string(forKey: CredentialKeys.wdaToken(host: "127.0.0.1", port: 8101)) == "wda-tok")
        let loaded = BridgePairingStore.load(defaults: defaults, secrets: secrets, environment: [:])
        #expect(loaded?.token == "tok-123456789")
        #expect(loaded?.wdaToken == "wda-tok")
    }

    @Test("legacy UserDefaults tokens migrate to the secure store and are deleted")
    func migratesLegacy() {
        let suite = "PrivateAgent.KeychainStoreTests.migrate"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("192.168.12.110", forKey: BridgePairingStore.hostKey)
        defaults.set("8765", forKey: BridgePairingStore.portKey)
        defaults.set("legacy-token-xyz", forKey: BridgePairingStore.tokenKey)
        defaults.set("legacy-wda", forKey: BridgePairingStore.wdaTokenKey)
        let secrets = InMemoryCredentialStore()
        let loaded = BridgePairingStore.load(defaults: defaults, secrets: secrets, environment: [:])
        #expect(loaded?.token == "legacy-token-xyz")
        #expect(defaults.string(forKey: BridgePairingStore.tokenKey) == nil)
        #expect(defaults.string(forKey: BridgePairingStore.wdaTokenKey) == nil)
        #expect(secrets.string(forKey: CredentialKeys.bridgeToken(host: "192.168.12.110", port: 8765)) == "legacy-token-xyz")
        #expect(secrets.string(forKey: CredentialKeys.wdaToken(host: "127.0.0.1", port: 8101)) == "legacy-wda")
    }
}
