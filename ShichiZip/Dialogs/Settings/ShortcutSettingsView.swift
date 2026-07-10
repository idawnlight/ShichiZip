import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPageView {
            SettingsSectionView(SZL10n.string("app.settings.currentShortcuts")) {
                Picker(SZL10n.string("app.settings.preset"), selection: presetBinding) {
                    ForEach(FileManagerShortcutPreset.allCases, id: \.rawValue) { preset in
                        Text(preset.displayName)
                            .tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.shortcutPreset")

                Divider()

                SettingsNote(SZL10n.string("app.settings.shortcutsCustomNote"))

                ForEach(Array(FileManagerShortcutCommand.allCases.enumerated()),
                        id: \.element.rawValue)
                { index, command in
                    if index > 0 {
                        Divider()
                    }

                    HStack(spacing: 12) {
                        Text(command.title)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ShortcutRecorderRepresentable(
                            shortcut: store.shortcut(for: command),
                            accessibilityLabel: command.title,
                            accessibilityIdentifier: "settings.shortcut.\(command.rawValue)",
                            onChange: { store.setShortcut($0, for: command) },
                        )
                        .frame(width: 165, height: 28)

                        Button {
                            store.setShortcut(nil, for: command)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(SZL10n.string("app.settings.clear"))
                        .accessibilityLabel("\(SZL10n.string("app.settings.clear")): \(command.title)")
                        .disabled(store.shortcut(for: command) == nil)
                    }
                }
            }
        }
    }

    private var presetBinding: Binding<FileManagerShortcutPreset> {
        Binding(
            get: { store.shortcutPreset },
            set: { store.selectShortcutPreset($0) },
        )
    }
}

private struct ShortcutRecorderRepresentable: NSViewRepresentable {
    let shortcut: FileManagerShortcut?
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let onChange: (FileManagerShortcut?) -> Void

    func makeNSView(context _: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(frame: .zero)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context _: Context) {
        button.shortcut = shortcut
        button.setAccessibilityValue(
            shortcut?.displayName ?? SZL10n.string("app.settings.recordShortcut"),
        )
        button.onShortcutChanged = onChange
    }
}
