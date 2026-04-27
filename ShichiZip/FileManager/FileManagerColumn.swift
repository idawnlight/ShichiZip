import Cocoa

enum FileManagerColumnID: String, CaseIterable {
    case name
    case size
    case packedSize
    case modified
    case created
    case accessed
    case attributes
    case encrypted
    case anti
    case method
    case crc
    case block
    case position
    case comment
}

enum FileManagerColumnTextStyle: Equatable {
    case standard
    case tabularNumbers
    case fixedWidth

    var font: NSFont {
        switch self {
        case .standard:
            .systemFont(ofSize: NSFont.systemFontSize)
        case .tabularNumbers:
            .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                       weight: .regular)
        case .fixedWidth:
            .monospacedSystemFont(ofSize: NSFont.systemFontSize,
                                  weight: .regular)
        }
    }
}

struct FileManagerColumn: Equatable {
    let id: FileManagerColumnID
    let titleKey: String
    let width: CGFloat
    let minWidth: CGFloat
    let defaultAscending: Bool
    let alignment: NSTextAlignment
    let sortSelector: Selector?

    var title: String {
        SZL10n.string(titleKey)
    }

    var sortKey: String {
        id.rawValue
    }

    var textStyle: FileManagerColumnTextStyle {
        switch id {
        case .size, .packedSize, .modified, .created, .accessed, .block, .position:
            .tabularNumbers
        case .attributes, .crc:
            .fixedWidth
        case .name, .encrypted, .anti, .method, .comment:
            .standard
        }
    }

    var font: NSFont {
        textStyle.font
    }

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(id.rawValue)
    }

    var sortDescriptorPrototype: NSSortDescriptor {
        if let sortSelector {
            NSSortDescriptor(key: sortKey,
                             ascending: defaultAscending,
                             selector: sortSelector)
        } else {
            NSSortDescriptor(key: sortKey,
                             ascending: defaultAscending)
        }
    }

    @MainActor func makeTableColumn() -> NSTableColumn {
        let tableColumn = NSTableColumn(identifier: identifier)
        tableColumn.title = title
        tableColumn.width = width
        tableColumn.minWidth = minWidth
        tableColumn.sortDescriptorPrototype = sortDescriptorPrototype
        return tableColumn
    }

    func normalizedDisplayString(_ string: String) -> String {
        string.replacingLineBreakSequencesWithSpaces()
    }

    static let fileSystemColumns: [FileManagerColumn] = [
        definition(for: .name),
        definition(for: .size),
        definition(for: .modified),
        definition(for: .created),
    ]

    private static let archiveColumnOrder: [FileManagerColumnID] = [
        .name,
        .size,
        .packedSize,
        .modified,
        .created,
        .accessed,
        .attributes,
        .encrypted,
        .method,
        .crc,
        .block,
        .position,
        .anti,
        .comment,
    ]

    static func archiveColumns(availablePropertyKeys: [String]) -> [FileManagerColumn] {
        archiveColumns(availablePropertyKeys: Set(availablePropertyKeys))
    }

    static func archiveColumns(availablePropertyKeys: Set<String>) -> [FileManagerColumn] {
        let availableIDs = Set(availablePropertyKeys.compactMap(FileManagerColumnID.init(rawValue:)))
        return archiveColumnOrder
            .filter { $0 == .name || availableIDs.contains($0) }
            .map { definition(for: $0) }
    }

    static func definition(for id: FileManagerColumnID) -> FileManagerColumn {
        switch id {
        case .name:
            FileManagerColumn(id: id,
                              titleKey: "column.name",
                              width: 250,
                              minWidth: 100,
                              defaultAscending: true,
                              alignment: .left,
                              sortSelector: #selector(NSString.localizedStandardCompare(_:)))
        case .size:
            FileManagerColumn(id: id,
                              titleKey: "column.size",
                              width: 80,
                              minWidth: 50,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil)
        case .packedSize:
            FileManagerColumn(id: id,
                              titleKey: "column.packedSize",
                              width: 100,
                              minWidth: 70,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil)
        case .modified:
            FileManagerColumn(id: id,
                              titleKey: "column.modified",
                              width: 140,
                              minWidth: 80,
                              defaultAscending: false,
                              alignment: .left,
                              sortSelector: nil)
        case .created:
            FileManagerColumn(id: id,
                              titleKey: "column.created",
                              width: 140,
                              minWidth: 80,
                              defaultAscending: false,
                              alignment: .left,
                              sortSelector: nil)
        case .accessed:
            FileManagerColumn(id: id,
                              titleKey: "column.accessed",
                              width: 140,
                              minWidth: 80,
                              defaultAscending: false,
                              alignment: .left,
                              sortSelector: nil)
        case .attributes:
            FileManagerColumn(id: id,
                              titleKey: "column.attributes",
                              width: 100,
                              minWidth: 70,
                              defaultAscending: true,
                              alignment: .right,
                              sortSelector: nil)
        case .encrypted:
            FileManagerColumn(id: id,
                              titleKey: "column.encrypted",
                              width: 80,
                              minWidth: 60,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil)
        case .anti:
            FileManagerColumn(id: id,
                              titleKey: "column.anti",
                              width: 70,
                              minWidth: 50,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil)
        case .method:
            FileManagerColumn(id: id,
                              titleKey: "column.method",
                              width: 120,
                              minWidth: 70,
                              defaultAscending: true,
                              alignment: .left,
                              sortSelector: #selector(NSString.localizedStandardCompare(_:)))
        case .crc:
            FileManagerColumn(id: id,
                              titleKey: "CRC",
                              width: 90,
                              minWidth: 70,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil)
        case .block:
            FileManagerColumn(id: id,
                              titleKey: "column.block",
                              width: 70,
                              minWidth: 50,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil)
        case .position:
            FileManagerColumn(id: id,
                              titleKey: "column.position",
                              width: 100,
                              minWidth: 70,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil)
        case .comment:
            FileManagerColumn(id: id,
                              titleKey: "column.comment",
                              width: 160,
                              minWidth: 80,
                              defaultAscending: true,
                              alignment: .left,
                              sortSelector: #selector(NSString.localizedStandardCompare(_:)))
        }
    }
}

private extension String {
    func replacingLineBreakSequencesWithSpaces() -> String {
        guard unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else {
            return self
        }

        var result = String()
        result.reserveCapacity(count)
        var previousWasLineBreak = false

        for scalar in unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                if !previousWasLineBreak {
                    result.append(" ")
                }
                previousWasLineBreak = true
            } else {
                result.unicodeScalars.append(scalar)
                previousWasLineBreak = false
            }
        }

        return result
    }
}
