import XCTest

final class SettingsWindowUITests: ShichiZipUITestCase {
    func testSwiftUISettingsNavigationAndFileTypeSearch() {
        openSettings()

        let fileTypesNavigation = settingsNavigation("fileTypes")
        XCTAssertTrue(fileTypesNavigation.waitForExistence(timeout: 10))
        fileTypesNavigation.click()

        let searchField = app.searchFields.matching(
            identifier: "settings.fileTypeSearch",
        ).firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeText("iso")

        XCTAssertTrue(app.staticTexts[".iso"].waitForExistence(timeout: 10))

        settingsNavigation("extensions").click()
        XCTAssertTrue(
            app.textFields.matching(
                identifier: "settings.quickLook.expansionDepth",
            ).firstMatch.waitForExistence(timeout: 5),
        )

        app.typeKey("w", modifierFlags: .command)
    }
}

final class SettingsWindowRovingFocusUITests: ShichiZipUITestCase {
    func testSettingsNavigationUsesSingleTabStop() throws {
        try XCTSkipUnless(
            UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 0x2 != 0,
            "Requires Keyboard Navigation to be enabled.",
        )

        openSettings()

        let generalNavigation = settingsNavigation("general")
        app.typeKey(.downArrow, modifierFlags: [])
        waitForSelection(settingsNavigation("archives"))

        let firstArchiveControl = app.descendants(matching: .any).matching(
            identifier: "settings.excludeMacResourceFiles",
        ).firstMatch
        XCTAssertTrue(firstArchiveControl.waitForExistence(timeout: 5))

        app.typeKey(.tab, modifierFlags: [])
        waitForKeyboardFocus(firstArchiveControl)

        app.typeKey(.tab, modifierFlags: .shift)
        app.typeKey(.upArrow, modifierFlags: [])
        waitForSelection(generalNavigation)

        app.typeKey("w", modifierFlags: .command)
    }
}

private extension ShichiZipUITestCase {
    func openSettings() {
        XCTAssertTrue(fileManagerWindow.waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Tools"].click()
        app.menuBars.menuBarItems["Tools"].menus.menuItems.firstMatch.click()
        XCTAssertTrue(settingsNavigation("general").waitForExistence(timeout: 10))
    }

    func settingsNavigation(_ destination: String) -> XCUIElement {
        app.buttons.matching(
            identifier: "settings.navigation.\(destination)",
        ).firstMatch
    }

    func waitForSelection(_ element: XCUIElement,
                          timeout: TimeInterval = 5)
    {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                (object as? XCUIElement)?.isSelected == true
            },
            object: element,
        )
        wait(for: [expectation], timeout: timeout)
    }

    func waitForKeyboardFocus(_ element: XCUIElement,
                              timeout: TimeInterval = 5)
    {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                (object as? XCUIElement)?.containsKeyboardFocus == true
            },
            object: element,
        )
        wait(for: [expectation], timeout: timeout)
    }
}

private extension XCUIElement {
    var containsKeyboardFocus: Bool {
        if (value(forKey: "hasKeyboardFocus") as? Bool) == true {
            return true
        }
        return descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .firstMatch.exists
    }
}
