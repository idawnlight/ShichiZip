import AppKit
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileManagerPaneEventCoordinatorTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipIfAffectedByIsolatedDeinitTaskLocalRuntimeBug()
    }

    func testColumnLayoutNotificationsUseObservedTableViewOnly() {
        let notificationCenter = NotificationCenter()
        let tableView = NSTableView()
        let otherTableView = NSTableView()
        let scrollView = NSScrollView()
        let host = TestEventHost()
        let coordinator = makeCoordinator(host: host,
                                          tableView: tableView,
                                          scrollView: scrollView,
                                          notificationCenter: notificationCenter)

        notificationCenter.post(name: NSTableView.columnDidMoveNotification,
                                object: tableView)
        notificationCenter.post(name: NSTableView.columnDidResizeNotification,
                                object: otherTableView)
        notificationCenter.post(name: NSTableView.columnDidResizeNotification,
                                object: tableView)

        XCTAssertEqual(host.columnLayoutChangeCount, 2)

        coordinator.tearDown()
        notificationCenter.post(name: NSTableView.columnDidMoveNotification,
                                object: tableView)

        XCTAssertEqual(host.columnLayoutChangeCount, 2)
    }

    func testAutoRefreshCoalescesRequestsWhileScrollViewIsLiveScrolling() {
        let notificationCenter = NotificationCenter()
        let tableView = NSTableView()
        let scrollView = NSScrollView()
        let host = TestEventHost()
        let coordinator = makeCoordinator(host: host,
                                          tableView: tableView,
                                          scrollView: scrollView,
                                          notificationCenter: notificationCenter)

        coordinator.autoRefreshWhenPossible()
        XCTAssertEqual(host.refreshCount, 1)

        notificationCenter.post(name: NSScrollView.willStartLiveScrollNotification,
                                object: scrollView)
        coordinator.autoRefreshWhenPossible()
        coordinator.autoRefreshWhenPossible()
        coordinator.autoRefreshWhenPossible()
        XCTAssertEqual(host.refreshCount, 1)

        notificationCenter.post(name: NSScrollView.didEndLiveScrollNotification,
                                object: scrollView)
        XCTAssertEqual(host.refreshCount, 2)

        notificationCenter.post(name: NSScrollView.didEndLiveScrollNotification,
                                object: scrollView)
        XCTAssertEqual(host.refreshCount, 2)
        coordinator.tearDown()
    }

    func testModelNotificationsDispatchTypedChangesToHost() {
        let notificationCenter = NotificationCenter()
        let tableView = NSTableView()
        let scrollView = NSScrollView()
        let archiveChange = FileManagerArchiveChange(archiveURL: URL(fileURLWithPath: "/tmp/payload.7z"),
                                                     targetSubdir: "nested",
                                                     selectingPaths: ["nested/file.txt"])
        let host = TestEventHost()
        let coordinator = makeCoordinator(host: host,
                                          tableView: tableView,
                                          scrollView: scrollView,
                                          notificationCenter: notificationCenter)

        notificationCenter.post(name: .szSettingsDidChange,
                                object: nil,
                                userInfo: ["key": SZSettingsKey.showGridLines.rawValue])
        notificationCenter.post(name: .szSettingsDidChange,
                                object: nil,
                                userInfo: ["key": "missing-setting"])
        notificationCenter.post(name: .fileManagerViewPreferencesDidChange,
                                object: nil,
                                userInfo: [FileManagerViewPreferences.listViewPreferencesResetUserInfoKey: true])
        notificationCenter.post(name: .fileManagerViewPreferencesDidChange,
                                object: nil)
        notificationCenter.post(name: .fileManagerArchiveDidChange,
                                object: nil,
                                userInfo: archiveChange.notificationUserInfo)
        notificationCenter.post(name: .fileManagerArchiveDidChange,
                                object: nil)
        notificationCenter.post(name: .szLanguageDidChange,
                                object: nil)

        XCTAssertEqual(host.settingsKeys, [.showGridLines])
        XCTAssertEqual(host.viewPreferenceResetRequests, [true, false])
        XCTAssertEqual(host.archiveChanges, [archiveChange])
        XCTAssertEqual(host.languageChangeCount, 1)
        coordinator.tearDown()
    }

    func testTearDownDropsDeferredRefreshAndStopsModelNotifications() {
        let notificationCenter = NotificationCenter()
        let scrollView = NSScrollView()
        let host = TestEventHost()
        let coordinator = makeCoordinator(host: host,
                                          tableView: NSTableView(),
                                          scrollView: scrollView,
                                          notificationCenter: notificationCenter)
        notificationCenter.post(name: NSScrollView.willStartLiveScrollNotification,
                                object: scrollView)
        coordinator.autoRefreshWhenPossible()

        coordinator.tearDown()
        notificationCenter.post(name: NSScrollView.didEndLiveScrollNotification,
                                object: scrollView)
        notificationCenter.post(name: .szLanguageDidChange,
                                object: nil)

        XCTAssertEqual(host.refreshCount, 0)
        XCTAssertEqual(host.languageChangeCount, 0)
    }

    func testCoordinatorDoesNotRetainItsHost() throws {
        var host: TestEventHost? = TestEventHost()
        weak let weakHost = host
        let coordinator = try makeCoordinator(host: XCTUnwrap(host),
                                              tableView: NSTableView(),
                                              scrollView: NSScrollView(),
                                              notificationCenter: NotificationCenter())

        host = nil

        XCTAssertNil(weakHost)
        coordinator.autoRefreshWhenPossible()
        coordinator.tearDown()
    }

    private func makeCoordinator(host: TestEventHost,
                                 tableView: NSTableView,
                                 scrollView: NSScrollView,
                                 notificationCenter: NotificationCenter) -> FileManagerPaneEventCoordinator
    {
        FileManagerPaneEventCoordinator(host: host,
                                        tableView: tableView,
                                        scrollView: scrollView,
                                        notificationCenter: notificationCenter,
                                        notificationQueue: nil)
    }
}

@MainActor
private final class TestEventHost: FileManagerPaneEventHost {
    private(set) var columnLayoutChangeCount = 0
    private(set) var settingsKeys: [SZSettingsKey] = []
    private(set) var viewPreferenceResetRequests: [Bool] = []
    private(set) var archiveChanges: [FileManagerArchiveChange] = []
    private(set) var languageChangeCount = 0
    private(set) var refreshCount = 0

    func handleTableColumnLayoutDidChange() {
        columnLayoutChangeCount += 1
    }

    func handleSettingsDidChange(_ settingsKey: SZSettingsKey) {
        settingsKeys.append(settingsKey)
    }

    func handleViewPreferencesDidChange(resetListView: Bool) {
        viewPreferenceResetRequests.append(resetListView)
    }

    func handlePublishedArchiveChange(_ change: FileManagerArchiveChange) {
        archiveChanges.append(change)
    }

    func handleLanguageDidChange() {
        languageChangeCount += 1
    }

    func autoRefreshCurrentDirectoryIfNeeded() {
        refreshCount += 1
    }
}
