import SwiftUI

struct ExtensionSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var showsQuickActionsError = false

    var body: some View {
        SettingsPageView {
            VStack(spacing: 20) {
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
    }

    private var quickLookDepthBinding: Binding<Int> {
        Binding(
            get: { store.quickLookExpansionDepth },
            set: { store.setQuickLookExpansionDepth($0) },
        )
    }
}
