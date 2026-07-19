import Foundation

struct FileManagerNestedArchiveIdentity: Hashable {
    struct Entry: Hashable {
        let archiveIndex: Int
        let path: String
        let isDirectory: Bool
    }

    let topLevelArchiveURL: URL
    let entryLineage: [Entry]
    let displayPath: String

    init(topLevelArchiveURL: URL,
         entryLineage: [Entry],
         displayPath: String)
    {
        self.topLevelArchiveURL = topLevelArchiveURL.standardizedFileURL
        self.entryLineage = entryLineage
        self.displayPath = NSString(string: displayPath).standardizingPath
    }

    static func root(topLevelArchiveURL: URL) -> Self {
        Self(topLevelArchiveURL: topLevelArchiveURL,
             entryLineage: [],
             displayPath: topLevelArchiveURL.path)
    }

    var isRoot: Bool {
        entryLineage.isEmpty
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.topLevelArchiveURL == rhs.topLevelArchiveURL
            && lhs.entryLineage == rhs.entryLineage
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(topLevelArchiveURL)
        hasher.combine(entryLineage)
    }
}

struct FileManagerNestedArchiveOpenSnapshot: Equatable {
    let archiveIdentifier: ObjectIdentifier
    let identity: FileManagerNestedArchiveIdentity?
    let isDirty: Bool
}

enum FileManagerNestedArchiveConflictDetector {
    static func hasConflictingOpenInstance(for identity: FileManagerNestedArchiveIdentity,
                                           in snapshots: [FileManagerNestedArchiveOpenSnapshot]) -> Bool
    {
        var matchingArchiveIdentifiers = Set<ObjectIdentifier>()
        let conflictingInstanceCount = identity.isRoot ? 1 : 2

        for snapshot in snapshots where matches(snapshot.identity,
                                                 target: identity)
        {
            matchingArchiveIdentifiers.insert(snapshot.archiveIdentifier)
            if matchingArchiveIdentifiers.count >= conflictingInstanceCount {
                return true
            }
        }

        return false
    }

    static func hasDirtyOpenInstance(for identity: FileManagerNestedArchiveIdentity,
                                     in snapshots: [FileManagerNestedArchiveOpenSnapshot]) -> Bool
    {
        for snapshot in snapshots where matches(snapshot.identity,
                                                 target: identity)
        {
            if snapshot.isDirty {
                return true
            }
        }

        return false
    }

    private static func matches(_ candidate: FileManagerNestedArchiveIdentity?,
                                target: FileManagerNestedArchiveIdentity) -> Bool
    {
        guard let candidate else { return false }
        if target.isRoot {
            return candidate.topLevelArchiveURL == target.topLevelArchiveURL
        }
        return candidate == target
    }
}
