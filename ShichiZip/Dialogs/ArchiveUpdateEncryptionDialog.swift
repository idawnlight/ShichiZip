import SwiftUI

@MainActor
enum ArchiveUpdateEncryptionDialog {
    static func runModal(forArchive archivePath: String, defaultEncryption: SZEncryptionMethod) -> SZArchiveUpdateEncryption? {
        let options = CompressDialogController.encryptionOptions(for: .formatZip)
        let model = Model(encryption: defaultEncryption)
        let content = NSHostingView(rootView: Content(model: model, options: options))
        let dialog = SZModalDialogController(
            style: .informational,
            title: SZL10n.string("app.archive.updateEncryption.title", (archivePath as NSString).lastPathComponent),
            message: nil,
            actions: [
                SZDialogAction(title: SZL10n.string("common.cancel"), roles: .cancel),
                SZDialogAction(title: SZL10n.string("common.ok"), roles: .default),
            ],
            accessoryView: content,
            preferredFirstResponder: nil,
        )
        var result: SZArchiveUpdateEncryption?
        dialog.shouldFinishHandler = { buttonIndex in
            guard buttonIndex == 1 else { return true }
            let selection = SZArchiveUpdateEncryption(encryption: model.encryption, password: model.password)
            do {
                try selection.validate()
                result = selection
                return true
            } catch {
                szPresentError(error, for: dialog.window)
                return false
            }
        }
        defer { dialog.shouldFinishHandler = nil }
        return dialog.runModal() == 1 ? result : nil
    }

    private final class Model: ObservableObject {
        @Published var encryption: SZEncryptionMethod
        @Published var password = ""

        init(encryption: SZEncryptionMethod) {
            self.encryption = encryption
        }
    }

    private struct EncryptionPicker: NSViewRepresentable {
        @Binding var selection: SZEncryptionMethod
        let options: [CompressDialogController.Option<SZEncryptionMethod>]

        func makeCoordinator() -> Coordinator {
            Coordinator(selection: $selection)
        }

        func makeNSView(context: Context) -> NSPopUpButton {
            // On macOS 27 / Xcode 27, selecting a SwiftUI menu Picker in this
            // NSApp.runModal accessory leaves subsequent XCTest button clicks without
            // actions, while physical clicks still work. A native popup avoids this
            // reproducible failure; the AES update UI test covers the full interaction.
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            let choices = [
                CompressDialogController.Option(title: SZL10n.string("app.archive.updateEncryption.none"), value: SZEncryptionMethod.none),
            ] + options
            for option in choices {
                popup.addItem(withTitle: option.title)
                popup.lastItem?.tag = option.value.rawValue
            }
            popup.target = context.coordinator
            popup.action = #selector(Coordinator.selectionChanged(_:))
            popup.setAccessibilityLabel(SZL10n.string("compress.encryptionMethod"))
            popup.setAccessibilityIdentifier("archiveUpdateEncryption.encryption")
            return popup
        }

        func updateNSView(_ popup: NSPopUpButton, context: Context) {
            context.coordinator.selection = $selection
            popup.selectItem(withTag: selection.rawValue)
        }

        @MainActor
        final class Coordinator: NSObject {
            var selection: Binding<SZEncryptionMethod>

            init(selection: Binding<SZEncryptionMethod>) {
                self.selection = selection
            }

            @objc func selectionChanged(_ sender: NSPopUpButton) {
                guard let item = sender.selectedItem,
                      let method = SZEncryptionMethod(rawValue: item.tag) else { return }
                selection.wrappedValue = method
            }
        }
    }

    private struct Content: View {
        @ObservedObject var model: Model
        let options: [CompressDialogController.Option<SZEncryptionMethod>]
        @State private var showsPassword = false
        @FocusState private var focusedField: PasswordField?

        private enum PasswordField {
            case secure, plain
        }

        var body: some View {
            Form {
                LabeledContent(SZL10n.string("compress.encryptionMethod")) {
                    EncryptionPicker(selection: $model.encryption, options: options)
                }

                LabeledContent(SZL10n.string("password.password")) {
                    Group {
                        if showsPassword {
                            TextField("", text: $model.password)
                                .focused($focusedField, equals: .plain)
                                .accessibilityIdentifier("archiveUpdateEncryption.passwordPlain")
                        } else {
                            SecureField("", text: $model.password)
                                .focused($focusedField, equals: .secure)
                                .accessibilityIdentifier("archiveUpdateEncryption.password")
                        }
                    }
                    .accessibilityLabel(SZL10n.string("password.password"))
                    .disabled(model.encryption == .none)
                }

                LabeledContent("") {
                    Toggle(SZL10n.string("password.showPassword"), isOn: $showsPassword)
                        .toggleStyle(.checkbox)
                        .disabled(model.encryption == .none)
                        .accessibilityIdentifier("archiveUpdateEncryption.showPassword")
                }
            }
            .formStyle(.columns)
            .frame(width: 360)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { focusedField = .secure }
            .onChange(of: showsPassword) { shown in
                focusedField = shown ? .plain : .secure
            }
        }
    }
}
