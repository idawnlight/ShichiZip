import Foundation

enum FileManagerFavoriteStore {
    static let slotCount = 10

    private static var defaults: UserDefaults {
        SZSharedUserDefaults.defaults
    }

    private static let defaultsKey = "FileManager.Favorites"

    static func url(for slot: Int) -> URL? {
        guard (0 ..< slotCount).contains(slot) else { return nil }

        let path = storedPaths()[slot]
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func set(url: URL, for slot: Int) {
        guard (0 ..< slotCount).contains(slot) else { return }

        var paths = storedPaths()
        paths[slot] = url.standardizedFileURL.path
        defaults.set(paths, forKey: defaultsKey)
    }

    static func saveSlotTitle(for slot: Int) -> String {
        "\(SZL10n.string("favorites.bookmark")) \(slot)"
    }

    static func displayTitle(for slot: Int) -> String {
        guard let url = url(for: slot) else {
            return "-"
        }

        return shortenedPath(url.path)
    }

    private static func storedPaths() -> [String] {
        var paths = defaults.stringArray(forKey: defaultsKey) ?? []

        if paths.count < slotCount {
            paths.append(contentsOf: Array(repeating: "", count: slotCount - paths.count))
        } else if paths.count > slotCount {
            paths.removeSubrange(slotCount ..< paths.count)
        }

        return paths
    }

    private static func shortenedPath(_ path: String) -> String {
        let maxLength = 100
        guard path.count > maxLength else { return path }

        let keepCount = max(1, (maxLength - 5) / 2)
        let prefix = String(path.prefix(keepCount))
        let suffix = String(path.suffix(keepCount))
        return "\(prefix) ... \(suffix)"
    }
}
