import Foundation

/// Honest Mac-side heuristic for the iPhone Mirroring window.
/// This is not an iOS AccessibilityService. It only classifies a Mac
/// frontmost-app name so the planner can treat mirrored iPhone UI as
/// an external observation source.
public enum IPhoneMirroring {
    public static func isMirroringApp(_ name: String) -> Bool {
        name.lowercased().contains("iphone mirroring")
    }

    public static func observationSource(frontmostApp: String, mirroringEnabled: Bool) -> ObservationSource {
        if mirroringEnabled && isMirroringApp(frontmostApp) {
            return .iphoneMirroring
        }
        return .macBridge
    }
}
