import AppKit
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class FileManagerTitleFieldLookupTests: XCTestCase, NSToolbarDelegate {
    func testUnifiedToolbarExcludesSameTitleItemAndKeepsNativeTitle() throws {
        let window = makeWindow(titled: true)
        window.toolbarStyle = .unified
        window.toolbar?.displayMode = .iconAndLabel
        let frame = try XCTUnwrap(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let viewerClass: AnyClass = try XCTUnwrap(NSClassFromString("NSToolbarItemViewer"))
        let viewer = try XCTUnwrap(descendants(of: frame).first { $0.isKind(of: viewerClass) })
        let title = try XCTUnwrap(window.titleField())
        XCTAssertFalse(title.isDescendant(of: viewer))
        window.title = "Other window title"
        XCTAssertNil(FileManagerTitleFieldLookup.find(in: window, text: "Copy"))
    }

    func testAccessibilityCellAndInvalidCandidatesFallBack() throws {
        let window = makeWindow(titled: true)
        window.title = "Native window title"
        let title = addTitle(to: window), candidate = addTitle(to: window)
        XCTAssertTrue(try FileManagerTitleFieldLookup.find(in: window, text: "Copy", accessibilityTitle: XCTUnwrap(candidate.cell)) === candidate)
        window.toolbar?.items.first?.view = candidate
        window.contentView?.superview?.addSubview(candidate)
        for value in [candidate, NSObject()] as [Any] {
            XCTAssertTrue(FileManagerTitleFieldLookup.find(in: window, text: "Copy", accessibilityTitle: value) === title)
        }
    }

    func testCachedTitleIsInvalidatedWhenMovedIntoContent() {
        let window = makeWindow()
        let original = addTitle(to: window)
        XCTAssertTrue(window.titleField() === original)
        window.contentView?.addSubview(original)
        XCTAssertNil(window.titleField())
    }

    private func makeWindow(titled: Bool = false) -> FileManagerWindow {
        let window = FileManagerWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 480), styleMask: titled ? [.titled] : [.borderless], backing: .buffered, defer: false)
        window.title = "Copy"
        if titled {
            let toolbar = NSToolbar(identifier: "title-lookup")
            toolbar.delegate = self
            window.toolbar = toolbar
        }
        return window
    }

    private func addTitle(to window: NSWindow) -> NSTextField {
        let field = NSTextField(labelWithString: "Copy")
        window.contentView?.superview?.addSubview(field)
        return field
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("same-title")]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Copy"
        item.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        return item
    }
}
