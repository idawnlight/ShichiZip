import Cocoa

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
            SZL10n.string("app.settings.finderLike")
        case .commander:
            SZL10n.string("app.settings.commanderLike")
        case .custom:
            SZL10n.string("app.settings.custom")
        }
    }
}

enum FileManagerShortcutCommand: String, CaseIterable {
    case openSelectedItem
    case toggleQuickLook
    case goUpOneLevel
    case renameSelection
    case switchPanes
    case toggleHiddenFiles
    case copyFiles
    case moveFiles
    case createFolder
    case deleteFiles
    case toggleDualPane
    case refreshActivePane

    var title: String {
        switch self {
        case .openSelectedItem:
            SZL10n.string("app.shortcut.openSelectedItem")
        case .toggleQuickLook:
            SZL10n.string("app.shortcut.quickLook")
        case .goUpOneLevel:
            SZL10n.string("view.upOneLevel")
        case .renameSelection:
            SZL10n.string("menu.rename")
        case .switchPanes:
            SZL10n.string("app.shortcut.switchPanes")
        case .toggleHiddenFiles:
            SZL10n.string("app.shortcut.toggleHiddenFiles")
        case .copyFiles:
            SZL10n.string("menu.copyTo")
        case .moveFiles:
            SZL10n.string("menu.moveTo")
        case .createFolder:
            SZL10n.string("menu.createFolder")
        case .deleteFiles:
            SZL10n.string("menu.delete")
        case .toggleDualPane:
            SZL10n.string("app.shortcut.toggleDualPane")
        case .refreshActivePane:
            SZL10n.string("view.refresh")
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
                .toggleHiddenFiles: FileManagerShortcut(keyCode: 47,
                                                        modifiers: [.command, .shift],
                                                        keyEquivalent: "."),
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
            ]
        case .custom:
            [:]
        }
    }
}
