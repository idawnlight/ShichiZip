import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class PathHistoryStoreTests: XCTestCase {
    func testRecordingPromotesDeduplicatesTruncatesAndHonorsCustomMatching() throws {
        let suiteName = "PathHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PathHistoryStore(defaults: defaults, entriesKey: "history")
        defaults.set((0 ..< 21).map { "/\($0)" } + ["/10"], forKey: "history")
        store.record("/10")
        XCTAssertEqual(store.entries(), ["/10"] + (0 ..< 20).filter { $0 != 10 }.map { "/\($0)" })
        defaults.set(["/destination", "/other/./folder/", "/destination/"], forKey: "history")
        store.record("/destination/", replacing: {
            URL(fileURLWithPath: $0).standardizedFileURL.path == "/destination"
        })
        XCTAssertEqual(store.entries(), ["/destination/", "/other/./folder/"])
    }
}
