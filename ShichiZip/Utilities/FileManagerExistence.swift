import Foundation

extension FileManager {
    enum SZExistingItemKind: Equatable {
        case directory
        case nonDirectory
    }

    func szExistingItemKind(at url: URL) -> SZExistingItemKind? {
        var isDirectory: ObjCBool = false
        guard fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue ? .directory : .nonDirectory
    }

    func szDirectoryExists(at url: URL) -> Bool {
        szExistingItemKind(at: url) == .directory
    }
}
