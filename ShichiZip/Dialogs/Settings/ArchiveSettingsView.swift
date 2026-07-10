import SwiftUI

struct ArchiveSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPageView {
            VStack(spacing: 20) {
                compressionSection
                extractionSection
                launchOpenSection
                workingDirectorySection
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var compressionSection: some View {
        SettingsSectionView(SZL10n.string("app.settings.compression")) {
            Toggle(
                SZL10n.string("app.settings.excludeMacResourceForks"),
                isOn: store.boolBinding(.excludeMacResourceFilesByDefault),
            )
            .accessibilityIdentifier("settings.excludeMacResourceFiles")
        }
    }

    private var extractionSection: some View {
        SettingsSectionView(SZL10n.string("app.settings.extraction")) {
            Toggle(
                SZL10n.string("app.extract.moveToTrash"),
                isOn: store.boolBinding(.moveArchiveToTrashAfterExtraction),
            )
            Toggle(
                SZL10n.string("app.extract.inheritQuarantine"),
                isOn: store.boolBinding(.inheritDownloadedFileQuarantine),
            )

            Divider()

            Toggle(SZL10n.string("app.settings.maxRAMForExtraction"),
                   isOn: store.boolBinding(.memLimitEnabled))

            SettingsLabeledRow(SZL10n.string("app.settings.limitTo")) {
                HStack(spacing: 6) {
                    TextField("", value: memoryLimitBinding, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 58)
                        .accessibilityLabel(SZL10n.string("app.settings.maxRAMForExtraction"))
                        .accessibilityIdentifier("settings.memLimitField")
                    Text("GB")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!store.isMemoryLimitEnabled)
        }
    }

    private var launchOpenSection: some View {
        SettingsSectionView(SZL10n.string("app.settings.launchOpen")) {
            Picker("", selection: launchOpenActionBinding) {
                Text(SZL10n.string("app.settings.launchOpen.showContents"))
                    .tag(LaunchOpenAction.browse)
                Text(SZL10n.string("app.settings.launchOpen.extractImmediately"))
                    .tag(LaunchOpenAction.extract)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            .accessibilityLabel(SZL10n.string("app.settings.launchOpen"))

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    SZL10n.string("app.settings.launchOpen.revealAfterExtract"),
                    isOn: store.boolBinding(.launchOpenRevealAfterExtract),
                )

                SettingsLabeledRow(SZL10n.string("app.settings.launchOpen.cancelWindow")) {
                    HStack(spacing: 8) {
                        Slider(value: launchOpenSliderBinding, in: 0 ... 10)
                            .frame(width: 150)
                            .accessibilityLabel(SZL10n.string("app.settings.launchOpen.cancelWindow"))
                        TextField(
                            "",
                            value: launchOpenDelayBinding,
                            format: .number.precision(.fractionLength(1)),
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                        .accessibilityLabel(SZL10n.string("app.settings.launchOpen.cancelWindow"))
                        Text(SZL10n.string("app.settings.launchOpen.cancelWindow.secondsSuffix"))
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsLabeledRow(SZL10n.string("app.settings.launchOpen.modifierToInvert")) {
                    Picker("", selection: launchOpenModifierBinding) {
                        Text(SZL10n.string("app.settings.launchOpen.modifier.none"))
                            .tag(LaunchOpenBrowseModifier.none)
                        Text("⌥ Option")
                            .tag(LaunchOpenBrowseModifier.option)
                        Text("⌃ Control")
                            .tag(LaunchOpenBrowseModifier.control)
                        Text("⇧ Shift")
                            .tag(LaunchOpenBrowseModifier.shift)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .accessibilityLabel(SZL10n.string("app.settings.launchOpen.modifierToInvert"))
                }
            }
            .disabled(store.launchOpenAction != .extract)
        }
    }

    private var workingDirectorySection: some View {
        SettingsSectionView(SZL10n.string("app.settings.workingFolderTitle")) {
            Picker("", selection: workingDirectoryModeBinding) {
                Text(SZL10n.string("settings.systemTempFolder"))
                    .tag(0)
                Text(SZL10n.string("settings.current"))
                    .tag(1)
                Text(SZL10n.string("settings.specified"))
                    .tag(2)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            .accessibilityLabel(SZL10n.string("app.settings.workingFolderTitle"))

            HStack(spacing: 8) {
                TextField("", text: store.stringBinding(.workDirPath))
                    .accessibilityLabel(SZL10n.string("app.settings.workingFolderTitle"))
                    .accessibilityIdentifier("settings.workDirPath")
                Button(SZL10n.string("compress.browse")) {
                    store.chooseWorkingDirectory()
                }
                .accessibilityIdentifier("settings.workDirBrowse")
            }
            .disabled(store.workingDirectoryMode != 2)

            Toggle(
                SZL10n.string("settings.removableDrivesOnly"),
                isOn: store.boolBinding(.workDirRemovableOnly),
            )
        }
    }

    private var memoryLimitBinding: Binding<Int> {
        Binding(
            get: { store.memoryLimitGB },
            set: { store.setMemoryLimitGB($0) },
        )
    }

    private var launchOpenActionBinding: Binding<LaunchOpenAction> {
        Binding(
            get: { store.launchOpenAction },
            set: { store.setLaunchOpenAction($0) },
        )
    }

    private var launchOpenDelayBinding: Binding<TimeInterval> {
        Binding(
            get: { store.launchOpenDelay },
            set: { store.setLaunchOpenDelay($0) },
        )
    }

    private var launchOpenSliderBinding: Binding<TimeInterval> {
        Binding(
            get: { min(store.launchOpenDelay, 10) },
            set: { store.setLaunchOpenDelay($0) },
        )
    }

    private var launchOpenModifierBinding: Binding<LaunchOpenBrowseModifier> {
        Binding(
            get: { store.launchOpenModifier },
            set: { store.setLaunchOpenModifier($0) },
        )
    }

    private var workingDirectoryModeBinding: Binding<Int> {
        Binding(
            get: { store.workingDirectoryMode },
            set: { store.setWorkingDirectoryMode($0) },
        )
    }
}
