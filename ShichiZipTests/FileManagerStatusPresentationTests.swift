#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import AppKit
import XCTest

final class FileManagerStatusPresentationTests: XCTestCase {
    func testFileSystemStatusSeparatesVisibleCountsFromShownFileSize() {
        let displayed = makeSummary(fileCount: 2,
                                    folderCount: 1,
                                    fileSize: 42)

        let content = FileManagerItemPresentation.statusBarContent(
            displayed: displayed,
            selected: nil,
            location: .fileSystem,
        )

        XCTAssertEqual(content.summary,
                       summaryPair(itemCount(2, singular: "app.fileManager.statusFile", plural: "app.fileManager.statusFiles"),
                                   itemCount(1, singular: "app.fileManager.statusFolder", plural: "app.fileManager.statusFolders")))
        XCTAssertEqual(content.detail,
                       SZL10n.string("app.fileManager.statusShownFilesSize", sizeString(42)))
    }

    func testFileSystemStatusOmitsSizeWhenNoFilesAreShown() {
        let content = FileManagerItemPresentation.statusBarContent(
            displayed: makeSummary(folderCount: 2),
            selected: nil,
            location: .fileSystem,
        )

        XCTAssertNil(content.detail)
    }

    func testArchiveStatusUsesWholeArchiveUncompressedSize() {
        let content = FileManagerItemPresentation.statusBarContent(
            displayed: makeSummary(fileCount: 1,
                                   folderCount: 2,
                                   fileSize: 10),
            selected: nil,
            location: .archive(uncompressedSize: 1024),
        )

        XCTAssertEqual(content.detail,
                       SZL10n.string("app.fileManager.statusArchiveUncompressedSize",
                                     sizeString(1024)))
        XCTAssertFalse(content.detail?.contains(sizeString(10)) == true)
    }

    func testSelectionReplacesContainerMetricAndBindsSizeToFiles() {
        let displayed = makeSummary(fileCount: 4,
                                    folderCount: 2,
                                    fileSize: 1000)
        let selected = makeSummary(fileCount: 2,
                                   folderCount: 1,
                                   fileSize: 42)

        let content = FileManagerItemPresentation.statusBarContent(
            displayed: displayed,
            selected: selected,
            location: .archive(uncompressedSize: 9999),
        )

        XCTAssertEqual(content.summary,
                       SZL10n.string("app.fileManager.statusSelection", 3, 6))
        XCTAssertEqual(content.detail,
                       summaryPair(itemCount(2,
                                             singular: "app.fileManager.statusFile",
                                             plural: "app.fileManager.statusFiles",
                                             size: 42),
                                   itemCount(1,
                                             singular: "app.fileManager.statusFolder",
                                             plural: "app.fileManager.statusFolders")))
        XCTAssertFalse(content.detail?.contains(sizeString(9999)) == true)
    }

    func testFolderOnlySelectionDoesNotReportFolderContents() {
        let content = FileManagerItemPresentation.statusBarContent(
            displayed: makeSummary(folderCount: 3),
            selected: makeSummary(folderCount: 1, folderSize: 500),
            location: .fileSystem,
        )

        XCTAssertEqual(content.detail,
                       itemCount(1,
                                 singular: "app.fileManager.statusFolder",
                                 plural: "app.fileManager.statusFolders"))
        XCTAssertFalse(content.detail?.contains(sizeString(500)) == true)
    }

    func testArchiveSummaryIgnoresAntiItemSize() {
        let summary = FileManagerItemPresentation.summary(for: [
            makeArchiveItem(path: "visible.txt", size: 4),
            makeArchiveItem(path: "removed.txt", size: 100, isAnti: true),
        ])

        XCTAssertEqual(summary.fileCount, 2)
        XCTAssertEqual(summary.fileSize, 4)
    }

    func testArchiveStatisticsIncludeHiddenFilesAndIgnoreDirectoriesAndAntiItems() {
        let statistics = FileManagerArchiveStatistics(entries: [
            makeArchiveItem(path: ".hidden", size: 4),
            makeArchiveItem(path: "folder", size: 100, isDirectory: true),
            makeArchiveItem(path: "removed.txt", size: 200, isAnti: true),
        ])

        XCTAssertEqual(statistics.uncompressedSize, 4)
    }

    func testArchiveStatisticsClampOverflow() {
        let statistics = FileManagerArchiveStatistics(entries: [
            makeArchiveItem(path: "large.bin", size: .max),
            makeArchiveItem(path: "more.bin", size: 1),
        ])

        XCTAssertEqual(statistics.uncompressedSize, .max)
    }

    @MainActor
    func testStatusViewPresentsAndClearsBothSegments() {
        let statusView = FileManagerPaneStatusView()
        let content = FileManagerStatusBarContent(summary: "3 files",
                                                  detail: "Shown files: 42 MB")

        statusView.setContent(content)

        XCTAssertEqual(statusView.summaryLabel.stringValue, content.summary)
        XCTAssertEqual(statusView.detailLabel.stringValue, content.detail)
        XCTAssertFalse(statusView.detailLabel.isHidden)

        statusView.clear()

        XCTAssertEqual(statusView.summaryLabel.stringValue, "")
        XCTAssertEqual(statusView.detailLabel.stringValue, "")
        XCTAssertTrue(statusView.detailLabel.isHidden)
    }

    private func makeSummary(fileCount: Int = 0,
                             folderCount: Int = 0,
                             fileSize: UInt64 = 0,
                             folderSize: UInt64 = 0) -> FileManagerItemStatusSummary
    {
        FileManagerItemStatusSummary(fileCount: fileCount,
                                     folderCount: folderCount,
                                     fileSize: fileSize,
                                     folderSize: folderSize)
    }

    private func itemCount(_ count: Int,
                           singular: String,
                           plural: String,
                           size: UInt64? = nil) -> String
    {
        let itemWord = SZL10n.string(count == 1 ? singular : plural)
        if let size {
            return SZL10n.string("app.fileManager.statusItemCountWithSize",
                                 count,
                                 itemWord,
                                 sizeString(size))
        }
        return SZL10n.string("app.fileManager.statusItemCount", count, itemWord)
    }

    private func summaryPair(_ first: String, _ second: String) -> String {
        SZL10n.string("app.fileManager.statusSummaryPair", first, second)
    }

    private func sizeString(_ size: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: size),
                                  countStyle: .file)
    }

    private func makeArchiveItem(path: String,
                                 size: UInt64,
                                 isDirectory: Bool = false,
                                 isAnti: Bool = false) -> ArchiveItem
    {
        ArchiveItem(index: isDirectory ? -1 : 0,
                    path: path,
                    name: path.split(separator: "/").last.map(String.init) ?? path,
                    size: size,
                    packedSize: 0,
                    modifiedDate: nil,
                    createdDate: nil,
                    accessedDate: nil,
                    crc: 0,
                    isDirectory: isDirectory,
                    isEncrypted: false,
                    isAnti: isAnti,
                    method: "",
                    attributes: 0,
                    position: 0,
                    block: 0,
                    comment: "")
    }
}
