import Foundation

struct ArchivePreviewSnapshot {
    let archiveURL: URL
    let items: [ArchiveItem]
    let availableColumns: [FileManagerColumn]
    let folderTypeID: String
    private let allRows: [ArchivePreviewRow]
    private let visibleRowsWithoutHiddenItems: [ArchivePreviewRow]
    private let allTreeNodes: [ArchivePreviewTreeNode]
    private let visibleTreeNodesWithoutHiddenItems: [ArchivePreviewTreeNode]
    private let allSummaryText: String
    private let visibleSummaryText: String

    init(archiveURL: URL,
         items: [ArchiveItem],
         entryProperties: [FileManagerArchiveEntryProperty],
         formatName: String?)
    {
        self.archiveURL = archiveURL
        self.items = items

        let columns = FileManagerColumn.archiveColumns(entryProperties: entryProperties)
        availableColumns = columns
        folderTypeID = FileManagerViewPreferences.archiveListViewFolderTypeID(formatName: formatName)

        let rows = ArchivePreviewPresentation.rows(for: items,
                                                   columns: columns)
        allRows = rows
        visibleRowsWithoutHiddenItems = rows.filter { !$0.isHidden }
        allTreeNodes = ArchivePreviewTreeBuilder.treeNodes(for: rows,
                                                           columns: columns)
        visibleTreeNodesWithoutHiddenItems = ArchivePreviewTreeBuilder.treeNodes(for: visibleRowsWithoutHiddenItems,
                                                                                 columns: columns)
        allSummaryText = ArchivePreviewPresentation.summaryText(for: allTreeNodes)
        visibleSummaryText = ArchivePreviewPresentation.summaryText(for: visibleTreeNodesWithoutHiddenItems)
    }

    func presentationRows(showHiddenItems: Bool) -> [ArchivePreviewRow] {
        showHiddenItems ? allRows : visibleRowsWithoutHiddenItems
    }

    func treeNodes(showHiddenItems: Bool) -> [ArchivePreviewTreeNode] {
        showHiddenItems ? allTreeNodes : visibleTreeNodesWithoutHiddenItems
    }

    func summaryText(showHiddenItems: Bool) -> String {
        showHiddenItems ? allSummaryText : visibleSummaryText
    }

    func visibleItems(showHiddenItems: Bool) -> [ArchiveItem] {
        presentationRows(showHiddenItems: showHiddenItems).map { items[$0.itemIndex] }
    }
}

struct ArchivePreviewSummary: Equatable {
    let fileCount: Int
    let folderCount: Int
    let fileSize: UInt64?
}

struct ArchivePreviewRow {
    let itemIndex: Int
    let path: String
    let pathParts: [String]
    let isHidden: Bool
    let isDirectory: Bool
    let uncompressedSize: UInt64?
    let nameText: String
    let iconKey: ArchivePreviewIconKey
    let columnTexts: [String: String]

    func text(for columnID: FileManagerColumnID) -> String {
        columnTexts[columnID.rawValue] ?? ""
    }
}

final class ArchivePreviewTreeNode: @unchecked Sendable {
    let row: ArchivePreviewRow
    let children: [ArchivePreviewTreeNode]
    let directoryID: ArchiveDirectoryID?

    init(row: ArchivePreviewRow,
         children: [ArchivePreviewTreeNode],
         directoryID: ArchiveDirectoryID? = nil)
    {
        self.row = row
        self.children = children
        self.directoryID = directoryID
    }

    func text(for columnID: FileManagerColumnID) -> String {
        if columnID == .name,
           let name = row.pathParts.last
        {
            return name
        }

        return row.text(for: columnID)
    }
}

enum ArchivePreviewIconKey: Hashable {
    case folder
    case fileExtension(String)
    case genericFile
}

enum ArchivePreviewLoadError: LocalizedError {
    case coordinationFailed(Error?)

    var errorDescription: String? {
        switch self {
        case let .coordinationFailed(error):
            if let error {
                SZL10n.string("app.quickLook.archivePreview.readErrorFormat",
                                                  error.localizedDescription)
            } else {
                SZL10n.string("app.quickLook.archivePreview.readError")
            }
        }
    }
}

enum ArchivePreviewLoader {
    static func loadArchiveContents(at archiveURL: URL) throws -> ArchivePreviewSnapshot {
        var coordinationError: NSError?
        var coordinatedResult: Result<ArchivePreviewSnapshot, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)

        coordinator.coordinate(readingItemAt: archiveURL,
                               options: [],
                               error: &coordinationError)
        { readableURL in
            coordinatedResult = Result {
                try loadCoordinatedArchiveContents(at: readableURL,
                                                   displayURL: archiveURL)
            }
        }

        if let coordinatedResult {
            return try coordinatedResult.get()
        }

        throw ArchivePreviewLoadError.coordinationFailed(coordinationError)
    }

    private static func loadCoordinatedArchiveContents(at readableURL: URL,
                                                       displayURL: URL) throws -> ArchivePreviewSnapshot
    {
        let didStartSecurityScope = readableURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                readableURL.stopAccessingSecurityScopedResource()
            }
        }

        let archive = SZArchive()
        try archive.open(atPath: readableURL.path, session: SZOperationSession())
        defer { archive.close() }

        let entries = try archive.entries(with: nil)
        let items = entries
            .map(ArchiveItem.init)
            .sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }

        return ArchivePreviewSnapshot(archiveURL: displayURL.standardizedFileURL,
                                      items: items,
                                      entryProperties: archive.entryProperties.map(FileManagerArchiveEntryProperty.init),
                                      formatName: archive.formatName)
    }
}

enum ArchivePreviewPresentation {
    static let hiddenAttributeMask = HiddenItemVisibility.hiddenAttributeMask

    static func rows(for items: [ArchiveItem],
                     columns: [FileManagerColumn]) -> [ArchivePreviewRow]
    {
        var builder = RowBuilder(columns: columns)
        return items.enumerated().map { index, item in
            builder.row(for: item, itemIndex: index)
        }
    }

    static func filteredItems(_ items: [ArchiveItem],
                              showHiddenItems: Bool) -> [ArchiveItem]
    {
        guard !showHiddenItems else { return items }
        return items.filter { !isHidden($0) }
    }

    static func isHidden(_ item: ArchiveItem) -> Bool {
        item.isHidden
    }

    static func isHidden(pathParts: [String],
                         attributes: UInt32 = 0) -> Bool
    {
        HiddenItemVisibility.isHidden(pathParts: pathParts,
                                      attributes: attributes)
    }

    static func summary(for items: [ArchiveItem]) -> ArchivePreviewSummary {
        summary(for: rows(for: items, columns: []))
    }

    static func summaryText(for items: [ArchiveItem]) -> String {
        let summary = summary(for: items)
        return summaryText(for: summary)
    }

    static func summary(for rows: [ArchivePreviewRow]) -> ArchivePreviewSummary {
        rows.reduce(ArchivePreviewSummary(fileCount: 0,
                                          folderCount: 0,
                                          fileSize: 0))
        { partialResult, row in
            adding(row, to: partialResult)
        }
    }

    static func summaryText(for rows: [ArchivePreviewRow]) -> String {
        summaryText(for: summary(for: rows))
    }

    static func summary(for treeNodes: [ArchivePreviewTreeNode]) -> ArchivePreviewSummary {
        // Iterative DFS so deep trees can't overflow the call stack.
        var summary = ArchivePreviewSummary(fileCount: 0,
                                            folderCount: 0,
                                            fileSize: 0)
        var stack = treeNodes
        while let node = stack.popLast() {
            summary = adding(node.row, to: summary)
            stack.append(contentsOf: node.children)
        }
        return summary
    }

    static func summaryText(for treeNodes: [ArchivePreviewTreeNode]) -> String {
        summaryText(for: summary(for: treeNodes))
    }

    private static func summaryText(for summary: ArchivePreviewSummary) -> String {
        let fileWord = summary.fileCount == 1
            ? SZL10n.string("app.fileManager.statusFile")
            : SZL10n.string("app.fileManager.statusFiles")
        let folderWord = summary.folderCount == 1
            ? SZL10n.string("app.fileManager.statusFolder")
            : SZL10n.string("app.fileManager.statusFolders")
        let counts = "\(summary.fileCount) \(fileWord), \(summary.folderCount) \(folderWord)"
        guard let fileSize = summary.fileSize else { return counts }
        return "\(counts) — \(fileSizeString(fileSize))"
    }

    private static func adding(_ row: ArchivePreviewRow,
                               to summary: ArchivePreviewSummary) -> ArchivePreviewSummary
    {
        if row.isDirectory {
            return ArchivePreviewSummary(fileCount: summary.fileCount,
                                         folderCount: summary.folderCount + 1,
                                         fileSize: summary.fileSize)
        }

        return ArchivePreviewSummary(fileCount: summary.fileCount + 1,
                                     folderCount: summary.folderCount,
                                     fileSize: addingFileSize(summary.fileSize, row.uncompressedSize))
    }

    private static func addingFileSize(_ lhs: UInt64?,
                                       _ rhs: UInt64?) -> UInt64?
    {
        guard let lhs, let rhs else { return nil }
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    static func nameText(for item: ArchiveItem) -> String {
        item.path.isEmpty ? item.name : item.path
    }

    private static func normalizedFileExtension(for item: ArchiveItem) -> String {
        item.fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func iconKey(for item: ArchiveItem,
                                fileExtension: String) -> ArchivePreviewIconKey
    {
        if item.isDirectory {
            return .folder
        }

        guard !fileExtension.isEmpty else {
            return .genericFile
        }

        return .fileExtension(fileExtension.lowercased())
    }

    private static func fileSizeString(_ size: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: size),
                                  countStyle: .file)
    }

    private struct RowBuilder {
        private let columns: [FileManagerColumn]
        private let dateFormatter = ArchivePreviewPreferences.makeListDateFormatter()

        init(columns: [FileManagerColumn]) {
            self.columns = columns
        }

        mutating func row(for item: ArchiveItem,
                          itemIndex: Int) -> ArchivePreviewRow
        {
            let fileExtension = ArchivePreviewPresentation.normalizedFileExtension(for: item)

            return ArchivePreviewRow(itemIndex: itemIndex,
                                     path: item.path,
                                     pathParts: item.pathParts,
                                     isHidden: ArchivePreviewPresentation.isHidden(item),
                                     isDirectory: item.isDirectory,
                                     uncompressedSize: item.size,
                                     nameText: ArchivePreviewPresentation.nameText(for: item),
                                     iconKey: ArchivePreviewPresentation.iconKey(for: item,
                                                                                 fileExtension: fileExtension),
                                     columnTexts: columnTexts(for: item))
        }

        private func columnTexts(for item: ArchiveItem) -> [String: String] {
            Dictionary(uniqueKeysWithValues: columns.map { column in
                (column.id.rawValue,
                 ArchiveItemPresentation.listCellText(for: item,
                                                      columnID: column.id,
                                                      dateFormatter: dateFormatter,
                                                      nameStyle: .path))
            })
        }
    }
}

enum ArchivePreviewTreeBuilder {
    static func treeNodes(for rows: [ArchivePreviewRow],
                          columns: [FileManagerColumn]) -> [ArchivePreviewTreeNode]
    {
        let rowsByItemIndex = Dictionary(uniqueKeysWithValues: rows.map { ($0.itemIndex, $0) })
        let hierarchy = ArchiveHierarchy(records: rows.map {
            ArchiveHierarchyRecord(itemIndex: $0.itemIndex,
                                   pathParts: $0.pathParts,
                                   isDirectory: $0.isDirectory)
        })

        var directoryOrder: [ArchiveHierarchy.Directory] = []
        var stack = hierarchy.root.childDirectories
        while let directory = stack.popLast() {
            directoryOrder.append(directory)
            stack.append(contentsOf: directory.childDirectories)
        }

        let dateFormatter = ArchivePreviewPreferences.makeListDateFormatter()
        var finalizedDirectories: [ObjectIdentifier: ArchivePreviewTreeNode] = [:]
        for directory in directoryOrder.reversed() {
            let row = directory.representativeItemIndex
                .flatMap { rowsByItemIndex[$0] }
                ?? syntheticDirectoryRow(for: directory,
                                         columns: columns,
                                         dateFormatter: dateFormatter)
            finalizedDirectories[ObjectIdentifier(directory)] = ArchivePreviewTreeNode(
                row: row,
                children: finalizedChildren(
                    of: directory,
                    rowsByItemIndex: rowsByItemIndex,
                    finalizedDirectories: finalizedDirectories,
                ),
                directoryID: directory.id,
            )
        }

        return finalizedChildren(
            of: hierarchy.root,
            rowsByItemIndex: rowsByItemIndex,
            finalizedDirectories: finalizedDirectories,
        )
    }

    private static func finalizedChildren(
        of directory: ArchiveHierarchy.Directory,
        rowsByItemIndex: [Int: ArchivePreviewRow],
        finalizedDirectories: [ObjectIdentifier: ArchivePreviewTreeNode],
    ) -> [ArchivePreviewTreeNode] {
        let directories = directory.childDirectories.compactMap {
            finalizedDirectories[ObjectIdentifier($0)]
        }
        let entries = directory.terminalItemIndices.compactMap { itemIndex in
            rowsByItemIndex[itemIndex].map {
                ArchivePreviewTreeNode(row: $0,
                                       children: [])
            }
        }
        return (directories + entries).sorted(by: sortTreeNodes)
    }

    private static func syntheticDirectoryRow(
        for directory: ArchiveHierarchy.Directory,
        columns: [FileManagerColumn],
        dateFormatter: DateFormatter,
    ) -> ArchivePreviewRow {
        let path = directory.pathParts.joined(separator: "/")
        let item = ArchiveItem(index: -1,
                               path: path,
                               pathParts: directory.pathParts,
                               name: directory.name,
                               size: 0,
                               packedSize: 0,
                               modifiedDate: nil,
                               createdDate: nil,
                               accessedDate: nil,
                               crc: 0,
                               isDirectory: true,
                               isEncrypted: false,
                               isAnti: false,
                               method: "",
                               attributes: 0,
                               position: 0,
                               block: 0,
                               comment: "")
        let columnTexts = Dictionary(uniqueKeysWithValues: columns.map { column in
            (column.id.rawValue,
             ArchiveItemPresentation.listCellText(for: item,
                                                  columnID: column.id,
                                                  dateFormatter: dateFormatter,
                                                  nameStyle: .path))
        })

        return ArchivePreviewRow(itemIndex: -1,
                                 path: path,
                                 pathParts: directory.pathParts,
                                 isHidden: ArchivePreviewPresentation.isHidden(pathParts: directory.pathParts),
                                 isDirectory: true,
                                 uncompressedSize: nil,
                                 nameText: directory.name,
                                 iconKey: .folder,
                                 columnTexts: columnTexts)
    }

    private static func sortTreeNodes(_ lhs: ArchivePreviewTreeNode,
                                      _ rhs: ArchivePreviewTreeNode) -> Bool
    {
        if lhs.row.isDirectory != rhs.row.isDirectory {
            return lhs.row.isDirectory && !rhs.row.isDirectory
        }

        let nameResult = lhs.row.nameText.localizedStandardCompare(rhs.row.nameText)
        if nameResult != .orderedSame {
            return nameResult == .orderedAscending
        }

        let pathResult = lhs.row.path.localizedStandardCompare(rhs.row.path)
        if pathResult != .orderedSame {
            return pathResult == .orderedAscending
        }

        return lhs.row.itemIndex < rhs.row.itemIndex
    }
}
