import Foundation
import Testing
@testable import AetherEngine

struct DisplayCapabilitiesTests {

    @Test("AE#493: an eligible on-demand EDR display can present HDR10 and HLG")
    func eligibleDisplayPresentsPQAndHLG() {
        let caps = DisplayCapabilities.onDemandEDRDisplay(hdrEligible: true)
        #expect(caps.supportsHDR)
        #expect(caps.supportsHDR10)
        #expect(caps.supportsHLG)
    }

    @Test("AE#493: eligibility says nothing about Dolby Vision, so it stays unclaimed")
    func eligibilityDoesNotClaimDolbyVision() {
        #expect(DisplayCapabilities.onDemandEDRDisplay(hdrEligible: true).supportsDolbyVision == false)
    }

    @Test("AE#493: an ineligible display claims nothing, which is what the SDR-only Mac needs")
    func ineligibleDisplayClaimsNothing() {
        let caps = DisplayCapabilities.onDemandEDRDisplay(hdrEligible: false)
        #expect(caps.supportsHDR == false)
        #expect(caps.supportsHDR10 == false)
        #expect(caps.supportsHLG == false)
        #expect(caps.supportsDolbyVision == false)
    }
}
