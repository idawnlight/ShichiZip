import Cocoa

class ExtractDialogController: NSViewController {

    private var destinationField: NSPathControl!
    private var pathModePopup: NSPopUpButton!
    private var overwritePopup: NSPopUpButton!
    private var passwordField: NSSecureTextField!
    private var showPasswordCheckbox: NSButton!
    private var passwordTextField: NSTextField!

    var destinationURL: URL?
    var completionHandler: ((SZExtractionSettings?, URL?) -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 260))

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 10

        // Destination
        let destLabel = NSTextField(labelWithString: "Extract to:")
        destinationField = NSPathControl()
        destinationField.pathStyle = .standard
        destinationField.isEditable = false
        destinationField.url = destinationURL ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")

        let browseButton = NSButton(title: "Browse...", target: self, action: #selector(browseDest(_:)))
        let destStack = NSStackView(views: [destinationField, browseButton])
        destStack.orientation = .horizontal
        grid.addRow(with: [destLabel, destStack])

        // Path mode
        let pathLabel = NSTextField(labelWithString: "Path mode:")
        pathModePopup = NSPopUpButton(title: "", target: nil, action: nil)
        pathModePopup.addItems(withTitles: ["Full pathnames", "No pathnames", "Absolute pathnames"])
        grid.addRow(with: [pathLabel, pathModePopup])

        // Overwrite mode
        let overwriteLabel = NSTextField(labelWithString: "Overwrite mode:")
        overwritePopup = NSPopUpButton(title: "", target: nil, action: nil)
        overwritePopup.addItems(withTitles: ["Ask before overwrite", "Skip existing files", "Auto rename", "Overwrite all"])
        overwritePopup.selectItem(at: 3) // Default: overwrite
        grid.addRow(with: [overwriteLabel, overwritePopup])

        // Password
        let passLabel = NSTextField(labelWithString: "Password:")
        passwordField = NSSecureTextField()
        passwordField.placeholderString = "Enter password if required"
        passwordTextField = NSTextField()
        passwordTextField.placeholderString = "Enter password if required"
        passwordTextField.isHidden = true

        showPasswordCheckbox = NSButton(checkboxWithTitle: "Show password", target: self, action: #selector(togglePasswordVisibility(_:)))

        let passStack = NSStackView(views: [passwordField, passwordTextField, showPasswordCheckbox])
        passStack.orientation = .vertical
        passStack.alignment = .leading
        grid.addRow(with: [passLabel, passStack])

        container.addSubview(grid)

        // Buttons
        let extractButton = NSButton(title: "Extract", target: self, action: #selector(doExtract(_:)))
        extractButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(doCancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonStack = NSStackView(views: [cancelButton, extractButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        container.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            buttonStack.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 20),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        self.view = container
    }

    @objc private func browseDest(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        if let window = view.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.destinationField.url = url
                }
            }
        }
    }

    @objc private func togglePasswordVisibility(_ sender: NSButton) {
        let isVisible = sender.state == .on
        passwordField.isHidden = isVisible
        passwordTextField.isHidden = !isVisible
        if isVisible {
            passwordTextField.stringValue = passwordField.stringValue
        } else {
            passwordField.stringValue = passwordTextField.stringValue
        }
    }

    @objc private func doExtract(_ sender: Any?) {
        let settings = SZExtractionSettings()
        settings.pathMode = SZPathMode(rawValue: pathModePopup.indexOfSelectedItem) ?? .fullPaths
        settings.overwriteMode = SZOverwriteMode(rawValue: overwritePopup.indexOfSelectedItem) ?? .overwrite

        let password = showPasswordCheckbox.state == .on ? passwordTextField.stringValue : passwordField.stringValue
        if !password.isEmpty {
            settings.password = password
        }

        view.window?.sheetParent?.endSheet(view.window!, returnCode: .OK)
        completionHandler?(settings, destinationField.url)
    }

    @objc private func doCancel(_ sender: Any?) {
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .cancel)
        completionHandler?(nil, nil)
    }
}
