import AppKit
import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable {
    case general
    case archives
    case shortcuts
    case fileTypes
    case extensions

    var id: Self {
        self
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
    let store: SettingsStore
    let fileAssociations: FileAssociationSettingsModel
    @State private var selection: SettingsDestination? = .general
    @FocusState private var sidebarHasFocus: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsDestination.allCases) { destination in
                    NavigationLink(value: destination) {
                        Label(destination.title, systemImage: destination.systemImage)
                    }
                    .accessibilityIdentifier("settings.navigation.\(destination.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .focused($sidebarHasFocus)
            .id(store.localizationVersion)
            .navigationSplitViewColumnWidth(min: 140, ideal: 180, max: 240)
        } detail: {
            selectedPage
                .frame(minWidth: 480, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(SZL10n.string("settings.options"))
        .defaultFocus($sidebarHasFocus, true)
        .frame(minWidth: 660, maxWidth: .infinity, minHeight: 440, maxHeight: .infinity)
        .background(
            SettingsWindowBehaviorBridge(
                updateToken: "\(selection?.rawValue ?? ""):\(store.localizationVersion)",
            ),
        )
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selection {
        case .general, nil:
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
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
