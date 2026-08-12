import AppKit

@MainActor
final class ShichiZipDocumentController: NSDocumentController {
    override func noteNewRecentDocumentURL(_: URL) {
        // ArchiveDocument is only a Launch Services shim. Record the archive
        // after the file manager has actually opened it instead.
    }

    fileprivate func recordRecentArchive(_ url: URL) {
        guard SZSettings.bool(.rememberRecentArchives) else { return }
        precondition(url.isFileURL, "Recent archives must be local file URLs")
        super.noteNewRecentDocumentURL(url.standardizedFileURL)
    }
}

@MainActor
enum RecentArchiveHistory {
    static var recentArchiveURLs: [URL] {
        documentController.recentDocumentURLs
    }

    static func recordOpenedArchive(_ url: URL) {
        documentController.recordRecentArchive(url)
    }

    static func clear(_ sender: Any? = nil) {
        documentController.clearRecentDocuments(sender)
    }

    private static var documentController: ShichiZipDocumentController {
        guard let controller = NSDocumentController.shared as? ShichiZipDocumentController else {
            preconditionFailure("ShichiZipDocumentController must be installed before document handling begins")
        }
        return controller
    }
}
