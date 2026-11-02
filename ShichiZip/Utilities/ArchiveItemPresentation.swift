import Foundation

/// Text formatting shared by file-manager archive lists and Quick Look.
enum ArchiveItemPresentation {
    enum NameStyle {
        case name
        case path
    }

    static func listCellText(for item: ArchiveItem,
                             columnID: FileManagerColumnID,
                             dateFormatter: DateFormatter,
                             nameStyle: NameStyle = .name) -> String
    {
        switch columnID {
        case .name:
            nameStyle == .path && !item.path.isEmpty ? item.path : item.name
        case .size:
            item.isDirectory ? "--" : item.formattedSize
        case .packedSize:
            item.isDirectory ? "" : item.formattedPackedSize
        case .modified:
            item.modifiedDate.map { dateFormatter.string(from: $0) } ?? ""
        case .created:
            item.createdDate.map { dateFormatter.string(from: $0) } ?? ""
        case .accessed:
            item.accessedDate.map { dateFormatter.string(from: $0) } ?? ""
        case .attributes:
            formattedAttributes(item.attributes)
        case .encrypted:
            item.isEncrypted ? "+" : "-"
        case .anti:
            item.isAnti ? "+" : "-"
        case .method:
            item.method
        case .crc:
            item.crc == 0 ? "" : String(format: "%08X", item.crc)
        case .block:
            String(item.block)
        case .position:
            String(item.position)
        case .comment:
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
