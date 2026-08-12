import SwiftUI

struct GeneralSettingsView: View {
    private enum ResetAction: Int, Identifiable {
        case windowFrame
        case listLayouts

        var id: Int {
            rawValue
        }
    }

    @ObservedObject var store: SettingsStore
    @State private var resetAction: ResetAction?

    var body: some View {
        SettingsPageView {
            VStack(spacing: 20) {
                applicationSection
                displaySection
                windowAndLayoutSection
            }
            .frame(maxWidth: .infinity)
        }
        .alert(item: $resetAction, content: resetAlert)
    }

    private var applicationSection: some View {
        SettingsSectionView(SZL10n.string("app.settings.application")) {
            SettingsLabeledRow(SZL10n.string("settings.languageLabel")) {
                Picker("", selection: languageBinding) {
                    Text(SZL10n.string("app.settings.followSystem"))
                        .tag("")

                    Divider()

                    ForEach(store.availableLanguages, id: \.localeCode) { language in
                        Text(language.displayName)
                            .tag(language.localeCode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
                .accessibilityLabel(SZL10n.string("settings.languageLabel"))
                .accessibilityIdentifier("settings.language")
            }

            Toggle(
                SZL10n.string("app.settings.quitOnLastClose"),
                isOn: store.boolBinding(.quitAfterLastWindowClosed),
            )

            Toggle(
                SZL10n.string("app.settings.rememberRecentArchives"),
                isOn: Binding(
                    get: { store.remembersRecentArchives },
                    set: { store.setRemembersRecentArchives($0) },
                ),
            )
            .accessibilityIdentifier("settings.rememberRecentArchives")
        }
    }

    private var displaySection: some View {
        SettingsSectionView(SZL10n.string("app.settings.display")) {
            Toggle(SZL10n.string("settings.showDotDot"), isOn: store.boolBinding(.showDots))
            Toggle(SZL10n.string("settings.showRealIcons"), isOn: store.boolBinding(.showRealFileIcons))
            Toggle(SZL10n.string("app.settings.showHiddenFiles"), isOn: store.boolBinding(.showHiddenFiles))
            Toggle(SZL10n.string("settings.showGridLines"), isOn: store.boolBinding(.showGridLines))
            Toggle(SZL10n.string("settings.singleClick"), isOn: store.boolBinding(.singleClickOpen))
        }
    }

    private var windowAndLayoutSection: some View {
        SettingsSectionView(SZL10n.string("app.settings.windowAndLayout")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    SZL10n.string("app.settings.rememberFileManagerWindowFrame"),
                    isOn: Binding(
                        get: { store.remembersFileManagerWindowFrame },
                        set: { store.setRemembersFileManagerWindowFrame($0) },
                    ),
                )
                .accessibilityIdentifier("settings.rememberFileManagerWindowFrame")

                Button(SZL10n.string("app.settings.resetFileManagerWindowFrame")) {
                    resetAction = .windowFrame
                }
                .accessibilityIdentifier("settings.resetFileManagerWindowFrame")
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Button(SZL10n.string("app.settings.resetFileListLayout")) {
                    resetAction = .listLayouts
                }
                .accessibilityIdentifier("settings.resetFileListLayout")

                SettingsNote(SZL10n.string("app.settings.resetFileListLayoutNote"))
            }
        }
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { store.languageOverride },
            set: { store.setLanguageOverride($0) },
        )
    }

    private func resetAlert(for action: ResetAction) -> Alert {
        let title: String
        let message: String?

        switch action {
        case .windowFrame:
            title = SZL10n.string("app.settings.resetFileManagerWindowFrame")
            message = nil
        case .listLayouts:
            title = SZL10n.string("app.settings.resetFileListLayout")
            message = SZL10n.string("app.settings.resetFileListLayoutConfirmDetail")
        }

        return Alert(
            title: Text(SZL10n.string("app.settings.confirmActionFormat", title)),
            message: message.map(Text.init),
            primaryButton: .destructive(Text(SZL10n.string("app.settings.reset"))) {
                switch action {
                case .windowFrame:
                    store.resetFileManagerWindowFrame()
                case .listLayouts:
                    store.resetFileListLayouts()
                }
            },
            secondaryButton: .cancel(Text(SZL10n.string("common.cancel"))),
        )
    }
}
