import CoreFoundation
import Darwin

/// Resolves optional CoreMedia attachment keys without hard-linking symbols missing from older OS releases.
enum DynamicCoreMediaAttachmentKeys {
    /// Cached runtime lookup so frame rendering does not reopen the process image per frame.
    nonisolated(unsafe) private static let hdr10PlusPerFrameDataKey = resolve(
        symbolName: "kCMSampleAttachmentKey_HDR10PlusPerFrameData"
    )

    /// The HDR10+ per-frame metadata key when the current CoreMedia runtime exports it.
    static func hdr10PlusPerFrameData() -> CFString? {
        hdr10PlusPerFrameDataKey
    }

    /// Resolves a CoreMedia `CFStringRef` constant from the current process at runtime.
    ///
    /// - Parameter symbolName: The exported CoreMedia symbol to resolve.
    /// - Returns: The referenced Core Foundation string, or `nil` when the OS does not export it.
    static func resolve(symbolName: String) -> CFString? {
        guard let processHandle = dlopen(nil, RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(processHandle) }

        return symbolName.withCString { name in
            guard let symbol = dlsym(processHandle, name) else {
                return nil
            }
            return symbol.assumingMemoryBound(to: CFString?.self).pointee
        }
    }
}
