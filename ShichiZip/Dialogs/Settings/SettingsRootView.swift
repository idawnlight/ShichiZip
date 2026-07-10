import AppKit
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
        .background(
            SettingsWindowBehaviorBridge(
                updateToken: "\(selection.rawValue):\(store.localizationVersion)",
            ),
        )
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
    private static let rowHeight: CGFloat = 30
    private static let rowSpacing: CGFloat = 3
    private static let minimumContentWidth: CGFloat = 120

    @Binding var selection: SettingsDestination
    let localizationVersion: Int
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button {} label: {
                Color.clear
                    .frame(minWidth: Self.minimumContentWidth, maxWidth: .infinity)
                    .frame(height: Self.rowHeight)
            }
            .buttonStyle(.plain)
            .offset(y: selectedRowOffset)
            .focused($hasKeyboardFocus)
            .modifier(SettingsNavigationFocusEffectModifier())
            .onMoveCommand(perform: moveSelection)
            .accessibilityHidden(true)

            VStack(spacing: Self.rowSpacing) {
                ForEach(SettingsDestination.allCases) { destination in
                    Button {
                        selection = destination
                        hasKeyboardFocus = true
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
                        .frame(height: Self.rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(
                        SettingsNavigationButtonStyle(
                            isSelected: selection == destination,
                            isKeyboardFocused: hasKeyboardFocus && selection == destination,
                        ),
                    )
                    .focusable(false)
                    .accessibilityAddTraits(selection == destination ? .isSelected : [])
                    .accessibilityIdentifier("settings.navigation.\(destination.rawValue)")
                }

                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .id(localizationVersion)
    }

    private var selectedRowOffset: CGFloat {
        let index = SettingsDestination.allCases.firstIndex(of: selection) ?? 0
        return CGFloat(index) * (Self.rowHeight + Self.rowSpacing)
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
        let nextDestination = SettingsDestination.allCases[nextIndex]
        selection = nextDestination
    }
}

private struct SettingsNavigationButtonStyle: ButtonStyle {
    @Environment(\.controlActiveState) private var controlActiveState

    let isSelected: Bool
    let isKeyboardFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        let keyboardNavigationEnabled = NSApplication.shared.isFullKeyboardAccessEnabled
        let usesEmphasizedSelection = controlActiveState == .key
            && (!keyboardNavigationEnabled || isKeyboardFocused || configuration.isPressed)

        configuration.label
            .foregroundStyle(foregroundColor(emphasized: usesEmphasizedSelection))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor(emphasized: usesEmphasizedSelection)),
            )
    }

    private func foregroundColor(emphasized: Bool) -> Color {
        guard isSelected else {
            return .primary
        }
        return Color(nsColor: emphasized ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor)
    }

    private func backgroundColor(emphasized: Bool) -> Color {
        guard isSelected else {
            return .clear
        }
        return Color(nsColor: emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
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

private struct SettingsWindowBehaviorBridge: NSViewRepresentable {
    let updateToken: String

    func makeNSView(context _: Context) -> SettingsWindowBehaviorView {
        SettingsWindowBehaviorView(updateToken: updateToken)
    }

    func updateNSView(_ view: SettingsWindowBehaviorView,
                      context _: Context)
    {
        view.update(updateToken: updateToken)
    }
}

private final class SettingsWindowBehaviorView: NSView {
    private static let tabKeyCode: UInt16 = 48

    private var updateToken: String
    private var keyMonitor: Any?

    init(updateToken: String) {
        self.updateToken = updateToken
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeKeyMonitor()
        } else {
            installKeyMonitor()
            scheduleKeyViewLoopUpdate()
        }
    }

    isolated deinit {
        removeKeyMonitor()
    }

    func update(updateToken: String) {
        guard self.updateToken != updateToken else { return }
        self.updateToken = updateToken
        scheduleKeyViewLoopUpdate()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === window,
                  event.keyCode == Self.tabKeyCode
            else {
                return event
            }

            DispatchQueue.main.async { [weak self] in
                self?.scrollFirstResponderIntoView()
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func scheduleKeyViewLoopUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            window.recalculateKeyViewLoop()
        }
    }

    private func scrollFirstResponderIntoView() {
        guard let focusedView = focusedView() else { return }
        focusedView.scrollToVisible(
            focusedView.bounds.insetBy(dx: -8, dy: -12),
        )
    }

    private func focusedView() -> NSView? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        if let fieldEditor = responder as? NSTextView,
           fieldEditor.isFieldEditor,
           let delegateView = fieldEditor.delegate as? NSView
        {
            return delegateView
        }
        return responder
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
