import XCTest

/// Tests for notification-driven menu and toolbar refresh code paths.
final class MenuRefreshUITests: ShichiZipUITestCase {
    func testLanguageSwitchRefreshesMenuAndToolbar() {
        let window = fileManagerWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Open Settings via Tools menu
        app.menuBars.menuBarItems["Tools"].click()
        app.menuBars.menuBarItems["Tools"].menus.menuItems.firstMatch.click()

        // Wait for the settings window language popup
        let langPopup = app.popUpButtons.matching(identifier: "settings.language").firstMatch
        XCTAssertTrue(langPopup.waitForExistence(timeout: 10),
                      "Language popup should exist in settings")

        // Remember the current language title, switch to a different one
        let originalTitle = langPopup.value as? String ?? ""
        langPopup.click()

        // Pick a different language — try Japanese, fall back to second item
        let targetItem = langPopup.menus.menuItems["日本語 – Japanese"]
        if targetItem.waitForExistence(timeout: 3) {
            targetItem.click()
        } else {
            let items = langPopup.menus.menuItems
            if items.count > 1 {
                items.element(boundBy: 1).click()
            } else {
                langPopup.typeKey(.escape, modifierFlags: [])
            }
        }

        usleep(500_000)

        // The app should not crash after language switch triggers
        // notification-driven menu rebuild + toolbar refresh
        XCTAssertTrue(app.state == .runningForeground,
                      "App should not crash after language switch")

        // Verify the settings window title changed to Japanese
        let settingsWindow = app.windows.firstMatch
        let titlePredicate = NSPredicate(format: "title CONTAINS %@", "オプション")
        let titleExpectation = XCTNSPredicateExpectation(predicate: titlePredicate, object: settingsWindow)
        wait(for: [titleExpectation], timeout: 5)

        // Switch back to original language
        let langPopup2 = app.popUpButtons.matching(identifier: "settings.language").firstMatch
        if langPopup2.exists {
            langPopup2.click()
            let restoreItem = langPopup2.menus.menuItems[originalTitle]
            if restoreItem.waitForExistence(timeout: 3) {
                restoreItem.click()
            } else {
                langPopup2.menus.menuItems.firstMatch.click()
            }
        }

        usleep(500_000)

        // Close settings window
        app.typeKey("w", modifierFlags: .command)
    }

    func testDualPaneToggleDoesNotCrash() {
        let window = fileManagerWindow
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Enable dual pane
        app.menuBars.menuBarItems["View"].click()
        let dualPaneItem = app.menuBars.menuBarItems["View"].menus.menuItems["2 Panels"]
        if dualPaneItem.waitForExistence(timeout: 3) {
            dualPaneItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        usleep(500_000)

        // Disable dual pane
        app.menuBars.menuBarItems["View"].click()
        let dualPaneItem2 = app.menuBars.menuBarItems["View"].menus.menuItems["2 Panels"]
        if dualPaneItem2.waitForExistence(timeout: 3) {
            dualPaneItem2.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        usleep(500_000)
        XCTAssertTrue(app.state == .runningForeground,
                      "App should survive dual-pane toggle")
    }
}
