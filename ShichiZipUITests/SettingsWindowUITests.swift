import XCTest

final class SettingsWindowUITests: ShichiZipUITestCase {
    func testSwiftUISettingsNavigationAndFileTypeSearch() {
        XCTAssertTrue(fileManagerWindow.waitForExistence(timeout: 10))

        app.menuBars.menuBarItems["Tools"].click()
        app.menuBars.menuBarItems["Tools"].menus.menuItems.firstMatch.click()

        let generalNavigation = app.buttons.matching(
            identifier: "settings.navigation.general",
        ).firstMatch
        XCTAssertTrue(generalNavigation.waitForExistence(timeout: 10))
        generalNavigation.click()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(
            app.buttons.matching(
                identifier: "settings.navigation.archives",
            ).firstMatch.isSelected,
        )

        let fileTypesNavigation = app.buttons.matching(
            identifier: "settings.navigation.fileTypes",
        ).firstMatch
        XCTAssertTrue(fileTypesNavigation.waitForExistence(timeout: 10))
        fileTypesNavigation.click()

        let searchField = app.searchFields.matching(
            identifier: "settings.fileTypeSearch",
        ).firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeText("iso")

        XCTAssertTrue(app.staticTexts[".iso"].waitForExistence(timeout: 5))

        app.buttons.matching(identifier: "settings.navigation.extensions").firstMatch.click()
        XCTAssertTrue(
            app.textFields.matching(
                identifier: "settings.quickLook.expansionDepth",
            ).firstMatch.waitForExistence(timeout: 5),
        )

        app.typeKey("w", modifierFlags: .command)
    }
}
