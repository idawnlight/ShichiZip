import Observation
import os
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

@MainActor
final class SettingsObservationTests: XCTestCase {
    func testSettingsEventInvalidatesComputedReadAndExistingBinding() {
        let center = NotificationCenter(), store = SettingsStore(notificationCenter: center)
        let binding = store.boolBinding(.showHiddenFiles)
        let changes = track { _ = store.memoryLimitGB }
        let bindingChanges = track { _ = binding.wrappedValue }
        center.post(name: .szSettingsDidChange, object: nil)
        XCTAssertEqual(changes.withLock { $0 }, 1)
        XCTAssertEqual(bindingChanges.withLock { $0 }, 1)
        XCTAssertEqual(store.localizationVersion, 0)
    }

    func testLanguageEventInvalidatesLocalizationAndSettingsDependencies() {
        let center = NotificationCenter(), store = SettingsStore(notificationCenter: center)
        let settingsChanges = track { _ = store.languageOverride }
        let localizationChanges = track { _ = store.localizationVersion }
        center.post(name: .szLanguageDidChange, object: nil)
        XCTAssertEqual(settingsChanges.withLock { $0 }, 1)
        XCTAssertEqual(localizationChanges.withLock { $0 }, 1)
        XCTAssertEqual(store.localizationVersion, 1)
        let subsequent = track { _ = store.localizationVersion }
        center.post(name: .szSettingsDidChange, object: nil)
        XCTAssertEqual(subsequent.withLock { $0 }, 0)
    }

    private func track(_ read: () -> Void) -> OSAllocatedUnfairLock<Int> {
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            read()
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        return changes
    }
}
