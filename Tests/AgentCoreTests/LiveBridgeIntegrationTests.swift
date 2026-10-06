import Foundation
import Testing
@testable import AgentCore

/// Opt-in end-to-end check against a real `Bridge/mac_bridge_helper.py`.
/// Runs only when PRIVATEAGENT_LIVE_BRIDGE_PORT and PRIVATEAGENT_LIVE_BRIDGE_CODE are set:
///
///     python3 Bridge/mac_bridge_helper.py --host 127.0.0.1 --port 18765 &
///     PRIVATEAGENT_LIVE_BRIDGE_PORT=18765 PRIVATEAGENT_LIVE_BRIDGE_CODE=<code> swift test --filter LiveBridge
@Suite("LiveBridge integration")
struct LiveBridgeIntegrationTests {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["PRIVATEAGENT_LIVE_BRIDGE_PORT"] != nil && env["PRIVATEAGENT_LIVE_BRIDGE_CODE"] != nil

    @Test("unpaired -> pair with code -> paired -> forget", .enabled(if: enabled))
    func pairAgainstRealBridge() async throws {
        let host = Self.env["PRIVATEAGENT_LIVE_BRIDGE_HOST"] ?? "127.0.0.1"
        let port = try #require(Int(Self.env["PRIVATEAGENT_LIVE_BRIDGE_PORT"] ?? ""))
        let code = try #require(Self.env["PRIVATEAGENT_LIVE_BRIDGE_CODE"])
        let store = InMemoryCredentialStore()
        let manager = BridgeConnectionManager(host: host, port: port, tokenStore: store)

        let before = await manager.checkStatus()
        #expect(before.state == .reachableUnpaired)
        #expect(before.pairingAvailable == true)

        let wrong = await manager.pair(code: code == "000000" ? "111111" : "000000")
        #expect(wrong.title == "Wrong code")

        let paired = await manager.pair(code: code)
        #expect(paired.state == .paired)
        #expect(manager.storedToken() != nil)

        let again = await manager.checkStatus()
        #expect(again.state == .paired)

        try store.set("bogus-token-not-issued-by-bridge", forKey: manager.tokenKey)
        let invalid = await manager.checkStatus()
        #expect(invalid.state == .tokenInvalid)
    }
}
