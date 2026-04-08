import Cocoa

enum FileManagerFavoriteStore {
    static let slotCount = 10

    private static let defaults = UserDefaults.standard
    private static let defaultsKey = "FileManager.Favorites"

    static func url(for slot: Int) -> URL? {
        guard (0..<slotCount).contains(slot) else { return nil }

        let path = storedPaths()[slot]
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func set(url: URL, for slot: Int) {
        guard (0..<slotCount).contains(slot) else { return }

        var paths = storedPaths()
        paths[slot] = url.standardizedFileURL.path
        defaults.set(paths, forKey: defaultsKey)
    }

    static func saveSlotTitle(for slot: Int) -> String {
        "Bookmark \(slot)"
    }

    static func displayTitle(for slot: Int) -> String {
        guard let url = url(for: slot) else {
            return "-"
        }

        return shortenedPath(url.path)
    }

    private static func storedPaths() -> [String] {
        var paths = defaults.stringArray(forKey: defaultsKey) ?? []

        if paths.count < slotCount {
            paths.append(contentsOf: Array(repeating: "", count: slotCount - paths.count))
        } else if paths.count > slotCount {
            paths.removeSubrange(slotCount..<paths.count)
        }

        return paths
    }

    private static func shortenedPath(_ path: String) -> String {
        let maxLength = 100
        guard path.count > maxLength else { return path }

        let keepCount = max(1, (maxLength - 5) / 2)
        let prefix = String(path.prefix(keepCount))
        let suffix = String(path.suffix(keepCount))
        return "\(prefix) ... \(suffix)"
    }
}

private final class MainMenuCoordinator: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let addToFavoritesItem = NSMenuItem(title: "Add Folder to Favorites As", action: nil, keyEquivalent: "")
        let addToFavoritesMenu = NSMenu(title: addToFavoritesItem.title)

        for slot in 0..<FileManagerFavoriteStore.slotCount {
            let item = NSMenuItem(title: FileManagerFavoriteStore.saveSlotTitle(for: slot),
                                  action: #selector(FileManagerWindowController.saveFavoriteSlot(_:)),
                                  keyEquivalent: "")
            item.tag = slot
            addToFavoritesMenu.addItem(item)
        }

        addToFavoritesItem.submenu = addToFavoritesMenu
        menu.addItem(addToFavoritesItem)
        menu.addItem(.separator())

        for slot in 0..<FileManagerFavoriteStore.slotCount {
            let item = NSMenuItem(title: FileManagerFavoriteStore.displayTitle(for: slot),
                                  action: #selector(FileManagerWindowController.openFavoriteSlot(_:)),
                                  keyEquivalent: "")
            item.tag = slot
            menu.addItem(item)
        }
    }
}

/// Sets up the main application menu bar programmatically.
enum MainMenu {
    private static let coordinator = MainMenuCoordinator()

    static func setup() {
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenu = NSMenu(title: "ShichiZip")
        addTopLevelMenu(appMenu, to: mainMenu)
        addItem(to: appMenu,
                title: "About ShichiZip",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                target: NSApp)
        appMenu.addItem(.separator())
        addItem(to: appMenu,
                title: "Preferences…",
                action: #selector(AppDelegate.showPreferences(_:)),
                keyEquivalent: ",",
                target: NSApp.delegate)
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)

        appMenu.addItem(.separator())
        addItem(to: appMenu,
                title: "Hide ShichiZip",
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h",
                target: NSApp)
        addItem(to: appMenu,
                title: "Hide Others",
                action: #selector(NSApplication.hideOtherApplications(_:)),
                keyEquivalent: "h",
                modifiers: [.command, .option],
                target: NSApp)
        addItem(to: appMenu,
                title: "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                target: NSApp)
        appMenu.addItem(.separator())
        addItem(to: appMenu,
                title: "Quit ShichiZip",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q",
                target: NSApp)

        let fileMenu = NSMenu(title: "File")
        addTopLevelMenu(fileMenu, to: mainMenu)
        addItem(to: fileMenu,
                title: "Open",
                action: #selector(FileManagerWindowController.openSelectedItem(_:)))
        addItem(to: fileMenu,
                title: "Open Archive…",
                action: #selector(AppDelegate.openArchives(_:)),
                keyEquivalent: "o",
                target: NSApp.delegate)
        fileMenu.addItem(.separator())
        addItem(to: fileMenu,
                title: "Add",
                action: #selector(FileManagerWindowController.addToArchive(_:)))
        addItem(to: fileMenu,
                title: "Extract…",
                action: #selector(FileManagerWindowController.extractArchive(_:)))
        addItem(to: fileMenu,
                title: "Extract Here",
                action: #selector(FileManagerWindowController.extractHere(_:)))
        addItem(to: fileMenu,
                title: "Test",
                action: #selector(FileManagerWindowController.testArchive(_:)))
        fileMenu.addItem(.separator())
        addItem(to: fileMenu,
                title: "Rename",
                action: #selector(FileManagerWindowController.renameSelection(_:)))
        addItem(to: fileMenu,
                title: "Copy To…",
                action: #selector(FileManagerWindowController.copyFiles(_:)))
        addItem(to: fileMenu,
                title: "Move To…",
                action: #selector(FileManagerWindowController.moveFiles(_:)))
        addItem(to: fileMenu,
                title: "Delete",
                action: #selector(FileManagerWindowController.deleteFiles(_:)))
        fileMenu.addItem(.separator())
        addItem(to: fileMenu,
                title: "Properties",
                action: #selector(FileManagerWindowController.showProperties(_:)))
        fileMenu.addItem(.separator())
        addItem(to: fileMenu,
                title: "Create Folder",
                action: #selector(FileManagerWindowController.createFolder(_:)))
        fileMenu.addItem(.separator())
        addItem(to: fileMenu,
                title: "Close",
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w")

        let editMenu = NSMenu(title: "Edit")
        addTopLevelMenu(editMenu, to: mainMenu)
        addItem(to: editMenu,
                title: "Select All",
                action: #selector(FileManagerWindowController.selectAllItems(_:)),
                keyEquivalent: "a")
        addItem(to: editMenu,
                title: "Deselect All",
                action: #selector(FileManagerWindowController.deselectAllItems(_:)),
                keyEquivalent: "a",
                modifiers: [.command, .shift])
        addItem(to: editMenu,
                title: "Invert Selection",
                action: #selector(FileManagerWindowController.invertSelection(_:)))

        let viewMenu = NSMenu(title: "View")
        addTopLevelMenu(viewMenu, to: mainMenu)
        addDisabledItem(to: viewMenu, title: "Large Icons")
        addDisabledItem(to: viewMenu, title: "Small Icons")
        addDisabledItem(to: viewMenu, title: "List")
        let detailsItem = addDisabledItem(to: viewMenu, title: "Details")
        detailsItem.state = .on
        viewMenu.addItem(.separator())
        addItem(to: viewMenu,
                title: "Name",
                action: #selector(FileManagerWindowController.sortByName(_:)))
        addItem(to: viewMenu,
                title: "Type",
                action: #selector(FileManagerWindowController.sortByType(_:)))
        addItem(to: viewMenu,
                title: "Date",
                action: #selector(FileManagerWindowController.sortByModifiedDate(_:)))
        addItem(to: viewMenu,
                title: "Size",
                action: #selector(FileManagerWindowController.sortBySize(_:)))
        addDisabledItem(to: viewMenu, title: "Unsorted")
        viewMenu.addItem(.separator())
        addDisabledItem(to: viewMenu, title: "Flat View")
        addItem(to: viewMenu,
                title: "2 Panels",
                action: #selector(FileManagerWindowController.toggleDualPane(_:)))

        let timeMenuItem = NSMenuItem(title: "Time", action: nil, keyEquivalent: "")
        let timeMenu = NSMenu(title: "Time")
        let localTimeItem = addDisabledItem(to: timeMenu, title: "Local Time")
        localTimeItem.state = .on
        addDisabledItem(to: timeMenu, title: "UTC")
        timeMenuItem.submenu = timeMenu
        viewMenu.addItem(timeMenuItem)

        let toolbarsMenuItem = NSMenuItem(title: "Toolbars", action: nil, keyEquivalent: "")
        let toolbarsMenu = NSMenu(title: "Toolbars")
        addItem(to: toolbarsMenu,
                title: "Archive Toolbar",
                action: #selector(FileManagerWindowController.toggleArchiveToolbar(_:)))
        addItem(to: toolbarsMenu,
                title: "Standard Toolbar",
                action: #selector(FileManagerWindowController.toggleStandardToolbar(_:)))
        toolbarsMenu.addItem(.separator())
        addItem(to: toolbarsMenu,
                title: "Large Buttons",
                action: #selector(FileManagerWindowController.toggleLargeToolbarButtons(_:)))
        addItem(to: toolbarsMenu,
                title: "Show Buttons Text",
                action: #selector(FileManagerWindowController.toggleToolbarButtonText(_:)))
        toolbarsMenuItem.submenu = toolbarsMenu
        viewMenu.addItem(toolbarsMenuItem)

        addItem(to: viewMenu,
                title: "Open Root Folder",
                action: #selector(FileManagerWindowController.openRootFolder(_:)))
        addItem(to: viewMenu,
                title: "Up One Level",
                action: #selector(FileManagerWindowController.goUpOneLevel(_:)))
        addItem(to: viewMenu,
                title: "Folders History…",
                action: #selector(FileManagerWindowController.showFoldersHistory(_:)))
        addItem(to: viewMenu,
                title: "Refresh",
                action: #selector(FileManagerWindowController.refreshActivePane(_:)),
                keyEquivalent: "r")
        addDisabledItem(to: viewMenu, title: "Auto Refresh")
        viewMenu.addItem(.separator())
        addItem(to: viewMenu,
                title: "Enter Full Screen",
                action: #selector(NSWindow.toggleFullScreen(_:)),
                keyEquivalent: "f",
                modifiers: [.command, .control])

        let favoritesMenu = NSMenu(title: "Favorites")
        favoritesMenu.delegate = coordinator
        addTopLevelMenu(favoritesMenu, to: mainMenu)

        let toolsMenu = NSMenu(title: "Tools")
        addTopLevelMenu(toolsMenu, to: mainMenu)
        addItem(to: toolsMenu,
                title: "Options…",
                action: #selector(AppDelegate.showPreferences(_:)),
                target: NSApp.delegate)
        toolsMenu.addItem(.separator())
        addItem(to: toolsMenu,
                title: "Benchmark",
                action: #selector(AppDelegate.showBenchmark(_:)),
                keyEquivalent: "b",
                modifiers: [.command, .shift],
                target: NSApp.delegate)

        let windowMenu = NSMenu(title: "Window")
        addTopLevelMenu(windowMenu, to: mainMenu)
        addItem(to: windowMenu,
                title: "File Manager",
                action: #selector(AppDelegate.showFileManager(_:)),
                target: NSApp.delegate)
        windowMenu.addItem(.separator())
        addItem(to: windowMenu,
                title: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m")
        addItem(to: windowMenu,
                title: "Zoom",
                action: #selector(NSWindow.performZoom(_:)))
        windowMenu.addItem(.separator())
        addItem(to: windowMenu,
                title: "Bring All to Front",
                action: #selector(NSApplication.arrangeInFront(_:)),
                target: NSApp)
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        addTopLevelMenu(helpMenu, to: mainMenu)
        addItem(to: helpMenu,
                title: "ShichiZip Help",
                action: #selector(NSApplication.showHelp(_:)),
                keyEquivalent: "?",
                target: NSApp)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private static func addItem(to menu: NSMenu,
                                title: String,
                                action: Selector?,
                                keyEquivalent: String = "",
                                modifiers: NSEvent.ModifierFlags = [.command],
                                target: AnyObject? = nil) -> NSMenuItem {
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
