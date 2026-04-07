import Cocoa

private enum ArchiveErrorCode: Int {
    case unsupportedArchive = -2
    case userCancelled = -5
}

private func szIsArchiveError(_ error: Error, code: ArchiveErrorCode) -> Bool {
    let nsError = error as NSError
    return nsError.domain == SZArchiveErrorDomain && nsError.code == code.rawValue
}

func szIsUserCancellation(_ error: Error) -> Bool {
    szIsArchiveError(error, code: .userCancelled)
}

func szIsUnsupportedArchive(_ error: Error) -> Bool {
    szIsArchiveError(error, code: .unsupportedArchive)
}

func szPresentError(_ error: Error, for window: NSWindow?) {
    guard !szIsUserCancellation(error) else { return }
    SZDialogPresenter.presentError(error as NSError, for: window)
}

func szPresentMessage(title: String,
                      message: String = "",
                      style: SZDialogStyle = .informational,
                      for window: NSWindow?) {
    SZDialogPresenter.presentMessage(with: style,
                                     title: title,
                                     message: message,
                                     buttonTitle: "OK",
                                     for: window)
}

func szRunChoiceDialog(title: String,
                       message: String,
                       style: SZDialogStyle = .informational,
                       buttons: [String]) -> Int {
    SZDialogPresenter.runMessage(with: style,
                                 title: title,
                                 message: message,
                                 buttonTitles: buttons)
}

func szPromptForPasswordSync(title: String,
                             message: String? = nil,
                             initialValue: String? = nil) -> String? {
    var password: NSString?
    let confirmed = SZDialogPresenter.promptForPassword(withTitle: title,
                                                        message: message,
                                                        initialValue: initialValue,
                                                        password: &password)
    guard confirmed else { return nil }
    return password as String?
}

func szBeginConfirmation(on window: NSWindow,
                         title: String,
                         message: String,
                         confirmTitle: String,
                         style: SZDialogStyle = .warning,
                         completion: @escaping (Bool) -> Void) {
    let controller = SZModalDialogController(style: style,
                                             title: title,
                                             message: message,
                                             buttonTitles: ["Cancel", confirmTitle],
                                             accessoryView: nil,
                                             preferredFirstResponder: nil,
                                             cancelButtonIndex: 0)
    controller.beginSheetModal(for: window) { buttonIndex in
        completion(buttonIndex == 1)
    }
}

func szBeginTextInput(on window: NSWindow,
                      title: String,
                      message: String? = nil,
                      initialValue: String = "",
                      placeholder: String? = nil,
                      confirmTitle: String,
                      style: SZDialogStyle = .informational,
                      completion: @escaping (String?) -> Void) {
    let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    inputField.stringValue = initialValue
    inputField.placeholderString = placeholder

    let controller = SZModalDialogController(style: style,
                                             title: title,
                                             message: message,
                                             buttonTitles: ["Cancel", confirmTitle],
                                             accessoryView: inputField,
                                             preferredFirstResponder: inputField,
                                             cancelButtonIndex: 0)
    controller.beginSheetModal(for: window) { buttonIndex in
        completion(buttonIndex == 1 ? inputField.stringValue : nil)
    }
}

func szShowDetailsDialog(title: String,
                         summary: String? = nil,
                         details: String,
                         style: SZDialogStyle = .informational,
                         for window: NSWindow?) {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
    textView.string = details
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 0, height: 4)
    textView.font = .systemFont(ofSize: 12)

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.documentView = textView

    let controller = SZModalDialogController(style: style,
                                             title: title,
                                             message: summary,
                                             buttonTitles: ["OK"],
                                             accessoryView: scrollView,
                                             preferredFirstResponder: nil,
                                             cancelButtonIndex: 0)

    if let window {
        controller.beginSheetModal(for: window) { _ in }
    } else {
        _ = controller.runModal()
    }
}