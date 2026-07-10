import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable {
    case general
    case archives
    case shortcuts
    case fileTypes
    case extensions

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .general:
            SZL10n.string("app.settings.general")
        case .archives:
            SZL10n.string("app.settings.archives")
        case .shortcuts:
            SZL10n.string("app.settings.shortcuts")
        case .fileTypes:
            SZL10n.string("app.settings.fileTypes")
        case .extensions:
            SZL10n.string("app.settings.extensions")
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .archives:
            "archivebox"
        case .shortcuts:
            "keyboard"
        case .fileTypes:
            "doc.on.doc"
        case .extensions:
            "puzzlepiece.extension"
        }
    }
}

@MainActor
struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var fileAssociations: FileAssociationSettingsModel
    @State private var selection = SettingsDestination.general

    var body: some View {
        HStack(spacing: 0) {
            SettingsNavigationView(
                selection: $selection,
                localizationVersion: store.localizationVersion,
            )
            .frame(minWidth: 140)
            .fixedSize(horizontal: true, vertical: false)

            Divider()

            selectedPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selection {
        case .general:
            GeneralSettingsView(store: store)
        case .archives:
            ArchiveSettingsView(store: store)
        case .shortcuts:
            ShortcutSettingsView(store: store)
        case .fileTypes:
            FileAssociationSettingsView(model: fileAssociations)
        case .extensions:
            ExtensionSettingsView(store: store)
        }
    }
}

private struct SettingsNavigationView: View {
    @Binding var selection: SettingsDestination
    let localizationVersion: Int

    var body: some View {
        VStack(spacing: 3) {
            ForEach(SettingsDestination.allCases) { destination in
                Button {
                    selection = destination
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: destination.systemImage)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(destination.title)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsNavigationButtonStyle(isSelected: selection == destination))
                .modifier(SettingsNavigationFocusEffectModifier())
                .accessibilityAddTraits(selection == destination ? .isSelected : [])
                .accessibilityIdentifier("settings.navigation.\(destination.rawValue)")
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .onMoveCommand(perform: moveSelection)
        .id(localizationVersion)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard let currentIndex = SettingsDestination.allCases.firstIndex(of: selection) else {
            return
        }

        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(SettingsDestination.allCases.startIndex, currentIndex - 1)
        case .down:
            nextIndex = min(SettingsDestination.allCases.index(before: SettingsDestination.allCases.endIndex),
                            currentIndex + 1)
        default:
            return
        }
        selection = SettingsDestination.allCases[nextIndex]
    }
}

private struct SettingsNavigationButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(configuration.isPressed ? 0.24 : 0.15) : .clear),
            )
    }
}

private struct SettingsNavigationFocusEffectModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled(true)
        } else {
            content
        }
    }
}

struct SettingsPageView<Content: View>: View {
    let scrolls: Bool
    private let content: Content

    init(scrolls: Bool = true,
         @ViewBuilder content: () -> Content)
    {
        self.scrolls = scrolls
        self.content = content()
    }

    var body: some View {
        if scrolls {
            ScrollView {
                content
                    .padding(22)
            }
        } else {
            content
                .padding(22)
        }
    }
}

struct SettingsSectionView<Content: View>: View {
    let title: String
    private let content: Content

    init(_ title: String,
         @ViewBuilder content: () -> Content)
    {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsLabeledRow<Content: View>: View {
    let title: String
    private let content: Content

    init(_ title: String,
         @ViewBuilder content: () -> Content)
    {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            content
        }
    }
}

struct SettingsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
