import Foundation

struct ArchivePreviewSnapshot {
    let archiveURL: URL
    let items: [ArchiveItem]
    let availableColumns: [ArchivePreviewColumn]
    let folderTypeID: String
    private let allRows: [ArchivePreviewRow]
    private let visibleRowsWithoutHiddenItems: [ArchivePreviewRow]
    private let allTreeNodes: [ArchivePreviewTreeNode]
    private let visibleTreeNodesWithoutHiddenItems: [ArchivePreviewTreeNode]
    private let allSummaryText: String
    private let visibleSummaryText: String

    init(archiveURL: URL,
         items: [ArchiveItem],
         entryProperties: [ArchivePreviewEntryProperty],
         formatName: String?)
    {
        self.archiveURL = archiveURL
        self.items = items

        let columns = ArchivePreviewColumn.archiveColumns(entryProperties: entryProperties)
        availableColumns = columns
        folderTypeID = ArchivePreviewColumnPreferences.archiveFolderTypeID(formatName: formatName)

        let rows = ArchivePreviewPresentation.rows(for: items,
                                                   columns: columns)
        allRows = rows
        visibleRowsWithoutHiddenItems = rows.filter { !$0.isHidden }
        allTreeNodes = ArchivePreviewTreeBuilder.treeNodes(for: rows,
                                                           columns: columns)
        visibleTreeNodesWithoutHiddenItems = ArchivePreviewTreeBuilder.treeNodes(for: rows.filter { !$0.isHidden },
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

    func text(for columnID: ArchivePreviewColumnID) -> String {
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

    func text(for columnID: ArchivePreviewColumnID) -> String {
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

struct ArchivePreviewColumnID: RawRepresentable, Hashable, Codable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    static let name = Self(rawValue: "name")
    static let size = Self(rawValue: "size")
    static let packedSize = Self(rawValue: "packedSize")
    static let modified = Self(rawValue: "modified")
    static let created = Self(rawValue: "created")
    static let accessed = Self(rawValue: "accessed")
    static let changed = Self(rawValue: "changed")
    static let attributes = Self(rawValue: "attributes")
    static let encrypted = Self(rawValue: "encrypted")
    static let anti = Self(rawValue: "anti")
    static let method = Self(rawValue: "method")
    static let crc = Self(rawValue: "crc")
    static let block = Self(rawValue: "block")
    static let position = Self(rawValue: "position")
    static let comment = Self(rawValue: "comment")
    static let inode = Self(rawValue: "inode")
    static let links = Self(rawValue: "links")
}

struct ArchivePreviewEntryProperty: Equatable {
    let id: ArchivePreviewColumnID
    let titleKey: String?
    let title: String
    let valueType: UInt

    init(id: ArchivePreviewColumnID,
         titleKey: String?,
         title: String,
         valueType: UInt)
    {
        self.id = id
        self.titleKey = titleKey
        self.title = title
        self.valueType = valueType
    }

    init(_ property: SZArchiveEntryProperty) {
        self.init(id: ArchivePreviewColumnID(rawValue: property.key),
                  titleKey: property.titleKey,
                  title: property.title,
                  valueType: UInt(property.valueType))
    }
}

enum ArchivePreviewColumnAlignment {
    case left
    case right
}

enum ArchivePreviewColumnTextStyle {
    case standard
    case tabularNumbers
    case fixedWidth
}

struct ArchivePreviewColumn: Equatable {
    let id: ArchivePreviewColumnID
    let titleKey: String?
    let titleFallback: String
    let width: CGFloat
    let minWidth: CGFloat
    let defaultVisible: Bool
    let alignment: ArchivePreviewColumnAlignment
    let textStyle: ArchivePreviewColumnTextStyle

    var title: String {
        guard let titleKey else { return titleFallback }
        let localizedTitle = ArchivePreviewLocalization.string(titleKey)
        return localizedTitle == titleKey ? titleFallback : localizedTitle
    }

    static func archiveColumns(entryProperties: [ArchivePreviewEntryProperty]) -> [ArchivePreviewColumn] {
        var columns: [ArchivePreviewColumn] = []
        var seenIDs = Set<ArchivePreviewColumnID>()

        func appendColumn(for property: ArchivePreviewEntryProperty) {
            guard seenIDs.insert(property.id).inserted else { return }
            columns.append(column(for: property))
        }

        appendColumn(for: ArchivePreviewEntryProperty(id: .name,
                                                      titleKey: "column.name",
                                                      title: "Name",
                                                      valueType: ArchivePreviewVariantType.bstr))
        for property in entryProperties where property.id != .name {
            appendColumn(for: property)
        }

        return columns
    }

    private static func knownDefinition(for id: ArchivePreviewColumnID) -> ArchivePreviewColumn? {
        switch id.rawValue {
        case ArchivePreviewColumnID.name.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.name",
                                 titleFallback: "Name",
                                 width: 250,
                                 minWidth: 100,
                                 defaultVisible: true,
                                 alignment: .left,
                                 textStyle: .standard)
        case ArchivePreviewColumnID.size.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.size",
                                 titleFallback: "Size",
                                 width: 80,
                                 minWidth: 50,
                                 defaultVisible: true,
                                 alignment: .right,
                                 textStyle: .tabularNumbers)
        case ArchivePreviewColumnID.packedSize.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.packedSize",
                                 titleFallback: "Packed Size",
                                 width: 100,
                                 minWidth: 70,
                                 defaultVisible: true,
                                 alignment: .right,
                                 textStyle: .tabularNumbers)
        case ArchivePreviewColumnID.modified.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.modified",
                                 titleFallback: "Modified",
                                 width: 180,
                                 minWidth: 80,
                                 defaultVisible: true,
                                 alignment: .left,
                                 textStyle: .tabularNumbers)
        case ArchivePreviewColumnID.created.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.created",
                                 titleFallback: "Created",
                                 width: 180,
                                 minWidth: 80,
                                 defaultVisible: true,
                                 alignment: .left,
                                 textStyle: .tabularNumbers)
        case ArchivePreviewColumnID.accessed.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.accessed",
                                 titleFallback: "Accessed",
                                 width: 180,
                                 minWidth: 80,
                                 defaultVisible: true,
                                 alignment: .left,
                                 textStyle: .tabularNumbers)
        case ArchivePreviewColumnID.changed.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.changed",
                                 titleFallback: "Metadata Changed",
                                 width: 180,
                                 minWidth: 80,
                                 defaultVisible: true,
                                 alignment: .left,
                                 textStyle: .tabularNumbers)
        case ArchivePreviewColumnID.attributes.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.attributes",
                                 titleFallback: "Attributes",
                                 width: 100,
                                 minWidth: 70,
                                 defaultVisible: true,
                                 alignment: .right,
                                 textStyle: .fixedWidth)
        case ArchivePreviewColumnID.encrypted.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.encrypted",
                                 titleFallback: "Encrypted",
                                 width: 80,
                                 minWidth: 60,
                                 defaultVisible: true,
                                 alignment: .right,
                                 textStyle: .standard)
        case ArchivePreviewColumnID.anti.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.anti",
                                 titleFallback: "Anti",
                                 width: 70,
                                 minWidth: 50,
                                 defaultVisible: true,
                                 alignment: .right,
                                 textStyle: .standard)
        case ArchivePreviewColumnID.method.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.method",
                                 titleFallback: "Method",
                                 width: 120,
                                 minWidth: 70,
                                 defaultVisible: true,
                                 alignment: .left,
                                 textStyle: .standard)
        case ArchivePreviewColumnID.crc.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.crc",
                                 titleFallback: "CRC",
                                 width: 90,
                                 minWidth: 70,
                                 defaultVisible: true,
                                 alignment: .right,
                                 textStyle: .fixedWidth)
        case ArchivePreviewColumnID.block.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.block",
                                 titleFallback: "Block",
                                 width: 70,
                                 minWidth: 50,
                                 defaultVisible: true,
                                 alignment: .right,
                                 textStyle: .tabularNumbers)
        case ArchivePreviewColumnID.position.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.position",
                                 titleFallback: "Position",
                                 width: 100,
                                 minWidth: 70,
                                 defaultVisible: true,
                                 alignment: .right,
                                 textStyle: .tabularNumbers)
        case ArchivePreviewColumnID.comment.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.comment",
                                 titleFallback: "Comment",
                                 width: 160,
                                 minWidth: 80,
                                 defaultVisible: true,
                                 alignment: .left,
                                 textStyle: .standard)
        case ArchivePreviewColumnID.inode.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.inode",
                                 titleFallback: "iNode",
                                 width: 100,
                                 minWidth: 70,
                                 defaultVisible: true,
                                 alignment: .right,
                                 textStyle: .tabularNumbers)
        case ArchivePreviewColumnID.links.rawValue:
            ArchivePreviewColumn(id: id,
                                 titleKey: "column.links",
                                 titleFallback: "Links",
                                 width: 70,
                                 minWidth: 50,
                                 defaultVisible: true,
                                 alignment: .right,
                                 textStyle: .tabularNumbers)
        default:
            nil
        }
    }

    private static func column(for property: ArchivePreviewEntryProperty) -> ArchivePreviewColumn {
        if let knownColumn = knownDefinition(for: property.id) {
            return knownColumn
        }

        let rightAligned = isRightAligned(valueType: property.valueType)
        return ArchivePreviewColumn(id: property.id,
                                    titleKey: property.titleKey,
                                    titleFallback: property.title,
                                    width: property.id == .name ? 250 : 100,
                                    minWidth: property.id == .name ? 100 : 50,
                                    defaultVisible: true,
                                    alignment: rightAligned ? .right : .left,
                                    textStyle: textStyle(for: property))
    }

    private static func isRightAligned(valueType: UInt) -> Bool {
        switch valueType {
        case ArchivePreviewVariantType.ui1, ArchivePreviewVariantType.i2, ArchivePreviewVariantType.ui2,
             ArchivePreviewVariantType.i4, ArchivePreviewVariantType.ui4, ArchivePreviewVariantType.int,
             ArchivePreviewVariantType.uint, ArchivePreviewVariantType.i8, ArchivePreviewVariantType.ui8,
             ArchivePreviewVariantType.bool:
            true
        default:
            false
        }
    }

    private static func textStyle(for property: ArchivePreviewEntryProperty) -> ArchivePreviewColumnTextStyle {
        switch property.valueType {
        case ArchivePreviewVariantType.filetime, ArchivePreviewVariantType.ui1, ArchivePreviewVariantType.i2,
             ArchivePreviewVariantType.ui2, ArchivePreviewVariantType.i4, ArchivePreviewVariantType.ui4,
             ArchivePreviewVariantType.int, ArchivePreviewVariantType.uint, ArchivePreviewVariantType.i8,
             ArchivePreviewVariantType.ui8, ArchivePreviewVariantType.bool:
            .tabularNumbers
        default:
            .standard
        }
    }
}

enum ArchivePreviewColumnPreferences {
    struct ResolvedColumn: Equatable {
        let column: ArchivePreviewColumn
        let width: CGFloat
    }

    private struct ListViewColumnInfo {
        let id: ArchivePreviewColumnID
        let isVisible: Bool
        let width: CGFloat
    }

    private struct ListViewInfo {
        let columns: [ListViewColumnInfo]
    }

    private static let listViewInfoKeyPrefix = "FileManager.ListViewInfo."
    private static let listViewInfoVersion = 1
    private static let maximumStoredColumnWidth: CGFloat = 4000

    static func archiveFolderTypeID(formatName: String?) -> String {
        let trimmedName = formatName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? "7-Zip" : "7-Zip." + trimmedName
    }

    static func resolvedColumns(_ columns: [ArchivePreviewColumn],
                                folderTypeID: String,
                                defaults: UserDefaults = SZSharedUserDefaults.defaults) -> [ResolvedColumn]
    {
        guard let info = listViewInfo(forFolderTypeID: folderTypeID,
                                      defaults: defaults)
        else {
            return columns
                .filter(\.defaultVisible)
                .map { ResolvedColumn(column: $0, width: $0.width) }
        }

        let availableColumns = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0) })
        var resolvedColumns: [ResolvedColumn] = []
        var seenColumnIDs = Set<ArchivePreviewColumnID>()

        for columnInfo in info.columns {
            guard let column = availableColumns[columnInfo.id],
                  !seenColumnIDs.contains(columnInfo.id)
            else {
                continue
            }

            seenColumnIDs.insert(columnInfo.id)
            guard columnInfo.isVisible || columnInfo.id == .name else { continue }

            resolvedColumns.append(ResolvedColumn(column: column,
                                                  width: normalizedColumnWidth(columnInfo.width,
                                                                               for: column)))
        }

        for column in columns where !seenColumnIDs.contains(column.id) && column.defaultVisible {
            resolvedColumns.append(ResolvedColumn(column: column, width: column.width))
        }

        return resolvedColumns
    }

    private static func listViewInfo(forFolderTypeID folderTypeID: String,
                                     defaults: UserDefaults) -> ListViewInfo?
    {
        guard let data = defaults.data(forKey: listViewInfoKeyPrefix + folderTypeID),
              let storedInfo = try? PropertyListDecoder().decode(StoredListViewInfo.self, from: data),
              storedInfo.version == listViewInfoVersion
        else {
            return nil
        }

        return ListViewInfo(columns: storedInfo.columns.map { storedColumn in
            ListViewColumnInfo(id: ArchivePreviewColumnID(rawValue: storedColumn.id),
                               isVisible: storedColumn.isVisible,
                               width: CGFloat(storedColumn.width))
        })
    }

    private static func normalizedColumnWidth(_ width: CGFloat,
                                              for column: ArchivePreviewColumn) -> CGFloat
    {
        guard width.isFinite, width > 0 else {
            return column.width
        }
        return min(max(width, column.minWidth), maximumStoredColumnWidth)
    }
}

private struct StoredListViewColumnInfo: Codable {
    let id: String
    let isVisible: Bool
    let width: Double
}

private struct StoredListViewInfo: Codable {
    let version: Int
    let sortKey: String
    let ascending: Bool
    let columns: [StoredListViewColumnInfo]
}

enum ArchivePreviewLoadError: LocalizedError {
    case coordinationFailed(Error?)

    var errorDescription: String? {
        switch self {
        case let .coordinationFailed(error):
            if let error {
                ArchivePreviewLocalization.string("app.quickLook.archivePreview.readErrorFormat",
                                                  error.localizedDescription)
            } else {
                ArchivePreviewLocalization.string("app.quickLook.archivePreview.readError")
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
                                      entryProperties: archive.entryProperties.map(ArchivePreviewEntryProperty.init),
                                      formatName: archive.formatName)
    }
}

enum ArchivePreviewPresentation {
    static let hiddenAttributeMask = HiddenItemVisibility.hiddenAttributeMask

    static func rows(for items: [ArchiveItem],
                     columns: [ArchivePreviewColumn]) -> [ArchivePreviewRow]
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
            ? ArchivePreviewLocalization.string("app.fileManager.statusFile")
            : ArchivePreviewLocalization.string("app.fileManager.statusFiles")
        let folderWord = summary.folderCount == 1
            ? ArchivePreviewLocalization.string("app.fileManager.statusFolder")
            : ArchivePreviewLocalization.string("app.fileManager.statusFolders")
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

    static func listCellText(for item: ArchiveItem,
                             columnID: ArchivePreviewColumnID,
                             dateFormatter: DateFormatter) -> String
    {
        switch columnID.rawValue {
        case ArchivePreviewColumnID.name.rawValue:
            nameText(for: item)
        case ArchivePreviewColumnID.size.rawValue:
            item.isDirectory ? "--" : item.formattedSize
        case ArchivePreviewColumnID.packedSize.rawValue:
            item.isDirectory ? "" : item.formattedPackedSize
        case ArchivePreviewColumnID.modified.rawValue:
            item.modifiedDate.map { dateFormatter.string(from: $0) } ?? ""
        case ArchivePreviewColumnID.created.rawValue:
            item.createdDate.map { dateFormatter.string(from: $0) } ?? ""
        case ArchivePreviewColumnID.accessed.rawValue:
            item.accessedDate.map { dateFormatter.string(from: $0) } ?? ""
        case ArchivePreviewColumnID.changed.rawValue:
            item.propertyValues[ArchivePreviewColumnID.changed.rawValue] ?? ""
        case ArchivePreviewColumnID.attributes.rawValue:
            formattedAttributes(item.attributes)
        case ArchivePreviewColumnID.inode.rawValue:
            item.propertyValues[ArchivePreviewColumnID.inode.rawValue] ?? ""
        case ArchivePreviewColumnID.links.rawValue:
            item.propertyValues[ArchivePreviewColumnID.links.rawValue] ?? ""
        case ArchivePreviewColumnID.encrypted.rawValue:
            item.isEncrypted ? "+" : "-"
        case ArchivePreviewColumnID.anti.rawValue:
            item.isAnti ? "+" : "-"
        case ArchivePreviewColumnID.method.rawValue:
            item.method
        case ArchivePreviewColumnID.crc.rawValue:
            item.crc == 0 ? "" : String(format: "%08X", item.crc)
        case ArchivePreviewColumnID.block.rawValue:
            String(item.block)
        case ArchivePreviewColumnID.position.rawValue:
            String(item.position)
        case ArchivePreviewColumnID.comment.rawValue:
            item.comment
        default:
            item.propertyValues[columnID.rawValue] ?? ""
        }
    }

    static func formattedAttributes(_ attributes: UInt32) -> String {
        guard attributes != 0 else { return "" }

        let windowsAttributeCharacters = Array("RHS8DAdNTsLCOIEVvX.PU.M......B")
        var remaining = attributes
        var result = ""
        let posixAttributes: UInt32?

        if remaining & 0x8000 != 0 {
            posixAttributes = remaining >> 16
            if remaining & 0xF000_0000 != 0 {
                remaining &= 0x3FFF
            }
        } else {
            posixAttributes = nil
        }

        for index in windowsAttributeCharacters.indices {
            let flag = UInt32(1) << UInt32(index)
            guard remaining & flag != 0 else { continue }

            let character = windowsAttributeCharacters[index]
            if character != "." {
                result.append(character)
                remaining &= ~flag
            }
        }

        if remaining != 0 || (result.isEmpty && posixAttributes == nil) {
            if !result.isEmpty {
                result.append(" ")
            }
            result.append(String(format: "%08X", remaining))
        }

        if let posixAttributes {
            if !result.isEmpty {
                result.append(" ")
            }
            result.append(formattedPosixAttributes(posixAttributes))
        }

        return result
    }

    private static func fileSizeString(_ size: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: size),
                                  countStyle: .file)
    }

    private static func formattedPosixAttributes(_ attributes: UInt32) -> String {
        let typeCharacters = Array("0pc3d5b7-9lBsDEF")
        var result = String(typeCharacters[Int((attributes >> 12) & 0xF)])

        for shift in stride(from: 6, through: 0, by: -3) {
            result.append(attributes & (UInt32(1) << UInt32(shift + 2)) != 0 ? "r" : "-")
            result.append(attributes & (UInt32(1) << UInt32(shift + 1)) != 0 ? "w" : "-")
            result.append(attributes & (UInt32(1) << UInt32(shift)) != 0 ? "x" : "-")
        }

        if attributes & 0x800 != 0 {
            result.replaceSubrange(result.index(result.startIndex, offsetBy: 3) ... result.index(result.startIndex, offsetBy: 3),
                                   with: attributes & (UInt32(1) << 6) != 0 ? "s" : "S")
        }
        if attributes & 0x400 != 0 {
            result.replaceSubrange(result.index(result.startIndex, offsetBy: 6) ... result.index(result.startIndex, offsetBy: 6),
                                   with: attributes & (UInt32(1) << 3) != 0 ? "s" : "S")
        }
        if attributes & 0x200 != 0 {
            result.replaceSubrange(result.index(result.startIndex, offsetBy: 9) ... result.index(result.startIndex, offsetBy: 9),
                                   with: attributes & (UInt32(1) << 0) != 0 ? "t" : "T")
        }

        let remaining = attributes & ~UInt32(0xFFFF)
        if remaining != 0 {
            result.append(" ")
            result.append(String(format: "%08X", remaining))
        }

        return result
    }

    private struct RowBuilder {
        private let columns: [ArchivePreviewColumn]
        private let dateFormatter = ArchivePreviewPreferences.makeListDateFormatter()

        init(columns: [ArchivePreviewColumn]) {
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
                 ArchivePreviewPresentation.listCellText(for: item,
                                                         columnID: column.id,
                                                         dateFormatter: dateFormatter))
            })
        }
    }
}

enum ArchivePreviewTreeBuilder {
    static func treeNodes(for rows: [ArchivePreviewRow],
                          columns: [ArchivePreviewColumn]) -> [ArchivePreviewTreeNode]
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

        var finalizedDirectories: [ObjectIdentifier: ArchivePreviewTreeNode] = [:]
        for directory in directoryOrder.reversed() {
            let row = directory.representativeItemIndex
                .flatMap { rowsByItemIndex[$0] }
                ?? syntheticDirectoryRow(for: directory,
                                         columns: columns)
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
        columns: [ArchivePreviewColumn],
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
        let dateFormatter = ArchivePreviewPreferences.makeListDateFormatter()
        let columnTexts = Dictionary(uniqueKeysWithValues: columns.map { column in
            (column.id.rawValue,
             ArchivePreviewPresentation.listCellText(for: item,
                                                     columnID: column.id,
                                                     dateFormatter: dateFormatter))
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

enum ArchivePreviewLocalization {
    private static let localizationBundleIdentifier = "ee.dawn.ShichiZip.Localization"

    static func string(_ key: String) -> String {
        let bundle = baseBundle
        if let overrideBundle = languageOverrideBundle(in: bundle),
           let value = lookup(key, in: overrideBundle) ?? lookup(key, in: bundle) ?? lookup(key, in: .main)
        {
            return value
        }

        return lookup(key, in: bundle) ?? lookup(key, in: .main) ?? key
    }

    static func string(_ key: String,
                       _ args: any CVarArg...) -> String
    {
        String(format: string(key), arguments: args)
    }

    private static var baseBundle: Bundle {
        localizationBundle() ?? .main
    }

    private static func localizationBundle() -> Bundle? {
        if let bundle = Bundle(identifier: localizationBundleIdentifier) {
            return bundle
        }

        let candidateURLs = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("ShichiZipLocalization.framework", isDirectory: true),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/ShichiZipLocalization.framework", isDirectory: true),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Frameworks/ShichiZipLocalization.framework", isDirectory: true),
        ]

        for url in candidateURLs.compactMap(\.self) {
            if let bundle = Bundle(url: url),
               bundle.bundleIdentifier == localizationBundleIdentifier
            {
                return bundle
            }
        }

        return nil
    }

    private static func languageOverrideBundle(in bundle: Bundle) -> Bundle? {
        guard let override = SZSharedUserDefaults.defaults.string(forKey: "LanguageOverride"),
              !override.isEmpty,
              let path = bundle.path(forResource: override, ofType: "lproj")
        else {
            return nil
        }

        return Bundle(path: path)
    }

    private static func lookup(_ key: String,
                               in bundle: Bundle) -> String?
    {
        let appValue = bundle.localizedString(forKey: key, value: nil, table: "App")
        if appValue != key {
            return appValue
        }

        let upstreamValue = bundle.localizedString(forKey: key, value: nil, table: "Upstream")
        if upstreamValue != key {
            return upstreamValue
        }

        return nil
    }
}

private enum ArchivePreviewVariantType {
    static let bstr: UInt = 8
    static let bool: UInt = 11
    static let i2: UInt = 2
    static let i4: UInt = 3
    static let i8: UInt = 20
    static let int: UInt = 22
    static let ui1: UInt = 17
    static let ui2: UInt = 18
    static let ui4: UInt = 19
    static let ui8: UInt = 21
    static let uint: UInt = 23
    static let filetime: UInt = 64
}
