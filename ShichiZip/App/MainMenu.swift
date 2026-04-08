import Cocoa

private enum MainMenuIdentifiers {
        static let favoritesMenu = NSUserInterfaceItemIdentifier("FavoritesMenu")
        static let viewMenu = NSUserInterfaceItemIdentifier("ViewMenu")
        static let timeMenu = NSUserInterfaceItemIdentifier("TimeMenu")
}

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

enum FileManagerMenuFactory {
    private enum TargetKind {
          case windowController
          case appDelegate
    }

    private struct Shortcut {
          let keyEquivalent: String
          let modifiers: NSEvent.ModifierFlags

          init(_ keyEquivalent: String,
                 modifiers: NSEvent.ModifierFlags = [.command]) {
                self.keyEquivalent = keyEquivalent
                self.modifiers = modifiers
          }
    }

    private indirect enum Node {
          case item(title: String,
                        action: Selector,
                        shortcut: Shortcut? = nil,
                        target: TargetKind = .windowController)
          case submenu(title: String, children: [Node])
          case separator
    }

    static func makeFileMenu(appTarget: AnyObject?) -> NSMenu {
          let menu = NSMenu(title: "File")
          populate(menu,
                     with: fileMenuNodes,
                     windowTarget: nil,
                     appTarget: appTarget)
          return menu
    }

    static func makeContextMenu(windowTarget: AnyObject?) -> NSMenu {
          let menu = NSMenu(title: "File")
          populate(menu,
                     with: contextMenuNodes,
                     windowTarget: windowTarget,
                     appTarget: nil)
          return menu
    }

    private static let openNodes: [Node] = [
          .item(title: "Open",
                  action: #selector(FileManagerWindowController.openSelectedItem(_:))),
          .item(title: "Open Inside",
                  action: #selector(FileManagerWindowController.openSelectedItemInside(_:))),
          .item(title: "Open Inside *",
                  action: #selector(FileManagerWindowController.openSelectedItemInsideWildcard(_:))),
          .item(title: "Open Inside #",
                  action: #selector(FileManagerWindowController.openSelectedItemInsideParser(_:))),
          .item(title: "Open Outside",
                  action: #selector(FileManagerWindowController.openSelectedItemOutside(_:))),
    ]

    private static let hashNodes: [Node] = [
          .item(title: "*",
                  action: #selector(FileManagerWindowController.showAllHashes(_:))),
          .item(title: "CRC-32",
                  action: #selector(FileManagerWindowController.showCRC32Hash(_:))),
          .item(title: "CRC-64",
                  action: #selector(FileManagerWindowController.showCRC64Hash(_:))),
          .item(title: "XXH64",
                  action: #selector(FileManagerWindowController.showXXH64Hash(_:))),
          .item(title: "MD5",
                  action: #selector(FileManagerWindowController.showMD5Hash(_:))),
          .item(title: "SHA-1",
                  action: #selector(FileManagerWindowController.showSHA1Hash(_:))),
          .item(title: "SHA-256",
                  action: #selector(FileManagerWindowController.showSHA256Hash(_:))),
          .item(title: "SHA-384",
                  action: #selector(FileManagerWindowController.showSHA384Hash(_:))),
          .item(title: "SHA-512",
                  action: #selector(FileManagerWindowController.showSHA512Hash(_:))),
          .item(title: "SHA3-256",
                  action: #selector(FileManagerWindowController.showSHA3256Hash(_:))),
          .item(title: "BLAKE2sp",
                  action: #selector(FileManagerWindowController.showBLAKE2spHash(_:))),
    ]

    private static var fileMenuNodes: [Node] {
          openNodes + [
                .item(title: "Open Archive…",
                        action: #selector(AppDelegate.openArchives(_:)),
                        shortcut: Shortcut("o"),
                        target: .appDelegate),
                .separator,
                .item(title: "Add",
                        action: #selector(FileManagerWindowController.addToArchive(_:))),
                .item(title: "Extract…",
                        action: #selector(FileManagerWindowController.extractArchive(_:))),
                .item(title: "Extract Here",
                        action: #selector(FileManagerWindowController.extractHere(_:))),
                .item(title: "Test",
                        action: #selector(FileManagerWindowController.testArchive(_:))),
                .separator,
                .item(title: "Rename",
                        action: #selector(FileManagerWindowController.renameSelection(_:))),
                .item(title: "Copy To…",
                        action: #selector(FileManagerWindowController.copyFiles(_:))),
                .item(title: "Move To…",
                        action: #selector(FileManagerWindowController.moveFiles(_:))),
                .item(title: "Delete",
                        action: #selector(FileManagerWindowController.deleteFiles(_:))),
                .separator,
                .item(title: "Properties",
                        action: #selector(FileManagerWindowController.showProperties(_:))),
                .submenu(title: "CRC", children: hashNodes),
                .separator,
                .item(title: "Create Folder",
                        action: #selector(FileManagerWindowController.createFolder(_:))),
                .item(title: "Create File",
                        action: #selector(FileManagerWindowController.createFile(_:))),
                .separator,
                .item(title: "Close",
                        action: #selector(NSWindow.performClose(_:)),
                        shortcut: Shortcut("w")),
          ]
    }

    private static var contextMenuNodes: [Node] {
          openNodes + [
                .separator,
                .item(title: "Compress…",
                        action: #selector(FileManagerWindowController.addToArchive(_:))),
                .item(title: "Extract…",
                        action: #selector(FileManagerWindowController.extractArchive(_:))),
                .item(title: "Extract Here",
                        action: #selector(FileManagerWindowController.extractHere(_:))),
                .item(title: "Test",
                        action: #selector(FileManagerWindowController.testArchive(_:))),
                .separator,
                .item(title: "Rename",
                        action: #selector(FileManagerWindowController.renameSelection(_:))),
                .item(title: "Copy To…",
                        action: #selector(FileManagerWindowController.copyFiles(_:))),
                .item(title: "Move To…",
                        action: #selector(FileManagerWindowController.moveFiles(_:))),
                .item(title: "Delete",
                        action: #selector(FileManagerWindowController.deleteFiles(_:))),
                .separator,
                .submenu(title: "CRC", children: hashNodes),
                .separator,
                .item(title: "Create Folder",
                        action: #selector(FileManagerWindowController.createFolder(_:))),
                .item(title: "Create File",
                        action: #selector(FileManagerWindowController.createFile(_:))),
                .separator,
                .item(title: "Properties",
                        action: #selector(FileManagerWindowController.showProperties(_:))),
          ]
    }

    private static func populate(_ menu: NSMenu,
                                           with nodes: [Node],
                                           windowTarget: AnyObject?,
                                           appTarget: AnyObject?) {
          for node in nodes {
                switch node {
                case let .item(title, action, shortcut, targetKind):
                    let item = NSMenuItem(title: title,
                                                  action: action,
                                                  keyEquivalent: shortcut?.keyEquivalent ?? "")
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
                                 appTarget: appTarget)
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.submenu = submenu
                    menu.addItem(item)

                case .separator:
                    menu.addItem(.separator())
                }
          }
    }
}

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

                for level in FileManagerViewPreferences.TimestampDisplayLevel.allCases {
                        let item = NSMenuItem(title: FileManagerViewPreferences.timeMenuPreviewTitle(for: level),
                                                                  action: selector(for: level),
                                                                  keyEquivalent: "")
                        menu.addItem(item)
                }

                menu.addItem(.separator())
                menu.addItem(NSMenuItem(title: "UTC",
                                                                action: #selector(FileManagerWindowController.toggleTimestampUTC(_:)),
                                                                keyEquivalent: ""))
                refreshTimeMenuTitle()
        }

        private func rebuildFavoritesMenu(_ menu: NSMenu) {
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

        private func selector(for level: FileManagerViewPreferences.TimestampDisplayLevel) -> Selector {
                switch level {
                case .day:
                        return #selector(FileManagerWindowController.showTimestampDay(_:))
                case .minute:
                        return #selector(FileManagerWindowController.showTimestampMinute(_:))
                case .second:
                        return #selector(FileManagerWindowController.showTimestampSecond(_:))
                case .ntfs:
                        return #selector(FileManagerWindowController.showTimestampNTFS(_:))
                case .nanoseconds:
                        return #selector(FileManagerWindowController.showTimestampNanoseconds(_:))
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
                action: #selector(AppDelegate.showAbout(_:)),
                target: NSApp.delegate)
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

        let fileMenu = FileManagerMenuFactory.makeFileMenu(appTarget: NSApp.delegate as AnyObject?)
        addTopLevelMenu(fileMenu, to: mainMenu)

        let editMenu = NSMenu(title: "Edit")
        addTopLevelMenu(editMenu, to: mainMenu)
        addItem(to: editMenu,
                title: "Cut",
                action: #selector(NSText.cut(_:)),
                keyEquivalent: "x")
        addItem(to: editMenu,
                title: "Copy",
                action: #selector(NSText.copy(_:)),
                keyEquivalent: "c")
        addItem(to: editMenu,
                title: "Paste",
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v")
        editMenu.addItem(.separator())
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
        viewMenu.identifier = MainMenuIdentifiers.viewMenu
        viewMenu.delegate = coordinator
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

        let timeMenuItem = NSMenuItem(title: FileManagerViewPreferences.timeMenuPreviewTitle(for: .day),
                                      action: nil,
                                      keyEquivalent: "")
        let timeMenu = NSMenu(title: timeMenuItem.title)
        timeMenu.identifier = MainMenuIdentifiers.timeMenu
        timeMenu.delegate = coordinator
        coordinator.timeMenuItem = timeMenuItem
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
        addItem(to: viewMenu,
                title: "Auto Refresh",
                action: #selector(FileManagerWindowController.toggleAutoRefresh(_:)))
        viewMenu.addItem(.separator())
        addItem(to: viewMenu,
                title: "Enter Full Screen",
                action: #selector(NSWindow.toggleFullScreen(_:)),
                keyEquivalent: "f",
                modifiers: [.command, .control])

        let favoritesMenu = NSMenu(title: "Favorites")
        favoritesMenu.identifier = MainMenuIdentifiers.favoritesMenu
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
        toolsMenu.addItem(.separator())
        addItem(to: toolsMenu,
                title: "Delete Temporary Files…",
                action: #selector(AppDelegate.showDeleteTemporaryFiles(_:)),
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
                coordinator.refreshTimeMenuTitle()
        }

        static func refreshDynamicMenuState() {
                coordinator.refreshTimeMenuTitle()
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
