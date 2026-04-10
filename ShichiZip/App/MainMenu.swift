import Cocoa

private enum MainMenuIdentifiers {
        static let favoritesMenu = NSUserInterfaceItemIdentifier("FavoritesMenu")
        static let viewMenu = NSUserInterfaceItemIdentifier("ViewMenu")
        static let timeMenu = NSUserInterfaceItemIdentifier("TimeMenu")
}

struct FileManagerMenuShortcut {
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags

        init(_ keyEquivalent: String,
                 modifiers: NSEvent.ModifierFlags = [.command]) {
                self.keyEquivalent = keyEquivalent
                self.modifiers = modifiers
        }
}

struct FileManagerShortcut: Equatable {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let keyEquivalent: String

        init(keyCode: UInt16,
                 modifiers: NSEvent.ModifierFlags = [],
                 keyEquivalent: String) {
                self.keyCode = keyCode
                self.modifiers = Self.normalizedModifiers(modifiers)
                self.keyEquivalent = keyEquivalent
        }

        init?(event: NSEvent) {
                guard let keyEquivalent = Self.keyEquivalentString(for: event) else {
                        return nil
                }

                self.init(keyCode: event.keyCode,
                          modifiers: event.modifierFlags,
                          keyEquivalent: keyEquivalent)
        }

        var menuShortcut: FileManagerMenuShortcut {
                FileManagerMenuShortcut(keyEquivalent, modifiers: modifiers)
        }

        var displayName: String {
                let keyName = Self.baseKeyDisplayName(forKeyCode: keyCode,
                                                      keyEquivalent: keyEquivalent)
                let modifierNames = Self.modifierDisplayNames(for: modifiers)
                return (modifierNames + [keyName]).joined(separator: "+")
        }

        func matches(_ event: NSEvent) -> Bool {
                keyCode == event.keyCode && modifiers == Self.normalizedModifiers(event.modifierFlags)
        }

        var serializedRepresentation: [String: Any] {
                [
                        "keyCode": Int(keyCode),
                        "modifiers": Int(modifiers.rawValue),
                        "keyEquivalent": keyEquivalent,
                ]
        }

        static func fromSerializedRepresentation(_ representation: [String: Any]) -> FileManagerShortcut? {
                guard let keyCode = representation["keyCode"] as? Int,
                          let modifiers = representation["modifiers"] as? Int,
                          let keyEquivalent = representation["keyEquivalent"] as? String else {
                        return nil
                }

                return FileManagerShortcut(keyCode: UInt16(keyCode),
                                           modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)),
                                           keyEquivalent: keyEquivalent)
        }

        private static func normalizedModifiers(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
                modifiers.intersection([.command, .option, .control, .shift])
        }

        private static func keyEquivalentString(for event: NSEvent) -> String? {
                if let specialKeyEquivalent = specialKeyEquivalent(for: event.keyCode) {
                        return specialKeyEquivalent
                }

                guard var characters = event.charactersIgnoringModifiers,
                          !characters.isEmpty else {
                        return nil
                }

                if characters.count > 1 {
                        characters = String(characters.prefix(1))
                }

                return characters.lowercased()
        }

        private static func specialKeyEquivalent(for keyCode: UInt16) -> String? {
                switch keyCode {
                case 36:
                        return "\r"
                case 48:
                        return "\t"
                case 49:
                        return " "
                case 51:
                        return String(UnicodeScalar(NSDeleteCharacter)!)
                case 96:
                        return functionKeyEquivalent(5)
                case 97:
                        return functionKeyEquivalent(6)
                case 98:
                        return functionKeyEquivalent(7)
                case 100:
                        return functionKeyEquivalent(8)
                case 101:
                        return functionKeyEquivalent(9)
                case 120:
                        return functionKeyEquivalent(2)
                case 123:
                        return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
                case 124:
                        return String(UnicodeScalar(NSRightArrowFunctionKey)!)
                case 125:
                        return String(UnicodeScalar(NSDownArrowFunctionKey)!)
                case 126:
                        return String(UnicodeScalar(NSUpArrowFunctionKey)!)
                default:
                        return nil
                }
        }

        private static func functionKeyEquivalent(_ number: Int) -> String {
                String(UnicodeScalar(Int(NSF1FunctionKey) + number - 1)!)
        }

        private static func baseKeyDisplayName(forKeyCode keyCode: UInt16,
                                               keyEquivalent: String) -> String {
                switch keyCode {
                case 36:
                        return "Return"
                case 48:
                        return "Tab"
                case 49:
                        return "Space"
                case 51:
                        return "Delete"
                case 96:
                        return "F5"
                case 97:
                        return "F6"
                case 98:
                        return "F7"
                case 100:
                        return "F8"
                case 101:
                        return "F9"
                case 120:
                        return "F2"
                case 123:
                        return "Left Arrow"
                case 124:
                        return "Right Arrow"
                case 125:
                        return "Down Arrow"
                case 126:
                        return "Up Arrow"
                default:
                        return keyEquivalent == " " ? "Space" : keyEquivalent.uppercased()
                }
        }

        private static func modifierDisplayNames(for modifiers: NSEvent.ModifierFlags) -> [String] {
                var names: [String] = []
                if modifiers.contains(.command) {
                        names.append("Command")
                }
                if modifiers.contains(.shift) {
                        names.append("Shift")
                }
                if modifiers.contains(.option) {
                        names.append("Option")
                }
                if modifiers.contains(.control) {
                        names.append("Control")
                }
                return names
        }
}

enum FileManagerShortcutPreset: Int, CaseIterable {
        case finder = 0
        case commander = 1
        case custom = 2

        var displayName: String {
                switch self {
                case .finder:
                        return "Finder-like"
                case .commander:
                        return "Commander-like"
                case .custom:
                        return "Custom"
                }
        }

        var descriptionText: String {
                switch self {
                case .finder:
                        return "Uses macOS-style file manager shortcuts, including Return to rename and Command+Arrow navigation."
                case .commander:
                        return "Uses the classic 7-Zip function-key workflow for file operations and pane management."
                case .custom:
                        return "Uses your saved per-command file manager shortcuts."
                }
        }
}

enum FileManagerShortcutCommand: String, CaseIterable {
        case openSelectedItem
        case toggleQuickLook
        case goUpOneLevel
        case renameSelection
        case switchPanes
        case copyFiles
        case moveFiles
        case createFolder
        case deleteFiles
        case toggleDualPane
        case refreshActivePane

        var title: String {
                switch self {
                case .openSelectedItem:
                        return "Open selected item"
                case .toggleQuickLook:
                        return "Quick Look"
                case .goUpOneLevel:
                        return "Up one level"
                case .renameSelection:
                        return "Rename"
                case .switchPanes:
                        return "Switch panes"
                case .copyFiles:
                        return "Copy To"
                case .moveFiles:
                        return "Move To"
                case .createFolder:
                        return "Create folder"
                case .deleteFiles:
                        return "Delete"
                case .toggleDualPane:
                        return "Toggle dual pane"
                case .refreshActivePane:
                        return "Refresh"
                }
        }
}

struct FileManagerShortcutBinding {
        let command: FileManagerShortcutCommand
        let shortcut: FileManagerShortcut?

        var displayKey: String {
                shortcut?.displayName ?? "None"
        }

        var menuShortcut: FileManagerMenuShortcut? {
                shortcut?.menuShortcut
        }
}

enum FileManagerShortcuts {
        static func bindings(for preset: FileManagerShortcutPreset = SZSettings.fileManagerShortcutPreset) -> [FileManagerShortcutBinding] {
                let bindingMap = resolvedBindingMap(for: preset)
                return FileManagerShortcutCommand.allCases.map { command in
                        FileManagerShortcutBinding(command: command,
                                                   shortcut: bindingMap[command])
                }
        }

        static func resolvedBindingMap(for preset: FileManagerShortcutPreset = SZSettings.fileManagerShortcutPreset) -> [FileManagerShortcutCommand: FileManagerShortcut] {
                switch preset {
                case .finder, .commander:
                        return standardBindingMap(for: preset)
                case .custom:
                        if SZSettings.hasFileManagerCustomShortcutMap {
                                return SZSettings.fileManagerCustomShortcutMap
                        }
                        return standardBindingMap(for: .finder)
                }
        }

        static func menuShortcut(for command: FileManagerShortcutCommand,
                                                         preset: FileManagerShortcutPreset = SZSettings.fileManagerShortcutPreset) -> FileManagerMenuShortcut? {
                binding(for: command, preset: preset).menuShortcut
        }

        static func binding(for command: FileManagerShortcutCommand,
                            preset: FileManagerShortcutPreset = SZSettings.fileManagerShortcutPreset) -> FileManagerShortcutBinding {
                return FileManagerShortcutBinding(command: command,
                                                  shortcut: resolvedBindingMap(for: preset)[command])
        }

        static func command(for event: NSEvent,
                            preset: FileManagerShortcutPreset = SZSettings.fileManagerShortcutPreset) -> FileManagerShortcutCommand? {
                for command in FileManagerShortcutCommand.allCases {
                        guard let shortcut = resolvedBindingMap(for: preset)[command] else {
                                continue
                        }
                        if shortcut.matches(event) {
                                return command
                        }
                }

                return nil
        }

        private static func standardBindingMap(for preset: FileManagerShortcutPreset) -> [FileManagerShortcutCommand: FileManagerShortcut] {
                switch preset {
                case .finder:
                        return [
                                .openSelectedItem: FileManagerShortcut(keyCode: 125,
                                                                       modifiers: [.command],
                                                                       keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!)),
                                .toggleQuickLook: FileManagerShortcut(keyCode: 49,
                                                                      keyEquivalent: " "),
                                .goUpOneLevel: FileManagerShortcut(keyCode: 126,
                                                                   modifiers: [.command],
                                                                   keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)),
                                .renameSelection: FileManagerShortcut(keyCode: 36,
                                                                      keyEquivalent: "\r"),
                                .switchPanes: FileManagerShortcut(keyCode: 48,
                                                                  keyEquivalent: "\t"),
                                .createFolder: FileManagerShortcut(keyCode: 45,
                                                                   modifiers: [.command, .shift],
                                                                   keyEquivalent: "n"),
                                .deleteFiles: FileManagerShortcut(keyCode: 51,
                                                                  modifiers: [.command],
                                                                  keyEquivalent: String(UnicodeScalar(NSDeleteCharacter)!)),
                                .refreshActivePane: FileManagerShortcut(keyCode: 15,
                                                                        modifiers: [.command],
                                                                        keyEquivalent: "r"),
                        ]
                case .commander:
                        return [
                                .openSelectedItem: FileManagerShortcut(keyCode: 36,
                                                                       keyEquivalent: "\r"),
                                .toggleQuickLook: FileManagerShortcut(keyCode: 49,
                                                                      keyEquivalent: " "),
                                .goUpOneLevel: FileManagerShortcut(keyCode: 51,
                                                                   keyEquivalent: String(UnicodeScalar(NSDeleteCharacter)!)),
                                .renameSelection: FileManagerShortcut(keyCode: 120,
                                                                      keyEquivalent: String(UnicodeScalar(Int(NSF1FunctionKey) + 1)!)),
                                .switchPanes: FileManagerShortcut(keyCode: 48,
                                                                  keyEquivalent: "\t"),
                                .copyFiles: FileManagerShortcut(keyCode: 96,
                                                                keyEquivalent: String(UnicodeScalar(Int(NSF1FunctionKey) + 4)!)),
                                .moveFiles: FileManagerShortcut(keyCode: 97,
                                                                keyEquivalent: String(UnicodeScalar(Int(NSF1FunctionKey) + 5)!)),
                                .createFolder: FileManagerShortcut(keyCode: 98,
                                                                   keyEquivalent: String(UnicodeScalar(Int(NSF1FunctionKey) + 6)!)),
                                .deleteFiles: FileManagerShortcut(keyCode: 100,
                                                                  keyEquivalent: String(UnicodeScalar(Int(NSF1FunctionKey) + 7)!)),
                                .toggleDualPane: FileManagerShortcut(keyCode: 101,
                                                                     keyEquivalent: String(UnicodeScalar(Int(NSF1FunctionKey) + 8)!)),
                                .refreshActivePane: FileManagerShortcut(keyCode: 15,
                                                                        modifiers: [.command],
                                                                        keyEquivalent: "r"),
                        ]
                case .custom:
                        return [:]
                }
        }
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

            init(_ shortcut: FileManagerMenuShortcut) {
                    self.keyEquivalent = shortcut.keyEquivalent
                    self.modifiers = shortcut.modifiers
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

    private static func shortcut(_ command: FileManagerShortcutCommand) -> Shortcut? {
            guard let shortcut = FileManagerShortcuts.menuShortcut(for: command) else {
                    return nil
            }
            return Shortcut(shortcut)
    }

    private static let openNodes: [Node] = [
          .item(title: "Open",
                        action: #selector(FileManagerWindowController.openSelectedItem(_:)),
                        shortcut: shortcut(.openSelectedItem)),
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
                        action: #selector(FileManagerWindowController.renameSelection(_:)),
                        shortcut: shortcut(.renameSelection)),
                .item(title: "Copy To…",
                        action: #selector(FileManagerWindowController.copyFiles(_:)),
                        shortcut: shortcut(.copyFiles)),
                .item(title: "Move To…",
                        action: #selector(FileManagerWindowController.moveFiles(_:)),
                        shortcut: shortcut(.moveFiles)),
                .item(title: "Delete",
                        action: #selector(FileManagerWindowController.deleteFiles(_:)),
                        shortcut: shortcut(.deleteFiles)),
                .separator,
                .item(title: "Properties",
                        action: #selector(FileManagerWindowController.showProperties(_:))),
                .submenu(title: "CRC", children: hashNodes),
                .separator,
                .item(title: "Create Folder",
                        action: #selector(FileManagerWindowController.createFolder(_:)),
                        shortcut: shortcut(.createFolder)),
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
                        action: #selector(FileManagerWindowController.renameSelection(_:)),
                        shortcut: shortcut(.renameSelection)),
                .item(title: "Copy To…",
                        action: #selector(FileManagerWindowController.copyFiles(_:)),
                        shortcut: shortcut(.copyFiles)),
                .item(title: "Move To…",
                        action: #selector(FileManagerWindowController.moveFiles(_:)),
                        shortcut: shortcut(.moveFiles)),
                .item(title: "Delete",
                        action: #selector(FileManagerWindowController.deleteFiles(_:)),
                        shortcut: shortcut(.deleteFiles)),
                .separator,
                .submenu(title: "CRC", children: hashNodes),
                .separator,
                .item(title: "Create Folder",
                        action: #selector(FileManagerWindowController.createFolder(_:)),
                        shortcut: shortcut(.createFolder)),
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
        private static var settingsObserver: NSObjectProtocol?

    static func setup() {
                installSettingsObserverIfNeeded()
        let appName = AppBuildInfo.appDisplayName()
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenu = NSMenu(title: appName)
        addTopLevelMenu(appMenu, to: mainMenu)
        addItem(to: appMenu,
                title: "About \(appName)",
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
                title: "Hide \(appName)",
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
                title: "Quit \(appName)",
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
                action: #selector(FileManagerWindowController.goUpOneLevel(_:)),
                keyEquivalent: FileManagerShortcuts.menuShortcut(for: .goUpOneLevel)?.keyEquivalent ?? "",
                modifiers: FileManagerShortcuts.menuShortcut(for: .goUpOneLevel)?.modifiers ?? [.command])
        addItem(to: viewMenu,
                title: "Folders History…",
                action: #selector(FileManagerWindowController.showFoldersHistory(_:)))
        addItem(to: viewMenu,
                title: "Refresh",
                action: #selector(FileManagerWindowController.refreshActivePane(_:)),
                keyEquivalent: FileManagerShortcuts.menuShortcut(for: .refreshActivePane)?.keyEquivalent ?? "r",
                modifiers: FileManagerShortcuts.menuShortcut(for: .refreshActivePane)?.modifiers ?? [.command])
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
                        queue: .main
                ) { notification in
                        guard let key = notification.userInfo?["key"] as? String,
                                  key == SZSettingsKey.fileManagerShortcutPreset.rawValue ||
                                  key == SZSettingsKey.fileManagerCustomShortcuts.rawValue else {
                                return
                        }

                        setup()
                }
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
