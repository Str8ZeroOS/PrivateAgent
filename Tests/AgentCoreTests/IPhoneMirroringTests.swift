import Testing
@testable import AgentCore

@Suite("iPhone Mirroring observation source")
struct IPhoneMirroringTests {
    @Test("classifies the Mac iPhone Mirroring app")
    func classifiesMirroringApp() {
        #expect(IPhoneMirroring.isMirroringApp("iPhone Mirroring"))
        #expect(!IPhoneMirroring.isMirroringApp("Safari"))
        #expect(
            IPhoneMirroring.observationSource(frontmostApp: "iPhone Mirroring", mirroringEnabled: true)
                == .iphoneMirroring
        )
        #expect(
            IPhoneMirroring.observationSource(frontmostApp: "iPhone Mirroring", mirroringEnabled: false)
                == .macBridge
        )
        #expect(
            IPhoneMirroring.observationSource(frontmostApp: "Safari", mirroringEnabled: true)
                == .macBridge
        )
    }
}
