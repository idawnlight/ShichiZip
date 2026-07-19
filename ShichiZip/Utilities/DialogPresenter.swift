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

func szArchiveMutationWasCommitted(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == SZArchiveErrorDomain
        && nsError.userInfo[SZArchiveMutationCommittedErrorKey] as? Bool == true
}

func szArchiveMutationRequiresReopen(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == SZArchiveErrorDomain
        && nsError.userInfo[SZArchiveMutationReopenFailedErrorKey] as? Bool == true
}

func szIsUnsupportedArchive(_ error: Error) -> Bool {
    szIsArchiveError(error, code: .unsupportedArchive)
}

func szSheetParentWindow(_ window: NSWindow?) -> NSWindow? {
    SZDialogPresenter.sheetParentWindow(for: window)
}

func szPresentError(_ error: Error, for window: NSWindow?) {
    guard !szIsUserCancellation(error) else { return }

    if Thread.isMainThread {
        SZDialogPresenter.presentError(error as NSError, for: szSheetParentWindow(window))
    } else {
        let window = window
        DispatchQueue.main.async {
            SZDialogPresenter.presentError(error as NSError, for: szSheetParentWindow(window))
        }
    }
}

func szPresentMessage(title: String,
                      message: String = "",
                      style: SZDialogStyle = .informational,
                      for window: NSWindow?)
{
    if Thread.isMainThread {
        SZDialogPresenter.presentMessage(with: style,
                                         title: title,
                                         message: message,
                                         buttonTitle: SZL10n.string("common.ok"),
                                         for: szSheetParentWindow(window))
    } else {
        let window = window
        DispatchQueue.main.async {
            SZDialogPresenter.presentMessage(with: style,
                                             title: title,
                                             message: message,
                                             buttonTitle: SZL10n.string("common.ok"),
                                             for: szSheetParentWindow(window))
        }
    }
}

func szRunChoiceDialog(_ request: SZOperationChoiceRequest) -> Int {
    SZDialogPresenter.run(request)
}

func szPromptForPasswordSync(title: String,
                             message: String? = nil,
                             initialValue: String? = nil) -> String?
{
    var password: NSString?
    let confirmed = SZDialogPresenter.promptForPassword(withTitle: title,
                                                        message: message,
                                                        initialValue: initialValue,
                                                        password: &password)
    guard confirmed else { return nil }
    return password as String?
}

@MainActor
extension SZModalDialogController {
    func szBeginSheetOrRunModal(for window: NSWindow?,
                                completionHandler: @escaping @MainActor @Sendable (Int) -> Void)
    {
        guard let sheetParent = szSheetParentWindow(window) else {
            completionHandler(runModal())
            return
        }

        beginSheetModal(for: sheetParent, completionHandler: completionHandler)
    }

    func modalResult(for window: NSWindow?) async -> Int {
        await withCheckedContinuation { continuation in
            szBeginSheetOrRunModal(for: window) { buttonIndex in
                continuation.resume(returning: buttonIndex)
            }
        }
    }
}

@MainActor
func szBeginConfirmation(on window: NSWindow,
                         title: String,
                         message: String,
                         confirmTitle: String,
                         style: SZDialogStyle = .warning,
                         completion: @escaping @MainActor @Sendable (Bool) -> Void)
{
    let controller = SZModalDialogController(style: style,
                                             title: title,
                                             message: message,
                                             actions: [
                                                 SZDialogAction(title: SZL10n.string("common.cancel"),
                                                                roles: .cancel),
                                                 SZDialogAction(title: confirmTitle,
                                                                roles: .default),
                                             ],
                                             accessoryView: nil,
                                             preferredFirstResponder: nil)
    controller.szBeginSheetOrRunModal(for: window) { buttonIndex in
        completion(buttonIndex == 1)
    }
}

@MainActor
func szBeginTextInput(on window: NSWindow,
                      title: String,
                      message: String? = nil,
                      initialValue: String = "",
                      placeholder: String? = nil,
                      confirmTitle: String,
                      style: SZDialogStyle = .informational,
                      completion: @escaping @MainActor @Sendable (String?) -> Void)
{
    let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    inputField.stringValue = initialValue
    inputField.placeholderString = placeholder

    let controller = SZModalDialogController(style: style,
                                             title: title,
                                             message: message,
                                             actions: [
                                                 SZDialogAction(title: SZL10n.string("common.cancel"),
                                                                roles: .cancel),
                                                 SZDialogAction(title: confirmTitle,
                                                                roles: .default),
                                             ],
                                             accessoryView: inputField,
                                             preferredFirstResponder: inputField)
    controller.szBeginSheetOrRunModal(for: window) { buttonIndex in
        completion(buttonIndex == 1 ? inputField.stringValue : nil)
    }
}

@MainActor
extension NSSavePanel {
    func szBeginSheetOrRunModal(for window: NSWindow?,
                                completionHandler: @escaping @MainActor @Sendable (NSApplication.ModalResponse) -> Void)
    {
        guard let sheetParent = szSheetParentWindow(window) else {
            completionHandler(runModal())
            return
        }

        beginSheetModal(for: sheetParent, completionHandler: completionHandler)
    }
}

func szShowDetailsDialog(title: String,
                         summary: String? = nil,
                         details: String,
                         detailsHeight: CGFloat = 220,
                         style: SZDialogStyle = .informational,
                         for window: NSWindow?)
{
    let present: @Sendable () -> Void = {
        MainActor.assumeIsolated {
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: detailsHeight))
            textView.string = details
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 0, height: 4)
            textView.font = .systemFont(ofSize: 12)

            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: detailsHeight))
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
            scrollView.documentView = textView
            scrollView.heightAnchor.constraint(equalToConstant: detailsHeight).isActive = true

            let controller = SZModalDialogController(style: style,
                                                     title: title,
                                                     message: summary,
                                                     actions: [
                                                         SZDialogAction(title: SZL10n.string("common.ok"),
                                                                        roles: [.default, .cancel]),
                                                     ],
                                                     accessoryView: scrollView,
                                                     preferredFirstResponder: nil)

            controller.szBeginSheetOrRunModal(for: window) { _ in }
        }
    }

    if Thread.isMainThread {
        present()
    } else {
        DispatchQueue.main.async(execute: present)
    }
}
