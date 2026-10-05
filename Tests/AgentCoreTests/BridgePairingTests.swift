import Foundation
import Testing
@testable import AgentCore

@Suite("Mac/iPhone pairing")
struct BridgePairingTests {
    @Test("LAN defaults match the MacBook SSH hop")
    func lanDefaultsMatchSSHHop() {
        #expect(PrivateAgentLAN.macHost == "192.168.12.110")
        #expect(PrivateAgentLAN.sshUser == "jay")
        #expect(PrivateAgentLAN.sshPort == 2222)
        #expect(PrivateAgentLAN.bridgePort == 8765)
        #expect(PrivateAgentLAN.sshHostFingerprint == "SHA256:emqKZwPshfgeWHiI35S8DIbs3PiMU5ZIo/4PZJCz67Q")
    }

    @Test("parses a privateagent pair deep link and recommends Mac-assisted mode")
    func parsesPairDeepLink() {
        let url = URL(string: "privateagent://pair?host=192.168.1.20&port=8765&token=secret-token")!
        let pairing = BridgePairing.fromDeepLink(url)
        #expect(pairing?.host == "192.168.1.20")
        #expect(pairing?.port == 8765)
        #expect(pairing?.token == "secret-token")
        #expect(pairing?.recommendedModes().contains(AutomationMode.macAssisted) == true)
        #expect(pairing?.pairingURL?.absoluteString.contains("privateagent://pair") == true)
    }

    @Test("loads pairing from environment variables")
    func loadsFromEnvironment() {
        let pairing = BridgePairing.fromEnvironment([
            "PRIVATEAGENT_BRIDGE_HOST": "10.0.0.4",
            "PRIVATEAGENT_BRIDGE_PORT": "9000",
            "PRIVATEAGENT_BRIDGE_TOKEN": "env-token",
            "PRIVATEAGENT_ENABLE_WDA": "true"
        ])
        #expect(pairing?.host == "10.0.0.4")
        #expect(pairing?.port == 9000)
        #expect(pairing?.enableWebDriverAgent == true)
        #expect(pairing?.recommendedModes().contains(AutomationMode.webDriverAgent) == true)
    }

    @Test("persists pairing through the store")
    func persistsThroughStore() {
        let defaults = UserDefaults(suiteName: "PrivateAgent.BridgePairingTests")!
        defaults.removePersistentDomain(forName: "PrivateAgent.BridgePairingTests")
        let pairing = BridgePairing(host: "192.168.0.8", port: 8765, token: "stored")
        BridgePairingStore.save(pairing, defaults: defaults)
        let loaded = BridgePairingStore.load(defaults: defaults, environment: [:])
        #expect(loaded?.host == "192.168.0.8")
        #expect(loaded?.token == "stored")
        #expect(loaded?.enableMacAssisted == true)
    }

    @Test("doctor tells a Linux cloud agent it cannot drive the iPhone")
    func doctorBlocksCloudAgent() {
        let diagnosis = BridgePairingDoctor.diagnose(
            pairing: nil,
            onDarwin: false,
            selfHostedWorkerAvailable: false
        )
        #expect(!diagnosis.canDriveIPhoneFromThisProcess)
        #expect(diagnosis.nextAction.contains("192.168.12.110"))
        #expect(diagnosis.nextAction.contains("2222"))
        #expect(diagnosis.nextAction.contains("jay@"))
        #expect(diagnosis.nextAction.contains("start-mac-bridge.sh"))
    }

    @Test("doctor allows a configured Mac to continue into Agent Mode")
    func doctorAllowsConfiguredMac() {
        let pairing = BridgePairing(host: "192.168.1.20", token: "secret")
        let diagnosis = BridgePairingDoctor.diagnose(
            pairing: pairing,
            onDarwin: true,
            bridgeReachable: true
        )
        #expect(diagnosis.canDriveIPhoneFromThisProcess)
        #expect(diagnosis.recommendedModes.contains(.macAssisted))
        #expect(diagnosis.nextAction.contains("Agent Mode"))
    }
}
