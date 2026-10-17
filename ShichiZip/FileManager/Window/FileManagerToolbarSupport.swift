import AppKit

@MainActor
final class FileManagerWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           (windowController as? FileManagerWindowController)?.handleTitlePathMouseEvent(event) == true {
            return
        }
        super.sendEvent(event)
    }

    private func locationTitle() -> NSTextField? {
        guard FileManagerToolbarPreferences.style == .unified, titleVisibility == .visible,
              let title = FileManagerPathToolbar.titleField(in: self) else { return nil }
        if title.accessibilityIdentifier() != "fileManager.locationTitle" {
            title.setAccessibilityIdentifier("fileManager.locationTitle")
            title.setAccessibilityElement(true)
            title.setAccessibilityRole(.staticText)
            title.setAccessibilityParent(self)
        }
        return title
    }

    override func accessibilityTitleUIElement() -> Any? {
        if let title = locationTitle() { return title }
        return super.accessibilityTitleUIElement()
    }

    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        guard let title = locationTitle() else { return children }
        // Expose the actual title text instead of AppKit's flexible title-area proxy.
        let proxy = super.accessibilityTitleUIElement() as AnyObject?
        children.removeAll { ($0 as AnyObject) === proxy || ($0 as AnyObject) === title }
        children.append(title)
        return children
    }
}

extension FileManagerWindowController: NSToolbarDelegate {
    static let upItem = NSToolbarItem.Identifier("fm_up")
    static let addItem = NSToolbarItem.Identifier("fm_add")
    static let extractItem = NSToolbarItem.Identifier("fm_extract")
    static let testItem = NSToolbarItem.Identifier("fm_test")
    static let copyItem = NSToolbarItem.Identifier("fm_copy")
    static let moveItem = NSToolbarItem.Identifier("fm_move")
    static let deleteItem = NSToolbarItem.Identifier("fm_delete")
    static let infoItem = NSToolbarItem.Identifier("fm_info")

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem?
    {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        guard toolbarAllowedItemIdentifiers(toolbar).contains(itemIdentifier) else {
            return nil
        }

        configureToolbarItem(item)

        return item
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = FileManagerToolbarPreferences.style == .unified ? [Self.upItem, .flexibleSpace] : []

        if FileManagerToolbarPreferences.showsArchiveToolbar {
            identifiers.append(contentsOf: [Self.addItem, Self.extractItem, Self.testItem])
        }

        if FileManagerToolbarPreferences.showsStandardToolbar {
            if FileManagerToolbarPreferences.showsArchiveToolbar {
                identifiers.append(.space)
            }
            identifiers.append(contentsOf: [Self.copyItem, Self.moveItem, Self.deleteItem, Self.infoItem])
        }

        return identifiers
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        (FileManagerToolbarPreferences.style == .unified ? [Self.upItem] : []) +
            [Self.addItem, Self.extractItem, Self.testItem,
             Self.copyItem, Self.moveItem, Self.deleteItem, Self.infoItem,
             .space, .flexibleSpace]
    }

    func toolbarImmovableItemIdentifiers(_: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        FileManagerToolbarPreferences.style == .unified ? [Self.upItem] : []
    }

    func configureToolbarItem(_ item: NSToolbarItem) {
        item.target = self
        item.isBordered = true

        switch item.itemIdentifier {
        case Self.upItem:
            item.label = SZL10n.string("view.upOneLevel")
            item.toolTip = item.label
            item.image = toolbarImage(systemSymbolName: "chevron.up", accessibilityDescription: item.label)
            item.action = #selector(goUpOneLevel(_:))
            item.isNavigational = true
            item.visibilityPriority = .high

        case Self.addItem:
            item.label = SZL10n.string("toolbar.add")
            item.toolTip = SZL10n.string("toolbar.add")
            item.image = toolbarImage(systemSymbolName: "plus.circle", accessibilityDescription: SZL10n.string("toolbar.add"))
            item.action = #selector(addToArchive(_:))

        case Self.extractItem:
            item.label = SZL10n.string("toolbar.extract")
            item.toolTip = SZL10n.string("toolbar.extract")
            item.image = toolbarImage(systemSymbolName: "tray.and.arrow.up", accessibilityDescription: SZL10n.string("toolbar.extract"))
            item.action = #selector(extractArchive(_:))

        case Self.testItem:
            item.label = SZL10n.string("toolbar.test")
            item.toolTip = SZL10n.string("toolbar.test")
            item.image = toolbarImage(systemSymbolName: "checkmark.seal", accessibilityDescription: SZL10n.string("toolbar.test"))
            item.action = #selector(testArchive(_:))

        case Self.copyItem:
            item.label = SZL10n.string("toolbar.copy")
            item.toolTip = SZL10n.string("toolbar.copy")
            item.image = toolbarImage(systemSymbolName: "doc.on.doc", accessibilityDescription: SZL10n.string("toolbar.copy"))
            item.action = #selector(copyFiles(_:))

        case Self.moveItem:
            item.label = SZL10n.string("toolbar.move")
            item.toolTip = SZL10n.string("toolbar.move")
            item.image = toolbarImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: SZL10n.string("toolbar.move"))
            item.action = #selector(moveFiles(_:))

        case Self.deleteItem:
            item.label = SZL10n.string("toolbar.delete")
            item.toolTip = SZL10n.string("toolbar.delete")
            item.image = toolbarImage(systemSymbolName: "trash", accessibilityDescription: SZL10n.string("toolbar.delete"))
            item.action = #selector(deleteFiles(_:))

        case Self.infoItem:
            item.label = SZL10n.string("toolbar.info")
            item.toolTip = SZL10n.string("toolbar.info")
            item.image = toolbarImage(systemSymbolName: "info.circle", accessibilityDescription: SZL10n.string("toolbar.info"))
            item.action = #selector(showProperties(_:))

        default:
            item.isBordered = false
        }
    }

    private func toolbarImage(systemSymbolName name: String,
                              accessibilityDescription: String) -> NSImage?
    {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) else { return nil }
        guard FileManagerToolbarPreferences.style == .unified else { return symbol }
        // Equal image canvases give native toolbar buttons consistent widths.
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            let scale = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}

/// A native toolbar-sized path editor, with the pane address field's navigation behavior.
final class FileManagerTitlePathField: NSTextField, NSTextFieldDelegate {
    var onSubmit: ((String) -> Bool)?
    var onFinish: (() -> Void)?
    private var isFinished = false
    private var isSubmitting = false
    private var isRestoringSheetFocus = false
    convenience init(path: String) {
        self.init(string: path)
        lineBreakMode = .byTruncatingHead
        isAutomaticTextCompletionEnabled = false
        controlSize = .large
        bezelStyle = .roundedBezel
        isBezeled = true
        delegate = self
        setAccessibilityIdentifier("fileManager.titlePathField")
    }

    func install() {
        NotificationCenter.default.addObserver(self, selector: #selector(sheetDidEnd(_:)),
                                               name: NSWindow.didEndSheetNotification, object: window)
    }

    func uninstall() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEndSheetNotification, object: window)
    }

    func beginPathEditing() {
        guard !isFinished else { return }
        selectText(nil)
    }

    @objc private func sheetDidEnd(_ notification: Notification) {
        // Let AppKit finish restoring the sheet's previous first responder first.
        isRestoringSheetFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.beginPathEditing()
            self.isRestoringSheetFocus = false
        }
    }

    func cancelPathEditing() {
        finish()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        onFinish?()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !isSubmitting, !isRestoringSheetFocus, window?.attachedSheet == nil else { return }
        finish()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            finish()
        case #selector(NSResponder.insertNewline(_:)):
            isSubmitting = true
            let accepted = onSubmit?(stringValue) ?? false
            isSubmitting = false
            if accepted {
                finish()
            } else if window?.attachedSheet != nil {
                isRestoringSheetFocus = true
            } else {
                beginPathEditing()
            }
        default:
            return false
        }
        return true
    }
}

/// Uses a separate native toolbar for path editing, preserving the user's toolbar object and layout.
@MainActor
final class FileManagerPathToolbar: NSObject, NSToolbarDelegate {
    private static let pathItem = NSToolbarItem.Identifier("fm_path")
    private weak var window: NSWindow?
    private let originalToolbar: NSToolbar?
    private let originalTitleVisibility: NSWindow.TitleVisibility
    private let toolbar = NSToolbar(identifier: "FileManagerPathToolbar")
    private let item = NSToolbarItem(itemIdentifier: FileManagerPathToolbar.pathItem)
    private let widthLimit: NSLayoutConstraint

    init(window: NSWindow, field: FileManagerTitlePathField) {
        self.window = window
        originalToolbar = window.toolbar
        originalTitleVisibility = window.titleVisibility
        // AppKit allocates the available toolbar width and owns all item geometry.
        let content = NSStackView(views: [field])
        content.orientation = .horizontal
        content.distribution = .fill
        content.edgeInsets = NSEdgeInsetsZero
        content.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        widthLimit = content.widthAnchor.constraint(lessThanOrEqualToConstant: window.frame.width)
        widthLimit.isActive = true
        item.view = content
        item.label = SZL10n.string("column.path")
        item.isBordered = true
        super.init()
        toolbar.delegate = self
        // Text-only mode must still show the editor. Modern toolbars keep their
        // label row in icon-and-label mode so entering a path does not resize the window content.
        toolbar.displayMode = .iconOnly
        if #available(macOS 26.0, *), originalToolbar?.displayMode == .iconAndLabel {
            toolbar.displayMode = .iconAndLabel
        }
    }

    func install() {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.subtitle = ""
        window.toolbar = toolbar
        window.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    func restore() {
        guard let window else { return }
        window.toolbar = originalToolbar
        window.titleVisibility = originalTitleVisibility
    }

    func updateWidth() {
        guard let window else { return }
        widthLimit.constant = window.frame.width
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.pathItem]
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.pathItem]
    }

    func toolbar(_: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
        identifier == Self.pathItem ? item : nil
    }

    static func titleField(in window: NSWindow, text: String? = nil) -> NSTextField? {
        let text = text ?? window.title
        guard !text.isEmpty else { return nil }
        guard let content = window.contentView, let frame = content.superview else { return nil }
        func find(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == text,
               !field.isHiddenOrHasHiddenAncestor, !field.isDescendant(of: content) {
                return field
            }
            for child in view.subviews {
                if let field = find(in: child) { return field }
            }
            return nil
        }
        return find(in: frame)
    }

}
