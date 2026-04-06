import Cocoa

class ArchiveDocument: NSDocument {

    private(set) var archive: SZArchive?
    private(set) var entries: [ArchiveItem] = []
    private(set) var treeRoot: [ArchiveTreeNode] = []
    private(set) var formatName: String = ""

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
        let wc = ArchiveWindowController()
        addWindowController(wc)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        let arch = SZArchive()

        try arch.open(atPath: url.path)

        self.archive = arch
        self.formatName = arch.formatName ?? "Unknown"

        // Load entries
        let szEntries = arch.entries()
        self.entries = szEntries.map { ArchiveItem(from: $0) }
        self.treeRoot = ArchiveTreeNode.buildTree(from: entries)
    }

    // MARK: - Operations

    func extractAll(to destinationURL: URL, password: String? = nil,
                    progress: SZProgressDelegate?) throws {
        guard let archive = archive else {
            throw NSError(domain: "SZArchiveErrorDomain", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "No archive is open"])
        }

        let settings = SZExtractionSettings()
        settings.password = password

        try archive.extract(toPath: destinationURL.path,
                            settings: settings,
                            progress: progress)
    }

    func extractEntries(indices: [Int], to destinationURL: URL, password: String? = nil,
                        progress: SZProgressDelegate?) throws {
        guard let archive = archive else {
            throw NSError(domain: "SZArchiveErrorDomain", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "No archive is open"])
        }

        let settings = SZExtractionSettings()
        settings.password = password

        let indexNumbers = indices.map { NSNumber(value: $0) }
        try archive.extractEntries(indexNumbers,
                                   toPath: destinationURL.path,
                                   settings: settings,
                                   progress: progress)
    }

    func testArchive(progress: SZProgressDelegate?) throws {
        guard let archive = archive else {
            throw NSError(domain: "SZArchiveErrorDomain", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "No archive is open"])
        }

        try archive.test(withProgress: progress)
    }

    override func close() {
        archive?.close()
        archive = nil
        super.close()
    }
}
