import XCTest

final class UnifiedToolbarUITests: ShichiZipUITestCase {
    override var additionalLaunchArguments: [String] {
        ["-FileManager.ToolbarStyle", "unified",
         "-FileManager.ToolbarShowButtonText", "NO"]
    }

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(fileManagerWindow.waitForExistence(timeout: 10))
        fileManagerWindow.buttons["Up One Level"].rightClick()
        app.menuItems["Icon Only"].click()
    }

    func testNavigationSurvivesHiddenToolbarsAndPathEditingKeepsHeight() throws {
        let window = fileManagerWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        setToolbar("Archive Toolbar", button: "Add", visible: false)
        setToolbar("Standard Toolbar", button: "Copy", visible: false)
        let up = window.buttons["Up One Level"]
        XCTAssertTrue(up.waitForExistence(timeout: 5))
        XCTAssertTrue(up.isHittable)
        XCTAssertGreaterThanOrEqual(up.frame.width, 28)
        XCTAssertGreaterThanOrEqual(up.frame.height, 30)
        let close = window.buttons["_XCUI:CloseWindow"]
        XCTAssertEqual(up.frame.midY, close.frame.midY, accuracy: 2)
        XCTAssertFalse(leftPanePathField.exists && leftPanePathField.isHittable)
        let contentTop = leftPaneTable.frame.minY

        openPathEditor()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let path = window.textFields["fileManager.titlePathField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(path.frame.width, window.frame.width * 0.7)
        XCTAssertEqual(leftPaneTable.frame.minY, contentTop, accuracy: 1)
        app.typeKey(.escape, modifierFlags: [])
        waitForPathEditorToClose()
        XCTAssertTrue(up.waitForExistence(timeout: 5))

        let folder = try makeTemporaryDirectory(named: "ToolbarTitle")
        openPathEditor()
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.selectAll()
        path.pasteText(folder.path)
        path.typeText("\r")
        let titleMatches = NSPredicate(format: "title == %@", folder.lastPathComponent)
        expectation(for: titleMatches, evaluatedWith: window)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(up.isHittable)
        up.click()
        let parentMatches = NSPredicate(format: "title == %@", folder.deletingLastPathComponent().lastPathComponent)
        expectation(for: parentMatches, evaluatedWith: window)
        waitForExpectations(timeout: 10)
    }

    func testToolbarGroupsReappearAndSurvivePathEditing() throws {
        XCTAssertTrue(fileManagerWindow.waitForExistence(timeout: 10))
        saveScreenshot("launch")
        setToolbar("Archive Toolbar", button: "Add", visible: true)
        setToolbar("Standard Toolbar", button: "Copy", visible: true)
        let toolbar = fileManagerWindow
        XCTAssertTrue(toolbar.buttons["Test"].exists)
        XCTAssertTrue(toolbar.buttons["Info"].exists)
        let up = fileManagerWindow.buttons["Up One Level"]
        let add = toolbar.buttons["Add"]
        XCTAssertEqual(up.frame.midY, add.frame.midY, accuracy: 1)
        saveScreenshot("normal")
        up.hover()
        saveScreenshot("hover")
        openPathEditor()
        XCTAssertTrue(fileManagerWindow.textFields["fileManager.titlePathField"].waitForExistence(timeout: 5))
        saveScreenshot("path")
        app.typeKey(.escape, modifierFlags: [])
        waitForPathEditorToClose()
        XCTAssertTrue(toolbar.buttons["Add"].waitForExistence(timeout: 5))
        XCTAssertTrue(toolbar.buttons["Copy"].exists)
        let originalContentTop = leftPaneTable.frame.minY
        setToolbar("Archive Toolbar", button: "Add", visible: false)
        setToolbar("Standard Toolbar", button: "Copy", visible: false)
        XCTAssertTrue(up.isHittable)
        XCTAssertEqual(leftPaneTable.frame.minY, originalContentTop, accuracy: 1)
        setToolbar("Archive Toolbar", button: "Add", visible: true)
        setToolbar("Standard Toolbar", button: "Copy", visible: true)
        saveScreenshot("restored")
    }

    func testNativeCustomizationCanReorderRemoveAndRestoreLayout() throws {
        let window = fileManagerWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        setToolbar("Archive Toolbar", button: "Add", visible: true)
        setToolbar("Standard Toolbar", button: "Copy", visible: true)
        window.buttons["Up One Level"].rightClick()
        try clickCustomizeToolbarMenuItem()
        let done = try customizationDoneButton()
        saveScreenshot("customize")
        let toolbar = window.toolbars.firstMatch
        let copy = toolbar.buttons["Copy"]
        let add = toolbar.buttons["Add"]
        copy.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(
            forDuration: 0.3,
            thenDragTo: add.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)))
        XCTAssertLessThan(copy.frame.minX, add.frame.minX)
        let info = toolbar.buttons["Info"]
        info.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(
            forDuration: 0.3,
            thenDragTo: leftPaneTable.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        done.click()
        XCTAssertFalse(info.exists)
        openPathEditor()
        XCTAssertTrue(window.textFields["fileManager.titlePathField"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        waitForPathEditorToClose()
        XCTAssertFalse(info.exists)
        XCTAssertLessThan(copy.frame.minX, add.frame.minX)
        app.terminate()
        app.launch()
        XCTAssertTrue(fileManagerWindow.waitForExistence(timeout: 10))
        XCTAssertFalse(fileManagerWindow.toolbars.firstMatch.buttons["Info"].exists)
        XCTAssertLessThan(fileManagerWindow.toolbars.firstMatch.buttons["Copy"].frame.minX,
                          fileManagerWindow.toolbars.firstMatch.buttons["Add"].frame.minX)
        setToolbar("Standard Toolbar", button: "Copy", visible: false)
        setToolbar("Standard Toolbar", button: "Copy", visible: true)
    }

    func testCustomizationOpensFromToolbarWithoutClosingWindow() throws {
        let window = fileManagerWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.buttons["Up One Level"].rightClick()
        try clickCustomizeToolbarMenuItem()
        let done = try customizationDoneButton()
        XCTAssertEqual(app.state, .runningForeground)
        saveScreenshot("customize-from-toolbar")
        done.click()
        XCTAssertTrue(window.buttons["Up One Level"].isHittable)
        XCTAssertTrue(window.staticTexts["fileManager.locationTitle"].exists)
        XCTAssertFalse(window.textFields["fileManager.titlePathField"].exists)
    }

    func testClickOutsidePathEditorCancelsWithoutNavigating() {
        let window = fileManagerWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let originalTitle = window.title
        let up = window.buttons["Up One Level"]
        openPathEditor()
        let path = window.textFields["fileManager.titlePathField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(path.exists)
        path.selectAll()
        path.pasteText("/Users")
        // Status text does not take keyboard focus, so ending editing alone is insufficient.
        let status = window.staticTexts.matching(identifier: "fileManager.statusLabel").firstMatch
        XCTAssertTrue(status.isHittable)
        status.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        waitForPathEditorToClose()
        XCTAssertTrue(up.waitForExistence(timeout: 5))
        XCTAssertFalse(path.exists)
        XCTAssertEqual(window.title, originalTitle)
    }

    func testArchiveSubfolderUsesOriginalAddressBarPath() throws {
        let directory = try makeTemporaryDirectory(named: "ToolbarArchivePath")
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try createTextFile(at: nested.appendingPathComponent("payload.txt"))
        let archive = try createTestArchive(named: "navigation", sourceFileNames: ["nested/payload.txt"], in: directory)
        let window = fileManagerWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        openPathEditor()
        let path = window.textFields["fileManager.titlePathField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.selectAll()
        path.pasteText(archive.path)
        path.typeText("\r")
        let folder = leftPaneTable.cells.staticTexts["nested"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.doubleClick()
        XCTAssertTrue(leftPaneTable.cells.staticTexts["payload.txt"].waitForExistence(timeout: 5))
        openPathEditor()
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        XCTAssertEqual(path.value as? String, archive.path + "/nested")
        app.typeKey(.escape, modifierFlags: [])
        waitForPathEditorToClose()
    }

    func testPathEditingPreservesNativeDisplayModes() {
        // Collect every display mode even if one geometry assertion fails.
        continueAfterFailure = true
        let window = fileManagerWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        setToolbar("Archive Toolbar", button: "Add", visible: true)
        let up = window.buttons["Up One Level"]
        let path = window.textFields["fileManager.titlePathField"]
        var editorHeight: CGFloat?
        for mode in ["Icon and Text", "Text Only", "Icon Only"] {
            window.buttons["Add"].rightClick()
            app.menuItems[mode].click()
            let originalWidth = up.frame.width
            let originalActionFrame = window.buttons["Add"].frame
            let contentTop = leftPaneTable.frame.minY
            openPathEditor()
            XCTAssertTrue(path.waitForExistence(timeout: 5))
            XCTAssertEqual(path.frame.midY, window.buttons["_XCUI:CloseWindow"].frame.midY, accuracy: 2)
            if let editorHeight {
                XCTAssertEqual(path.frame.height, editorHeight, accuracy: 1)
            } else {
                editorHeight = path.frame.height
            }
            let appearance = XCTAttachment(screenshot: window.screenshot())
            appearance.name = "path-editor-\(mode)"
            appearance.lifetime = .keepAlways
            add(appearance)
            XCTAssertGreaterThan(path.frame.width, window.frame.width * 0.7)
            XCTAssertEqual(leftPaneTable.frame.minY, contentTop, accuracy: 1)
            app.typeKey(.escape, modifierFlags: [])
            waitForPathEditorToClose()
            XCTAssertTrue(up.waitForExistence(timeout: 5))
            XCTAssertEqual(up.frame.width, originalWidth, accuracy: 1)
            XCTAssertEqual(window.buttons["Add"].frame, originalActionFrame)
            XCTAssertEqual(leftPaneTable.frame.minY, contentTop, accuracy: 1)
        }
    }

    func testRightClickOnTitleOpensPathEditor() throws {
        let window = fileManagerWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let originalTitle = window.title
        openPathEditor()
        let path = window.textFields["fileManager.titlePathField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        let displayedPath = try XCTUnwrap(path.value as? String)
        XCTAssertEqual((displayedPath as NSString).lastPathComponent, originalTitle)
        app.typeKey(.escape, modifierFlags: [])
        waitForPathEditorToClose()
    }

    func testInvalidPathKeepsEditorOpenForCorrection() throws {
        let window = fileManagerWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let originalTitle = window.title
        openPathEditor()
        let path = window.textFields["fileManager.titlePathField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        let folder = try makeTemporaryDirectory(named: "CorrectedPath")
        let missingPath = folder.appendingPathComponent(UUID().uuidString).path
        path.selectAll()
        path.pasteText(missingPath)
        app.typeKey(.return, modifierFlags: [])
        let dismissButtons = app.windows.buttons.matching(identifier: "modal.button.0")
        XCTAssertTrue(dismissButtons.firstMatch.waitForExistence(timeout: 5))
        let dismiss = try XCTUnwrap(dismissButtons.allElementsBoundByIndex.first {
            $0.isHittable && !$0.frame.isEmpty && !$0.frame.isInfinite
        })
        XCTAssertTrue(path.exists)
        dismiss.click()
        expectation(for: NSPredicate(format: "exists == NO"), evaluatedWith: dismiss)
        waitForExpectations(timeout: 5)
        expectation(for: NSPredicate(format: "hittable == YES"), evaluatedWith: path)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(path.value as? String, missingPath)
        XCTAssertEqual(window.title, originalTitle)
        // The editor should regain focus without another click.
        app.typeKey("a", modifierFlags: .command)
        app.typeText(folder.path)
        app.typeKey(.return, modifierFlags: [])
        waitForPathEditorToClose()
        XCTAssertEqual(window.title, folder.lastPathComponent)
    }

    private func clickCustomizeToolbarMenuItem() throws {
        let items = app.menuItems.matching(identifier: "Customize Toolbar…")
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5))
        let visibleItem = try XCTUnwrap(items.allElementsBoundByIndex.first { $0.isHittable })
        visibleItem.click()
    }

    private func customizationDoneButton() throws -> XCUIElement {
        let buttons = app.windows.buttons.matching(identifier: "Done")
        XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 5))
        return try XCTUnwrap(buttons.allElementsBoundByIndex.first { $0.isHittable })
    }

    private func openPathEditor() {
        let window = fileManagerWindow
        let title = window.staticTexts["fileManager.locationTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(title.isHittable)
        let frame = title.frame
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertLessThan(frame.width, window.frame.width)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(window.textFields["fileManager.titlePathField"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.textFields["fileManager.titlePathField"].isHittable)
    }

    private func waitForPathEditorToClose() {
        let path = fileManagerWindow.textFields["fileManager.titlePathField"]
        expectation(for: NSPredicate(format: "exists == NO"), evaluatedWith: path)
        expectation(for: NSPredicate(format: "hittable == YES"), evaluatedWith: fileManagerWindow.buttons["Up One Level"])
        waitForExpectations(timeout: 5)
    }

    private func setToolbar(_ title: String, button: String, visible: Bool) {
        let item = fileManagerWindow.buttons[button]
        guard item.exists != visible else { return }
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Toolbars"].hover()
        app.menuItems[title].click()
        saveScreenshot("menu-\(button)-\(visible)")
        expectation(for: NSPredicate(format: "exists == %@", NSNumber(value: visible)), evaluatedWith: item)
        waitForExpectations(timeout: 5)
    }

    private func saveScreenshot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// This class deliberately uses normal preferences so launch arguments cannot mask menu changes.
final class ToolbarStyleMenuUITests: ShichiZipUITestCase {
    func testWindowSubtitleTracksLocationAndCanBeDisabled() throws {
        let window = fileManagerWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let originallyShowsAddressBar = leftPanePathField.isHittable
        if originallyShowsAddressBar {
            toggleToolbarMenuItem("Unified Style")
        }
        defer {
            if originallyShowsAddressBar {
                toggleToolbarMenuItem("Unified Style")
            }
        }
        let title = window.descendants(matching: .any).matching(identifier: "fileManager.locationTitle").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.rightClick()
        let path = window.textFields["fileManager.titlePathField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        let folder = try makeTemporaryDirectory(named: "WindowSubtitle")
        path.selectAll()
        path.pasteText(folder.path)
        path.typeText("\r")
        expectation(for: NSPredicate(format: "exists == NO"), evaluatedWith: path)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(window.title.contains(folder.path))
        toggleToolbarMenuItem("Show Full Path")
        expectation(for: NSPredicate(format: "title CONTAINS %@", folder.path), evaluatedWith: window)
        waitForExpectations(timeout: 10)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "window-subtitle"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        window.buttons["Up One Level"].click()
        let parentPath = folder.deletingLastPathComponent().path
        expectation(for: NSPredicate(format: "title CONTAINS %@", parentPath), evaluatedWith: window)
        waitForExpectations(timeout: 10)
        toggleToolbarMenuItem("Show Full Path")
        XCTAssertFalse(window.title.contains(parentPath))
    }

    private func toggleToolbarMenuItem(_ title: String) {
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Toolbars"].hover()
        app.menuItems[title].click()
    }

    func testUnifiedStyleCanBeDisabledAndReenabled() {
        XCTAssertTrue(fileManagerWindow.waitForExistence(timeout: 10))
        let originallyShowsAddressBar = leftPanePathField.isHittable
        for expectedVisibility in [!originallyShowsAddressBar, originallyShowsAddressBar] {
            app.menuBars.menuBarItems["View"].click()
            app.menuItems["Toolbars"].hover()
            app.menuItems["Unified Style"].click()
            expectation(for: NSPredicate(format: "hittable == %@", NSNumber(value: expectedVisibility)), evaluatedWith: leftPanePathField)
            waitForExpectations(timeout: 5)
        }
    }
}
