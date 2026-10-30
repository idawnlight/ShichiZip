import Foundation

/// Persists MRU entries while callers retain their path normalization and display rules.
struct PathHistoryStore {
    let defaults: UserDefaults
    let entriesKey: String
    let maxEntries: Int

    init(defaults: UserDefaults = SZSharedUserDefaults.defaults, entriesKey: String, maxEntries: Int = 20) {
        self.defaults = defaults
        self.entriesKey = entriesKey
        self.maxEntries = maxEntries
    }

    func entries() -> [String] {
        defaults.stringArray(forKey: entriesKey) ?? []
    }

    func record(_ path: String) {
        record(path, replacing: { $0 == path })
    }

    func record(_ path: String, replacing matches: (String) -> Bool) {
        var updatedEntries = entries().filter { !matches($0) }
        updatedEntries.insert(path, at: 0)
        if updatedEntries.count > maxEntries {
            updatedEntries.removeSubrange(maxEntries ..< updatedEntries.count)
        }
        defaults.set(updatedEntries, forKey: entriesKey)
    }
}
