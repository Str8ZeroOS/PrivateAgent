import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AgentCore

private let directReady = #"{"value":{"ready":true,"message":"WebDriverAgent is ready to accept commands","state":"success","build":{}},"sessionId":null}"#

@Suite("WebDriverAgent session management")
struct WebDriverAgentSessionTests {
    private func manager(
        _ transport: StubHTTPTransport,
        store: InMemoryCredentialStore = InMemoryCredentialStore(),
        host: String = "127.0.0.1",
        port: Int = 8100
    ) -> WebDriverAgentSessionManager {
        WebDriverAgentSessionManager(host: host, port: port, transport: transport, sessionStore: store, timeout: 1)
    }

    @Test("unreachable on-device WDA explains the runner must be running")
    func unreachableDirectPort() async {
        let transport = StubHTTPTransport()
        transport.onAny(refused)
        let status = await manager(transport).check()
        #expect(status.state == .unreachable)
        #expect(status.hint?.contains("WebDriverAgentRunner") == true)
    }

    @Test("loopback 8101 hint explains the adapter runs on a computer")
    func unreachableAdapterPort() async {
        let transport = StubHTTPTransport()
        transport.onAny(refused)
        let status = await manager(transport, port: 8101).check()
        #expect(status.hint?.contains("8101") == true)
        #expect(status.hint?.contains("LAN IP") == true)
    }

    @Test("ready direct WDA creates a session and stores its id")
    func createsSession() async {
        let store = InMemoryCredentialStore()
        let transport = StubHTTPTransport()
        transport.on("GET /status", status: 200, json: directReady)
        transport.on("POST /session") { request in
            let body = StubHTTPTransport.json(request)
            #expect(body["capabilities"] != nil)
            return HTTPResponse(statusCode: 200, body: Data(#"{"value":{"sessionId":"SESSION-NEW-1","capabilities":{}},"sessionId":"SESSION-NEW-1"}"#.utf8))
        }
        let status = await manager(transport, store: store).check()
        #expect(status.state == .ready)
        #expect(status.kind == .direct)
        #expect(status.sessionId == "SESSION-NEW-1")
        #expect(status.sessionReused == false)
        #expect(store.string(forKey: CredentialKeys.wdaSession(host: "127.0.0.1", port: 8100)) == "SESSION-NEW-1")
    }

    @Test("a stored live session is reused without creating a new one")
    func reusesSession() async {
        let store = InMemoryCredentialStore()
        try? store.set("SESSION-OLD", forKey: CredentialKeys.wdaSession(host: "127.0.0.1", port: 8100))
        let transport = StubHTTPTransport()
        transport.on("GET /status", status: 200, json: directReady)
        transport.on("GET /session/SESSION-OLD", status: 200, json: #"{"value":{"capabilities":{}},"sessionId":"SESSION-OLD"}"#)
        let status = await manager(transport, store: store).check()
        #expect(status.state == .ready)
        #expect(status.sessionId == "SESSION-OLD")
        #expect(status.sessionReused)
        #expect(transport.count("POST /session") == 0)
    }

    @Test("an expired stored session is replaced")
    func recreatesExpiredSession() async {
        let store = InMemoryCredentialStore()
        let key = CredentialKeys.wdaSession(host: "127.0.0.1", port: 8100)
        try? store.set("SESSION-DEAD", forKey: key)
        let transport = StubHTTPTransport()
        transport.on("GET /status", status: 200, json: directReady)
        transport.on("GET /session/SESSION-DEAD", status: 404, json: #"{"value":{"error":"invalid session id","message":"Session does not exist"}}"#)
        transport.on("POST /session", status: 200, json: #"{"value":{"sessionId":"SESSION-FRESH"}}"#)
        let status = await manager(transport, store: store).check()
        #expect(status.state == .ready)
        #expect(status.sessionId == "SESSION-FRESH")
        #expect(!status.sessionReused)
        #expect(store.string(forKey: key) == "SESSION-FRESH")
    }

    @Test("a session advertised by /status is adopted")
    func adoptsAdvertisedSession() async {
        let transport = StubHTTPTransport()
        transport.on("GET /status", status: 200, json: #"{"value":{"ready":true,"message":"ok"},"sessionId":"SESSION-ACTIVE"}"#)
        transport.on("GET /session/SESSION-ACTIVE", status: 200, json: #"{"value":{}}"#)
        let status = await manager(transport).check()
        #expect(status.sessionId == "SESSION-ACTIVE")
        #expect(status.sessionReused)
        #expect(transport.count("POST /session") == 0)
    }

    @Test("WDA not ready is reported without creating a session")
    func notReady() async {
        let transport = StubHTTPTransport()
        transport.on("GET /status", status: 200, json: #"{"value":{"ready":false,"message":"Starting"}}"#)
        let status = await manager(transport).check()
        #expect(status.state == .notReady)
        #expect(transport.count("POST /session") == 0)
    }

    @Test("session creation failure is reported with WDA's reason")
    func sessionFailed() async {
        let transport = StubHTTPTransport()
        transport.on("GET /status", status: 200, json: directReady)
        transport.on("POST /session", status: 500, json: #"{"value":{"error":"session not created","message":"Device is locked"}}"#)
        let status = await manager(transport).check()
        #expect(status.state == .sessionFailed)
        #expect(status.detail.contains("Device is locked"))
    }

    @Test("adapter status is recognized and its session id recorded")
    func adapterReady() async {
        let store = InMemoryCredentialStore()
        let transport = StubHTTPTransport()
        transport.on("GET /status", status: 200, json: #"{"ready":true,"message":"ok","sessionId":"ADAPTER-S1"}"#)
        let status = await manager(transport, store: store, host: "192.168.12.141", port: 8101).check()
        #expect(status.state == .ready)
        #expect(status.kind == .adapter)
        #expect(status.sessionId == "ADAPTER-S1")
        #expect(transport.count("POST /session") == 0)
    }

    @Test("adapter that cannot reach WDA is not ready")
    func adapterNotReady() async {
        let transport = StubHTTPTransport()
        transport.on("GET /status", status: 200, json: #"{"ready":false,"message":"WebDriverAgent is not reachable.","sessionId":null}"#)
        let status = await manager(transport, host: "192.168.12.141", port: 8101).check()
        #expect(status.state == .notReady)
        #expect(status.detail.contains("not reachable"))
    }

    @Test("adapter started with --token reports unauthorized")
    func adapterUnauthorized() async {
        let transport = StubHTTPTransport()
        transport.on("GET /status", status: 401, json: #"{"error":"unauthorized"}"#)
        let status = await manager(transport, host: "192.168.12.141", port: 8101).check()
        #expect(status.state == .unauthorized)
    }

    @Test("probe falls back from loopback 8101 to on-device 8100")
    func probeFallsBack() async {
        let transport = StubHTTPTransport()
        transport.on("GET /status") { request in
            if request.url?.port == 8101 { throw URLError(.cannotConnectToHost) }
            return HTTPResponse(statusCode: 200, body: Data(directReady.utf8))
        }
        transport.on("POST /session", status: 200, json: #"{"value":{"sessionId":"S-8100"}}"#)
        let (status, manager) = await WebDriverAgentProbe.check(host: "127.0.0.1", port: 8101, transport: transport, sessionStore: InMemoryCredentialStore(), timeout: 1)
        #expect(status.state == .ready)
        #expect(status.port == 8100)
        #expect(manager.port == 8100)
        #expect(status.detail.contains("switched"))
    }

    @Test("probe does not guess other ports for LAN hosts")
    func probeNoFallbackForLAN() async {
        #expect(WebDriverAgentProbe.candidatePorts(host: "192.168.12.141", port: 8101) == [8101])
        #expect(WebDriverAgentProbe.candidatePorts(host: "127.0.0.1", port: 8101) == [8101, 8100])
        #expect(WebDriverAgentProbe.candidatePorts(host: "localhost", port: 8100) == [8100])
        let transport = StubHTTPTransport()
        transport.onAny(refused)
        let (status, _) = await WebDriverAgentProbe.check(host: "127.0.0.1", port: 8101, transport: transport, sessionStore: InMemoryCredentialStore(), timeout: 1)
        #expect(status.state == .unreachable)
        #expect(status.port == 8101)
    }

    @Test("managed client recreates an expired session and retries the action")
    func clientRecreatesOnExpiry() async throws {
        let store = InMemoryCredentialStore()
        let key = CredentialKeys.wdaSession(host: "127.0.0.1", port: 8100)
        try store.set("S-OLD", forKey: key)
        let transport = StubHTTPTransport()
        transport.on("GET /status", status: 200, json: directReady)
        transport.on("GET /session/S-OLD", status: 200, json: #"{"value":{}}"#)
        // The stored session looks alive at check time, then expires before the action.
        transport.on("POST /session/S-OLD/element", status: 404, json: #"{"value":{"error":"invalid session id","message":"gone"}}"#)
        transport.on("POST /session", status: 200, json: #"{"value":{"sessionId":"S-NEW"}}"#)
        transport.on("POST /session/S-NEW/element", status: 200, json: #"{"value":{"ELEMENT":"EL-1"}}"#)
        transport.on("POST /session/S-NEW/element/EL-1/click", status: 200, json: #"{"value":null}"#)

        let manager = WebDriverAgentSessionManager(host: "127.0.0.1", port: 8100, transport: transport, sessionStore: store, timeout: 1)
        let client = ManagedWebDriverAgentClient(manager: manager, transport: transport)
        let response = try await client.executeAction(WebDriverAgentActionRequest(sessionId: UUID(), action: .tap(controlId: "Wi-Fi")))
        #expect(response.status == .completed)
        #expect(response.wdaSessionId == "S-NEW")
        #expect(store.string(forKey: key) == "S-NEW")
    }

    @Test("managed client builds an observation from WDA page source")
    func clientObservation() async throws {
        let transport = StubHTTPTransport()
        transport.on("GET /status", status: 200, json: directReady)
        transport.on("POST /session", status: 200, json: #"{"value":{"sessionId":"S1"}}"#)
        transport.on("GET /session/S1/source", status: 200, json: #"{"value":"<XCUIElementTypeApplication name=\"Settings\"><XCUIElementTypeCell name=\"Wi-Fi\"/><XCUIElementTypeCell name=\"Wi-Fi\"/></XCUIElementTypeApplication>"}"#)
        let manager = WebDriverAgentSessionManager(host: "127.0.0.1", port: 8100, transport: transport, sessionStore: InMemoryCredentialStore(), timeout: 1)
        let client = ManagedWebDriverAgentClient(manager: manager, transport: transport)
        let response = try await client.requestObservation(WebDriverAgentObservationRequest(goal: "Open Wi-Fi"))
        #expect(response.observation?.source == .webDriverAgent)
        #expect(response.observation?.controls.map(\.label) == ["Settings", "Wi-Fi"])
        #expect(response.wdaSessionId == "S1")
    }

    @Test("managed client forwards to the adapter protocol")
    func clientAdapterForwarding() async throws {
        let transport = StubHTTPTransport()
        transport.on("GET /status", status: 200, json: #"{"ready":true,"message":"ok","sessionId":"A1"}"#)
        transport.on("POST /action", status: 200, json: #"{"status":"completed","message":"Tapped play","wdaSessionId":"A1"}"#)
        let manager = WebDriverAgentSessionManager(host: "192.168.12.141", port: 8101, transport: transport, sessionStore: InMemoryCredentialStore(), timeout: 1)
        let client = ManagedWebDriverAgentClient(manager: manager, transport: transport)
        let response = try await client.executeAction(WebDriverAgentActionRequest(sessionId: UUID(), action: .tap(controlId: "play")))
        #expect(response.status == .completed)
        #expect(response.message == "Tapped play")
    }
}
