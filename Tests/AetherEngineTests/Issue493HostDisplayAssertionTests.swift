import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

/// AE#493 / AE#459: what the host asserts about a display the engine cannot observe.
///
/// The two issues are the same gap from two sides. macOS has no per-mode capability API at all
/// (`AVPlayer.availableHDRModes` is `API_UNAVAILABLE(macos)`), and on tvOS the panel-mode readout
/// answers only around a dynamic-range transition, which a panel parked in HDR never makes and which
/// one tvOS 27 box stopped answering entirely. Both are closed by letting the host claim it, and by
/// keeping a wrong claim cheap.
struct Issue493HostDisplayAssertionTests {

    private let stub = DisplayCapabilities(
        supportsHDR: false, supportsDolbyVision: false, supportsHDR10: false, supportsHLG: false)
    private let eligibleMac = DisplayCapabilities.onDemandEDRDisplay(hdrEligible: true)

    // MARK: - The capability assertion

    @Test("AE#493: the assertion claims Dolby Vision where nothing could observe it")
    func assertionClaimsDolbyVision() {
        #expect(eligibleMac.supportsDolbyVision == false)
        #expect(eligibleMac.assertingDolbyVision(true).supportsDolbyVision)
    }

    @Test("AE#493: HDR rides along, because a display presenting DV presents HDR")
    func assertionEntailsHDR() {
        #expect(stub.assertingDolbyVision(true).supportsHDR)
    }

    @Test("AE#493: HDR10 and HLG are not implied by a Dolby Vision claim")
    func assertionDoesNotInventTheOtherFlavours() {
        let asserted = stub.assertingDolbyVision(true)
        #expect(asserted.supportsHDR10 == false)
        #expect(asserted.supportsHLG == false)
    }

    @Test("AE#493: an assertion only ever adds, so false cannot hide an observed capability")
    func assertionNeverRemoves() {
        let dvPanel = DisplayCapabilities(
            supportsHDR: true, supportsDolbyVision: true, supportsHDR10: true, supportsHLG: true)
        #expect(dvPanel.assertingDolbyVision(false) == dvPanel)
        #expect(eligibleMac.assertingDolbyVision(false) == eligibleMac)
    }

    // MARK: - What the assertion changes about the source

    @Test("AE#493: a DV source on an asserted display keeps Dolby Vision instead of its base layer")
    func assertedDisplayKeepsDolbyVision() {
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_SMPTE2084,
            capabilities: eligibleMac) == .hdr10)
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_SMPTE2084,
            capabilities: eligibleMac.assertingDolbyVision(true)) == .dolbyVision)
    }

    @Test("AE#493: the all-false table is what collapsed a DV source to SDR")
    func stubTableCollapsesDolbyVisionToSDR() {
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_SMPTE2084, capabilities: stub) == .sdr)
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_ARIB_STD_B67, capabilities: stub) == .sdr)
    }

    @Test("AE#493: an HLG-base DV source falls to HLG, not to the PQ base")
    func hlgBaseFallsToHLG() {
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_ARIB_STD_B67,
            capabilities: eligibleMac) == .hlg)
    }

    /// The correction the reporter's measurement forced onto the split: the clamp returns early for
    /// anything that is not Dolby Vision, so the capability table never reached a plain HDR10 or HLG
    /// source at all. "Every PQ source plays as SDR" was the label branch, not this one.
    @Test("AE#493: the capability table never touches a source that is not Dolby Vision")
    func nonDVSourcesBypassTheTableEntirely() {
        for format in [VideoFormat.hdr10, .hlg, .sdr] {
            #expect(AetherEngine.effectiveVideoFormat(
                detected: format, baseTransfer: AVCOL_TRC_SMPTE2084, capabilities: stub) == format)
        }
    }

    /// Why `supportsHDR` rides along with the DV claim: without it the routing gate that decides
    /// master-vs-media would have sent the asserted DV session media-direct, and a DV source served
    /// through a bare media playlist is the HDR10 base layer, which is exactly what the assertion
    /// exists to stop.
    @Test("AE#493: an asserted display routes the DV master rather than the base layer")
    func assertedDisplayRoutesTheMaster() {
        let asserted = stub.assertingDolbyVision(true)
        #expect(HLSVideoEngine.resolveUseMasterPlaylist(
            videoRange: .pq, effectiveDvMode: true, panelIsInHDRMode: false,
            displaySupportsHDR: asserted.supportsHDR, hasNativeSubs: false,
            builtInPanelEngagesOnDemand: true, frameRateKnown: true))
        #expect(HLSVideoEngine.resolveUseMasterPlaylist(
            videoRange: .pq, effectiveDvMode: true, panelIsInHDRMode: false,
            displaySupportsHDR: stub.supportsHDR, hasNativeSubs: false,
            builtInPanelEngagesOnDemand: true, frameRateKnown: true) == false)
    }

    // MARK: - The panel-mode assertion (AE#459)

    @Test("AE#459: the host assertion is an OR term over the readout, not a replacement")
    func panelAssertionIsAnORTerm() {
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: true, criteriaReadout: false))
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: false, criteriaReadout: true))
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: true, criteriaReadout: true))
    }

    @Test("AE#459: asserting nothing leaves the readout in charge, which is the shipping default")
    func noAssertionKeepsTheReadout() {
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: false, criteriaReadout: false) == false)
        #expect(LoadOptions().panelIsInHDRMode == false)
    }

    @Test("AE#459: a suppressed-criteria session has no readout, so the assertion is the whole answer")
    func suppressedSessionRestsOnTheAssertion() {
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: true, criteriaReadout: nil))
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: false, criteriaReadout: nil) == false)
    }

    // MARK: - The option itself

    @Test("AE#493: the DV assertion is off by default, so an unchanged host is unchanged")
    func assertionDefaultsOff() {
        #expect(LoadOptions().panelPresentsDolbyVision == false)
    }

    @Test("AE#493: two option sets differing only in the assertion are not equal")
    func assertionParticipatesInEquality() {
        #expect(LoadOptions(panelPresentsDolbyVision: true) != LoadOptions(panelPresentsDolbyVision: false))
    }

    /// AE#460: the assertion is a correction, not an identity. A host that learns the display does DV
    /// after the session started can say so without restarting the item.
    @Test("AE#493: the assertion is correctable mid-session")
    func assertionIsCorrectable() {
        #expect(SessionOptionCorrection.knownFields.contains("panelPresentsDolbyVision"))
        #expect(SessionOptionCorrection.loadIdentityFields.contains("panelPresentsDolbyVision") == false)
        let corrected = SessionOptionCorrection.changedFields(
            from: LoadOptions(), to: LoadOptions(panelPresentsDolbyVision: true))
        #expect(corrected == ["panelPresentsDolbyVision"])
        #expect(SessionOptionCorrection.refusedFields(
            from: LoadOptions(), to: LoadOptions(panelPresentsDolbyVision: true)).isEmpty)
    }
}
