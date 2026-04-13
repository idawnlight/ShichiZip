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
         modifiers: NSEvent.ModifierFlags = [.command])
    {
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
         keyEquivalent: String)
    {
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
              let keyEquivalent = representation["keyEquivalent"] as? String
        else {
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
              !characters.isEmpty
        else {
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
            "\r"
        case 48:
            "\t"
        case 49:
            " "
        case 51:
            String(UnicodeScalar(NSDeleteCharacter)!)
        case 96:
            functionKeyEquivalent(5)
        case 97:
            functionKeyEquivalent(6)
        case 98:
            functionKeyEquivalent(7)
        case 100:
            functionKeyEquivalent(8)
        case 101:
            functionKeyEquivalent(9)
        case 120:
            functionKeyEquivalent(2)
        case 123:
            String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124:
            String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 125:
            String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126:
            String(UnicodeScalar(NSUpArrowFunctionKey)!)
        default:
            nil
        }
    }

    private static func functionKeyEquivalent(_ number: Int) -> String {
        String(UnicodeScalar(Int(NSF1FunctionKey) + number - 1)!)
    }

    private static func baseKeyDisplayName(forKeyCode keyCode: UInt16,
                                           keyEquivalent: String) -> String
    {
        switch keyCode {
        case 36:
            "Return"
        case 48:
            "Tab"
        case 49:
            "Space"
        case 51:
            "Delete"
        case 96:
            "F5"
        case 97:
            "F6"
        case 98:
            "F7"
        case 100:
            "F8"
        case 101:
            "F9"
        case 120:
            "F2"
        case 123:
            "Left Arrow"
        case 124:
            "Right Arrow"
        case 125:
            "Down Arrow"
        case 126:
            "Up Arrow"
        default:
            keyEquivalent == " " ? "Space" : keyEquivalent.uppercased()
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
            "Finder-like"
        case .commander:
            "Commander-like"
        case .custom:
            "Custom"
        }
    }

    var descriptionText: String {
        switch self {
        case .finder:
            "Uses macOS-style file manager shortcuts, including Return to rename and Command+Arrow navigation."
        case .commander:
            "Uses the classic 7-Zip function-key workflow for file operations and pane management."
        case .custom:
            "Uses your saved per-command file manager shortcuts."
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
            "Open selected item"
        case .toggleQuickLook:
            "Quick Look"
        case .goUpOneLevel:
            "Up one level"
        case .renameSelection:
            "Rename"
        case .switchPanes:
            "Switch panes"
        case .copyFiles:
            "Copy To"
        case .moveFiles:
            "Move To"
        case .createFolder:
            "Create folder"
        case .deleteFiles:
            "Delete"
        case .toggleDualPane:
            "Toggle dual pane"
        case .refreshActivePane:
            "Refresh"
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
                             preset: FileManagerShortcutPreset = SZSettings.fileManagerShortcutPreset) -> FileManagerMenuShortcut?
    {
        binding(for: command, preset: preset).menuShortcut
    }

    static func binding(for command: FileManagerShortcutCommand,
                        preset: FileManagerShortcutPreset = SZSettings.fileManagerShortcutPreset) -> FileManagerShortcutBinding
    {
        FileManagerShortcutBinding(command: command,
                                   shortcut: resolvedBindingMap(for: preset)[command])
    }

    static func command(for event: NSEvent,
                        preset: FileManagerShortcutPreset = SZSettings.fileManagerShortcutPreset) -> FileManagerShortcutCommand?
    {
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
            [
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
            [
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
            [:]
        }
    }
}

enum FileManagerFavoriteStore {
    static let slotCount = 10

    private static var defaults: UserDefaults {
        .standard
    }

    private static let defaultsKey = "FileManager.Favorites"

    static func url(for slot: Int) -> URL? {
        guard (0 ..< slotCount).contains(slot) else { return nil }

        let path = storedPaths()[slot]
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func set(url: URL, for slot: Int) {
        guard (0 ..< slotCount).contains(slot) else { return }

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
            paths.removeSubrange(slotCount ..< paths.count)
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
                  target: TargetKind = .windowController)
        case submenu(title: String, children: [Node])
        case separator
    }

    static func makeFileMenu(appTarget: AnyObject?) -> NSMenu {
        let menu = NSMenu(title: SZL10n.string("menu.file"))
        populate(menu,
                 with: fileMenuNodes,
                 windowTarget: nil,
                 appTarget: appTarget)
        return menu
    }

    static func makeContextMenu(windowTarget: AnyObject?) -> NSMenu {
        let menu = NSMenu(title: SZL10n.string("menu.file"))
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
        [
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
    }

    private static var fileMenuNodes: [Node] {
        openNodes + [
            .item(title: SZL10n.string("app.fileManager.openArchive"),
                  action: #selector(AppDelegate.openArchives(_:)),
                  shortcut: Shortcut("o"),
                  target: .appDelegate),
            .separator,
            .item(title: SZL10n.string("toolbar.add"),
                  action: #selector(FileManagerWindowController.addToArchive(_:))),
            .item(title: SZL10n.string("toolbar.extract") + "…",
                  action: #selector(FileManagerWindowController.extractArchive(_:))),
            .item(title: SZL10n.string("app.fileManager.extractHere"),
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
            .item(title: SZL10n.string("app.fileManager.extractHere"),
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
                                 appTarget: AnyObject?)
    {
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

    private func selector(for level: FileManagerViewPreferences.TimestampDisplayLevel) -> Selector {
        switch level {
        case .day:
            #selector(FileManagerWindowController.showTimestampDay(_:))
        case .minute:
            #selector(FileManagerWindowController.showTimestampMinute(_:))
        case .second:
            #selector(FileManagerWindowController.showTimestampSecond(_:))
        case .ntfs:
            #selector(FileManagerWindowController.showTimestampNTFS(_:))
        case .nanoseconds:
            #selector(FileManagerWindowController.showTimestampNanoseconds(_:))
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

        let fileMenu = FileManagerMenuFactory.makeFileMenu(appTarget: NSApp.delegate as AnyObject?)
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
                action: #selector(FileManagerWindowController.selectAllItems(_:)),
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
        addItem(to: viewMenu,
                title: SZL10n.string("column.name"),
                action: #selector(FileManagerWindowController.sortByName(_:)))
        addItem(to: viewMenu,
                title: SZL10n.string("column.type"),
                action: #selector(FileManagerWindowController.sortByType(_:)))
        addItem(to: viewMenu,
                title: SZL10n.string("column.modified"),
                action: #selector(FileManagerWindowController.sortByModifiedDate(_:)))
        addItem(to: viewMenu,
                title: SZL10n.string("column.size"),
                action: #selector(FileManagerWindowController.sortBySize(_:)))
        addDisabledItem(to: viewMenu, title: SZL10n.string("view.unsorted"))
        viewMenu.addItem(.separator())
        addDisabledItem(to: viewMenu, title: SZL10n.string("view.flatView"))
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
                keyEquivalent: FileManagerShortcuts.menuShortcut(for: .refreshActivePane)?.keyEquivalent ?? "r",
                modifiers: FileManagerShortcuts.menuShortcut(for: .refreshActivePane)?.modifiers ?? [.command])
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

            setup()
        }

        NotificationCenter.default.addObserver(
            forName: .szLanguageDidChange,
            object: nil,
            queue: .main,
        ) { _ in
            setup()
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
