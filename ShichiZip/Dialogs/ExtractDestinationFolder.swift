import Cocoa

struct ExtractDestinationFolder: Equatable {
    var isEnabled: Bool
    var name: String

    private static let preferenceKey = "FileManager.ExtractSplitDestination"

    static var preferredIsEnabled: Bool {
        get { SZSharedUserDefaults.defaults.bool(forKey: preferenceKey, default: true) }
        set { SZSharedUserDefaults.defaults.set(newValue, forKey: preferenceKey) }
    }

    func destinationURL(in baseDirectory: URL) throws -> URL {
        guard isEnabled else { return baseDirectory }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [
                NSLocalizedDescriptionKey: SZL10n.string("app.fileManager.enterFolderName"),
            ])
        }
        guard trimmedName != ".", trimmedName != "..", !trimmedName.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: trimmedName])
        }

        let destinationURL = baseDirectory.appendingPathComponent(trimmedName, isDirectory: true).standardizedFileURL
        if let itemKind = FileManager.default.szExistingItemKind(at: destinationURL), itemKind != .directory {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destinationURL.path])
        }
        return destinationURL
    }
}

@MainActor
final class ExtractDestinationFolderControl: NSObject {
    let view = NSStackView()

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))

    var value: ExtractDestinationFolder {
        ExtractDestinationFolder(isEnabled: checkbox.state == .on, name: nameField.stringValue)
    }

    init(value: ExtractDestinationFolder, accessibilityPrefix: String) {
        super.init()

        checkbox.target = self
        checkbox.action = #selector(toggled(_:))
        checkbox.state = value.isEnabled ? .on : .off
        checkbox.toolTip = SZL10n.string("app.extract.createSeparateFolder")
        checkbox.setAccessibilityLabel(SZL10n.string("app.extract.createSeparateFolder"))
        checkbox.setAccessibilityIdentifier(accessibilityPrefix + ".splitDestination")

        nameField.placeholderString = "Archive"
        nameField.stringValue = value.name
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        nameField.setAccessibilityIdentifier(accessibilityPrefix + ".splitName")

        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 8
        view.distribution = .fill
        view.addArrangedSubview(checkbox)
        view.addArrangedSubview(nameField)
        updateNameField()
    }

    @objc private func toggled(_: Any?) {
        updateNameField()
    }

    private func updateNameField() {
        let enabled = checkbox.state == .on
        nameField.isEnabled = enabled
        nameField.alphaValue = enabled ? 1.0 : 0.55
    }
}
