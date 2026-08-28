import Testing
@testable import AetherEngine

@Suite("Dynamic CoreMedia attachment keys")
struct DynamicCoreMediaAttachmentKeysTests {
    @Test("a missing runtime constant remains an optional capability")
    func missingSymbol() {
        #expect(
            DynamicCoreMediaAttachmentKeys.resolve(
                symbolName: "IPTVXMissingCoreMediaAttachmentKey"
            ) == nil
        )
    }

    @Test("the current runtime exposes the HDR10+ metadata key")
    func hdr10PlusKey() {
        #expect(DynamicCoreMediaAttachmentKeys.hdr10PlusPerFrameData() != nil)
    }
}
