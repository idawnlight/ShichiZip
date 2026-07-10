import Cocoa
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onWindowWillClose: (() -> Void)?

    private let fileAssociations: FileAssociationSettingsModel
    private var languageObserver: NSObjectProtocol?

    init(fileAssociations: FileAssociationSettingsModel = FileAssociationSettingsModel()) {
        self.fileAssociations = fileAssociations

        let store = SettingsStore()
        let rootView = SettingsRootView(
            store: store,
            fileAssociations: fileAssociations,
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)

        window.title = SZL10n.string("settings.options")
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 650, height: 500))
        window.minSize = NSSize(width: 620, height: 440)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()

        super.init(window: window)
        window.delegate = self

        languageObserver = NotificationCenter.default.addObserver(
            forName: .szLanguageDidChange,
            object: nil,
            queue: .main,
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                window?.title = SZL10n.string("settings.options")
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }

    override func showWindow(_ sender: Any?) {
        window?.title = SZL10n.string("settings.options")
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_: Notification) {
        fileAssociations.cancelUpdates()
        onWindowWillClose?()
    }
}
