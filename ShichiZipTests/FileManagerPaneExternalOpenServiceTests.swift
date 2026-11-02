import AppKit
import XCTest
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

@MainActor
final class FileManagerPaneExternalOpenServiceTests: XCTestCase {
    func testOpenIfPossibleReturnsFalseWhenNoExternalApplicationIsAvailable() {
        var didOpen = false
        let service = makeService(defaultApplicationURL: { _ in nil },
                                  applicationOpener: { _, _, _, _ in didOpen = true })

        XCTAssertFalse(service.openIfPossible(URL(fileURLWithPath: "/tmp/payload.txt")))

        XCTAssertFalse(didOpen)
    }

    func testOpenIfPossibleUsesResolvedExternalApplication() {
        let fileURL = URL(fileURLWithPath: "/tmp/payload.txt")
        let applicationURL = URL(fileURLWithPath: "/Applications/TextEdit.app")
        var openedRequest: ExternalOpenRequest?
        let service = makeService(defaultApplicationURL: { url in
            XCTAssertEqual(url, fileURL)
            return applicationURL
        }, applicationOpener: { url, applicationURL, configuration, completion in
            openedRequest = ExternalOpenRequest(url: url,
                                                applicationURL: applicationURL,
                                                configuration: configuration,
                                                completion: completion)
        })

        XCTAssertTrue(service.openIfPossible(fileURL))

        XCTAssertEqual(openedRequest?.url, fileURL)
        XCTAssertEqual(openedRequest?.applicationURL, applicationURL)
        XCTAssertNotNil(openedRequest?.configuration)
    }

    func testSuccessfulExternalOpenTransfersTemporaryDirectoryCleanupToApplicationTermination() {
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/staged-open", isDirectory: true)
        var openedRequest: ExternalOpenRequest?
        var scheduledCleanup: (url: URL, application: NSRunningApplication)?
        let didScheduleCleanup = expectation(description: "temporary directory cleanup scheduled")
        let service = makeService(applicationOpener: { url, applicationURL, configuration, completion in
            openedRequest = ExternalOpenRequest(url: url,
                                                applicationURL: applicationURL,
                                                configuration: configuration,
                                                completion: completion)
        }, scheduleCleanup: { url, application in
            scheduledCleanup = (url, application)
            didScheduleCleanup.fulfill()
        }, cleanupTemporaryDirectory: { _ in
            XCTFail("Successful external open must transfer cleanup instead of removing immediately")
        })

        XCTAssertTrue(service.open(URL(fileURLWithPath: "/tmp/payload.txt"),
                                   withApplicationAt: URL(fileURLWithPath: "/Applications/TextEdit.app"),
                                   preservingTemporaryDirectory: temporaryDirectory))
        openedRequest?.completion(NSRunningApplication.current, nil)

        wait(for: [didScheduleCleanup], timeout: 1)
        XCTAssertEqual(scheduledCleanup?.url, temporaryDirectory)
        XCTAssertEqual(scheduledCleanup?.application.processIdentifier,
                       NSRunningApplication.current.processIdentifier)
    }

    func testFailedExternalOpenCleansTemporaryDirectoryAndShowsUnsuppressedError() {
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/staged-open", isDirectory: true)
        let openError = NSError(domain: NSCocoaErrorDomain,
                                code: NSFileNoSuchFileError)
        var openedRequest: ExternalOpenRequest?
        var cleanedTemporaryDirectory: URL?
        var presentedError: NSError?
        let didCleanup = expectation(description: "temporary directory cleaned")
        let didShowError = expectation(description: "external open error shown")
        let service = makeService(applicationOpener: { url, applicationURL, configuration, completion in
            openedRequest = ExternalOpenRequest(url: url,
                                                applicationURL: applicationURL,
                                                configuration: configuration,
                                                completion: completion)
        }, cleanupTemporaryDirectory: { url in
            cleanedTemporaryDirectory = url
            didCleanup.fulfill()
        }, showError: { error in
            presentedError = error as NSError
            didShowError.fulfill()
        })

        XCTAssertTrue(service.open(URL(fileURLWithPath: "/tmp/payload.txt"),
                                   withApplicationAt: URL(fileURLWithPath: "/Applications/TextEdit.app"),
                                   preservingTemporaryDirectory: temporaryDirectory))
        openedRequest?.completion(nil, openError)

        wait(for: [didCleanup, didShowError], timeout: 1)
        XCTAssertEqual(cleanedTemporaryDirectory, temporaryDirectory)
        XCTAssertEqual(presentedError, openError)
    }

    func testCancelledExternalOpenCleansTemporaryDirectoryWithoutShowingError() {
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/staged-open", isDirectory: true)
        let cancellationError = NSError(domain: NSCocoaErrorDomain,
                                        code: NSUserCancelledError)
        var openedRequest: ExternalOpenRequest?
        let didCleanup = expectation(description: "temporary directory cleaned")
        let didShowError = expectation(description: "cancelled open should not show error")
        didShowError.isInverted = true
        let service = makeService(applicationOpener: { url, applicationURL, configuration, completion in
            openedRequest = ExternalOpenRequest(url: url,
                                                applicationURL: applicationURL,
                                                configuration: configuration,
                                                completion: completion)
        }, cleanupTemporaryDirectory: { _ in
            didCleanup.fulfill()
        }, showError: { _ in
            didShowError.fulfill()
        })

        XCTAssertTrue(service.open(URL(fileURLWithPath: "/tmp/payload.txt"),
                                   withApplicationAt: URL(fileURLWithPath: "/Applications/TextEdit.app"),
                                   preservingTemporaryDirectory: temporaryDirectory))
        openedRequest?.completion(nil, cancellationError)

        wait(for: [didCleanup], timeout: 1)
        wait(for: [didShowError], timeout: 0.1)
    }

    func testUnavailableExternalOpenErrorIncludesItemName() {
        let service = makeService()
        let error = service.unavailableExternalOpenError(for: "payload.txt")

        XCTAssertEqual(error.domain, SZArchiveErrorDomain)
        XCTAssertEqual(error.code, -1)
        XCTAssertTrue(error.localizedDescription.contains("payload.txt"))
    }

    private func makeService(defaultApplicationURL: @escaping (URL) -> URL? = { _ in URL(fileURLWithPath: "/Applications/TextEdit.app") },
                             applicationOpener: @escaping FileManagerPaneExternalOpenService.ApplicationOpener = { _, _, _, _ in },
                             scheduleCleanup: @escaping (URL, NSRunningApplication) -> Void = { _, _ in },
                             cleanupTemporaryDirectory: @escaping (URL) -> Void = { _ in },
                             showError: @escaping (Error) -> Void = { error in XCTFail("Unexpected external open error: \(error)") }) -> FileManagerPaneExternalOpenService
    {
        FileManagerPaneExternalOpenService(defaultApplicationURL: defaultApplicationURL,
                                           applicationOpener: applicationOpener,
                                           scheduleCleanup: scheduleCleanup,
                                           cleanupTemporaryDirectory: cleanupTemporaryDirectory,
                                           showError: showError)
    }
}

private struct ExternalOpenRequest {
    let url: URL
    let applicationURL: URL
    let configuration: NSWorkspace.OpenConfiguration
    let completion: FileManagerPaneExternalOpenService.OpenCompletion
}
