import Cocoa
import os.log

/// Launch Services integration shim.
/// Windows 7-Zip opens archives through the file-manager panel, so this document
/// class exists only to redirect archive opens into the unified file-manager UI.
class ArchiveDocument: NSDocument {
    private static let excludedTypeIdentifiers: Set<String> = [
        "public.data",
        "com.aone.keka-extraction",
    ]

    override class var autosavesInPlace: Bool {
        false
    }

    override class var readableTypes: [String] {
        guard let documentTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] else {
            return []
        }

        var readableTypeIdentifiers: [String] = []
        var seenTypeIdentifiers: Set<String> = []

        for documentType in documentTypes {
            guard let contentTypes = documentType["LSItemContentTypes"] as? [String] else {
                continue
            }

            for contentType in contentTypes where !excludedTypeIdentifiers.contains(contentType) {
                if seenTypeIdentifiers.insert(contentType).inserted {
                    readableTypeIdentifiers.append(contentType)
                }
            }
        }

        return readableTypeIdentifiers
    }

    /// Accept all types — let 7-Zip core detect format
    override class func isNativeType(_: String) -> Bool {
        true
    }

    override func makeWindowControllers() {
        // Redirect document opens to the unified file-manager surface.
        let appDelegate = NSApp.delegate as? AppDelegate
        appDelegate?.beginDeferredArchiveOpen()
        defer { appDelegate?.endDeferredArchiveOpen() }
        guard let url = fileURL else { return }
        appDelegate?.openArchiveInNewFileManager(url)
        close()
    }

    override func showWindows() {
        // Intentionally empty: archive windows are handled by the file manager.
    }

    override func read(from url: URL, ofType _: String) throws {
        #if DEBUG
            NSLog("[ShichiZip] Opening via document: %@ — will redirect to File Manager", url.path)
        #else
            // Keep user paths private in Release logs.
            os_log(.info, "[ShichiZip] Opening via document: %{private}@ — will redirect to File Manager",
                   url.path)
        #endif
        // Actual archive parsing happens when the file manager enters the archive.
    }
}
