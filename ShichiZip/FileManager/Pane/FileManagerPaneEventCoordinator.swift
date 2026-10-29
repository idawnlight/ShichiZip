import Cocoa

@MainActor
protocol FileManagerPaneEventHost: AnyObject {
    func handleTableColumnLayoutDidChange()
    func handleSettingsDidChange(_ settingsKey: SZSettingsKey)
    func handleViewPreferencesDidChange(resetListView: Bool)
    func handlePublishedArchiveChange(_ change: FileManagerArchiveChange)
    func handleLanguageDidChange()
    func autoRefreshCurrentDirectoryIfNeeded()
}

@MainActor
final class FileManagerPaneEventCoordinator {
    private let notificationCenter: NotificationCenter
    private weak var host: (any FileManagerPaneEventHost)?
    private var observers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    private var pendingAutoRefresh = false

    init(host: any FileManagerPaneEventHost,
         tableView: NSTableView,
         scrollView: NSScrollView,
         notificationCenter: NotificationCenter = .default,
         notificationQueue: OperationQueue? = .main)
    {
        self.host = host
        self.notificationCenter = notificationCenter

        observers = [
            notificationCenter.addObserver(forName: NSTableView.columnDidMoveNotification,
                                           object: tableView,
                                           queue: notificationQueue)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.host?.handleTableColumnLayoutDidChange()
                }
            },
            notificationCenter.addObserver(forName: NSTableView.columnDidResizeNotification,
                                           object: tableView,
                                           queue: notificationQueue)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.host?.handleTableColumnLayoutDidChange()
                }
            },
            notificationCenter.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                           object: scrollView,
                                           queue: notificationQueue)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveScrolling = true
                }
            },
            notificationCenter.addObserver(forName: NSScrollView.didEndLiveScrollNotification,
                                           object: scrollView,
                                           queue: notificationQueue)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLiveScrolling = false

                    guard self.pendingAutoRefresh else { return }
                    self.pendingAutoRefresh = false
                    self.host?.autoRefreshCurrentDirectoryIfNeeded()
                }
            },
            notificationCenter.addObserver(forName: .szSettingsDidChange,
                                           object: nil,
                                           queue: notificationQueue)
            { [weak self] notification in
                let settingsKey = (notification.userInfo?["key"] as? String)
                    .flatMap(SZSettingsKey.init(rawValue:))
                MainActor.assumeIsolated {
                    guard let settingsKey else { return }
                    self?.host?.handleSettingsDidChange(settingsKey)
                }
            },
            notificationCenter.addObserver(forName: .fileManagerViewPreferencesDidChange,
                                           object: nil,
                                           queue: notificationQueue)
            { [weak self] notification in
                let shouldResetListViewPreferences = notification.userInfo?[FileManagerViewPreferences.listViewPreferencesResetUserInfoKey] as? Bool == true
                MainActor.assumeIsolated {
                    self?.host?.handleViewPreferencesDidChange(resetListView: shouldResetListViewPreferences)
                }
            },
            notificationCenter.addObserver(forName: .fileManagerArchiveDidChange,
                                           object: nil,
                                           queue: notificationQueue)
            { [weak self] notification in
                let change = FileManagerArchiveChange(notification: notification)
                MainActor.assumeIsolated {
                    guard let change else { return }
                    self?.host?.handlePublishedArchiveChange(change)
                }
            },
            notificationCenter.addObserver(forName: .szLanguageDidChange,
                                           object: nil,
                                           queue: notificationQueue)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.host?.handleLanguageDidChange()
                }
            },
        ]
    }

    isolated deinit {
        tearDown()
    }

    func tearDown() {
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
        pendingAutoRefresh = false
        isLiveScrolling = false
    }

    func autoRefreshWhenPossible() {
        guard !isLiveScrolling else {
            pendingAutoRefresh = true
            return
        }

        pendingAutoRefresh = false
        host?.autoRefreshCurrentDirectoryIfNeeded()
    }
}
