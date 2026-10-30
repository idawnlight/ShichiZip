#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class ArchivePreviewPresentationTests: XCTestCase {
    func testHiddenFilteringRemovesDotPathComponentsAndHiddenAttributes() {
        let visible = makeItem(path: "Documents/visible.txt")
        let dotFile = makeItem(path: "Documents/.secret")
        let dotDirectoryChild = makeItem(path: ".config/settings.json")
        let hiddenAttribute = makeItem(path: "hidden.txt",
                                       attributes: ArchivePreviewPresentation.hiddenAttributeMask)

        let allItems = [visible, dotFile, dotDirectoryChild, hiddenAttribute]

        XCTAssertEqual(ArchivePreviewPresentation.filteredItems(allItems,
                                                                showHiddenItems: false).map(\.path),
                       ["Documents/visible.txt"])
        XCTAssertEqual(ArchivePreviewPresentation.filteredItems(allItems,
                                                                showHiddenItems: true).map(\.path),
                       allItems.map(\.path))
        XCTAssertFalse(visible.isHidden)
        XCTAssertTrue(dotFile.isHidden)
        XCTAssertTrue(dotDirectoryChild.isHidden)
        XCTAssertTrue(hiddenAttribute.isHidden)
    }

    func testSummaryMatchesMainFileManagerStatusFormat() {
        let items = [
            makeItem(path: "a.txt", size: 2),
            makeItem(path: "folder", size: 0, isDirectory: true),
            makeItem(path: "b.txt", size: 5),
        ]

        let summary = ArchivePreviewPresentation.summary(for: items)

        XCTAssertEqual(summary, ArchivePreviewSummary(fileCount: 2,
                                                      folderCount: 1,
                                                      fileSize: 7))
        XCTAssertEqual(ArchivePreviewPresentation.summaryText(for: items),
                       "2 \(SZL10n.string("app.fileManager.statusFiles")), 1 \(SZL10n.string("app.fileManager.statusFolder")) — \(ByteCountFormatter.string(fromByteCount: 7, countStyle: .file))")
    }

    func testSummaryAndCellsOmitUnknownSizeWithoutHidingKnownZero() {
        let unknown = makeItem(path: "unknown.bin", size: nil)
        let zero = makeItem(path: "empty.bin", size: 0)
        let zeroText = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
        let dateFormatter = DateFormatter()

        XCTAssertEqual(ArchiveItemPresentation.listCellText(for: unknown,
                                                            columnID: .size,
                                                            dateFormatter: dateFormatter),
                       "")
        XCTAssertEqual(ArchiveItemPresentation.listCellText(for: zero,
                                                            columnID: .size,
                                                            dateFormatter: dateFormatter),
                       zeroText)
        XCTAssertNil(ArchivePreviewPresentation.summary(for: [unknown]).fileSize)
        XCTAssertFalse(ArchivePreviewPresentation.summaryText(for: [unknown]).contains(zeroText))
        XCTAssertEqual(ArchivePreviewPresentation.summary(for: [zero]).fileSize, 0)
        XCTAssertTrue(ArchivePreviewPresentation.summaryText(for: [zero]).contains(zeroText))
    }

    func testLoadingDifferentArchivesBuildsSharedColumnsAndPathPresentation() throws {
        let directory = try makeTemporaryDirectory(named: "preview-shared-presentation")
        let folder = directory.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for name in ["first.txt", "second.txt"] {
            try name.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            let archiveURL = directory.appendingPathComponent(name + ".zip")
            let entryPath = "Folder/" + name
            try createZipFixture(at: archiveURL, currentDirectory: directory, entryPaths: [entryPath])

            let snapshot = try ArchivePreviewLoader.loadArchiveContents(at: archiveURL)

            XCTAssertEqual(snapshot.items.map(\.path), [entryPath])
            XCTAssertEqual(snapshot.presentationRows(showHiddenItems: true).first?.text(for: .name), entryPath)
            XCTAssertEqual(snapshot.treeNodes(showHiddenItems: true).first?.text(for: .name), "Folder")
            XCTAssertEqual(snapshot.treeNodes(showHiddenItems: true).first?.children.first?.text(for: .name), name)
            XCTAssertEqual(snapshot.availableColumns.first?.id, .name)
            XCTAssertTrue(snapshot.availableColumns.contains { $0.id == .size })
        }
    }

    func testPreviewRowsKeepFullPathsWhileMainAppCellsUseNames() {
        let item = makeItem(path: "Folder/file.txt")
        let columns = FileManagerColumn.archiveColumns(entryProperties: [])
        let rows = ArchivePreviewPresentation.rows(for: [item], columns: columns)

        XCTAssertEqual(rows.first?.text(for: .name), "Folder/file.txt")
        XCTAssertEqual(FileManagerItemPresentation.listCellText(for: item,
                                                                columnID: .name,
                                                                dateFormatter: DateFormatter()),
                       "file.txt")
    }

    func testArchiveColumnsUseMainAppArchiveDefaults() {
        let columns = FileManagerColumn.archiveColumns(entryProperties: [
            FileManagerArchiveEntryProperty(id: .size,
                                            titleKey: "column.size",
                                            title: "Size",
                                            valueType: 21),
            FileManagerArchiveEntryProperty(id: .packedSize,
                                            titleKey: "column.packedSize",
                                            title: "Packed Size",
                                            valueType: 21),
            FileManagerArchiveEntryProperty(id: .modified,
                                            titleKey: "column.modified",
                                            title: "Modified",
                                            valueType: 64),
        ])

        XCTAssertEqual(columns.map(\.id), [.name, .size, .packedSize, .modified])
        XCTAssertEqual(columns.map(\.titleFallback), ["Name", "Size", "Packed Size", "Modified"])
        XCTAssertEqual(columns.map(\.width), [250, 80, 100, 180])
    }

    func testArchiveColumnsResolveStoredMainAppVisibilityOrderAndWidths() throws {
        let suiteName = "ArchivePreviewPresentationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let folderTypeID = FileManagerViewPreferences.archiveListViewFolderTypeID(formatName: "Zip")
        let mainAppInfo = FileManagerViewPreferences.ListViewInfo(
            sortKey: "name",
            ascending: true,
            columns: [
                FileManagerViewPreferences.ListViewColumnInfo(id: FileManagerColumnID.packedSize,
                                                              isVisible: true,
                                                              width: 123),
                FileManagerViewPreferences.ListViewColumnInfo(id: FileManagerColumnID.name,
                                                              isVisible: true,
                                                              width: 321),
                FileManagerViewPreferences.ListViewColumnInfo(id: FileManagerColumnID.size,
                                                              isVisible: false,
                                                              width: 88),
            ],
        )
        FileManagerViewPreferences.setListViewInfo(mainAppInfo,
                                                   forFolderTypeID: folderTypeID,
                                                   defaults: defaults)

        let columns = FileManagerColumn.archiveColumns(entryProperties: [
            FileManagerArchiveEntryProperty(id: .size,
                                            titleKey: "column.size",
                                            title: "Size",
                                            valueType: 21),
            FileManagerArchiveEntryProperty(id: .packedSize,
                                            titleKey: "column.packedSize",
                                            title: "Packed Size",
                                            valueType: 21),
            FileManagerArchiveEntryProperty(id: .modified,
                                            titleKey: "column.modified",
                                            title: "Modified",
                                            valueType: 64),
        ])

        let storedInfo = FileManagerViewPreferences.listViewInfo(forFolderTypeID: folderTypeID,
                                                                 defaults: defaults)
        let resolved = FileManagerViewPreferences.resolvedListViewColumns(columns, using: storedInfo)

        XCTAssertEqual(resolved.map(\.column.id), [.packedSize, .name, .modified])
        XCTAssertEqual(resolved.map(\.width), [123, 321, 180])
    }

    func testArchivePreviewSnapshotBuildsCollapsibleTreeWithImplicitFolders() {
        let snapshot = ArchivePreviewSnapshot(
            archiveURL: URL(fileURLWithPath: "/tmp/payload.zip"),
            items: [
                makeItem(path: "Folder/file.txt"),
                makeItem(path: "Folder/Sub/nested.txt"),
                makeItem(path: ".hidden/secret.txt"),
                makeItem(path: "root.txt"),
            ],
            entryProperties: [
                FileManagerArchiveEntryProperty(id: .size,
                                                titleKey: "column.size",
                                                title: "Size",
                                                valueType: 21),
            ],
            formatName: "Zip",
        )

        let visibleRoots = snapshot.treeNodes(showHiddenItems: false)

        XCTAssertEqual(visibleRoots.map { $0.text(for: .name) },
                       ["Folder", "root.txt"])
        XCTAssertEqual(visibleRoots.first?.children.map { $0.text(for: .name) },
                       ["Sub", "file.txt"])
        XCTAssertEqual(visibleRoots.first?.children.first?.children.map { $0.text(for: .name) },
                       ["nested.txt"])
        XCTAssertEqual(snapshot.summaryText(showHiddenItems: false),
                       "3 \(SZL10n.string("app.fileManager.statusFiles")), 2 \(SZL10n.string("app.fileManager.statusFolders")) — \(ByteCountFormatter.string(fromByteCount: 3, countStyle: .file))")

        XCTAssertEqual(snapshot.treeNodes(showHiddenItems: true).map { $0.text(for: .name) },
                       [".hidden", "Folder", "root.txt"])
    }

    func testArchivePreviewSnapshotPreservesDuplicateFileRecords() {
        let snapshot = ArchivePreviewSnapshot(
            archiveURL: URL(fileURLWithPath: "/tmp/duplicates.zip"),
            items: [
                makeItem(index: 4, path: "duplicate.txt", size: 2),
                makeItem(index: 9, path: "duplicate.txt", size: 3),
            ],
            entryProperties: [],
            formatName: "Zip",
        )

        let roots = snapshot.treeNodes(showHiddenItems: true)

        XCTAssertEqual(roots.map(\.row.itemIndex), [0, 1])
        XCTAssertEqual(roots.map { $0.text(for: .name) },
                       ["duplicate.txt", "duplicate.txt"])
        XCTAssertEqual(ArchivePreviewPresentation.summary(for: roots),
                       ArchivePreviewSummary(fileCount: 2,
                                             folderCount: 0,
                                             fileSize: 5))
    }

    func testArchivePreviewSnapshotSeparatesFileAndDirectoryWithSamePath() {
        let snapshot = ArchivePreviewSnapshot(
            archiveURL: URL(fileURLWithPath: "/tmp/file-directory-collision.zip"),
            items: [
                makeItem(index: 2, path: "collision", isDirectory: true),
                makeItem(index: 7, path: "collision"),
                makeItem(index: 11, path: "collision/nested.txt"),
            ],
            entryProperties: [],
            formatName: "Zip",
        )

        let roots = snapshot.treeNodes(showHiddenItems: true)

        XCTAssertEqual(roots.map(\.row.itemIndex), [0, 1])
        XCTAssertEqual(roots.map(\.row.isDirectory), [true, false])
        XCTAssertEqual(roots.map { $0.text(for: .name) },
                       ["collision", "collision"])
        XCTAssertEqual(roots[0].children.map(\.row.itemIndex), [2])
        XCTAssertTrue(roots[1].children.isEmpty)
    }

    func testArchivePreviewSnapshotUsesFirstExplicitDuplicateDirectory() {
        let snapshot = ArchivePreviewSnapshot(
            archiveURL: URL(fileURLWithPath: "/tmp/duplicate-directories.zip"),
            items: [
                makeItem(index: 3, path: "Folder", isDirectory: true),
                makeItem(index: 8, path: "Folder", isDirectory: true),
                makeItem(index: 12, path: "Folder/file.txt"),
            ],
            entryProperties: [],
            formatName: "Zip",
        )

        let roots = snapshot.treeNodes(showHiddenItems: true)

        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].row.itemIndex, 0)
        XCTAssertEqual(roots[0].children.map(\.row.itemIndex), [2])
    }

    func testArchivePreviewLoaderListsAndFiltersHiddenEntries() throws {
        let tempRoot = try makeTemporaryDirectory(named: "archive-preview-loader")
        try "visible".write(to: tempRoot.appendingPathComponent("visible.txt"),
                            atomically: true,
                            encoding: .utf8)
        try "hidden".write(to: tempRoot.appendingPathComponent(".hidden"),
                           atomically: true,
                           encoding: .utf8)
        let archiveURL = tempRoot.appendingPathComponent("payload.zip")

        try createZipFixture(at: archiveURL,
                             currentDirectory: tempRoot,
                             entryPaths: ["visible.txt", ".hidden"])

        let snapshot = try ArchivePreviewLoader.loadArchiveContents(at: archiveURL)

        XCTAssertEqual(snapshot.visibleItems(showHiddenItems: false).map(\.path),
                       ["visible.txt"])
        XCTAssertEqual(Set(snapshot.visibleItems(showHiddenItems: true).map(\.path)),
                       ["visible.txt", ".hidden"])
    }

    private func makeItem(index: Int = 0,
                          path: String,
                          size: UInt64? = 1,
                          packedSize: UInt64? = 1,
                          isDirectory: Bool = false,
                          attributes: UInt32 = 0) -> ArchiveItem
    {
        ArchiveItem(index: index,
                    path: path,
                    name: path.split(separator: "/").last.map(String.init) ?? path,
                    size: size,
                    packedSize: packedSize,
                    modifiedDate: nil,
                    createdDate: nil,
                    accessedDate: nil,
                    crc: 0,
                    isDirectory: isDirectory,
                    isEncrypted: false,
                    isAnti: false,
                    method: "",
                    attributes: attributes,
                    position: 0,
                    block: 0,
                    comment: "")
    }
}
