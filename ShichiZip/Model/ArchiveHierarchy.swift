import Foundation

struct ArchiveDirectoryID: Hashable {
    fileprivate let componentKeys: [Data]
}

struct ArchiveHierarchyRecord {
    let itemIndex: Int
    let pathParts: [String]
    let isDirectory: Bool
}

struct ArchiveHierarchy {
    enum Child {
        case directory(Directory)
        case entry(itemIndex: Int)

        fileprivate var firstItemIndex: Int {
            switch self {
            case let .directory(directory):
                directory.firstItemIndex
            case let .entry(itemIndex):
                itemIndex
            }
        }
    }

    final class Directory {
        let id: ArchiveDirectoryID
        let name: String
        let pathParts: [String]
        fileprivate(set) var representativeItemIndex: Int?
        fileprivate(set) var firstItemIndex: Int
        fileprivate(set) var childDirectories: [Directory] = []
        fileprivate(set) var explicitItemIndices: [Int] = []
        fileprivate(set) var terminalItemIndices: [Int] = []

        private var childrenByKey: [Data: Directory] = [:]

        fileprivate init(id: ArchiveDirectoryID,
                         name: String,
                         pathParts: [String],
                         firstItemIndex: Int)
        {
            self.id = id
            self.name = name
            self.pathParts = pathParts
            self.firstItemIndex = firstItemIndex
        }

        fileprivate func child(named name: String,
                               pathParts: [String],
                               itemIndex: Int) -> Directory
        {
            let key = Self.comparisonKey(for: name)
            if let child = childrenByKey[key] {
                child.firstItemIndex = min(child.firstItemIndex, itemIndex)
                return child
            }

            let child = Directory(
                id: ArchiveDirectoryID(componentKeys: id.componentKeys + [key]),
                name: name,
                pathParts: pathParts,
                firstItemIndex: itemIndex,
            )
            childrenByKey[key] = child
            childDirectories.append(child)
            return child
        }

        fileprivate func child(named name: String) -> Directory? {
            childrenByKey[Self.comparisonKey(for: name)]
        }

        fileprivate func finalize() {
            explicitItemIndices.sort()
            terminalItemIndices.sort()
            childDirectories.sort {
                if $0.firstItemIndex != $1.firstItemIndex {
                    return $0.firstItemIndex < $1.firstItemIndex
                }
                return $0.name < $1.name
            }
        }

        var childrenInArchiveOrder: [Child] {
            let directories = childDirectories.map(Child.directory)
            let entries = terminalItemIndices.map(Child.entry)
            return (directories + entries).sorted {
                $0.firstItemIndex < $1.firstItemIndex
            }
        }

        private static func comparisonKey(for component: String) -> Data {
            SZArchive.fileNameComparisonKey(forArchivePathComponent: component)
        }
    }

    let root: Directory

    init(records: [ArchiveHierarchyRecord]) {
        root = Directory(id: ArchiveDirectoryID(componentKeys: []),
                         name: "",
                         pathParts: [],
                         firstItemIndex: 0)

        for record in records where !record.pathParts.isEmpty {
            var directory = root
            let directoryDepth = record.isDirectory
                ? record.pathParts.count
                : record.pathParts.count - 1

            if directoryDepth > 0 {
                for depth in 0 ..< directoryDepth {
                    directory = directory.child(
                        named: record.pathParts[depth],
                        pathParts: Array(record.pathParts.prefix(depth + 1)),
                        itemIndex: record.itemIndex,
                    )
                }
            }

            if record.isDirectory {
                directory.explicitItemIndices.append(record.itemIndex)
                if let representativeItemIndex = directory.representativeItemIndex {
                    directory.representativeItemIndex = min(representativeItemIndex,
                                                            record.itemIndex)
                } else {
                    directory.representativeItemIndex = record.itemIndex
                }
            } else {
                directory.terminalItemIndices.append(record.itemIndex)
            }
        }

        var stack = [root]
        while let directory = stack.popLast() {
            directory.finalize()
            stack.append(contentsOf: directory.childDirectories)
        }
    }

    func directory(at pathParts: [String]) -> Directory? {
        var directory = root
        for component in pathParts {
            guard let child = directory.child(named: component) else {
                return nil
            }
            directory = child
        }
        return directory
    }

    func recordIndices(in rootDirectory: Directory) -> [Int] {
        var result: [Int] = []
        var stack = [rootDirectory]
        while let directory = stack.popLast() {
            result.append(contentsOf: directory.explicitItemIndices)
            result.append(contentsOf: directory.terminalItemIndices)
            stack.append(contentsOf: directory.childDirectories)
        }
        return result.sorted()
    }
}
