#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerTrashOperationTests: XCTestCase {
    func testTrashItemsAttemptsEveryPathAndCollectsFailures() {
        let paths = ["/tmp/alpha.txt", "/tmp/bravo.txt", "/tmp/charlie.txt"]
        let rejectedNames: Set = ["alpha.txt", "charlie.txt"]
        var attemptedPaths: [String] = []

        let failures = FileManagerTrashOperation.trashItems(at: paths) { url in
            attemptedPaths.append(url.path)
            if rejectedNames.contains(url.lastPathComponent) {
                throw NSError(domain: NSCocoaErrorDomain,
                              code: CocoaError.fileWriteNoPermission.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
            }
        }

        XCTAssertEqual(attemptedPaths, paths)
        XCTAssertEqual(failures.map(\.url.lastPathComponent), ["alpha.txt", "charlie.txt"])
    }

    func testErrorSummarizesPartialTrashFailure() throws {
        let underlying = NSError(domain: NSCocoaErrorDomain,
                                 code: CocoaError.fileWriteNoPermission.rawValue,
                                 userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        let failures = [
            FileManagerTrashFailure(url: URL(fileURLWithPath: "/tmp/locked.txt"), error: underlying),
        ]

        let error = try XCTUnwrap(FileManagerTrashOperation.error(for: failures, attemptedCount: 3))

        XCTAssertTrue(error.localizedDescription.contains("1"))
        XCTAssertTrue(error.localizedFailureReason?.contains("1") == true)
        XCTAssertTrue(error.localizedFailureReason?.contains("3") == true)
        XCTAssertTrue(error.localizedRecoverySuggestion?.contains("locked.txt") == true)
        XCTAssertTrue(error.localizedRecoverySuggestion?.contains("Permission denied") == true)
        XCTAssertEqual((error.userInfo[NSUnderlyingErrorKey] as? NSError), underlying)
        XCTAssertEqual(error.userInfo[NSFilePathErrorKey] as? String, "/tmp/locked.txt")
    }
}
