import ShichiZipQuickActionCore
import SwiftUI

struct ExtensionSettingsView: View {
    let store: SettingsStore
    @State private var showsQuickActionsError = false
    @State private var showsServicesError = false
    @State private var servicesError = ""

    var body: some View {
        SettingsPageView {
            VStack(spacing: 20) {
                SettingsSectionView(SZL10n.string("app.settings.finderServices")) {
                    SettingsNote(SZL10n.string("app.settings.servicesDescription"))

                    ForEach(FinderServiceInstaller.actions, id: \.rawValue) { action in
                        Toggle(store.finderServiceTitle(action), isOn: serviceBinding(for: action))
                            .accessibilityIdentifier("settings.finderService.\(action.rawValue)")
                    }

                    Button(SZL10n.string("app.settings.openKeyboardSettings")) {
                        if !store.openKeyboardSettings() {
                            servicesError = SZL10n.string("app.settings.servicesOpenErrorDetail")
                            showsServicesError = true
                        }
                    }
                    .accessibilityIdentifier("settings.openKeyboardSettings")

                    SettingsNote(SZL10n.string("app.settings.servicesNote"))
                }

                SettingsSectionView(SZL10n.string("app.settings.finderQuickActions")) {
                    SettingsNote(
                        SZL10n.string(
                            "app.settings.quickActionsDescription",
                            AppBuildInfo.appDisplayName(),
                        ),
                    )

                    Button(SZL10n.string("app.settings.openFinderQuickActionsSettings")) {
                        showsQuickActionsError = !store.openFinderQuickActionsSettings()
                    }
                    .accessibilityIdentifier("settings.openQuickActionsSettings")

                    SettingsNote(SZL10n.string("app.settings.quickActionsNote"))
                }

                SettingsSectionView(SZL10n.string("app.settings.quickLook")) {
                    SettingsLabeledRow(SZL10n.string("app.settings.quickLookExpansionDepth")) {
                        HStack(spacing: 8) {
                            TextField(
                                "",
                                value: quickLookDepthBinding,
                                format: .number,
                            )
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 44)
                            .accessibilityLabel(SZL10n.string("app.settings.quickLookExpansionDepth"))
                            .accessibilityIdentifier("settings.quickLook.expansionDepth")

                            Stepper(
                                "",
                                value: quickLookDepthBinding,
                                in: 0 ... ArchivePreviewPreferences.maximumExpansionDepth,
                            )
                            .labelsHidden()
                            .accessibilityLabel(SZL10n.string("app.settings.quickLookExpansionDepth"))

                            Text(SZL10n.string("app.settings.quickLookExpansionDepthLevels"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .alert(
            SZL10n.string("app.settings.quickActionsOpenError"),
            isPresented: $showsQuickActionsError,
        ) {
            Button(SZL10n.string("common.ok")) {}
        } message: {
            Text(
                SZL10n.string(
                    "app.settings.quickActionsOpenErrorDetail",
                    AppBuildInfo.appDisplayName(),
                ),
            )
        }
        .alert(
            SZL10n.string("app.settings.finderServices"),
            isPresented: $showsServicesError,
        ) {
            Button(SZL10n.string("common.ok")) {}
        } message: {
            Text(servicesError)
        }
    }

    private func serviceBinding(for action: ShichiZipQuickAction) -> Binding<Bool> {
        Binding(
            get: { store.isFinderServiceEnabled(action) },
            set: { enabled in
                do {
                    try store.setFinderServiceEnabled(enabled, for: action)
                } catch {
                    servicesError = error.localizedDescription
                    showsServicesError = true
                }
            },
        )
    }

    private var quickLookDepthBinding: Binding<Int> {
        Binding(
            get: { store.quickLookExpansionDepth },
            set: { store.setQuickLookExpansionDepth($0) },
        )
    }
}
