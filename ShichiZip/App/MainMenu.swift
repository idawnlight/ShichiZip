import Cocoa

private enum MainMenuIdentifiers {
    static let favoritesMenu = NSUserInterfaceItemIdentifier("FavoritesMenu")
    static let recentArchivesMenu = NSUserInterfaceItemIdentifier("RecentArchivesMenu")
    static let viewMenu = NSUserInterfaceItemIdentifier("ViewMenu")
    static let timeMenu = NSUserInterfaceItemIdentifier("TimeMenu")
}

enum FileManagerMenuFactory {
    private enum TargetKind {
        case windowController
        case appDelegate
    }

    private struct Shortcut {
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags

        init(_ keyEquivalent: String,
             modifiers: NSEvent.ModifierFlags = [.command])
        {
            self.keyEquivalent = keyEquivalent
            self.modifiers = modifiers
        }

        init(_ shortcut: FileManagerMenuShortcut) {
            keyEquivalent = shortcut.keyEquivalent
            modifiers = shortcut.modifiers
        }
    }

    private indirect enum Node {
        case item(title: String,
                  action: Selector,
                  shortcut: Shortcut? = nil,
                  target: TargetKind = .windowController,
                  tag: Int = 0)
        case submenu(title: String, children: [Node])
        case recentArchives
        case separator
    }

    static func makeFileMenu(appTarget: AnyObject?,
                             recentArchivesMenuDelegate: (any NSMenuDelegate)?) -> NSMenu
    {
        let menu = NSMenu(title: SZL10n.string("menu.file"))
        populate(menu,
                 with: fileMenuNodes,
                 windowTarget: nil,
                 appTarget: appTarget,
                 recentArchivesMenuDelegate: recentArchivesMenuDelegate)
        return menu
    }

    static func makeContextMenu(windowTarget: AnyObject?) -> NSMenu {
        let menu = NSMenu(title: SZL10n.string("menu.file"))
        populate(menu,
                 with: contextMenuNodes,
                 windowTarget: windowTarget,
                 appTarget: nil,
                 recentArchivesMenuDelegate: nil)
        return menu
    }

    static func makeSortMenuItems() -> [NSMenuItem] {
        [FileManagerSortField.name, .type, .modified, .size].map { field in
            let item = NSMenuItem(title: SZL10n.string("column.\(field.key)"),
                                  action: #selector(FileManagerWindowController.sortItems(_:)),
                                  keyEquivalent: "")
            item.tag = field.rawValue
            return item
        }
    }

    static func makeTimestampMenuItems() -> [NSMenuItem] {
        FileManagerViewPreferences.TimestampDisplayLevel.allCases.map { level in
            let item = NSMenuItem(title: FileManagerViewPreferences.timeMenuPreviewTitle(for: level),
                                  action: #selector(FileManagerWindowController.showTimestamp(_:)),
                                  keyEquivalent: "")
            item.tag = level.rawValue
            return item
        }
    }

    private static func shortcut(_ command: FileManagerShortcutCommand) -> Shortcut? {
        guard let shortcut = FileManagerShortcuts.menuShortcut(for: command) else {
            return nil
        }
        return Shortcut(shortcut)
    }

    private static var openNodes: [Node] {
        [
            .item(title: SZL10n.string("menu.open"),
                  action: #selector(FileManagerWindowController.openSelectedItem(_:)),
                  shortcut: shortcut(.openSelectedItem)),
            .item(title: SZL10n.string("menu.openInside"),
                  action: #selector(FileManagerWindowController.openSelectedItemInside(_:))),
            .item(title: SZL10n.string("menu.openInside") + " *",
                  action: #selector(FileManagerWindowController.openSelectedItemInsideWildcard(_:))),
            .item(title: SZL10n.string("menu.openInside") + " #",
                  action: #selector(FileManagerWindowController.openSelectedItemInsideParser(_:))),
            .item(title: SZL10n.string("menu.openOutside"),
                  action: #selector(FileManagerWindowController.openSelectedItemOutside(_:))),
        ]
    }

    private static var hashNodes: [Node] {
        FileManagerHashAlgorithm.allCases.map { algorithm in
            .item(title: algorithm.title,
                  action: #selector(FileManagerWindowController.showHash(_:)),
                  tag: algorithm.rawValue)
        }
    }

    private static var fileMenuNodes: [Node] {
        openNodes + [
            .item(title: SZL10n.string("shell.openArchive"),
                  action: #selector(AppDelegate.openArchives(_:)),
                  shortcut: Shortcut("o"),
                  target: .appDelegate),
            .recentArchives,
            .separator,
            .item(title: SZL10n.string("toolbar.add"),
                  action: #selector(FileManagerWindowController.addToArchive(_:))),
            .item(title: SZL10n.string("toolbar.extract") + "…",
                  action: #selector(FileManagerWindowController.extractArchive(_:))),
            .item(title: SZL10n.string("app.fileManager.smartExtract"),
                  action: #selector(FileManagerWindowController.extractSmart(_:))),
            .item(title: SZL10n.string("shell.extractHere"),
                  action: #selector(FileManagerWindowController.extractHere(_:))),
            .item(title: SZL10n.string("toolbar.test"),
                  action: #selector(FileManagerWindowController.testArchive(_:))),
            .separator,
            .item(title: SZL10n.string("menu.rename"),
                  action: #selector(FileManagerWindowController.renameSelection(_:)),
                  shortcut: shortcut(.renameSelection)),
            .item(title: SZL10n.string("menu.copyTo"),
                  action: #selector(FileManagerWindowController.copyFiles(_:)),
                  shortcut: shortcut(.copyFiles)),
            .item(title: SZL10n.string("menu.moveTo"),
                  action: #selector(FileManagerWindowController.moveFiles(_:)),
                  shortcut: shortcut(.moveFiles)),
            .item(title: SZL10n.string("menu.delete"),
                  action: #selector(FileManagerWindowController.deleteFiles(_:)),
                  shortcut: shortcut(.deleteFiles)),
            .separator,
            .item(title: SZL10n.string("menu.properties"),
                  action: #selector(FileManagerWindowController.showProperties(_:))),
            .submenu(title: SZL10n.string("menu.calculateChecksum"), children: hashNodes),
            .separator,
            .item(title: SZL10n.string("menu.createFolder"),
                  action: #selector(FileManagerWindowController.createFolder(_:)),
                  shortcut: shortcut(.createFolder)),
            .item(title: SZL10n.string("menu.createFile"),
                  action: #selector(FileManagerWindowController.createFile(_:))),
            .separator,
            .item(title: SZL10n.string("app.menu.closeDirectory"),
                  action: #selector(FileManagerWindowController.closeDirectory(_:))),
            .item(title: SZL10n.string("common.close"),
                  action: #selector(NSWindow.performClose(_:)),
                  shortcut: Shortcut("w")),
        ]
    }

    private static var contextMenuNodes: [Node] {
        openNodes + [
            .separator,
            .item(title: SZL10n.string("app.fileManager.compress"),
                  action: #selector(FileManagerWindowController.addToArchive(_:))),
            .item(title: SZL10n.string("toolbar.extract") + "…",
                  action: #selector(FileManagerWindowController.extractArchive(_:))),
            .item(title: SZL10n.string("app.fileManager.smartExtract"),
                  action: #selector(FileManagerWindowController.extractSmart(_:))),
            .item(title: SZL10n.string("shell.extractHere"),
                  action: #selector(FileManagerWindowController.extractHere(_:))),
            .item(title: SZL10n.string("toolbar.test"),
                  action: #selector(FileManagerWindowController.testArchive(_:))),
            .separator,
            .item(title: SZL10n.string("menu.rename"),
                  action: #selector(FileManagerWindowController.renameSelection(_:)),
                  shortcut: shortcut(.renameSelection)),
            .item(title: SZL10n.string("menu.copyTo"),
                  action: #selector(FileManagerWindowController.copyFiles(_:)),
                  shortcut: shortcut(.copyFiles)),
            .item(title: SZL10n.string("menu.moveTo"),
                  action: #selector(FileManagerWindowController.moveFiles(_:)),
                  shortcut: shortcut(.moveFiles)),
            .item(title: SZL10n.string("menu.delete"),
                  action: #selector(FileManagerWindowController.deleteFiles(_:)),
                  shortcut: shortcut(.deleteFiles)),
            .separator,
            .submenu(title: SZL10n.string("menu.calculateChecksum"), children: hashNodes),
            .separator,
            .item(title: SZL10n.string("menu.createFolder"),
                  action: #selector(FileManagerWindowController.createFolder(_:)),
                  shortcut: shortcut(.createFolder)),
            .item(title: SZL10n.string("menu.createFile"),
                  action: #selector(FileManagerWindowController.createFile(_:))),
            .separator,
            .item(title: SZL10n.string("menu.properties"),
                  action: #selector(FileManagerWindowController.showProperties(_:))),
        ]
    }

    private static func populate(_ menu: NSMenu,
                                 with nodes: [Node],
                                 windowTarget: AnyObject?,
                                 appTarget: AnyObject?,
                                 recentArchivesMenuDelegate: (any NSMenuDelegate)?)
    {
        for node in nodes {
            switch node {
            case let .item(title, action, shortcut, targetKind, tag):
                let item = NSMenuItem(title: title,
                                      action: action,
                                      keyEquivalent: shortcut?.keyEquivalent ?? "")
                item.tag = tag
                if let shortcut {
                    item.keyEquivalentModifierMask = shortcut.modifiers
                }
                switch targetKind {
                case .windowController:
                    item.target = windowTarget
                case .appDelegate:
                    item.target = appTarget
                }
                menu.addItem(item)

            case let .submenu(title, children):
                let submenu = NSMenu(title: title)
                populate(submenu,
                         with: children,
                         windowTarget: windowTarget,
                         appTarget: appTarget,
                         recentArchivesMenuDelegate: recentArchivesMenuDelegate)
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = submenu
                menu.addItem(item)

            case .recentArchives:
                let title = SZL10n.string("app.menu.openRecent")
                let submenu = NSMenu(title: title)
                submenu.identifier = MainMenuIdentifiers.recentArchivesMenu
                submenu.autoenablesItems = false
                submenu.delegate = recentArchivesMenuDelegate
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = submenu
                menu.addItem(item)

            case .separator:
                menu.addItem(.separator())
            }
        }
    }
}

@MainActor
private final class MainMenuCoordinator: NSObject, NSMenuDelegate {
    var timeMenuItem: NSMenuItem?

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier == MainMenuIdentifiers.viewMenu {
            refreshTimeMenuTitle()
            return
        }

        if menu.identifier == MainMenuIdentifiers.timeMenu {
            rebuildTimeMenu(menu)
            return
        }

        if menu.identifier == MainMenuIdentifiers.recentArchivesMenu {
            rebuildRecentArchivesMenu(menu)
            return
        }

        guard menu.identifier == MainMenuIdentifiers.favoritesMenu else {
            return
        }

        rebuildFavoritesMenu(menu)
    }

    func refreshTimeMenuTitle() {
        timeMenuItem?.title = FileManagerViewPreferences.timeMenuPreviewTitle(for: .day)
    }

    private func rebuildTimeMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        for item in FileManagerMenuFactory.makeTimestampMenuItems() {
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: SZL10n.string("app.view.systemTimeFormat"),
                                action: #selector(FileManagerWindowController.toggleTimestampSystemFormat(_:)),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "UTC",
                                action: #selector(FileManagerWindowController.toggleTimestampUTC(_:)),
                                keyEquivalent: ""))
        refreshTimeMenuTitle()
    }

    private func rebuildRecentArchivesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let archiveURLs = RecentArchiveHistory.recentArchiveURLs

        if !archiveURLs.isEmpty {
            for url in archiveURLs {
                let item = NSMenuItem(title: url.lastPathComponent,
                                      action: #selector(AppDelegate.openRecentArchive(_:)),
                                      keyEquivalent: "")
                item.target = NSApp.delegate
                item.representedObject = url
                item.toolTip = url.path
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let clearItem = NSMenuItem(title: SZL10n.string("app.menu.clearRecentArchives"),
                                   action: #selector(AppDelegate.clearRecentArchives(_:)),
                                   keyEquivalent: "")
        clearItem.target = NSApp.delegate
        clearItem.isEnabled = !archiveURLs.isEmpty
        menu.addItem(clearItem)
    }

    private func rebuildFavoritesMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let addToFavoritesItem = NSMenuItem(title: SZL10n.string("favorites.addFolder"), action: nil, keyEquivalent: "")
        let addToFavoritesMenu = NSMenu(title: addToFavoritesItem.title)

        for slot in 0 ..< FileManagerFavoriteStore.slotCount {
            let item = NSMenuItem(title: FileManagerFavoriteStore.saveSlotTitle(for: slot),
                                  action: #selector(FileManagerWindowController.saveFavoriteSlot(_:)),
                                  keyEquivalent: "")
            item.tag = slot
            addToFavoritesMenu.addItem(item)
        }

        addToFavoritesItem.submenu = addToFavoritesMenu
        menu.addItem(addToFavoritesItem)
        menu.addItem(.separator())

        for slot in 0 ..< FileManagerFavoriteStore.slotCount {
            let item = NSMenuItem(title: FileManagerFavoriteStore.displayTitle(for: slot),
                                  action: #selector(FileManagerWindowController.openFavoriteSlot(_:)),
                                  keyEquivalent: "")
            item.tag = slot
            menu.addItem(item)
        }
    }
}

/// Sets up the main application menu bar programmatically.
@MainActor
enum MainMenu {
    private static let coordinator = MainMenuCoordinator()
    private static var settingsObserver: NSObjectProtocol?

    static func setup() {
        installSettingsObserverIfNeeded()
        let appName = AppBuildInfo.appDisplayName()
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenu = NSMenu(title: appName)
        addTopLevelMenu(appMenu, to: mainMenu)
        addItem(to: appMenu,
                title: "\(SZL10n.string("app.menu.about", appName))",
                action: #selector(AppDelegate.showAbout(_:)),
                target: NSApp.delegate)
        appMenu.addItem(.separator())
        addItem(to: appMenu,
                title: SZL10n.string("app.menu.preferences"),
                action: #selector(AppDelegate.showPreferences(_:)),
                keyEquivalent: ",",
                target: NSApp.delegate)
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: SZL10n.string("app.menu.services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)

        appMenu.addItem(.separator())
        addItem(to: appMenu,
                title: SZL10n.string("app.menu.hide", appName),
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h",
                target: NSApp)
        addItem(to: appMenu,
                title: SZL10n.string("app.menu.hideOthers"),
                action: #selector(NSApplication.hideOtherApplications(_:)),
                keyEquivalent: "h",
                modifiers: [.command, .option],
                target: NSApp)
        addItem(to: appMenu,
                title: SZL10n.string("app.menu.showAll"),
                action: #selector(NSApplication.unhideAllApplications(_:)),
                target: NSApp)
        appMenu.addItem(.separator())
        addItem(to: appMenu,
                title: SZL10n.string("app.menu.quit", appName),
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q",
                target: NSApp)

        let fileMenu = FileManagerMenuFactory.makeFileMenu(
            appTarget: NSApp.delegate as AnyObject?,
            recentArchivesMenuDelegate: coordinator,
        )
        addTopLevelMenu(fileMenu, to: mainMenu)

        let editMenu = NSMenu(title: SZL10n.string("menu.edit"))
        addTopLevelMenu(editMenu, to: mainMenu)
        addItem(to: editMenu,
                title: SZL10n.string("app.menu.cut"),
                action: #selector(NSText.cut(_:)),
                keyEquivalent: "x")
        addItem(to: editMenu,
                title: SZL10n.string("app.menu.copy"),
                action: #selector(NSText.copy(_:)),
                keyEquivalent: "c")
        addItem(to: editMenu,
                title: SZL10n.string("app.menu.paste"),
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v")
        editMenu.addItem(.separator())
        addItem(to: editMenu,
                title: SZL10n.string("edit.selectAll"),
                action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a")
        addItem(to: editMenu,
                title: SZL10n.string("edit.deselectAll"),
                action: #selector(FileManagerWindowController.deselectAllItems(_:)),
                keyEquivalent: "a",
                modifiers: [.command, .shift])
        addItem(to: editMenu,
                title: SZL10n.string("edit.invertSelection"),
                action: #selector(FileManagerWindowController.invertSelection(_:)))

        let viewMenu = NSMenu(title: SZL10n.string("menu.view"))
        viewMenu.identifier = MainMenuIdentifiers.viewMenu
        viewMenu.delegate = coordinator
        addTopLevelMenu(viewMenu, to: mainMenu)
        addDisabledItem(to: viewMenu, title: SZL10n.string("view.largeIcons"))
        addDisabledItem(to: viewMenu, title: SZL10n.string("view.smallIcons"))
        addDisabledItem(to: viewMenu, title: SZL10n.string("view.list"))
        let detailsItem = addDisabledItem(to: viewMenu, title: SZL10n.string("view.details"))
        detailsItem.state = .on
        viewMenu.addItem(.separator())
        for item in FileManagerMenuFactory.makeSortMenuItems() {
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        addItem(to: viewMenu,
                title: SZL10n.string("view.showHiddenFiles"),
                action: #selector(FileManagerWindowController.toggleHiddenFiles(_:)),
                keyEquivalent: FileManagerShortcuts.menuShortcut(for: .toggleHiddenFiles)?.keyEquivalent ?? "",
                modifiers: FileManagerShortcuts.menuShortcut(for: .toggleHiddenFiles)?.modifiers ?? [])
        viewMenu.addItem(.separator())
        addItem(to: viewMenu,
                title: SZL10n.string("view.twoPanels"),
                action: #selector(FileManagerWindowController.toggleDualPane(_:)),
                keyEquivalent: FileManagerShortcuts.menuShortcut(for: .toggleDualPane)?.keyEquivalent ?? "",
                modifiers: FileManagerShortcuts.menuShortcut(for: .toggleDualPane)?.modifiers ?? [.command])

        let timeMenuItem = NSMenuItem(title: FileManagerViewPreferences.timeMenuPreviewTitle(for: .day),
                                      action: nil,
                                      keyEquivalent: "")
        let timeMenu = NSMenu(title: timeMenuItem.title)
        timeMenu.identifier = MainMenuIdentifiers.timeMenu
        timeMenu.delegate = coordinator
        coordinator.timeMenuItem = timeMenuItem
        timeMenuItem.submenu = timeMenu
        viewMenu.addItem(timeMenuItem)

        let toolbarsMenuItem = NSMenuItem(title: SZL10n.string("view.toolbars"), action: nil, keyEquivalent: "")
        let toolbarsMenu = NSMenu(title: SZL10n.string("view.toolbars"))
        addItem(to: toolbarsMenu,
                title: SZL10n.string("view.archiveToolbar"),
                action: #selector(FileManagerWindowController.toggleArchiveToolbar(_:)))
        addItem(to: toolbarsMenu,
                title: SZL10n.string("view.standardToolbar"),
                action: #selector(FileManagerWindowController.toggleStandardToolbar(_:)))
        toolbarsMenu.addItem(.separator())
        addItem(to: toolbarsMenu,
                title: SZL10n.string("view.showButtonsText"),
                action: #selector(FileManagerWindowController.toggleToolbarButtonText(_:)))
        toolbarsMenu.addItem(.separator())
        addItem(to: toolbarsMenu,
                title: SZL10n.string("app.view.unifiedToolbarStyle"),
                action: #selector(FileManagerWindowController.toggleUnifiedToolbarStyle(_:)))
        addItem(to: toolbarsMenu,
                title: SZL10n.string("app.view.showWindowSubtitle"),
                action: #selector(FileManagerWindowController.toggleWindowSubtitle(_:)))
        toolbarsMenuItem.submenu = toolbarsMenu
        viewMenu.addItem(toolbarsMenuItem)

        addItem(to: viewMenu,
                title: SZL10n.string("view.openRootFolder"),
                action: #selector(FileManagerWindowController.openRootFolder(_:)))
        addItem(to: viewMenu,
                title: SZL10n.string("view.upOneLevel"),
                action: #selector(FileManagerWindowController.goUpOneLevel(_:)),
                keyEquivalent: FileManagerShortcuts.menuShortcut(for: .goUpOneLevel)?.keyEquivalent ?? "",
                modifiers: FileManagerShortcuts.menuShortcut(for: .goUpOneLevel)?.modifiers ?? [.command])
        addItem(to: viewMenu,
                title: SZL10n.string("view.foldersHistory"),
                action: #selector(FileManagerWindowController.showFoldersHistory(_:)))
        addItem(to: viewMenu,
                title: SZL10n.string("view.refresh"),
                action: #selector(FileManagerWindowController.refreshActivePane(_:)),
                keyEquivalent: FileManagerShortcuts.menuShortcut(for: .refreshActivePane)?.keyEquivalent ?? "",
                modifiers: FileManagerShortcuts.menuShortcut(for: .refreshActivePane)?.modifiers ?? [])
        addItem(to: viewMenu,
                title: SZL10n.string("view.autoRefresh"),
                action: #selector(FileManagerWindowController.toggleAutoRefresh(_:)))
        viewMenu.addItem(.separator())
        addItem(to: viewMenu,
                title: SZL10n.string("app.fileManager.enterFullScreen"),
                action: #selector(NSWindow.toggleFullScreen(_:)),
                keyEquivalent: "f",
                modifiers: [.command, .control])

        let favoritesMenu = NSMenu(title: SZL10n.string("menu.favorites"))
        favoritesMenu.identifier = MainMenuIdentifiers.favoritesMenu
        favoritesMenu.delegate = coordinator
        addTopLevelMenu(favoritesMenu, to: mainMenu)

        let toolsMenu = NSMenu(title: SZL10n.string("menu.tools"))
        addTopLevelMenu(toolsMenu, to: mainMenu)
        addItem(to: toolsMenu,
                title: SZL10n.string("settings.options"),
                action: #selector(AppDelegate.showPreferences(_:)),
                target: NSApp.delegate)
        toolsMenu.addItem(.separator())
        addItem(to: toolsMenu,
                title: SZL10n.string("tools.benchmark"),
                action: #selector(AppDelegate.showBenchmark(_:)),
                keyEquivalent: "b",
                modifiers: [.command, .shift],
                target: NSApp.delegate)
        toolsMenu.addItem(.separator())
        addItem(to: toolsMenu,
                title: SZL10n.string("tools.deleteTempFiles"),
                action: #selector(AppDelegate.showDeleteTemporaryFiles(_:)),
                target: NSApp.delegate)

        let windowMenu = NSMenu(title: SZL10n.string("app.menu.window"))
        addTopLevelMenu(windowMenu, to: mainMenu)
        addItem(to: windowMenu,
                title: SZL10n.string("app.fileManager.fileManager"),
                action: #selector(AppDelegate.showFileManager(_:)),
                target: NSApp.delegate)
        windowMenu.addItem(.separator())
        addItem(to: windowMenu,
                title: SZL10n.string("app.menu.minimize"),
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m")
        addItem(to: windowMenu,
                title: SZL10n.string("app.menu.zoom"),
                action: #selector(NSWindow.performZoom(_:)))
        windowMenu.addItem(.separator())
        addItem(to: windowMenu,
                title: SZL10n.string("app.menu.bringAllToFront"),
                action: #selector(NSApplication.arrangeInFront(_:)),
                target: NSApp)
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: SZL10n.string("menu.help"))
        addTopLevelMenu(helpMenu, to: mainMenu)
        addItem(to: helpMenu,
                title: "\(appName) Help",
                action: #selector(NSApplication.showHelp(_:)),
                keyEquivalent: "?",
                target: NSApp)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
        coordinator.refreshTimeMenuTitle()
    }

    static func refreshDynamicMenuState() {
        coordinator.refreshTimeMenuTitle()
    }

    private static func installSettingsObserverIfNeeded() {
        guard settingsObserver == nil else { return }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .szSettingsDidChange,
            object: nil,
            queue: .main,
        ) { notification in
            guard let key = notification.userInfo?["key"] as? String,
                  key == SZSettingsKey.fileManagerShortcutPreset.rawValue ||
                  key == SZSettingsKey.fileManagerCustomShortcuts.rawValue
            else {
                return
            }

            MainActor.assumeIsolated {
                setup()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .szLanguageDidChange,
            object: nil,
            queue: .main,
        ) { _ in
            MainActor.assumeIsolated {
                setup()
            }
        }
    }

    @discardableResult
    private static func addItem(to menu: NSMenu,
                                title: String,
                                action: Selector?,
                                keyEquivalent: String = "",
                                modifiers: NSEvent.ModifierFlags = [.command],
                                target: AnyObject? = nil) -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        if !keyEquivalent.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        menu.addItem(item)
        return item
    }

    @discardableResult
    private static func addDisabledItem(to menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return item
    }

    private static func addTopLevelMenu(_ submenu: NSMenu, to mainMenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        mainMenu.addItem(item)
    }
}
