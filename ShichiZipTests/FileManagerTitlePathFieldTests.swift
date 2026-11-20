import AppKit
import XCTest
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

@MainActor
final class FileManagerTitlePathFieldTests: XCTestCase {
    func testUsesCustomCellAcrossInitializersWithoutMutatingBaseCellClass() throws {
        let nativeCellClass: AnyClass? = NSTextField.cellClass
        let frameInitialized = FileManagerTitlePathField(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        let frameCell = try XCTUnwrap(frameInitialized.cell)
        XCTAssertFalse(type(of: frameCell) === NSTextFieldCell.self)
        XCTAssertEqual(frameCell.drawingRect(forBounds: frameInitialized.bounds).minX, 9, accuracy: 0.1)
        XCTAssertTrue(NSTextField.cellClass === nativeCellClass)
    }

    func testTextMarginsSurviveEditingAndResizingWithoutChangingOtherFields() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let nativeCellClass: AnyClass? = NSTextField.cellClass
        let field = FileManagerTitlePathField(path: "/Users/資料")
        field.frame = NSRect(x: 20, y: 100, width: 600, height: field.fittingSize.height)
        let other = NSTextField(string: "/Users/資料")
        other.bezelStyle = field.bezelStyle
        other.controlSize = field.controlSize
        other.frame = NSRect(x: 20, y: 40, width: 300, height: other.fittingSize.height)
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(other)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(NSTextField.cellClass === nativeCellClass)

        let cell = try XCTUnwrap(field.cell)
        let otherCell = try XCTUnwrap(other.cell)
        let titleRect = cell.titleRect(forBounds: field.bounds)
        let drawingRect = cell.drawingRect(forBounds: field.bounds)
        let expectedExtraWidth = max(0, otherCell.drawingRect(forBounds: field.bounds).width - drawingRect.width)
        XCTAssertEqual(titleRect.minX - field.bounds.minX, 9, accuracy: 0.1)
        XCTAssertEqual(field.bounds.maxX - titleRect.maxX, 9, accuracy: 0.1)
        XCTAssertEqual(drawingRect, titleRect)
        XCTAssertGreaterThan(expectedExtraWidth, 0)
        XCTAssertEqual(cell.cellSize.width - otherCell.cellSize.width, expectedExtraWidth, accuracy: 0.1)

        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
        let originalInset = editor.textContainerInset
        let originalPadding = try XCTUnwrap(editor.textContainer?.lineFragmentPadding)
        field.beginPathEditing()
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertFalse(editor.isRichText)

        func assertVisualTextMargins() throws {
            let editorFrame = field.convert(editor.bounds, from: editor)
            let padding = try XCTUnwrap(editor.textContainer?.lineFragmentPadding)
            let leftMargin = editorFrame.minX + editor.textContainerOrigin.x + padding
            let rightMargin = field.bounds.maxX - (editorFrame.maxX - editor.textContainerOrigin.x - padding)
            XCTAssertEqual(leftMargin, 11, accuracy: 0.1)
            XCTAssertEqual(rightMargin, 11, accuracy: 0.1)
            let layoutManager = try XCTUnwrap(editor.layoutManager)
            let textContainer = try XCTUnwrap(editor.textContainer)
            let firstGlyph = layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: 1),
                                                        in: textContainer)
            XCTAssertEqual(editorFrame.minX + editor.textContainerOrigin.x + firstGlyph.minX, 11, accuracy: 0.1)
        }

        try assertVisualTextMargins()
        editor.insertText("/Users/別的資料夾", replacementRange: editor.selectedRange())
        field.frame.size.width = 400
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.string, "/Users/別的資料夾")
        try assertVisualTextMargins()
        XCTAssertEqual(editor.textContainerInset, originalInset)
        XCTAssertEqual(editor.textContainer?.lineFragmentPadding, originalPadding)

        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertTrue(other.currentEditor() === editor)
        XCTAssertEqual(editor.textContainerInset, originalInset)
        XCTAssertEqual(editor.textContainer?.lineFragmentPadding, originalPadding)
        XCTAssertEqual(other.stringValue, "/Users/資料")
        window.endEditing(for: other)
    }
}
