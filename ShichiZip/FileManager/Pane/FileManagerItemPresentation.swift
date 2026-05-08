import Foundation

struct FileManagerItemStatusSummary: Equatable {
    let fileCount: Int
    let folderCount: Int
    let fileSize: UInt64
    let folderSize: UInt64

    var itemCount: Int {
        fileCount + folderCount
    }

    var totalSize: UInt64 {
        fileSize
    }

    var copyDialogTotalSize: UInt64 {
        fileSize + folderSize
    }

    var isEmpty: Bool {
        itemCount == 0
    }
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
            (isDirectory: item.isDirectory, size: item.size)
        })
    }

    static func statusBarText(displayed: FileManagerItemStatusSummary,
                              selected: FileManagerItemStatusSummary?) -> String
    {
        let displayedSummaryText = summaryText(displayed)
        guard let selected, !selected.isEmpty else {
            return displayedSummaryText
        }

        let segments = [
            "\(selected.itemCount)/\(displayed.itemCount) \(SZL10n.string("app.fileManager.statusSelected")) — \(selectedSummaryText(selected))",
            "\(SZL10n.string("app.fileManager.statusTotal")) \(displayedSummaryText)",
        ]

        return segments.joined(separator: "  •  ")
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
        if summary.folderSize > 0, summary.fileSize > 0 {
            lines.append("\(SZL10n.string("column.size")): \(fileSizeString(summary.copyDialogTotalSize))")
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
        switch columnID.rawValue {
        case FileManagerColumnID.name.rawValue:
            item.name
        case FileManagerColumnID.size.rawValue:
            item.isDirectory ? "--" : fileSizeString(item.size)
        case FileManagerColumnID.packedSize.rawValue:
            item.isDirectory ? "" : fileSizeString(item.packedSize)
        case FileManagerColumnID.modified.rawValue:
            item.modifiedDate.map { dateFormatter.string(from: $0) } ?? ""
        case FileManagerColumnID.created.rawValue:
            item.createdDate.map { dateFormatter.string(from: $0) } ?? ""
        case FileManagerColumnID.accessed.rawValue:
            item.accessedDate.map { dateFormatter.string(from: $0) } ?? ""
        case FileManagerColumnID.changed.rawValue:
            item.propertyValues[FileManagerColumnID.changed.rawValue] ?? ""
        case FileManagerColumnID.attributes.rawValue:
            formattedAttributes(item.attributes)
        case FileManagerColumnID.inode.rawValue:
            item.propertyValues[FileManagerColumnID.inode.rawValue] ?? ""
        case FileManagerColumnID.links.rawValue:
            item.propertyValues[FileManagerColumnID.links.rawValue] ?? ""
        case FileManagerColumnID.encrypted.rawValue:
            item.isEncrypted ? "+" : "-"
        case FileManagerColumnID.anti.rawValue:
            item.isAnti ? "+" : "-"
        case FileManagerColumnID.method.rawValue:
            item.method
        case FileManagerColumnID.crc.rawValue:
            item.crc == 0 ? "" : String(format: "%08X", item.crc)
        case FileManagerColumnID.block.rawValue:
            String(item.block)
        case FileManagerColumnID.position.rawValue:
            String(item.position)
        case FileManagerColumnID.comment.rawValue:
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

    private static func summary(for items: [(isDirectory: Bool, size: UInt64)]) -> FileManagerItemStatusSummary {
        var fileCount = 0
        var folderCount = 0
        var fileSize: UInt64 = 0
        var folderSize: UInt64 = 0

        for item in items {
            if item.isDirectory {
                folderCount += 1
                folderSize += item.size
            } else {
                fileCount += 1
                fileSize += item.size
            }
        }

        return FileManagerItemStatusSummary(fileCount: fileCount,
                                            folderCount: folderCount,
                                            fileSize: fileSize,
                                            folderSize: folderSize)
    }

    private static func summaryText(_ summary: FileManagerItemStatusSummary) -> String {
        let sizeString = fileSizeString(summary.totalSize)
        let fileWord = summary.fileCount == 1 ? SZL10n.string("app.fileManager.statusFile") : SZL10n.string("app.fileManager.statusFiles")
        let folderWord = summary.folderCount == 1 ? SZL10n.string("app.fileManager.statusFolder") : SZL10n.string("app.fileManager.statusFolders")
        return "\(summary.fileCount) \(fileWord), \(summary.folderCount) \(folderWord) — \(sizeString)"
    }

    private static func selectedSummaryText(_ summary: FileManagerItemStatusSummary) -> String {
        let sizeString = fileSizeString(summary.totalSize)
        let fileWord = summary.fileCount == 1 ? SZL10n.string("app.fileManager.statusFile") : SZL10n.string("app.fileManager.statusFiles")
        let folderWord = summary.folderCount == 1 ? SZL10n.string("app.fileManager.statusFolder") : SZL10n.string("app.fileManager.statusFolders")

        return switch (summary.fileCount, summary.folderCount) {
        case (_, 0):
            "\(summary.fileCount) \(fileWord), \(sizeString)"
        case (0, _):
            "\(summary.folderCount) \(folderWord)"
        default:
            "\(summary.fileCount) \(fileWord), \(summary.folderCount) \(folderWord), \(sizeString)"
        }
    }

    private static func copyDialogValuePairLine(title: String, count: Int, size: UInt64) -> String {
        "\(title): \(count)    ( \(fileSizeString(size)) )"
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
}
