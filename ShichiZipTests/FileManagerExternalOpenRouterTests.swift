import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerExternalOpenRouterTests: XCTestCase {
    func testDefaultExternalApplicationURLReturnsExternalDefault() {
        let fileURL = URL(fileURLWithPath: "/tmp/payload.txt")
        let currentApplicationURL = URL(fileURLWithPath: "/Applications/ShichiZip.app")
        let externalApplicationURL = URL(fileURLWithPath: "/Applications/TextEdit.app")

        let result = FileManagerExternalOpenRouter.defaultExternalApplicationURL(for: fileURL,
                                                                                 defaultApplicationURLProvider: { url in
                                                                                     XCTAssertEqual(url, fileURL)
                                                                                     return externalApplicationURL
                                                                                 },
                                                                                 currentApplicationURL: currentApplicationURL)

        XCTAssertEqual(result, externalApplicationURL.resolvingSymlinksInPath().standardizedFileURL)
    }

    func testDefaultExternalApplicationURLReturnsNilForCurrentApplicationDefault() {
        let fileURL = URL(fileURLWithPath: "/tmp/payload.exe")
        let currentApplicationURL = URL(fileURLWithPath: "/Applications/ShichiZip.app")

        let result = FileManagerExternalOpenRouter.defaultExternalApplicationURL(for: fileURL,
                                                                                 defaultApplicationURLProvider: { url in
                                                                                     XCTAssertEqual(url, fileURL)
                                                                                     return currentApplicationURL
                                                                                 },
                                                                                 currentApplicationURL: currentApplicationURL)

        XCTAssertNil(result)
    }
}
