import Cocoa

struct FileManagerColumnID: RawRepresentable, Hashable, Codable, ExpressibleByStringLiteral {
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

struct FileManagerArchiveEntryProperty: Equatable {
    let id: FileManagerColumnID
    let titleKey: String?
    let title: String
    let valueType: UInt

    init(id: FileManagerColumnID,
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
        self.init(id: FileManagerColumnID(rawValue: property.key),
                  titleKey: property.titleKey,
                  title: property.title,
                  valueType: UInt(property.valueType))
    }
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
    let titleKey: String?
    let titleFallback: String
    let width: CGFloat
    let minWidth: CGFloat
    let defaultAscending: Bool
    let defaultVisible: Bool
    let alignment: NSTextAlignment
    let sortSelector: Selector?
    let textStyle: FileManagerColumnTextStyle

    init(id: FileManagerColumnID,
         titleKey: String?,
         titleFallback: String,
         width: CGFloat,
         minWidth: CGFloat,
         defaultAscending: Bool,
         defaultVisible: Bool = true,
         alignment: NSTextAlignment,
         sortSelector: Selector?,
         textStyle: FileManagerColumnTextStyle)
    {
        self.id = id
        self.titleKey = titleKey
        self.titleFallback = titleFallback
        self.width = width
        self.minWidth = minWidth
        self.defaultAscending = defaultAscending
        self.defaultVisible = defaultVisible
        self.alignment = alignment
        self.sortSelector = sortSelector
        self.textStyle = textStyle
    }

    var title: String {
        guard let titleKey else { return titleFallback }
        let localizedTitle = SZL10n.string(titleKey)
        return localizedTitle == titleKey ? titleFallback : localizedTitle
    }

    var sortKey: String {
        id.rawValue
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

    func withDefaultVisible(_ defaultVisible: Bool) -> FileManagerColumn {
        FileManagerColumn(id: id,
                          titleKey: titleKey,
                          titleFallback: titleFallback,
                          width: width,
                          minWidth: minWidth,
                          defaultAscending: defaultAscending,
                          defaultVisible: defaultVisible,
                          alignment: alignment,
                          sortSelector: sortSelector,
                          textStyle: textStyle)
    }

    static let fileSystemColumns: [FileManagerColumn] = [
        definition(for: .name),
        definition(for: .size),
        definition(for: .modified),
        definition(for: .created),
        definition(for: .accessed).withDefaultVisible(false),
        definition(for: .changed).withDefaultVisible(false),
        definition(for: .attributes).withDefaultVisible(false),
        definition(for: .packedSize).withDefaultVisible(false),
        definition(for: .inode).withDefaultVisible(false),
        definition(for: .links).withDefaultVisible(false),
    ]

    static func archiveColumns(availablePropertyKeys: [String]) -> [FileManagerColumn] {
        var properties: [FileManagerArchiveEntryProperty] = [
            FileManagerArchiveEntryProperty(id: .name,
                                            titleKey: "column.name",
                                            title: "Name",
                                            valueType: VariantType.bstr),
        ]
        for key in availablePropertyKeys where key != FileManagerColumnID.name.rawValue {
            let id = FileManagerColumnID(rawValue: key)
            let knownColumn = knownDefinition(for: id)
            properties.append(FileManagerArchiveEntryProperty(id: id,
                                                              titleKey: knownColumn?.titleKey,
                                                              title: knownColumn?.titleFallback ?? key,
                                                              valueType: VariantType.bstr))
        }
        return archiveColumns(entryProperties: properties)
    }

    static func archiveColumns(availablePropertyKeys: Set<String>) -> [FileManagerColumn] {
        archiveColumns(availablePropertyKeys: Array(availablePropertyKeys).sorted())
    }

    static func archiveColumns(entryProperties: [FileManagerArchiveEntryProperty]) -> [FileManagerColumn] {
        var columns: [FileManagerColumn] = []
        var seenIDs = Set<FileManagerColumnID>()

        func appendColumn(for property: FileManagerArchiveEntryProperty) {
            guard seenIDs.insert(property.id).inserted else { return }
            columns.append(column(for: property))
        }

        appendColumn(for: FileManagerArchiveEntryProperty(id: .name,
                                                          titleKey: "column.name",
                                                          title: "Name",
                                                          valueType: VariantType.bstr))
        for property in entryProperties where property.id != .name {
            appendColumn(for: property)
        }

        return columns
    }

    static func visibleColumns(inTableOrder tableColumns: [NSTableColumn],
                               availableColumns: [FileManagerColumn]) -> [FileManagerColumn]
    {
        let columnsByID = Dictionary(uniqueKeysWithValues: availableColumns.map { ($0.id, $0) })
        return tableColumns.compactMap { tableColumn in
            columnsByID[FileManagerColumnID(rawValue: tableColumn.identifier.rawValue)]
        }
    }

    static func definition(for id: FileManagerColumnID) -> FileManagerColumn {
        knownDefinition(for: id)
            ?? column(for: FileManagerArchiveEntryProperty(id: id,
                                                           titleKey: nil,
                                                           title: id.rawValue,
                                                           valueType: VariantType.bstr))
    }

    private static func knownDefinition(for id: FileManagerColumnID) -> FileManagerColumn? {
        switch id.rawValue {
        case FileManagerColumnID.name.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.name",
                              titleFallback: "Name",
                              width: 250,
                              minWidth: 100,
                              defaultAscending: true,
                              alignment: .left,
                              sortSelector: #selector(NSString.localizedStandardCompare(_:)),
                              textStyle: .standard)
        case FileManagerColumnID.size.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.size",
                              titleFallback: "Size",
                              width: 80,
                              minWidth: 50,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil,
                              textStyle: .tabularNumbers)
        case FileManagerColumnID.packedSize.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.packedSize",
                              titleFallback: "Packed Size",
                              width: 100,
                              minWidth: 70,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil,
                              textStyle: .tabularNumbers)
        case FileManagerColumnID.modified.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.modified",
                              titleFallback: "Modified",
                              width: 140,
                              minWidth: 80,
                              defaultAscending: false,
                              alignment: .left,
                              sortSelector: nil,
                              textStyle: .tabularNumbers)
        case FileManagerColumnID.created.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.created",
                              titleFallback: "Created",
                              width: 140,
                              minWidth: 80,
                              defaultAscending: false,
                              alignment: .left,
                              sortSelector: nil,
                              textStyle: .tabularNumbers)
        case FileManagerColumnID.accessed.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.accessed",
                              titleFallback: "Accessed",
                              width: 140,
                              minWidth: 80,
                              defaultAscending: false,
                              alignment: .left,
                              sortSelector: nil,
                              textStyle: .tabularNumbers)
        case FileManagerColumnID.changed.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.changed",
                              titleFallback: "Metadata Changed",
                              width: 140,
                              minWidth: 80,
                              defaultAscending: false,
                              alignment: .left,
                              sortSelector: nil,
                              textStyle: .tabularNumbers)
        case FileManagerColumnID.attributes.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.attributes",
                              titleFallback: "Attributes",
                              width: 100,
                              minWidth: 70,
                              defaultAscending: true,
                              alignment: .right,
                              sortSelector: nil,
                              textStyle: .fixedWidth)
        case FileManagerColumnID.encrypted.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.encrypted",
                              titleFallback: "Encrypted",
                              width: 80,
                              minWidth: 60,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil,
                              textStyle: .standard)
        case FileManagerColumnID.anti.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.anti",
                              titleFallback: "Anti",
                              width: 70,
                              minWidth: 50,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil,
                              textStyle: .standard)
        case FileManagerColumnID.method.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.method",
                              titleFallback: "Method",
                              width: 120,
                              minWidth: 70,
                              defaultAscending: true,
                              alignment: .left,
                              sortSelector: #selector(NSString.localizedStandardCompare(_:)),
                              textStyle: .standard)
        case FileManagerColumnID.crc.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.crc",
                              titleFallback: "CRC",
                              width: 90,
                              minWidth: 70,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil,
                              textStyle: .fixedWidth)
        case FileManagerColumnID.block.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.block",
                              titleFallback: "Block",
                              width: 70,
                              minWidth: 50,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil,
                              textStyle: .tabularNumbers)
        case FileManagerColumnID.position.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.position",
                              titleFallback: "Position",
                              width: 100,
                              minWidth: 70,
                              defaultAscending: false,
                              alignment: .right,
                              sortSelector: nil,
                              textStyle: .tabularNumbers)
        case FileManagerColumnID.comment.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.comment",
                              titleFallback: "Comment",
                              width: 160,
                              minWidth: 80,
                              defaultAscending: true,
                              alignment: .left,
                              sortSelector: #selector(NSString.localizedStandardCompare(_:)),
                              textStyle: .standard)
        case FileManagerColumnID.inode.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.inode",
                              titleFallback: "iNode",
                              width: 100,
                              minWidth: 70,
                              defaultAscending: true,
                              alignment: .right,
                              sortSelector: nil,
                              textStyle: .tabularNumbers)
        case FileManagerColumnID.links.rawValue:
            FileManagerColumn(id: id,
                              titleKey: "column.links",
                              titleFallback: "Links",
                              width: 70,
                              minWidth: 50,
                              defaultAscending: true,
                              alignment: .right,
                              sortSelector: nil,
                              textStyle: .tabularNumbers)
        default:
            nil
        }
    }

    private static func column(for property: FileManagerArchiveEntryProperty) -> FileManagerColumn {
        if let knownColumn = knownDefinition(for: property.id) {
            return knownColumn
        }

        let rightAligned = isRightAligned(valueType: property.valueType)
        return FileManagerColumn(id: property.id,
                                 titleKey: property.titleKey,
                                 titleFallback: property.title,
                                 width: property.id == .name ? 250 : 100,
                                 minWidth: property.id == .name ? 100 : 50,
                                 defaultAscending: !rightAligned,
                                 alignment: rightAligned ? .right : .left,
                                 sortSelector: rightAligned ? nil : #selector(NSString.localizedStandardCompare(_:)),
                                 textStyle: textStyle(for: property))
    }

    private static func isRightAligned(valueType: UInt) -> Bool {
        switch valueType {
        case VariantType.ui1, VariantType.i2, VariantType.ui2, VariantType.i4, VariantType.ui4,
             VariantType.int, VariantType.uint, VariantType.i8, VariantType.ui8, VariantType.bool:
            true
        default:
            false
        }
    }

    private static func textStyle(for property: FileManagerArchiveEntryProperty) -> FileManagerColumnTextStyle {
        switch property.valueType {
        case VariantType.filetime, VariantType.ui1, VariantType.i2, VariantType.ui2, VariantType.i4,
             VariantType.ui4, VariantType.int, VariantType.uint, VariantType.i8, VariantType.ui8,
             VariantType.bool:
            .tabularNumbers
        default:
            .standard
        }
    }
}

enum FileManagerItemSorting {
    static func sort(_ items: inout [FileSystemItem], by descriptors: [NSSortDescriptor]) {
        guard let descriptor = descriptors.first else {
            sortByDefaultName(&items)
            return
        }

        let key = descriptor.key ?? FileManagerColumnID.name.rawValue
        let ascending = descriptor.ascending

        items.sort { firstItem, secondItem in
            if firstItem.isDirectory != secondItem.isDirectory {
                return firstItem.isDirectory
            }

            let result = compare(firstItem, secondItem, key: key)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    static func sort(_ items: inout [ArchiveItem], by descriptors: [NSSortDescriptor]) {
        guard let descriptor = descriptors.first else {
            sortByDefaultName(&items)
            return
        }

        let key = descriptor.key ?? FileManagerColumnID.name.rawValue
        let ascending = descriptor.ascending

        items.sort { firstItem, secondItem in
            if firstItem.isDirectory != secondItem.isDirectory {
                return firstItem.isDirectory
            }

            let result = compare(firstItem, secondItem, key: key)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func sortByDefaultName(_ items: inout [FileSystemItem]) {
        items.sort { firstItem, secondItem in
            if firstItem.isDirectory != secondItem.isDirectory {
                return firstItem.isDirectory
            }
            return firstItem.name.localizedStandardCompare(secondItem.name) == .orderedAscending
        }
    }

    private static func sortByDefaultName(_ items: inout [ArchiveItem]) {
        items.sort { firstItem, secondItem in
            if firstItem.isDirectory != secondItem.isDirectory {
                return firstItem.isDirectory
            }
            return firstItem.name.localizedStandardCompare(secondItem.name) == .orderedAscending
        }
    }

    private static func compare(_ firstItem: FileSystemItem,
                                _ secondItem: FileSystemItem,
                                key: String) -> ComparisonResult
    {
        switch key {
        case FileManagerColumnID.name.rawValue:
            firstItem.name.localizedStandardCompare(secondItem.name)
        case "type":
            compareType(firstItem.url.pathExtension,
                        secondItem.url.pathExtension,
                        firstName: firstItem.name,
                        secondName: secondItem.name)
        case FileManagerColumnID.size.rawValue:
            compare(firstItem.size, secondItem.size)
        case FileManagerColumnID.packedSize.rawValue:
            compare(firstItem.packedSize, secondItem.packedSize)
        case FileManagerColumnID.modified.rawValue:
            compare(firstItem.modifiedDate ?? Date.distantPast,
                    secondItem.modifiedDate ?? Date.distantPast)
        case FileManagerColumnID.created.rawValue:
            compare(firstItem.createdDate ?? Date.distantPast,
                    secondItem.createdDate ?? Date.distantPast)
        case FileManagerColumnID.accessed.rawValue:
            compare(firstItem.accessedDate ?? Date.distantPast,
                    secondItem.accessedDate ?? Date.distantPast)
        case FileManagerColumnID.changed.rawValue:
            compare(firstItem.changedDate ?? Date.distantPast,
                    secondItem.changedDate ?? Date.distantPast)
        case FileManagerColumnID.attributes.rawValue:
            compare(firstItem.attributes, secondItem.attributes)
        case FileManagerColumnID.inode.rawValue:
            compare(firstItem.inode ?? 0, secondItem.inode ?? 0)
        case FileManagerColumnID.links.rawValue:
            compare(firstItem.links ?? 0, secondItem.links ?? 0)
        case FileManagerColumnID.position.rawValue,
             FileManagerColumnID.block.rawValue,
             FileManagerColumnID.anti.rawValue:
            .orderedSame
        default:
            firstItem.name.localizedStandardCompare(secondItem.name)
        }
    }

    private static func compare(_ firstItem: ArchiveItem,
                                _ secondItem: ArchiveItem,
                                key: String) -> ComparisonResult
    {
        switch key {
        case FileManagerColumnID.name.rawValue:
            return firstItem.name.localizedStandardCompare(secondItem.name)
        case "type":
            return compareType(firstItem.fileExtension,
                               secondItem.fileExtension,
                               firstName: firstItem.name,
                               secondName: secondItem.name)
        case FileManagerColumnID.size.rawValue:
            return compare(firstItem.size, secondItem.size)
        case FileManagerColumnID.packedSize.rawValue:
            return compare(firstItem.packedSize, secondItem.packedSize)
        case FileManagerColumnID.modified.rawValue:
            return compare(firstItem.modifiedDate ?? Date.distantPast,
                           secondItem.modifiedDate ?? Date.distantPast)
        case FileManagerColumnID.created.rawValue:
            return compare(firstItem.createdDate ?? Date.distantPast,
                           secondItem.createdDate ?? Date.distantPast)
        case FileManagerColumnID.accessed.rawValue:
            return compare(firstItem.accessedDate ?? Date.distantPast,
                           secondItem.accessedDate ?? Date.distantPast)
        case FileManagerColumnID.attributes.rawValue:
            return compare(firstItem.attributes, secondItem.attributes)
        case FileManagerColumnID.encrypted.rawValue:
            return compare(firstItem.isEncrypted, secondItem.isEncrypted)
        case FileManagerColumnID.anti.rawValue:
            return compare(firstItem.isAnti, secondItem.isAnti)
        case FileManagerColumnID.method.rawValue:
            return firstItem.method.localizedStandardCompare(secondItem.method)
        case FileManagerColumnID.crc.rawValue:
            return compare(firstItem.crc, secondItem.crc)
        case FileManagerColumnID.block.rawValue:
            return compare(firstItem.block, secondItem.block)
        case FileManagerColumnID.position.rawValue:
            return compare(firstItem.position, secondItem.position)
        case FileManagerColumnID.comment.rawValue:
            return firstItem.comment.localizedStandardCompare(secondItem.comment)
        default:
            let firstValue = firstItem.propertyValues[key] ?? ""
            let secondValue = secondItem.propertyValues[key] ?? ""
            let valueResult = firstValue.localizedStandardCompare(secondValue)
            return valueResult == .orderedSame
                ? firstItem.name.localizedStandardCompare(secondItem.name)
                : valueResult
        }
    }

    private static func compareType(_ firstExtension: String,
                                    _ secondExtension: String,
                                    firstName: String,
                                    secondName: String) -> ComparisonResult
    {
        let typeResult = firstExtension.localizedLowercase.localizedStandardCompare(secondExtension.localizedLowercase)
        return typeResult == .orderedSame
            ? firstName.localizedStandardCompare(secondName)
            : typeResult
    }

    private static func compare<T: Comparable>(_ firstValue: T, _ secondValue: T) -> ComparisonResult {
        firstValue == secondValue ? .orderedSame : (firstValue < secondValue ? .orderedAscending : .orderedDescending)
    }

    private static func compare(_ firstValue: Bool, _ secondValue: Bool) -> ComparisonResult {
        firstValue == secondValue ? .orderedSame : (!firstValue && secondValue ? .orderedAscending : .orderedDescending)
    }
}

private enum VariantType {
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
