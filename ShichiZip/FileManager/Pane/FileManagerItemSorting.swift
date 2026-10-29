import Foundation

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

    private static func compare<T: Comparable>(_ firstValue: T?, _ secondValue: T?) -> ComparisonResult {
        switch (firstValue, secondValue) {
        case (nil, nil):
            .orderedSame
        case (nil, _):
            .orderedAscending
        case (_, nil):
            .orderedDescending
        case let (firstValue?, secondValue?):
            compare(firstValue, secondValue)
        }
    }

    private static func compare(_ firstValue: Bool, _ secondValue: Bool) -> ComparisonResult {
        firstValue == secondValue ? .orderedSame : (!firstValue && secondValue ? .orderedAscending : .orderedDescending)
    }
}
