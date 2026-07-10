import AppKit
import Combine
import SwiftUI

enum FileManagerShortcutSettings {
    static func selectPreset(_ preset: FileManagerShortcutPreset) {
        let previousPreset = SZSettings.fileManagerShortcutPreset
        guard preset != previousPreset else { return }

        if preset == .custom, !SZSettings.hasFileManagerCustomShortcutMap {
            SZSettings.setFileManagerCustomShortcutMap(
                FileManagerShortcuts.resolvedBindingMap(for: previousPreset),
            )
        }

        SZSettings.setFileManagerShortcutPreset(preset)
    }

    static func setShortcut(_ shortcut: FileManagerShortcut?,
                            for command: FileManagerShortcutCommand)
    {
        var bindingMap = FileManagerShortcuts.resolvedBindingMap()

        if let shortcut {
            for otherCommand in FileManagerShortcutCommand.allCases where otherCommand != command {
                if bindingMap[otherCommand] == shortcut {
                    bindingMap.removeValue(forKey: otherCommand)
                }
            }
            bindingMap[command] = shortcut
        } else {
            bindingMap.removeValue(forKey: command)
        }

        SZSettings.setFileManagerCustomShortcutMap(bindingMap)
        if SZSettings.fileManagerShortcutPreset != .custom {
            SZSettings.setFileManagerShortcutPreset(.custom)
        }
    }
}

@MainActor
final class SettingsStore: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var localizationVersion = 0

    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter

        for name in [Notification.Name.szSettingsDidChange, .szLanguageDidChange] {
            let isLanguageChange = name == .szLanguageDidChange
            observers.append(
                notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if isLanguageChange {
                            self.localizationVersion &+= 1
                        }
                        self.objectWillChange.send()
                    }
                },
            )
        }
    }

    isolated deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    var availableLanguages: [SZL10n.Language] {
        SZL10n.availableLanguages()
    }

    var languageOverride: String {
        SZSettings.string(.languageOverride)
    }

    func setLanguageOverride(_ localeCode: String) {
        guard localeCode != languageOverride else { return }
        SZSettings.set(localeCode, for: .languageOverride)
        SZL10n.reloadBundle()
        NotificationCenter.default.post(name: .szLanguageDidChange, object: nil)
    }

    func boolBinding(_ key: SZSettingsKey) -> Binding<Bool> {
        Binding(
            get: { SZSettings.bool(key) },
            set: { SZSettings.set($0, for: key) },
        )
    }

    func stringBinding(_ key: SZSettingsKey) -> Binding<String> {
        Binding(
            get: { SZSettings.string(key) },
            set: { SZSettings.set($0, for: key) },
        )
    }

    var remembersFileManagerWindowFrame: Bool {
        FileManagerWindowPreferences.remembersWindowFrame
    }

    func setRemembersFileManagerWindowFrame(_ value: Bool) {
        FileManagerWindowPreferences.setRemembersWindowFrame(value)
        objectWillChange.send()
    }

    func resetFileManagerWindowFrame() {
        FileManagerWindowPreferences.resetSavedWindowFrame()
    }

    func resetFileListLayouts() {
        FileManagerViewPreferences.removeAllListViewInfos()
    }

    var memoryLimitGB: Int {
        SZSettings.memLimitGB
    }

    var isMemoryLimitEnabled: Bool {
        SZSettings.bool(.memLimitEnabled)
    }

    func setMemoryLimitGB(_ value: Int) {
        SZSettings.set(max(1, value), for: .memLimitGB)
    }

    var launchOpenAction: LaunchOpenAction {
        SZSettings.launchOpenDefaultAction
    }

    func setLaunchOpenAction(_ action: LaunchOpenAction) {
        SZSettings.launchOpenDefaultAction = action
    }

    var launchOpenDelay: TimeInterval {
        SZSettings.launchOpenDelaySeconds
    }

    func setLaunchOpenDelay(_ delay: TimeInterval) {
        SZSettings.launchOpenDelaySeconds = max(0, (delay * 10).rounded() / 10)
    }

    var launchOpenModifier: LaunchOpenBrowseModifier {
        SZSettings.launchOpenBrowseModifier
    }

    func setLaunchOpenModifier(_ modifier: LaunchOpenBrowseModifier) {
        SZSettings.launchOpenBrowseModifier = modifier
    }

    var workingDirectoryMode: Int {
        SZSettings.workDirMode
    }

    func setWorkingDirectoryMode(_ mode: Int) {
        SZSettings.set(mode, for: .workDirMode)
    }

    func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            SZSettings.set(url.path, for: .workDirPath)
        }
    }

    var shortcutPreset: FileManagerShortcutPreset {
        SZSettings.fileManagerShortcutPreset
    }

    func selectShortcutPreset(_ preset: FileManagerShortcutPreset) {
        FileManagerShortcutSettings.selectPreset(preset)
    }

    func shortcut(for command: FileManagerShortcutCommand) -> FileManagerShortcut? {
        FileManagerShortcuts.resolvedBindingMap()[command]
    }

    func setShortcut(_ shortcut: FileManagerShortcut?,
                     for command: FileManagerShortcutCommand)
    {
        FileManagerShortcutSettings.setShortcut(shortcut, for: command)
    }

    var quickLookExpansionDepth: Int {
        SZSettings.quickLookPreviewExpansionDepth
    }

    func setQuickLookExpansionDepth(_ depth: Int) {
        SZSettings.quickLookPreviewExpansionDepth = depth
    }

    func openFinderQuickActionsSettings() -> Bool {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.finder-quick-actions",
        ) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
