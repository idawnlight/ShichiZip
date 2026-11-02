import Foundation

enum FileManagerItemSorting {
    static func sort(_ items: inout [FileSystemItem], by descriptors: [NSSortDescriptor]) {
        let descriptor = descriptors.first
        let columnID = FileManagerColumnID(rawValue: descriptor?.key ?? FileManagerColumnID.name.rawValue)
        let ascending = descriptor?.ascending ?? true

        items.sort { firstItem, secondItem in
            if firstItem.isDirectory != secondItem.isDirectory {
                return firstItem.isDirectory
            }

            let result = compare(firstItem, secondItem, columnID: columnID)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    static func sort(_ items: inout [ArchiveItem], by descriptors: [NSSortDescriptor]) {
        let descriptor = descriptors.first
        let columnID = FileManagerColumnID(rawValue: descriptor?.key ?? FileManagerColumnID.name.rawValue)
        let ascending = descriptor?.ascending ?? true

        items.sort { firstItem, secondItem in
            if firstItem.isDirectory != secondItem.isDirectory {
                return firstItem.isDirectory
            }

            let result = compare(firstItem, secondItem, columnID: columnID)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compare(_ firstItem: FileSystemItem,
                                _ secondItem: FileSystemItem,
                                columnID: FileManagerColumnID) -> ComparisonResult
    {
        switch columnID {
        case .name:
            firstItem.name.localizedStandardCompare(secondItem.name)
        case "type":
            compareText(firstItem.url.pathExtension.localizedLowercase,
                        secondItem.url.pathExtension.localizedLowercase,
                        firstName: firstItem.name,
                        secondName: secondItem.name)
        case .size:
            compare(firstItem.size, secondItem.size)
        case .packedSize:
            compare(firstItem.packedSize, secondItem.packedSize)
        case .modified:
            compare(firstItem.modifiedDate ?? Date.distantPast,
                    secondItem.modifiedDate ?? Date.distantPast)
        case .created:
            compare(firstItem.createdDate ?? Date.distantPast,
                    secondItem.createdDate ?? Date.distantPast)
        case .accessed:
            compare(firstItem.accessedDate ?? Date.distantPast,
                    secondItem.accessedDate ?? Date.distantPast)
        case .changed:
            compare(firstItem.changedDate ?? Date.distantPast,
                    secondItem.changedDate ?? Date.distantPast)
        case .attributes:
            compare(firstItem.attributes, secondItem.attributes)
        case .inode:
            compare(firstItem.inode ?? 0, secondItem.inode ?? 0)
        case .links:
            compare(firstItem.links ?? 0, secondItem.links ?? 0)
        case .position,
             .block,
             .anti:
            .orderedSame
        default:
            firstItem.name.localizedStandardCompare(secondItem.name)
        }
    }

    private static func compare(_ firstItem: ArchiveItem,
                                _ secondItem: ArchiveItem,
                                columnID: FileManagerColumnID) -> ComparisonResult
    {
        switch columnID {
        case .name:
            firstItem.name.localizedStandardCompare(secondItem.name)
        case "type":
            compareText(firstItem.fileExtension.localizedLowercase,
                        secondItem.fileExtension.localizedLowercase,
                        firstName: firstItem.name,
                        secondName: secondItem.name)
        case .size:
            compare(firstItem.size, secondItem.size)
        case .packedSize:
            compare(firstItem.packedSize, secondItem.packedSize)
        case .modified:
            compare(firstItem.modifiedDate ?? Date.distantPast,
                    secondItem.modifiedDate ?? Date.distantPast)
        case .created:
            compare(firstItem.createdDate ?? Date.distantPast,
                    secondItem.createdDate ?? Date.distantPast)
        case .accessed:
            compare(firstItem.accessedDate ?? Date.distantPast,
                    secondItem.accessedDate ?? Date.distantPast)
        case .attributes:
            compare(firstItem.attributes, secondItem.attributes)
        case .encrypted:
            compare(firstItem.isEncrypted, secondItem.isEncrypted)
        case .anti:
            compare(firstItem.isAnti, secondItem.isAnti)
        case .method:
            firstItem.method.localizedStandardCompare(secondItem.method)
        case .crc:
            compare(firstItem.crc, secondItem.crc)
        case .block:
            compare(firstItem.block, secondItem.block)
        case .position:
            compare(firstItem.position, secondItem.position)
        case .comment:
            firstItem.comment.localizedStandardCompare(secondItem.comment)
        default:
            compareText(firstItem.propertyValues[columnID.rawValue] ?? "",
                        secondItem.propertyValues[columnID.rawValue] ?? "",
                        firstName: firstItem.name,
                        secondName: secondItem.name)
        }
    }

    private static func compareText(_ firstValue: String,
                                    _ secondValue: String,
                                    firstName: String,
                                    secondName: String) -> ComparisonResult
    {
        let result = firstValue.localizedStandardCompare(secondValue)
        return result == .orderedSame
            ? firstName.localizedStandardCompare(secondName)
            : result
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
