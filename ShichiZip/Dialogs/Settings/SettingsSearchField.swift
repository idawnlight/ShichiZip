import AppKit
import SwiftUI

final class SettingsSearchFieldControl: NSSearchField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isAutomaticTextCompletionEnabled = false
        sendsSearchStringImmediately = true
        sendsWholeSearchString = false
        maximumRecents = 0
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SettingsSearchFieldControl {
        let searchField = SettingsSearchFieldControl(frame: .zero)
        searchField.delegate = context.coordinator
        searchField.placeholderString = placeholder
        searchField.setAccessibilityLabel(placeholder)
        searchField.setAccessibilityIdentifier(accessibilityIdentifier)
        return searchField
    }

    func updateNSView(_ searchField: SettingsSearchFieldControl,
                      context: Context)
    {
        context.coordinator.parent = self
        searchField.placeholderString = placeholder
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SettingsSearchField

        init(parent: SettingsSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                return
            }
            parent.text = searchField.stringValue
        }
    }
}
