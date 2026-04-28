#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerViewPreferencesTests: XCTestCase {
    func testListViewInfoRoundTripsPerFolderType() throws {
        let defaults = try makeIsolatedDefaults()
        let fileSystemInfo = FileManagerViewPreferences.ListViewInfo(
            sortKey: "size",
            ascending: false,
            columns: [
                FileManagerViewPreferences.ListViewColumnInfo(id: .name, isVisible: true, width: 312),
                FileManagerViewPreferences.ListViewColumnInfo(id: .size, isVisible: true, width: 116),
            ],
        )
        let archiveInfo = FileManagerViewPreferences.ListViewInfo(
            sortKey: "method",
            ascending: true,
            columns: [
                FileManagerViewPreferences.ListViewColumnInfo(id: .method, isVisible: true, width: 180),
                FileManagerViewPreferences.ListViewColumnInfo(id: .name, isVisible: true, width: 280),
            ],
        )
        let archiveFolderTypeID = FileManagerViewPreferences.archiveListViewFolderTypeID(formatName: "7z")

        FileManagerViewPreferences.setListViewInfo(fileSystemInfo,
                                                   forFolderTypeID: FileManagerViewPreferences.fileSystemListViewFolderTypeID,
                                                   defaults: defaults)
        FileManagerViewPreferences.setListViewInfo(archiveInfo,
                                                   forFolderTypeID: archiveFolderTypeID,
                                                   defaults: defaults)

        XCTAssertEqual(FileManagerViewPreferences.listViewInfo(forFolderTypeID: FileManagerViewPreferences.fileSystemListViewFolderTypeID,
                                                               defaults: defaults),
                       fileSystemInfo)
        XCTAssertEqual(FileManagerViewPreferences.listViewInfo(forFolderTypeID: archiveFolderTypeID,
                                                               defaults: defaults),
                       archiveInfo)
    }

    func testListViewInfoRoundTripsDynamicColumnIDs() throws {
        let defaults = try makeIsolatedDefaults()
        let dynamicColumnID = FileManagerColumnID(rawValue: "hostOS")
        let info = FileManagerViewPreferences.ListViewInfo(
            sortKey: dynamicColumnID.rawValue,
            ascending: true,
            columns: [
                FileManagerViewPreferences.ListViewColumnInfo(id: .name, isVisible: true, width: 280),
                FileManagerViewPreferences.ListViewColumnInfo(id: dynamicColumnID, isVisible: false, width: 120),
            ],
        )

        FileManagerViewPreferences.setListViewInfo(info,
                                                   forFolderTypeID: FileManagerViewPreferences.archiveListViewFolderTypeID(formatName: "zip"),
                                                   defaults: defaults)

        XCTAssertEqual(FileManagerViewPreferences.listViewInfo(forFolderTypeID: FileManagerViewPreferences.archiveListViewFolderTypeID(formatName: "zip"),
                                                               defaults: defaults),
                       info)
    }

    func testRemoveAllListViewInfosKeepsUnrelatedDefaults() throws {
        let defaults = try makeIsolatedDefaults()
        let info = FileManagerViewPreferences.ListViewInfo(
            sortKey: "name",
            ascending: true,
            columns: [FileManagerViewPreferences.ListViewColumnInfo(id: .name, isVisible: true, width: 250)],
        )

        defaults.set("keep", forKey: "UnrelatedPreference")
        FileManagerViewPreferences.setListViewInfo(info,
                                                   forFolderTypeID: FileManagerViewPreferences.fileSystemListViewFolderTypeID,
                                                   defaults: defaults)
        FileManagerViewPreferences.setListViewInfo(info,
                                                   forFolderTypeID: FileManagerViewPreferences.archiveListViewFolderTypeID(formatName: "zip"),
                                                   defaults: defaults)

        FileManagerViewPreferences.removeAllListViewInfos(defaults: defaults,
                                                          postsChangeNotification: false)

        XCTAssertNil(FileManagerViewPreferences.listViewInfo(forFolderTypeID: FileManagerViewPreferences.fileSystemListViewFolderTypeID,
                                                             defaults: defaults))
        XCTAssertNil(FileManagerViewPreferences.listViewInfo(forFolderTypeID: FileManagerViewPreferences.archiveListViewFolderTypeID(formatName: "zip"),
                                                             defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: "UnrelatedPreference"), "keep")
    }

    func testResolvedListViewColumnsApplySavedOrderAndWidths() {
        let columns = FileManagerColumn.fileSystemColumns
        let info = FileManagerViewPreferences.ListViewInfo(
            sortKey: "size",
            ascending: false,
            columns: [
                FileManagerViewPreferences.ListViewColumnInfo(id: .size, isVisible: true, width: 144),
                FileManagerViewPreferences.ListViewColumnInfo(id: .name, isVisible: true, width: 333),
            ],
        )

        let resolvedColumns = FileManagerViewPreferences.resolvedListViewColumns(columns, using: info)

        XCTAssertEqual(resolvedColumns.map(\.column.id), [.size, .name, .modified, .created])
        XCTAssertEqual(resolvedColumns.map(\.width), [144, 333, 140, 140])
    }

    func testResolvedListViewColumnsIgnoreUnavailableDuplicateAndHiddenColumns() {
        let columns = FileManagerColumn.fileSystemColumns
        let info = FileManagerViewPreferences.ListViewInfo(
            sortKey: "name",
            ascending: true,
            columns: [
                FileManagerViewPreferences.ListViewColumnInfo(id: .crc, isVisible: true, width: 90),
                FileManagerViewPreferences.ListViewColumnInfo(id: .created, isVisible: false, width: 200),
                FileManagerViewPreferences.ListViewColumnInfo(id: .name, isVisible: false, width: 320),
                FileManagerViewPreferences.ListViewColumnInfo(id: .name, isVisible: true, width: 180),
            ],
        )

        let resolvedColumns = FileManagerViewPreferences.resolvedListViewColumns(columns, using: info)

        XCTAssertEqual(resolvedColumns.map(\.column.id), [.name, .size, .modified])
        XCTAssertEqual(resolvedColumns.first?.width, 320)
    }

    func testResolvedListViewColumnsClampInvalidWidths() {
        let columns = FileManagerColumn.fileSystemColumns
        let info = FileManagerViewPreferences.ListViewInfo(
            sortKey: "name",
            ascending: true,
            columns: [
                FileManagerViewPreferences.ListViewColumnInfo(id: .name, isVisible: true, width: -20),
                FileManagerViewPreferences.ListViewColumnInfo(id: .size, isVisible: true, width: 1),
            ],
        )

        let resolvedColumns = FileManagerViewPreferences.resolvedListViewColumns(columns, using: info)

        XCTAssertEqual(resolvedColumns.first(where: { $0.column.id == .name })?.width, 250)
        XCTAssertEqual(resolvedColumns.first(where: { $0.column.id == .size })?.width, 50)
    }

    func testResolvedListViewColumnsPreserveHiddenDynamicColumns() {
        let hostOSColumnID = FileManagerColumnID(rawValue: "hostOS")
        let checksumColumnID = FileManagerColumnID(rawValue: "checksum")
        let columns = FileManagerColumn.archiveColumns(entryProperties: [
            FileManagerArchiveEntryProperty(id: hostOSColumnID,
                                            titleKey: "column.hostOS",
                                            title: "Host OS",
                                            valueType: 8),
            FileManagerArchiveEntryProperty(id: .size,
                                            titleKey: "column.size",
                                            title: "Size",
                                            valueType: 21),
            FileManagerArchiveEntryProperty(id: checksumColumnID,
                                            titleKey: "column.checksum",
                                            title: "Checksum",
                                            valueType: 19),
        ])
        let info = FileManagerViewPreferences.ListViewInfo(
            sortKey: "name",
            ascending: true,
            columns: [
                FileManagerViewPreferences.ListViewColumnInfo(id: hostOSColumnID, isVisible: false, width: 180),
                FileManagerViewPreferences.ListViewColumnInfo(id: .name, isVisible: true, width: 320),
            ],
        )

        let resolvedColumns = FileManagerViewPreferences.resolvedListViewColumns(columns, using: info)

        XCTAssertEqual(resolvedColumns.map(\.column.id), [.name, .size, checksumColumnID])
    }

    func testListViewColumnInfosPreserveHiddenPositionAndWidth() {
        let columns = FileManagerColumn.fileSystemColumns
        let previousInfo = FileManagerViewPreferences.ListViewInfo(
            sortKey: "name",
            ascending: true,
            columns: [
                FileManagerViewPreferences.ListViewColumnInfo(id: .name, isVisible: true, width: 320),
                FileManagerViewPreferences.ListViewColumnInfo(id: .size, isVisible: true, width: 128),
                FileManagerViewPreferences.ListViewColumnInfo(id: .modified, isVisible: true, width: 172),
                FileManagerViewPreferences.ListViewColumnInfo(id: .created, isVisible: true, width: 156),
            ],
        )
        let visibleColumnsAfterHidingSize = [
            FileManagerViewPreferences.ListViewColumnInfo(id: .name, isVisible: true, width: 320),
            FileManagerViewPreferences.ListViewColumnInfo(id: .modified, isVisible: true, width: 172),
            FileManagerViewPreferences.ListViewColumnInfo(id: .created, isVisible: true, width: 156),
        ]

        let savedColumns = FileManagerViewPreferences.listViewColumnInfosPreservingHiddenColumns(
            availableColumns: columns,
            visibleColumns: visibleColumnsAfterHidingSize,
            previousInfo: previousInfo,
        )

        XCTAssertEqual(savedColumns.map(\.id), [.name, .size, .modified, .created])
        XCTAssertEqual(savedColumns.map(\.isVisible), [true, false, true, true])
        XCTAssertEqual(savedColumns.first(where: { $0.id == .size })?.width, 128)
    }

    func testResolvedListViewSortDescriptorRestoresAvailableSortKey() {
        let columns = FileManagerColumn.archiveColumns(availablePropertyKeys: ["method", "size"])
        let info = FileManagerViewPreferences.ListViewInfo(sortKey: "method",
                                                           ascending: true,
                                                           columns: [])

        let descriptor = FileManagerViewPreferences.resolvedListViewSortDescriptor(using: info,
                                                                                   columns: columns)

        XCTAssertEqual(descriptor?.key, "method")
        XCTAssertEqual(descriptor?.ascending, true)
        XCTAssertNotNil(descriptor?.selector)
    }

    func testResolvedListViewSortDescriptorHandlesTypeSortAndFallback() {
        let typeInfo = FileManagerViewPreferences.ListViewInfo(sortKey: "type",
                                                               ascending: true,
                                                               columns: [])
        let fallbackInfo = FileManagerViewPreferences.ListViewInfo(sortKey: "crc",
                                                                   ascending: false,
                                                                   columns: [])

        let typeDescriptor = FileManagerViewPreferences.resolvedListViewSortDescriptor(using: typeInfo,
                                                                                       columns: FileManagerColumn.fileSystemColumns)
        let fallbackDescriptor = FileManagerViewPreferences.resolvedListViewSortDescriptor(using: fallbackInfo,
                                                                                           columns: FileManagerColumn.fileSystemColumns)

        XCTAssertEqual(typeDescriptor?.key, "type")
        XCTAssertEqual(FileManagerViewPreferences.highlightedColumnID(for: "type",
                                                                      columns: FileManagerColumn.fileSystemColumns),
                       .name)
        XCTAssertEqual(fallbackDescriptor?.key, "name")
        XCTAssertEqual(fallbackDescriptor?.ascending, true)
    }

    func testMakeDateFormatterReturnsIndependentInstances() {
        let first = FileManagerViewPreferences.makeDateFormatter(dateStyle: .medium,
                                                                 timeStyle: .medium)
        let second = FileManagerViewPreferences.makeDateFormatter(dateStyle: .medium,
                                                                  timeStyle: .medium)

        XCTAssertFalse(first === second)
        XCTAssertEqual(first.string(from: Date(timeIntervalSince1970: 1_713_635_445)),
                       second.string(from: Date(timeIntervalSince1970: 1_713_635_445)))
    }

    func testMakeListDateFormatterReturnsIndependentInstances() {
        let first = FileManagerViewPreferences.makeListDateFormatter()
        let second = FileManagerViewPreferences.makeListDateFormatter()

        XCTAssertFalse(first === second)
        XCTAssertEqual(first.string(from: Date(timeIntervalSince1970: 1_713_635_445)),
                       second.string(from: Date(timeIntervalSince1970: 1_713_635_445)))
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "FileManagerViewPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

final class FileManagerColumnTests: XCTestCase {
    func testFileSystemColumnsRemainFixed() {
        XCTAssertEqual(FileManagerColumn.fileSystemColumns.map(\.id), [.name, .size, .modified, .created])
    }

    func testArchiveColumnsFollowHandlerPropertyOrder() {
        let columns = FileManagerColumn.archiveColumns(availablePropertyKeys: [
            "crc",
            "method",
            "size",
            "unknown",
            "name",
            "encrypted",
            "accessed",
            "block",
            "position",
            "anti",
            "size",
            "packedSize",
        ])

        XCTAssertEqual(columns.map(\.id), [
            .name,
            .crc,
            .method,
            .size,
            FileManagerColumnID(rawValue: "unknown"),
            .encrypted,
            .accessed,
            .block,
            .position,
            .anti,
            .packedSize,
        ])
    }

    func testArchiveColumnsAlwaysIncludeName() {
        XCTAssertEqual(FileManagerColumn.archiveColumns(availablePropertyKeys: []).map(\.id), [.name])
    }

    func testArchiveColumnsIncludeDynamicProperties() {
        let hostOSColumnID = FileManagerColumnID(rawValue: "hostOS")
        let checksumColumnID = FileManagerColumnID(rawValue: "checksum")
        let columns = FileManagerColumn.archiveColumns(entryProperties: [
            FileManagerArchiveEntryProperty(id: hostOSColumnID,
                                            titleKey: "column.hostOS",
                                            title: "Host OS",
                                            valueType: 8),
            FileManagerArchiveEntryProperty(id: checksumColumnID,
                                            titleKey: "column.checksum",
                                            title: "Checksum",
                                            valueType: 19),
        ])

        XCTAssertEqual(columns.map(\.id), [.name, hostOSColumnID, checksumColumnID])
        XCTAssertEqual(columns.first(where: { $0.id == hostOSColumnID })?.titleFallback, "Host OS")
        XCTAssertEqual(columns.first(where: { $0.id == hostOSColumnID })?.alignment, .left)
        XCTAssertEqual(columns.first(where: { $0.id == checksumColumnID })?.alignment, .right)
    }

    func testColumnAlignmentFollowsUpstreamPropertyTypes() {
        XCTAssertEqual(FileManagerColumn.definition(for: .method).alignment, .left)
        XCTAssertEqual(FileManagerColumn.definition(for: .comment).alignment, .left)
        XCTAssertEqual(FileManagerColumn.definition(for: .modified).alignment, .left)
        XCTAssertEqual(FileManagerColumn.definition(for: .crc).alignment, .right)
        XCTAssertEqual(FileManagerColumn.definition(for: .attributes).alignment, .right)
        XCTAssertEqual(FileManagerColumn.definition(for: .encrypted).alignment, .right)
        XCTAssertEqual(FileManagerColumn.definition(for: .anti).alignment, .right)
    }

    func testColumnTextStylesSeparateNumbersAndFixedWidthFields() {
        XCTAssertEqual(FileManagerColumn.definition(for: .method).textStyle, .standard)
        XCTAssertEqual(FileManagerColumn.definition(for: .size).textStyle, .tabularNumbers)
        XCTAssertEqual(FileManagerColumn.definition(for: .modified).textStyle, .tabularNumbers)
        XCTAssertEqual(FileManagerColumn.definition(for: .crc).textStyle, .fixedWidth)
        XCTAssertEqual(FileManagerColumn.definition(for: .attributes).textStyle, .fixedWidth)
    }

    func testColumnDisplayStringsFlattenLineBreaks() {
        let column = FileManagerColumn.definition(for: .comment)

        XCTAssertEqual(column.normalizedDisplayString("alpha\nbeta\rgamma\r\ndelta\u{2028}epsilon"),
                       "alpha beta gamma delta epsilon")
        XCTAssertEqual(column.normalizedDisplayString("plain text"), "plain text")
    }

    func testArchiveExposesEntryPropertyKeysFromHandler() throws {
        let archiveURL = try makeArchive(named: "entry-property-keys")
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let keys = Set(archive.entryPropertyKeys)
        XCTAssertTrue(keys.contains("name"))
        XCTAssertTrue(keys.contains("size"))
        XCTAssertTrue(keys.contains("modified"))
    }
}

final class FileManagerDirectoryListingTests: XCTestCase {
    func testEntriesPreservePresentedSymlinkDirectoryPath() throws {
        let tempRoot = try makeTemporaryDirectory(named: "directory-listing-symlink")
        let targetDirectory = tempRoot.appendingPathComponent("target", isDirectory: true)
        let presentedDirectory = tempRoot.appendingPathComponent("presented", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: presentedDirectory, withDestinationURL: targetDirectory)

        let childDirectory = targetDirectory.appendingPathComponent("child", isDirectory: true)
        let childFile = targetDirectory.appendingPathComponent("payload.txt")
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        try "payload".write(to: childFile, atomically: true, encoding: .utf8)

        let entries = try FileManagerDirectoryListing.entriesPreservingPresentedPath(for: presentedDirectory,
                                                                                     options: [])
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }

        XCTAssertEqual(entries.map { $0.url.deletingLastPathComponent().standardizedFileURL },
                       [presentedDirectory.standardizedFileURL, presentedDirectory.standardizedFileURL])
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["child", "payload.txt"])
        XCTAssertEqual(entries.map { $0.resourceValues?.isDirectory }, [true, false])
    }
}
