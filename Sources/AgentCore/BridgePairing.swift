import Foundation

public enum PrivateAgentLAN {
    public static let macHost = "192.168.12.110"
    public static let sshUser = "jay"
    public static let sshPort = 2222
    public static let bridgePort = 8765
    public static let sshHostFingerprint = "SHA256:emqKZwPshfgeWHiI35S8DIbs3PiMU5ZIo/4PZJCz67Q"
}

public struct BridgePairing: Sendable, Codable, Equatable {
    public var host: String
    public var port: Int
    public var token: String
    public var wdaHost: String
    public var wdaPort: Int
    public var wdaToken: String
    public var enableMacAssisted: Bool
    public var enableWebDriverAgent: Bool

    public init(
        host: String,
        port: Int = PrivateAgentLAN.bridgePort,
        token: String,
        wdaHost: String = "127.0.0.1",
        wdaPort: Int = 8101,
        wdaToken: String = "",
        enableMacAssisted: Bool = true,
        enableWebDriverAgent: Bool = false
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.wdaHost = wdaHost
        self.wdaPort = wdaPort
        self.wdaToken = wdaToken
        self.enableMacAssisted = enableMacAssisted
        self.enableWebDriverAgent = enableWebDriverAgent
    }

    public var macBaseURL: URL? {
        url(host: host, port: port)
    }

    public var pairingURL: URL? {
        var components = URLComponents()
        components.scheme = InAppDeepLink.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: token)
        ]
        return components.url
    }

    public static func fromDeepLink(_ url: URL) -> BridgePairing? {
        guard url.scheme?.lowercased() == InAppDeepLink.scheme else { return nil }
        let hostName = (url.host ?? "").lowercased()
        guard hostName == "pair" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard let host = value("host"), !host.isEmpty, let token = value("token"), !token.isEmpty else {
            return nil
        }
        let port = Int(value("port") ?? "") ?? PrivateAgentLAN.bridgePort
        return BridgePairing(host: host, port: port, token: token)
    }

    public static func fromEnvironment(_ environment: [String: String]) -> BridgePairing? {
        guard let host = environment["PRIVATEAGENT_BRIDGE_HOST"], !host.isEmpty,
              let token = environment["PRIVATEAGENT_BRIDGE_TOKEN"], !token.isEmpty else {
            return nil
        }
        let port = Int(environment["PRIVATEAGENT_BRIDGE_PORT"] ?? "") ?? PrivateAgentLAN.bridgePort
        let wdaHost = environment["PRIVATEAGENT_WDA_HOST"] ?? "127.0.0.1"
        let wdaPort = Int(environment["PRIVATEAGENT_WDA_PORT"] ?? "") ?? 8101
        let wdaToken = environment["PRIVATEAGENT_WDA_TOKEN"] ?? ""
        let enableWDA = ["1", "true", "yes"].contains((environment["PRIVATEAGENT_ENABLE_WDA"] ?? "").lowercased())
        return BridgePairing(
            host: host,
            port: port,
            token: token,
            wdaHost: wdaHost,
            wdaPort: wdaPort,
            wdaToken: wdaToken,
            enableMacAssisted: true,
            enableWebDriverAgent: enableWDA
        )
    }

    public func recommendedModes(startingFrom modes: [AutomationMode] = [.inApp, .appIntents, .shortcuts]) -> [AutomationMode] {
        var result = modes
        if enableMacAssisted, !result.contains(.macAssisted) {
            result.append(.macAssisted)
        }
        if enableWebDriverAgent, !result.contains(.webDriverAgent) {
            result.append(.webDriverAgent)
        }
        return result
    }

    private func url(host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        return components.url
    }
}

/// A `privateagent://pair` link. New bridges print a one-time `code`
/// (never the token); older links that embed a `token` are still accepted.
public enum BridgePairingLink: Sendable, Equatable {
    case code(host: String, port: Int, code: String)
    case token(BridgePairing)

    public static func parse(_ url: URL) -> BridgePairingLink? {
        guard url.scheme?.lowercased() == InAppDeepLink.scheme,
              (url.host ?? "").lowercased() == "pair" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard let host = value("host"), !host.isEmpty else { return nil }
        let port = Int(value("port") ?? "") ?? PrivateAgentLAN.bridgePort
        if let raw = value("code"), let code = BridgeConnectionManager.normalizePairingCode(raw) {
            return .code(host: host, port: port, code: code)
        }
        if let pairing = BridgePairing.fromDeepLink(url) {
            return .token(pairing)
        }
        return nil
    }
}

/// Persists bridge settings. Host/port/flags live in UserDefaults; tokens
/// live only in the `secrets` store (the Keychain in the app). Tokens left
/// in UserDefaults by older builds are migrated and deleted on load/save.
public enum BridgePairingStore {
    public static let hostKey = "PrivateAgent.bridgeHost"
    public static let portKey = "PrivateAgent.bridgePort"
    /// Legacy UserDefaults key (pre-Keychain). Only read for migration.
    public static let tokenKey = "PrivateAgent.bridgeToken"
    public static let wdaHostKey = "PrivateAgent.wdaHost"
    public static let wdaPortKey = "PrivateAgent.wdaPort"
    /// Legacy UserDefaults key (pre-Keychain). Only read for migration.
    public static let wdaTokenKey = "PrivateAgent.wdaToken"
    public static let macAssistedKey = "PrivateAgent.enableMacAssisted"
    public static let wdaEnabledKey = "PrivateAgent.enableWebDriverAgent"

    public static func save(
        _ pairing: BridgePairing,
        defaults: UserDefaults = .standard,
        secrets: any CredentialStore = CredentialStores.secure()
    ) {
        defaults.set(pairing.host, forKey: hostKey)
        defaults.set(String(pairing.port), forKey: portKey)
        defaults.set(pairing.wdaHost, forKey: wdaHostKey)
        defaults.set(String(pairing.wdaPort), forKey: wdaPortKey)
        defaults.set(pairing.enableMacAssisted, forKey: macAssistedKey)
        defaults.set(pairing.enableWebDriverAgent, forKey: wdaEnabledKey)
        if !pairing.token.isEmpty {
            try? secrets.set(pairing.token, forKey: CredentialKeys.bridgeToken(host: pairing.host, port: pairing.port))
        }
        if !pairing.wdaToken.isEmpty {
            try? secrets.set(pairing.wdaToken, forKey: CredentialKeys.wdaToken(host: pairing.wdaHost, port: pairing.wdaPort))
        }
        defaults.removeObject(forKey: tokenKey)
        defaults.removeObject(forKey: wdaTokenKey)
    }

    /// Moves tokens that older builds stored in UserDefaults into `secrets`.
    public static func migrateLegacyTokens(
        defaults: UserDefaults = .standard,
        secrets: any CredentialStore = CredentialStores.secure()
    ) {
        let host = defaults.string(forKey: hostKey) ?? PrivateAgentLAN.macHost
        let port = Int(defaults.string(forKey: portKey) ?? "") ?? PrivateAgentLAN.bridgePort
        if let legacy = defaults.string(forKey: tokenKey) {
            if !legacy.isEmpty {
                try? secrets.set(legacy, forKey: CredentialKeys.bridgeToken(host: host, port: port))
            }
            defaults.removeObject(forKey: tokenKey)
        }
        let wdaHost = defaults.string(forKey: wdaHostKey) ?? "127.0.0.1"
        let wdaPort = Int(defaults.string(forKey: wdaPortKey) ?? "") ?? 8101
        if let legacy = defaults.string(forKey: wdaTokenKey) {
            if !legacy.isEmpty {
                try? secrets.set(legacy, forKey: CredentialKeys.wdaToken(host: wdaHost, port: wdaPort))
            }
            defaults.removeObject(forKey: wdaTokenKey)
        }
    }

    public static func load(
        defaults: UserDefaults = .standard,
        secrets: any CredentialStore = CredentialStores.secure(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BridgePairing? {
        if let env = BridgePairing.fromEnvironment(environment) {
            return env
        }
        migrateLegacyTokens(defaults: defaults, secrets: secrets)
        guard let host = defaults.string(forKey: hostKey), !host.isEmpty else { return nil }
        let port = Int(defaults.string(forKey: portKey) ?? "") ?? PrivateAgentLAN.bridgePort
        guard let token = secrets.string(forKey: CredentialKeys.bridgeToken(host: host, port: port)), !token.isEmpty else {
            return nil
        }
        let wdaHost = defaults.string(forKey: wdaHostKey) ?? "127.0.0.1"
        let wdaPort = Int(defaults.string(forKey: wdaPortKey) ?? "") ?? 8101
        return BridgePairing(
            host: host,
            port: port,
            token: token,
            wdaHost: wdaHost,
            wdaPort: wdaPort,
            wdaToken: secrets.string(forKey: CredentialKeys.wdaToken(host: wdaHost, port: wdaPort)) ?? "",
            enableMacAssisted: defaults.object(forKey: macAssistedKey) as? Bool ?? true,
            enableWebDriverAgent: defaults.object(forKey: wdaEnabledKey) as? Bool ?? false
        )
    }
}

public struct BridgePairingDiagnosis: Sendable, Equatable {
    public var pairingFound: Bool
    public var onDarwin: Bool
    public var selfHostedWorkerAvailable: Bool
    public var recommendedModes: [AutomationMode]
    public var nextAction: String
    public var canDriveIPhoneFromThisProcess: Bool

    public init(
        pairingFound: Bool,
        onDarwin: Bool,
        selfHostedWorkerAvailable: Bool,
        recommendedModes: [AutomationMode],
        nextAction: String,
        canDriveIPhoneFromThisProcess: Bool
    ) {
        self.pairingFound = pairingFound
        self.onDarwin = onDarwin
        self.selfHostedWorkerAvailable = selfHostedWorkerAvailable
        self.recommendedModes = recommendedModes
        self.nextAction = nextAction
        self.canDriveIPhoneFromThisProcess = canDriveIPhoneFromThisProcess
    }
}

public enum BridgePairingDoctor {
    public static func diagnose(
        pairing: BridgePairing?,
        onDarwin: Bool,
        selfHostedWorkerAvailable: Bool = false,
        bridgeReachable: Bool? = nil
    ) -> BridgePairingDiagnosis {
        let modes = pairing?.recommendedModes() ?? [.inApp, .appIntents, .shortcuts]
        if pairing == nil && !onDarwin && !selfHostedWorkerAvailable {
            return BridgePairingDiagnosis(
                pairingFound: false,
                onDarwin: onDarwin,
                selfHostedWorkerAvailable: false,
                recommendedModes: modes,
                nextAction: "This Cloud Agent cannot reach \(PrivateAgentLAN.macHost):\(PrivateAgentLAN.sshPort). From a machine on that LAN: ssh -p \(PrivateAgentLAN.sshPort) \(PrivateAgentLAN.sshUser)@\(PrivateAgentLAN.macHost) then ./Scripts/start-mac-bridge.sh, and enter the printed pairing code under Check Bridge on the iPhone.",
                canDriveIPhoneFromThisProcess: false
            )
        }
        if pairing == nil && onDarwin {
            return BridgePairingDiagnosis(
                pairingFound: false,
                onDarwin: true,
                selfHostedWorkerAvailable: selfHostedWorkerAvailable,
                recommendedModes: modes,
                nextAction: "Run Scripts/start-mac-bridge.sh on this Mac, grant Accessibility, and keep iPhone Mirroring frontmost.",
                canDriveIPhoneFromThisProcess: false
            )
        }
        if let pairing, bridgeReachable == false {
            return BridgePairingDiagnosis(
                pairingFound: true,
                onDarwin: onDarwin,
                selfHostedWorkerAvailable: selfHostedWorkerAvailable,
                recommendedModes: pairing.recommendedModes(),
                nextAction: "Pairing exists but \(pairing.host):\(pairing.port) is not reachable. Confirm the Mac helper is listening and the phone is on the same network.",
                canDriveIPhoneFromThisProcess: false
            )
        }
        if let pairing {
            return BridgePairingDiagnosis(
                pairingFound: true,
                onDarwin: onDarwin,
                selfHostedWorkerAvailable: selfHostedWorkerAvailable,
                recommendedModes: pairing.recommendedModes(),
                nextAction: "Mac-assisted mode is configured. Open Agent Mode, confirm the bridge health check, and run a goal while iPhone Mirroring is frontmost.",
                canDriveIPhoneFromThisProcess: onDarwin || selfHostedWorkerAvailable
            )
        }
        return BridgePairingDiagnosis(
            pairingFound: false,
            onDarwin: onDarwin,
            selfHostedWorkerAvailable: selfHostedWorkerAvailable,
            recommendedModes: modes,
            nextAction: "Start a Cursor self-hosted worker on the MacBook if this Cloud Agent should drive the Mac helper.",
            canDriveIPhoneFromThisProcess: false
        )
    }
}
