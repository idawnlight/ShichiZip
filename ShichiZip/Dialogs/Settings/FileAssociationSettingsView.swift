import SwiftUI

struct FileAssociationSettingsView: View {
    @ObservedObject var model: FileAssociationSettingsModel
    @State private var searchText = ""

    var body: some View {
        SettingsPageView(scrolls: false) {
            VStack(spacing: 12) {
                SettingsNote(
                    SZL10n.string(
                        "app.settings.defaultOpenersDescription",
                        AppBuildInfo.appDisplayName(),
                    ),
                )

                HStack(spacing: 10) {
                    SettingsSearchField(
                        text: $searchText,
                        placeholder: SZL10n.string("app.settings.searchFileTypes"),
                        accessibilityIdentifier: "settings.fileTypeSearch",
                    )
                    .frame(height: 28)
                    .frame(maxWidth: .infinity)

                    Button(SZL10n.string("app.settings.setAllAsDefault")) {
                        model.setAllAsDefault()
                    }
                    .disabled(!model.canSetAllAsDefault)
                    .accessibilityIdentifier("settings.setAllAsDefault")
                }

                associationList

                SettingsNote(SZL10n.string("app.settings.defaultOpenersNote"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            model.refresh()
        }
        .onDisappear {
            model.cancelUpdates()
        }
        .alert(item: updateFailureBinding) { failure in
            Alert(
                title: Text(SZL10n.string("app.settings.defaultOpenerFailedTitle")),
                message: Text(
                    SZL10n.string(
                        "app.settings.defaultOpenerFailedDetail",
                        failure.count,
                    ),
                ),
                dismissButton: .default(Text(SZL10n.string("common.ok"))),
            )
        }
    }

    private var associationList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(SZL10n.string("app.settings.fileType"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(SZL10n.string("app.settings.defaultApplication"))
                    .frame(width: 118, alignment: .leading)
                Color.clear
                    .frame(width: 104, height: 1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)

            Divider()

            if filteredAssociations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(SZL10n.string("app.settings.noMatchingFileTypes"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredAssociations, id: \.id) { association in
                            associationRow(association)
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)),
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5),
        )
    }

    private func associationRow(_ association: FileAssociation) -> some View {
        let state = model.state(for: association)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(association.displayName)
                    .lineLimit(1)
                if !association.extensionSummary.isEmpty {
                    Text(association.extensionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusText(state.displayStatus)
                .frame(width: 118, alignment: .leading)

            if state.isPendingUpdate {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 104)
            } else {
                Button(
                    state.isCurrentDefault
                        ? SZL10n.string("app.settings.currentDefault")
                        : SZL10n.string("app.settings.makeDefault"),
                ) {
                    model.setDefaultApplication(for: association)
                }
                .disabled(state.isCurrentDefault)
                .frame(width: 104)
                .accessibilityLabel(
                    "\(state.isCurrentDefault ? SZL10n.string("app.settings.currentDefault") : SZL10n.string("app.settings.makeDefault")): \(association.displayTitle)",
                )
                .accessibilityIdentifier(
                    "settings.makeDefault.\(association.primaryTypeIdentifier)",
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
    }

    private func statusText(_ status: FileAssociationDisplayStatus) -> some View {
        let text = switch status {
        case .noDefaultApp:
            SZL10n.string("app.settings.noDefaultApp")
        case let .defaultApp(displayName):
            displayName
        case .multipleDefaultApps:
            SZL10n.string("app.settings.multipleDefaultApps")
        }

        return Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var updateFailureBinding: Binding<FileAssociationUpdateFailure?> {
        Binding(
            get: { model.updateFailure },
            set: { failure in
                if failure == nil {
                    model.dismissUpdateFailure()
                }
            },
        )
    }

    private var filteredAssociations: [FileAssociation] {
        let query = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !query.isEmpty else {
            return model.associations
        }

        return model.associations.filter { association in
            association.displayName.localizedCaseInsensitiveContains(query)
                || association.fileExtensions.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
                || association.contentTypeIdentifiers.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
        }
    }
}
