import AppKit
import Observation
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
@Observable
final class SettingsStore {
    private(set) var localizationVersion = 0
    private var settingsVersion = 0

    private let notificationCenter: NotificationCenter
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter

        // Settings are read from shared defaults rather than stored properties.
        // Bridge the app's settings notifications into Observation.
        for name in [Notification.Name.szSettingsDidChange, .szLanguageDidChange] {
            let isLanguageChange = name == .szLanguageDidChange
            observers.append(
                notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if isLanguageChange {
                            self.localizationVersion &+= 1
                        }
                        self.settingsVersion &+= 1
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
        _ = settingsVersion
        return SZL10n.availableLanguages()
    }

    var languageOverride: String {
        _ = settingsVersion
        return SZSettings.string(.languageOverride)
    }

    func setLanguageOverride(_ localeCode: String) {
        guard localeCode != languageOverride else { return }
        SZSettings.set(localeCode, for: .languageOverride)
        SZL10n.reloadBundle()
        NotificationCenter.default.post(name: .szLanguageDidChange, object: nil)
    }

    func boolBinding(_ key: SZSettingsKey) -> Binding<Bool> {
        _ = settingsVersion
        return Binding(
            get: {
                _ = self.settingsVersion
                return SZSettings.bool(key)
            },
            set: { SZSettings.set($0, for: key) },
        )
    }

    func stringBinding(_ key: SZSettingsKey) -> Binding<String> {
        _ = settingsVersion
        return Binding(
            get: {
                _ = self.settingsVersion
                return SZSettings.string(key)
            },
            set: { SZSettings.set($0, for: key) },
        )
    }

    var remembersRecentArchives: Bool {
        _ = settingsVersion
        return SZSettings.bool(.rememberRecentArchives)
    }

    func setRemembersRecentArchives(_ value: Bool) {
        guard value != remembersRecentArchives else { return }
        SZSettings.set(value, for: .rememberRecentArchives)
        if !value {
            RecentArchiveHistory.clear()
        }
    }

    var remembersFileManagerWindowFrame: Bool {
        _ = settingsVersion
        return FileManagerWindowPreferences.remembersWindowFrame
    }

    func setRemembersFileManagerWindowFrame(_ value: Bool) {
        FileManagerWindowPreferences.setRemembersWindowFrame(value)
        settingsVersion &+= 1
    }

    func resetFileManagerWindowFrame() {
        FileManagerWindowPreferences.resetSavedWindowFrame()
    }

    func resetFileListLayouts() {
        FileManagerViewPreferences.removeAllListViewInfos()
    }

    var memoryLimitGB: Int {
        _ = settingsVersion
        return SZSettings.memLimitGB
    }

    var isMemoryLimitEnabled: Bool {
        _ = settingsVersion
        return SZSettings.bool(.memLimitEnabled)
    }

    func setMemoryLimitGB(_ value: Int) {
        SZSettings.set(max(1, value), for: .memLimitGB)
    }

    var launchOpenAction: LaunchOpenAction {
        _ = settingsVersion
        return SZSettings.launchOpenDefaultAction
    }

    func setLaunchOpenAction(_ action: LaunchOpenAction) {
        SZSettings.launchOpenDefaultAction = action
    }

    var launchOpenDelay: TimeInterval {
        _ = settingsVersion
        return SZSettings.launchOpenDelaySeconds
    }

    func setLaunchOpenDelay(_ delay: TimeInterval) {
        SZSettings.launchOpenDelaySeconds = max(0, (delay * 10).rounded() / 10)
    }

    var launchOpenModifier: LaunchOpenBrowseModifier {
        _ = settingsVersion
        return SZSettings.launchOpenBrowseModifier
    }

    func setLaunchOpenModifier(_ modifier: LaunchOpenBrowseModifier) {
        SZSettings.launchOpenBrowseModifier = modifier
    }

    var workingDirectoryMode: Int {
        _ = settingsVersion
        return SZSettings.workDirMode
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
        _ = settingsVersion
        return SZSettings.fileManagerShortcutPreset
    }

    func selectShortcutPreset(_ preset: FileManagerShortcutPreset) {
        FileManagerShortcutSettings.selectPreset(preset)
    }

    func shortcut(for command: FileManagerShortcutCommand) -> FileManagerShortcut? {
        _ = settingsVersion
        return FileManagerShortcuts.resolvedBindingMap()[command]
    }

    func setShortcut(_ shortcut: FileManagerShortcut?,
                     for command: FileManagerShortcutCommand)
    {
        FileManagerShortcutSettings.setShortcut(shortcut, for: command)
    }

    var quickLookExpansionDepth: Int {
        _ = settingsVersion
        return SZSettings.quickLookPreviewExpansionDepth
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
