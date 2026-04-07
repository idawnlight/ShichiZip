import Cocoa

/// Launch Services integration shim.
/// Windows 7-Zip opens archives through the file-manager panel, so this document
/// class exists only to redirect archive opens into the unified file-manager UI.
class ArchiveDocument: NSDocument {

    override class var autosavesInPlace: Bool { false }
    override class var readableTypes: [String] {
        [
            "org.7-zip.7-zip-archive",
            "public.zip-archive",
            "public.tar-archive",
            "org.gnu.gnu-zip-archive",
            "public.bzip2-archive",
            "org.tukaani.xz-archive",
            "com.rarlab.rar-archive",
            "public.iso-image",
            "com.apple.disk-image-udif",
            "public.archive",
            "public.data",
        ]
    }

    // Accept all types — let 7-Zip core detect format
    override class func isNativeType(_ type: String) -> Bool {
        return true
    }

    override func makeWindowControllers() {
        // Redirect document opens to the unified file-manager surface.
        let appDelegate = NSApp.delegate as? AppDelegate
        appDelegate?.beginDeferredArchiveOpen()
        DispatchQueue.main.async { [weak self] in
            defer { appDelegate?.endDeferredArchiveOpen() }
            guard let self, let url = self.fileURL else { return }
            appDelegate?.openArchiveInNewFileManager(url)
            self.close()
        }
    }

    override func showWindows() {
        // Intentionally empty: archive windows are handled by the file manager.
    }

    override func read(from url: URL, ofType typeName: String) throws {
        NSLog("[ShichiZip] Opening via document: %@ — will redirect to File Manager", url.path)
        // Actual archive parsing happens when the file manager enters the archive.
    }
}
