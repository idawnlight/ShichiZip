import Cocoa

class PasswordDialogController: NSViewController {

    private var passwordField: NSSecureTextField!
    private var showPasswordCheckbox: NSButton!
    private var passwordTextField: NSTextField!
    private var messageLabel: NSTextField!

    var archiveName: String = "Archive"
    var completionHandler: ((String?) -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))

        messageLabel = NSTextField(labelWithString: "Password is required for \"\(archiveName)\"")
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.lineBreakMode = .byTruncatingMiddle
        container.addSubview(messageLabel)

        passwordField = NSSecureTextField()
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.placeholderString = "Enter password"
        container.addSubview(passwordField)

        passwordTextField = NSTextField()
        passwordTextField.translatesAutoresizingMaskIntoConstraints = false
        passwordTextField.placeholderString = "Enter password"
        passwordTextField.isHidden = true
        container.addSubview(passwordTextField)

        showPasswordCheckbox = NSButton(checkboxWithTitle: "Show password", target: self, action: #selector(togglePassword(_:)))
        showPasswordCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(showPasswordCheckbox)

        let okButton = NSButton(title: "OK", target: self, action: #selector(doOK(_:)))
        okButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(doCancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonStack = NSStackView(views: [cancelButton, okButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        container.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            messageLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            messageLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            passwordField.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 12),
            passwordField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            passwordField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            passwordTextField.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 12),
            passwordTextField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            passwordTextField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            showPasswordCheckbox.topAnchor.constraint(equalTo: passwordField.bottomAnchor, constant: 8),
            showPasswordCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        self.view = container
    }

    @objc private func togglePassword(_ sender: NSButton) {
        let show = sender.state == .on
        passwordField.isHidden = show
        passwordTextField.isHidden = !show
        if show {
            passwordTextField.stringValue = passwordField.stringValue
        } else {
            passwordField.stringValue = passwordTextField.stringValue
        }
    }

    @objc private func doOK(_ sender: Any?) {
        let password = showPasswordCheckbox.state == .on ? passwordTextField.stringValue : passwordField.stringValue
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .OK)
        completionHandler?(password)
    }

    @objc private func doCancel(_ sender: Any?) {
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .cancel)
        completionHandler?(nil)
    }
}
