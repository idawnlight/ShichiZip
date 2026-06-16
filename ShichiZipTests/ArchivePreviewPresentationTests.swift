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
                       "2 \(ArchivePreviewLocalization.string("app.fileManager.statusFiles")), 1 \(ArchivePreviewLocalization.string("app.fileManager.statusFolder")) — \(ByteCountFormatter.string(fromByteCount: 7, countStyle: .file))")
    }

    func testStatusBarArchiveOnlyModeOmitsDisplayedSizeOutsideArchives() {
        let summary = makeStatusSummary(fileCount: 2,
                                        folderCount: 1,
                                        fileSize: 42)

        let text = FileManagerItemPresentation.statusBarText(displayed: summary,
                                                             selected: nil,
                                                             sizeMode: 1,
                                                             isInsideArchive: false)

        XCTAssertTrue(text.contains("2 \(SZL10n.string("app.fileManager.statusFiles"))"))
        XCTAssertTrue(text.contains("1 \(SZL10n.string("app.fileManager.statusFolder"))"))
        XCTAssertFalse(text.contains(statusSizeString(42)))
    }

    func testStatusBarArchiveOnlyModeShowsDisplayedSizeInsideArchives() {
        let summary = makeStatusSummary(fileCount: 2,
                                        folderCount: 1,
                                        fileSize: 42)

        let text = FileManagerItemPresentation.statusBarText(displayed: summary,
                                                             selected: nil,
                                                             sizeMode: 1,
                                                             isInsideArchive: true)

        XCTAssertTrue(text.contains(statusSizeString(42)))
    }

    func testStatusBarDefaultModeShowsDisplayedSizeInBothContexts() {
        let summary = makeStatusSummary(fileCount: 2,
                                        folderCount: 1,
                                        fileSize: 42)
        let defaultText = FileManagerItemPresentation.statusBarText(displayed: summary,
                                                                    selected: nil)
        let folderText = FileManagerItemPresentation.statusBarText(displayed: summary,
                                                                   selected: nil,
                                                                   sizeMode: 0,
                                                                   isInsideArchive: false)
        let archiveText = FileManagerItemPresentation.statusBarText(displayed: summary,
                                                                    selected: nil,
                                                                    sizeMode: 0,
                                                                    isInsideArchive: true)

        XCTAssertEqual(folderText, defaultText)
        XCTAssertEqual(archiveText, defaultText)
        XCTAssertTrue(folderText.contains(statusSizeString(42)))
        XCTAssertTrue(archiveText.contains(statusSizeString(42)))
    }

    func testStatusBarArchiveOnlyModeKeepsSelectionSizeOutsideArchives() {
        let displayed = makeStatusSummary(fileCount: 3,
                                          folderCount: 1,
                                          fileSize: 4_096)
        let selected = makeStatusSummary(fileCount: 1,
                                         folderCount: 0,
                                         fileSize: 123)

        let text = FileManagerItemPresentation.statusBarText(displayed: displayed,
                                                             selected: selected,
                                                             sizeMode: 1,
                                                             isInsideArchive: false)

        XCTAssertFalse(text.contains(statusSizeString(4_096)))
        XCTAssertTrue(text.contains(statusSizeString(123)))
    }

    func testStatusBarEmptySummariesRenderUnderBothModes() {
        let empty = makeStatusSummary()

        for sizeMode in [0, 1] {
            for isInsideArchive in [false, true] {
                let text = FileManagerItemPresentation.statusBarText(displayed: empty,
                                                                     selected: nil,
                                                                     sizeMode: sizeMode,
                                                                     isInsideArchive: isInsideArchive)

                XCTAssertTrue(text.contains("0 \(SZL10n.string("app.fileManager.statusFiles"))"))
                XCTAssertTrue(text.contains("0 \(SZL10n.string("app.fileManager.statusFolders"))"))
            }
        }
    }

    func testArchiveColumnsUseMainAppArchiveDefaults() {
        let columns = ArchivePreviewColumn.archiveColumns(entryProperties: [
            ArchivePreviewEntryProperty(id: .size,
                                        titleKey: "column.size",
                                        title: "Size",
                                        valueType: 21),
            ArchivePreviewEntryProperty(id: .packedSize,
                                        titleKey: "column.packedSize",
                                        title: "Packed Size",
                                        valueType: 21),
            ArchivePreviewEntryProperty(id: .modified,
                                        titleKey: "column.modified",
                                        title: "Modified",
                                        valueType: 64),
        ])

        XCTAssertEqual(columns.map(\.id), [.name, .size, .packedSize, .modified])
        XCTAssertEqual(columns.map(\.titleFallback), ["Name", "Size", "Packed Size", "Modified"])
        XCTAssertEqual(columns.map(\.width), [250, 80, 100, 140])
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

        let columns = ArchivePreviewColumn.archiveColumns(entryProperties: [
            ArchivePreviewEntryProperty(id: .size,
                                        titleKey: "column.size",
                                        title: "Size",
                                        valueType: 21),
            ArchivePreviewEntryProperty(id: .packedSize,
                                        titleKey: "column.packedSize",
                                        title: "Packed Size",
                                        valueType: 21),
            ArchivePreviewEntryProperty(id: .modified,
                                        titleKey: "column.modified",
                                        title: "Modified",
                                        valueType: 64),
        ])

        let resolved = ArchivePreviewColumnPreferences.resolvedColumns(columns,
                                                                       folderTypeID: folderTypeID,
                                                                       defaults: defaults)

        XCTAssertEqual(resolved.map(\.column.id), [.packedSize, .name, .modified])
        XCTAssertEqual(resolved.map(\.width), [123, 321, 140])
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
                ArchivePreviewEntryProperty(id: .size,
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
                       "3 \(ArchivePreviewLocalization.string("app.fileManager.statusFiles")), 2 \(ArchivePreviewLocalization.string("app.fileManager.statusFolders")) — \(ByteCountFormatter.string(fromByteCount: 3, countStyle: .file))")

        XCTAssertEqual(snapshot.treeNodes(showHiddenItems: true).map { $0.text(for: .name) },
                       [".hidden", "Folder", "root.txt"])
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

    private func makeItem(path: String,
                          size: UInt64 = 1,
                          packedSize: UInt64 = 1,
                          isDirectory: Bool = false,
                          attributes: UInt32 = 0) -> ArchiveItem
    {
        ArchiveItem(index: 0,
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

    private func makeStatusSummary(fileCount: Int = 0,
                                   folderCount: Int = 0,
                                   fileSize: UInt64 = 0,
                                   folderSize: UInt64 = 0) -> FileManagerItemStatusSummary
    {
        FileManagerItemStatusSummary(fileCount: fileCount,
                                     folderCount: folderCount,
                                     fileSize: fileSize,
                                     folderSize: folderSize)
    }

    private func statusSizeString(_ size: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
    }
}
