import Cocoa

extension FileManagerViewPreferences {
    struct ListViewColumnInfo: Equatable {
        let id: FileManagerColumnID
        let isVisible: Bool
        let width: CGFloat
    }

    struct ListViewInfo: Equatable {
        let sortKey: String
        let ascending: Bool
        let columns: [ListViewColumnInfo]
    }

    struct ResolvedListViewColumn: Equatable {
        let column: FileManagerColumn
        let width: CGFloat
    }

    static let fileSystemListViewFolderTypeID = "FSFolder"
    static let listViewPreferencesResetUserInfoKey = "FileManager.ListViewPreferencesReset"
    static let disableListViewInfoPersistenceDefaultsKey = "FileManager.DisableListViewInfoPersistence"

    private static let listViewInfoKeyPrefix = "FileManager.ListViewInfo."
    private static let listViewInfoVersion = 1
    private static let maximumStoredColumnWidth: CGFloat = 4000

    static var isListViewInfoPersistenceDisabled: Bool {
        UserDefaults.standard.bool(forKey: disableListViewInfoPersistenceDefaultsKey)
    }

    static func archiveListViewFolderTypeID(formatName: String?) -> String {
        let trimmedName = formatName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? "7-Zip" : "7-Zip." + trimmedName
    }

    static func listViewInfo(forFolderTypeID folderTypeID: String,
                             defaults: UserDefaults = .standard) -> ListViewInfo?
    {
        guard let data = defaults.data(forKey: listViewInfoDefaultsKey(forFolderTypeID: folderTypeID)),
              let storedInfo = try? PropertyListDecoder().decode(StoredListViewInfo.self, from: data),
              storedInfo.version == listViewInfoVersion,
              let info = ListViewInfo(storedInfo: storedInfo)
        else {
            return nil
        }

        return info
    }

    static func setListViewInfo(_ info: ListViewInfo,
                                forFolderTypeID folderTypeID: String,
                                defaults: UserDefaults = .standard)
    {
        let storedInfo = StoredListViewInfo(info: info, version: listViewInfoVersion)
        guard let data = try? PropertyListEncoder().encode(storedInfo) else { return }
        defaults.set(data, forKey: listViewInfoDefaultsKey(forFolderTypeID: folderTypeID))
    }

    static func removeAllListViewInfos(defaults: UserDefaults = .standard,
                                       postsChangeNotification: Bool = true)
    {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(listViewInfoKeyPrefix) {
            defaults.removeObject(forKey: key)
        }

        if postsChangeNotification {
            NotificationCenter.default.post(name: .fileManagerViewPreferencesDidChange,
                                            object: nil,
                                            userInfo: [listViewPreferencesResetUserInfoKey: true])
        }
    }

    static func resolvedListViewColumns(_ columns: [FileManagerColumn],
                                        using info: ListViewInfo?) -> [ResolvedListViewColumn]
    {
        guard let info else {
            return columns
                .filter(\.defaultVisible)
                .map { ResolvedListViewColumn(column: $0, width: $0.width) }
        }

        let availableColumns = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0) })
        var resolvedColumns: [ResolvedListViewColumn] = []
        var seenColumnIDs = Set<FileManagerColumnID>()

        for columnInfo in info.columns {
            guard let column = availableColumns[columnInfo.id],
                  !seenColumnIDs.contains(columnInfo.id)
            else {
                continue
            }

            seenColumnIDs.insert(columnInfo.id)
            guard columnInfo.isVisible || columnInfo.id == .name else { continue }

            resolvedColumns.append(ResolvedListViewColumn(column: column,
                                                          width: normalizedColumnWidth(columnInfo.width,
                                                                                       for: column)))
        }

        for column in columns where !seenColumnIDs.contains(column.id) && column.defaultVisible {
            resolvedColumns.append(ResolvedListViewColumn(column: column, width: column.width))
        }

        return resolvedColumns
    }

    static func listViewColumnInfosPreservingHiddenColumns(availableColumns: [FileManagerColumn],
                                                           visibleColumns: [ListViewColumnInfo],
                                                           previousInfo: ListViewInfo?) -> [ListViewColumnInfo]
    {
        let availableColumnsByID = Dictionary(uniqueKeysWithValues: availableColumns.map { ($0.id, $0) })
        var visibleColumnsByID: [FileManagerColumnID: ListViewColumnInfo] = [:]
        var orderedIDs: [FileManagerColumnID] = []
        var seenColumnIDs = Set<FileManagerColumnID>()

        for visibleColumn in visibleColumns where availableColumnsByID[visibleColumn.id] != nil {
            guard seenColumnIDs.insert(visibleColumn.id).inserted else { continue }
            orderedIDs.append(visibleColumn.id)
            visibleColumnsByID[visibleColumn.id] = visibleColumn
        }

        let previousColumnInfos = previousInfo?.columns ?? []
        var previousOrderedIDs: [FileManagerColumnID] = []
        var previousColumnInfosByID: [FileManagerColumnID: ListViewColumnInfo] = [:]
        seenColumnIDs.removeAll()
        for previousColumn in previousColumnInfos where availableColumnsByID[previousColumn.id] != nil {
            guard seenColumnIDs.insert(previousColumn.id).inserted else { continue }
            previousOrderedIDs.append(previousColumn.id)
            previousColumnInfosByID[previousColumn.id] = previousColumn
        }

        let visibleIDs = Set(visibleColumnsByID.keys)
        for hiddenID in previousOrderedIDs where !visibleIDs.contains(hiddenID) && !orderedIDs.contains(hiddenID) {
            let predecessors = previousOrderedIDs.prefix { $0 != hiddenID }
            let insertionIndex = predecessors
                .compactMap { orderedIDs.firstIndex(of: $0) }
                .max()
                .map { $0 + 1 } ?? 0
            orderedIDs.insert(hiddenID, at: min(insertionIndex, orderedIDs.count))
        }

        for column in availableColumns where !orderedIDs.contains(column.id) {
            orderedIDs.append(column.id)
        }

        return orderedIDs.compactMap { columnID in
            guard let column = availableColumnsByID[columnID] else { return nil }
            if let visibleColumn = visibleColumnsByID[columnID] {
                return ListViewColumnInfo(id: columnID,
                                          isVisible: true,
                                          width: normalizedColumnWidth(visibleColumn.width, for: column))
            }

            return ListViewColumnInfo(id: columnID,
                                      isVisible: columnID == .name,
                                      width: normalizedColumnWidth(previousColumnInfosByID[columnID]?.width ?? column.width,
                                                                   for: column))
        }
    }

    static func resolvedListViewSortDescriptor(using info: ListViewInfo?,
                                               columns: [FileManagerColumn]) -> NSSortDescriptor?
    {
        guard let info else {
            return columns.first(where: { $0.id == .name })?.sortDescriptorPrototype
        }

        return sortDescriptor(sortKey: info.sortKey,
                              ascending: info.ascending,
                              columns: columns)
            ?? columns.first(where: { $0.id == .name })?.sortDescriptorPrototype
    }

    static func highlightedColumnID(for sortKey: String,
                                    columns: [FileManagerColumn]) -> FileManagerColumnID?
    {
        if sortKey == "type" {
            return columns.contains(where: { $0.id == .name }) ? .name : nil
        }
        return columns.first(where: { $0.sortKey == sortKey })?.id
    }

    static func listViewInfoDefaultsKey(forFolderTypeID folderTypeID: String) -> String {
        listViewInfoKeyPrefix + folderTypeID
    }

    private static func sortDescriptor(sortKey: String,
                                       ascending: Bool,
                                       columns: [FileManagerColumn]) -> NSSortDescriptor?
    {
        if sortKey == "type", columns.contains(where: { $0.id == .name }) {
            return NSSortDescriptor(key: sortKey,
                                    ascending: ascending,
                                    selector: #selector(NSString.localizedStandardCompare(_:)))
        }

        guard let column = columns.first(where: { $0.sortKey == sortKey }) else {
            return nil
        }

        if let sortSelector = column.sortSelector {
            return NSSortDescriptor(key: column.sortKey,
                                    ascending: ascending,
                                    selector: sortSelector)
        }
        return NSSortDescriptor(key: column.sortKey,
                                ascending: ascending)
    }

    private static func normalizedColumnWidth(_ width: CGFloat,
                                              for column: FileManagerColumn) -> CGFloat
    {
        guard width.isFinite, width > 0 else {
            return column.width
        }
        return min(max(width, column.minWidth), maximumStoredColumnWidth)
    }
}

private struct StoredListViewColumnInfo: Codable {
    let id: String
    let isVisible: Bool
    let width: Double
}

private struct StoredListViewInfo: Codable {
    let version: Int
    let sortKey: String
    let ascending: Bool
    let columns: [StoredListViewColumnInfo]
}

private extension StoredListViewInfo {
    init(info: FileManagerViewPreferences.ListViewInfo,
         version: Int)
    {
        self.init(version: version,
                  sortKey: info.sortKey,
                  ascending: info.ascending,
                  columns: info.columns.map {
                      StoredListViewColumnInfo(id: $0.id.rawValue,
                                               isVisible: $0.isVisible,
                                               width: Double($0.width))
                  })
    }
}

private extension FileManagerViewPreferences.ListViewInfo {
    init?(storedInfo: StoredListViewInfo) {
        let columns = storedInfo.columns.map { storedColumn in
            FileManagerViewPreferences.ListViewColumnInfo(id: FileManagerColumnID(rawValue: storedColumn.id),
                                                          isVisible: storedColumn.isVisible,
                                                          width: CGFloat(storedColumn.width))
        }

        self.init(sortKey: storedInfo.sortKey,
                  ascending: storedInfo.ascending,
                  columns: columns)
    }
}
