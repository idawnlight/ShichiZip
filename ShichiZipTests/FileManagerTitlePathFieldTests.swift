import AppKit
import XCTest
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

@MainActor
final class FileManagerTitlePathFieldTests: XCTestCase {
    func testTextMarginsSurviveEditingAndDoNotLeakToAnotherField() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = FileManagerTitlePathField(path: "/Users/資料")
        field.frame = NSRect(x: 20, y: 100, width: 600, height: field.fittingSize.height)
        let other = NSTextField(string: "Another field")
        other.frame = NSRect(x: 20, y: 40, width: 300, height: other.fittingSize.height)
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(other)
        window.contentView?.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
        let originalInset = editor.textContainerInset
        field.beginPathEditing()
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertFalse(editor.isRichText)
        XCTAssertEqual(field.convert(editor.bounds, from: editor).minX + editor.textContainerInset.width, 9, accuracy: 0.1)
        editor.insertText("/Users/別的資料夾", replacementRange: editor.selectedRange())
        field.frame.size.width = 400
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.string, "/Users/別的資料夾")
        XCTAssertEqual(field.convert(editor.bounds, from: editor).minX + editor.textContainerInset.width, 9, accuracy: 0.1)
        XCTAssertEqual(editor.textContainerInset.height, originalInset.height)
        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertTrue(other.currentEditor() === editor)
        XCTAssertEqual(editor.textContainerInset, originalInset)
        XCTAssertEqual(other.stringValue, "Another field")
        window.endEditing(for: other)
    }
}
