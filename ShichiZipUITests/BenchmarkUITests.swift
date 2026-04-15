import XCTest

/// Tests for the Benchmark window opened from the Tools menu.
final class BenchmarkUITests: ShichiZipUITestCase {
    /// Opens the benchmark window, verifies all controls exist,
    /// and confirms the benchmark auto-starts (stop button becomes enabled).
    func testBenchmarkWindowOpensAndAutoStarts() {
        app.menuBars.menuBarItems["Tools"].click()
        app.menuBars.menuBarItems["Tools"].menus.menuItems["Benchmark"].click()

        let dictPopup = app.popUpButtons.matching(identifier: "benchmark.dictionary").firstMatch
        XCTAssertTrue(dictPopup.waitForExistence(timeout: 10),
                      "Benchmark dictionary popup should appear")

        let threadsPopup = app.popUpButtons.matching(identifier: "benchmark.threads").firstMatch
        XCTAssertTrue(threadsPopup.exists, "Threads popup should exist")

        let passesPopup = app.popUpButtons.matching(identifier: "benchmark.passes").firstMatch
        XCTAssertTrue(passesPopup.exists, "Passes popup should exist")

        let memoryLabel = app.staticTexts.matching(identifier: "benchmark.memoryLabel").firstMatch
        XCTAssertTrue(memoryLabel.exists, "Memory label should exist")

        let restartBtn = app.buttons.matching(identifier: "benchmark.restartButton").firstMatch
        XCTAssertTrue(restartBtn.exists, "Restart button should exist")

        let stopBtn = app.buttons.matching(identifier: "benchmark.stopButton").firstMatch
        XCTAssertTrue(stopBtn.exists, "Stop button should exist")

        // The stop button becomes enabled once benchmarking is running.
        let enabledPredicate = NSPredicate(format: "isEnabled == true")
        let autoStartExpectation = XCTNSPredicateExpectation(predicate: enabledPredicate, object: stopBtn)
        wait(for: [autoStartExpectation], timeout: 10)

        stopBtn.click()
    }

    /// Exercises stop, elapsed timer observation, restart, and second stop.
    func testBenchmarkStopRestartAndElapsedTimer() {
        app.menuBars.menuBarItems["Tools"].click()
        app.menuBars.menuBarItems["Tools"].menus.menuItems["Benchmark"].click()

        let stopBtn = app.buttons.matching(identifier: "benchmark.stopButton").firstMatch
        XCTAssertTrue(stopBtn.waitForExistence(timeout: 10))

        let enabledPredicate = NSPredicate(format: "isEnabled == true")
        let startExpectation = XCTNSPredicateExpectation(predicate: enabledPredicate, object: stopBtn)
        wait(for: [startExpectation], timeout: 10)

        // Verify the elapsed timer is ticking
        let elapsedLabel = app.staticTexts.matching(identifier: "benchmark.elapsedLabel").firstMatch
        if elapsedLabel.waitForExistence(timeout: 5) {
            let timerPredicate = NSPredicate(format: "value CONTAINS 's'")
            let timerExpectation = XCTNSPredicateExpectation(predicate: timerPredicate, object: elapsedLabel)
            wait(for: [timerExpectation], timeout: 10)
        }

        // Stop the benchmark
        stopBtn.click()

        // After stopping, the restart button should become enabled
        let restartBtn = app.buttons.matching(identifier: "benchmark.restartButton").firstMatch
        let restartExpectation = XCTNSPredicateExpectation(predicate: enabledPredicate, object: restartBtn)
        wait(for: [restartExpectation], timeout: 15)

        // Restart should not crash
        restartBtn.click()

        // Stop button should become enabled again
        let restartedExpectation = XCTNSPredicateExpectation(predicate: enabledPredicate, object: stopBtn)
        wait(for: [restartedExpectation], timeout: 10)

        // Stop again for a clean exit
        stopBtn.click()
    }

    func testBenchmarkCloseViaEscape() {
        app.menuBars.menuBarItems["Tools"].click()
        app.menuBars.menuBarItems["Tools"].menus.menuItems["Benchmark"].click()

        let dictPopup = app.popUpButtons.matching(identifier: "benchmark.dictionary").firstMatch
        XCTAssertTrue(dictPopup.waitForExistence(timeout: 10))

        // Press Escape to close
        app.typeKey(.escape, modifierFlags: [])

        // The benchmark controls should disappear
        XCTAssertFalse(dictPopup.waitForExistence(timeout: 3),
                       "Benchmark window should close on Escape")
    }
}
