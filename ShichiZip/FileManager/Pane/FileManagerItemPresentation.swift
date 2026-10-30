import Foundation

struct FileManagerItemStatusSummary: Equatable {
    let fileCount: Int
    let folderCount: Int
    let fileSize: UInt64?
    let folderSize: UInt64?

    var itemCount: Int {
        fileCount + folderCount
    }

    var copyDialogTotalSize: UInt64? {
        guard let fileSize, let folderSize else { return nil }
        let (total, overflow) = fileSize.addingReportingOverflow(folderSize)
        return overflow ? .max : total
    }

    var isEmpty: Bool {
        itemCount == 0
    }
}

enum FileManagerStatusBarLocation: Equatable {
    case fileSystem
    case archive(uncompressedSize: UInt64?)
}

struct FileManagerStatusBarContent: Equatable {
    let summary: String
    let detail: String?
}

struct FileManagerItemDetails {
    let title: String
    let details: String
}

enum FileManagerItemPresentation {
    static func summary(for fileSystemItems: [FileSystemItem]) -> FileManagerItemStatusSummary {
        summary(for: fileSystemItems.map { item in
            (isDirectory: item.isDirectory, size: item.size)
        })
    }

    static func summary(for archiveItems: [ArchiveItem]) -> FileManagerItemStatusSummary {
        summary(for: archiveItems.map { item in
            (isDirectory: item.isDirectory, size: item.isAnti ? 0 : item.size)
        })
    }

    static func statusBarContent(displayed: FileManagerItemStatusSummary,
                                 selected: FileManagerItemStatusSummary?,
                                 location: FileManagerStatusBarLocation) -> FileManagerStatusBarContent
    {
        guard let selected, !selected.isEmpty else {
            let detail: String? = switch location {
            case .fileSystem:
                if displayed.fileCount > 0, let fileSize = displayed.fileSize {
                    SZL10n.string("app.fileManager.statusShownFilesSize",
                                  fileSizeString(fileSize))
                } else {
                    nil
                }
            case let .archive(uncompressedSize):
                uncompressedSize.map {
                    SZL10n.string("app.fileManager.statusArchiveUncompressedSize",
                                  fileSizeString($0))
                }
            }
            return FileManagerStatusBarContent(summary: countSummaryText(displayed),
                                               detail: detail)
        }

        return FileManagerStatusBarContent(
            summary: SZL10n.string("app.fileManager.statusSelection",
                                   selected.itemCount,
                                   displayed.itemCount),
            detail: selectedSummaryText(selected),
        )
    }

    static func copyDialogSummaryLines(for summary: FileManagerItemStatusSummary) -> [String] {
        var lines: [String] = []
        if summary.folderCount > 0 {
            lines.append(copyDialogValuePairLine(title: SZL10n.string("column.folders"),
                                                 count: summary.folderCount,
                                                 size: summary.folderSize))
        }
        if summary.fileCount > 0 {
            lines.append(copyDialogValuePairLine(title: SZL10n.string("column.files"),
                                                 count: summary.fileCount,
                                                 size: summary.fileSize))
        }
        if let folderSize = summary.folderSize,
           let fileSize = summary.fileSize,
           let totalSize = summary.copyDialogTotalSize,
           folderSize > 0,
           fileSize > 0
        {
            lines.append("\(SZL10n.string("column.size")): \(fileSizeString(totalSize))")
        }
        return lines
    }

    static func displayNames(for fileSystemItems: [FileSystemItem],
                             limit: Int? = nil,
                             appendingDirectorySeparators: Bool = false) -> [String]
    {
        let visibleItems = limit.map { Array(fileSystemItems.prefix($0)) } ?? fileSystemItems
        return visibleItems.map { item in
            displayName(item.name,
                        isDirectory: item.isDirectory,
                        appendingDirectorySeparator: appendingDirectorySeparators)
        }
    }

    static func displayNames(for archiveItems: [ArchiveItem],
                             limit: Int? = nil,
                             appendingDirectorySeparators: Bool = false) -> [String]
    {
        let visibleItems = limit.map { Array(archiveItems.prefix($0)) } ?? archiveItems
        return visibleItems.map { item in
            displayName(item.name,
                        isDirectory: item.isDirectory,
                        appendingDirectorySeparator: appendingDirectorySeparators)
        }
    }

    static func itemPreviewLines(names: [String], totalCount: Int) -> [String] {
        var lines = names.map { "  \($0)" }
        if totalCount > names.count {
            lines.append("  ...")
        }
        return lines
    }

    static func fileSystemItemsInfoText(location: String,
                                        items: [FileSystemItem],
                                        previewItemLimit: Int) -> String
    {
        var lines = [location]
        let names = displayNames(for: items, limit: previewItemLimit)
        lines.append(contentsOf: itemPreviewLines(names: names, totalCount: items.count))
        return lines.joined(separator: "\n")
    }

    static func archiveItemsInfoText(location: String,
                                     items: [ArchiveItem],
                                     previewItemLimit: Int,
                                     includeSummary: Bool) -> String
    {
        var lines: [String] = []
        if includeSummary {
            lines = copyDialogSummaryLines(for: summary(for: items))
            if !lines.isEmpty {
                lines.append("")
            }
        }

        lines.append(location)
        let names = displayNames(for: items,
                                 limit: previewItemLimit,
                                 appendingDirectorySeparators: true)
        lines.append(contentsOf: itemPreviewLines(names: names, totalCount: items.count))
        return lines.joined(separator: "\n")
    }

    static func details(for item: FileSystemItem) -> FileManagerItemDetails {
        FileManagerItemDetails(
            title: item.name,
            details: detailLines(fileSystemDetailRows(for: item)),
        )
    }

    static func details(for item: ArchiveItem,
                        entryProperties: [FileManagerArchiveEntryProperty]) -> FileManagerItemDetails
    {
        FileManagerItemDetails(
            title: SZL10n.string("properties.title"),
            details: detailLines(archiveDetailRows(for: item,
                                                   entryProperties: entryProperties)),
        )
    }

    static func parentRowListCellText(for columnID: FileManagerColumnID) -> String {
        columnID == .name ? ".." : ""
    }

    static func listCellText(for item: FileSystemItem,
                             columnID: FileManagerColumnID,
                             dateFormatter: DateFormatter) -> String
    {
        switch columnID.rawValue {
        case FileManagerColumnID.name.rawValue:
            item.name
        case FileManagerColumnID.size.rawValue:
            item.formattedSize
        case FileManagerColumnID.packedSize.rawValue:
            item.formattedPackedSize
        case FileManagerColumnID.modified.rawValue:
            item.modifiedDate.map { dateFormatter.string(from: $0) } ?? ""
        case FileManagerColumnID.created.rawValue:
            item.createdDate.map { dateFormatter.string(from: $0) } ?? ""
        case FileManagerColumnID.accessed.rawValue:
            item.accessedDate.map { dateFormatter.string(from: $0) } ?? ""
        case FileManagerColumnID.changed.rawValue:
            item.changedDate.map { dateFormatter.string(from: $0) } ?? ""
        case FileManagerColumnID.attributes.rawValue:
            formattedAttributes(item.attributes)
        case FileManagerColumnID.inode.rawValue:
            item.inode.map(String.init) ?? ""
        case FileManagerColumnID.links.rawValue:
            item.links.map(String.init) ?? ""
        default:
            ""
        }
    }

    static func listCellText(for item: ArchiveItem,
                             columnID: FileManagerColumnID,
                             dateFormatter: DateFormatter) -> String
    {
        ArchiveItemPresentation.listCellText(for: item,
                                             columnID: columnID,
                                             dateFormatter: dateFormatter)
    }

    static func formattedAttributes(_ attributes: UInt32) -> String {
        ArchiveItemPresentation.formattedAttributes(attributes)
    }

    private static func summary(for items: [(isDirectory: Bool, size: UInt64?)]) -> FileManagerItemStatusSummary {
        var fileCount = 0
        var folderCount = 0
        var fileSize: UInt64? = 0
        var folderSize: UInt64? = 0

        for item in items {
            if item.isDirectory {
                folderCount += 1
                folderSize = addingClamped(folderSize, item.size)
            } else {
                fileCount += 1
                fileSize = addingClamped(fileSize, item.size)
            }
        }

        return FileManagerItemStatusSummary(fileCount: fileCount,
                                            folderCount: folderCount,
                                            fileSize: fileSize,
                                            folderSize: folderSize)
    }

    private static func countSummaryText(_ summary: FileManagerItemStatusSummary) -> String {
        SZL10n.string("app.fileManager.statusSummaryPair",
                      itemCountText(summary.fileCount,
                                    singularKey: "app.fileManager.statusFile",
                                    pluralKey: "app.fileManager.statusFiles"),
                      itemCountText(summary.folderCount,
                                    singularKey: "app.fileManager.statusFolder",
                                    pluralKey: "app.fileManager.statusFolders"))
    }

    private static func selectedSummaryText(_ summary: FileManagerItemStatusSummary) -> String {
        let filesText = itemCountText(summary.fileCount,
                                      singularKey: "app.fileManager.statusFile",
                                      pluralKey: "app.fileManager.statusFiles",
                                      size: summary.fileSize)
        let foldersText = itemCountText(summary.folderCount,
                                        singularKey: "app.fileManager.statusFolder",
                                        pluralKey: "app.fileManager.statusFolders")

        return switch (summary.fileCount, summary.folderCount) {
        case (_, 0):
            filesText
        case (0, _):
            foldersText
        default:
            SZL10n.string("app.fileManager.statusSummaryPair", filesText, foldersText)
        }
    }

    private static func itemCountText(_ count: Int,
                                      singularKey: String,
                                      pluralKey: String,
                                      size: UInt64? = nil) -> String
    {
        let itemWord = SZL10n.string(count == 1 ? singularKey : pluralKey)
        if let size {
            return SZL10n.string("app.fileManager.statusItemCountWithSize",
                                 count,
                                 itemWord,
                                 fileSizeString(size))
        }
        return SZL10n.string("app.fileManager.statusItemCount", count, itemWord)
    }

    private static func addingClamped(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
        guard let lhs, let rhs else { return nil }
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func copyDialogValuePairLine(title: String, count: Int, size: UInt64?) -> String {
        guard let size else { return "\(title): \(count)" }
        return "\(title): \(count)    ( \(fileSizeString(size)) )"
    }

    private static func fileSizeString(_ size: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
    }

    private static func displayName(_ name: String,
                                    isDirectory: Bool,
                                    appendingDirectorySeparator: Bool) -> String
    {
        guard appendingDirectorySeparator, isDirectory, !name.hasSuffix("/") else { return name }
        return name + "/"
    }

    private static func fileSystemTypeText(url: URL, isDirectory: Bool) -> String {
        if isDirectory {
            return SZL10n.string("column.folder")
        }

        let fileExtension = url.pathExtension.uppercased()
        return fileExtension.isEmpty ? SZL10n.string("menu.file") : fileExtension
    }

    private static func fileSystemDetailRows(for item: FileSystemItem) -> [(String, String)] {
        let dateFormatter = FileManagerViewPreferences.makeDateFormatter(dateStyle: .long,
                                                                         timeStyle: .medium)
        let typeRow = (SZL10n.string("column.type"), fileSystemTypeText(url: item.url,
                                                                        isDirectory: item.isDirectory))
        let columnRows = FileManagerColumn.fileSystemColumns.compactMap { column -> (String, String)? in
            guard let value = fileSystemDetailValue(for: column.id,
                                                    item: item,
                                                    dateFormatter: dateFormatter),
                !value.isEmpty
            else { return nil }

            return (column.title, value)
        }

        return [typeRow] + columnRows
    }

    private static func fileSystemDetailValue(for columnID: FileManagerColumnID,
                                              item: FileSystemItem,
                                              dateFormatter: DateFormatter) -> String?
    {
        switch columnID.rawValue {
        case FileManagerColumnID.name.rawValue:
            item.name
        case FileManagerColumnID.size.rawValue:
            item.formattedSize
        case FileManagerColumnID.packedSize.rawValue:
            item.formattedPackedSize
        case FileManagerColumnID.modified.rawValue:
            item.modifiedDate.map { dateFormatter.string(from: $0) }
        case FileManagerColumnID.created.rawValue:
            item.createdDate.map { dateFormatter.string(from: $0) }
        case FileManagerColumnID.accessed.rawValue:
            item.accessedDate.map { dateFormatter.string(from: $0) }
        case FileManagerColumnID.changed.rawValue:
            item.changedDate.map { dateFormatter.string(from: $0) }
        case FileManagerColumnID.attributes.rawValue:
            formattedAttributes(item.attributes)
        case FileManagerColumnID.inode.rawValue:
            item.inode.map(String.init)
        case FileManagerColumnID.links.rawValue:
            item.links.map(String.init)
        default:
            nil
        }
    }

    private static func archiveDetailRows(for item: ArchiveItem,
                                          entryProperties: [FileManagerArchiveEntryProperty]) -> [(String, String)]
    {
        let rows = FileManagerColumn.archiveColumns(entryProperties: entryProperties).compactMap { column -> (String, String)? in
            guard let value = archiveDetailValue(for: column.id, item: item) else { return nil }
            return (column.title, value)
        }

        guard !rows.isEmpty else {
            return [(FileManagerColumn.definition(for: .name).title, item.name)]
        }

        return rows
    }

    private static func archiveDetailValue(for columnID: FileManagerColumnID,
                                           item: ArchiveItem) -> String?
    {
        if let value = item.propertyValues[columnID.rawValue], !value.isEmpty {
            return value
        }

        guard item.index < 0, columnID == .name else { return nil }
        return item.name
    }

    private static func detailLines(_ rows: [(String, String)]) -> String {
        rows.map { title, value in
            "\(title): \(value)"
        }.joined(separator: "\n")
    }
}
