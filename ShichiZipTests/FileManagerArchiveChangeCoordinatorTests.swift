@testable import ShichiZip
import Foundation
import XCTest

final class FileManagerArchiveChangeCoordinatorTests: XCTestCase {
    func testPublishPostsDecodableNotification() throws {
        let archiveURL = try makeArchive(named: "publish-decodable-notification",
                                         prefix: "ShichiZipArchiveChangeTests")
        let expectation = expectation(description: "archive change notification")
        let change = FileManagerArchiveChange(archiveURL: archiveURL,
                                              targetSubdir: "folder",
                                              selectingPaths: ["folder/file.txt"])
        var receivedChange: FileManagerArchiveChange?

        let observer = NotificationCenter.default.addObserver(forName: .fileManagerArchiveDidChange,
                                                              object: nil,
                                                              queue: nil)
        { notification in
            receivedChange = FileManagerArchiveChange(notification: notification)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        FileManagerArchiveChangeCoordinator.publish(change)

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(receivedChange, change)
    }

    func testNotificationRoundTripPreservesNormalizedArchiveChange() throws {
        let archiveURL = try makeArchive(named: "round-trip-normalization",
                                         prefix: "ShichiZipArchiveChangeTests")
        let nonStandardArchiveURL = URL(fileURLWithPath: archiveURL.deletingLastPathComponent().path
                                            + "/nested/../" + archiveURL.lastPathComponent)
        let change = FileManagerArchiveChange(archiveURL: nonStandardArchiveURL,
                                              targetSubdir: "/folder/subdir/",
                                              selectingPaths: ["/folder/subdir/file.txt/", "folder/subdir/dir/"],
                                              sourceIdentifier: ObjectIdentifier(self))

        let notification = Notification(name: .fileManagerArchiveDidChange,
                                        object: nil,
                                        userInfo: change.notificationUserInfo)

        let decoded = FileManagerArchiveChange(notification: notification)

        XCTAssertEqual(decoded?.archiveURL, archiveURL.standardizedFileURL)
        XCTAssertEqual(decoded?.targetSubdir, "folder/subdir")
        XCTAssertEqual(decoded?.selectingPaths, ["folder/subdir/file.txt", "folder/subdir/dir"])
        XCTAssertEqual(decoded?.sourceIdentifier, ObjectIdentifier(self))
    }

    func testNotificationInitFailsWithoutArchiveURL() {
        let notification = Notification(name: .fileManagerArchiveDidChange,
                                        object: nil,
                                        userInfo: [FileManagerArchiveChangeCoordinator.targetSubdirUserInfoKey: "folder"])

        XCTAssertNil(FileManagerArchiveChange(notification: notification))
    }

    func testHandlingDecisionIgnoresChangeWithoutCurrentLocation() {
        let observer = NSObject()
        let archiveURL = URL(fileURLWithPath: "/dev/null/archive.7z")
        let change = FileManagerArchiveChange(archiveURL: archiveURL,
                                              targetSubdir: "folder",
                                              selectingPaths: ["folder/file.txt"])

        let decision = FileManagerArchiveChangeCoordinator.handlingDecision(for: change,
                                                                            currentLocation: nil,
                                                                            observerIdentifier: ObjectIdentifier(observer))

        XCTAssertEqual(decision, .ignore)
    }

    func testHandlingDecisionIgnoresDifferentArchive() throws {
        let observer = NSObject()
        let firstArchiveURL = try makeArchive(named: "ignore-different-archive-one",
                                              prefix: "ShichiZipArchiveChangeTests")
        let secondArchiveURL = try makeArchive(named: "ignore-different-archive-two",
                                               prefix: "ShichiZipArchiveChangeTests")
        let location = FileManagerCoordinatedArchiveLocation(archiveURL: firstArchiveURL,
                                                             currentSubdir: "folder")
        let change = FileManagerArchiveChange(archiveURL: secondArchiveURL,
                                              targetSubdir: "folder",
                                              selectingPaths: ["folder/file.txt"])

        let decision = FileManagerArchiveChangeCoordinator.handlingDecision(for: change,
                                                                            currentLocation: location,
                                                                            observerIdentifier: ObjectIdentifier(observer))

        XCTAssertEqual(decision, .ignore)
    }

    func testHandlingDecisionIgnoresChangeFromSameSource() throws {
        let observer = NSObject()
        let archiveURL = try makeArchive(named: "ignore-same-source",
                                         prefix: "ShichiZipArchiveChangeTests")
        let location = FileManagerCoordinatedArchiveLocation(archiveURL: archiveURL,
                                                             currentSubdir: "folder")
        let change = FileManagerArchiveChange(archiveURL: archiveURL,
                                              targetSubdir: "folder",
                                              selectingPaths: ["folder/file.txt"],
                                              sourceIdentifier: ObjectIdentifier(observer))

        let decision = FileManagerArchiveChangeCoordinator.handlingDecision(for: change,
                                                                            currentLocation: location,
                                                                            observerIdentifier: ObjectIdentifier(observer))

        XCTAssertEqual(decision, .ignore)
    }

    func testHandlingDecisionReloadsMatchingArchiveAndSubdirWithSelection() throws {
        let observer = NSObject()
        let source = NSObject()
        let archiveURL = try makeArchive(named: "reload-matching-subdir",
                                         prefix: "ShichiZipArchiveChangeTests")
        let nonStandardArchiveURL = URL(fileURLWithPath: archiveURL.deletingLastPathComponent().path
                                            + "/child/../" + archiveURL.lastPathComponent)
        let location = FileManagerCoordinatedArchiveLocation(archiveURL: archiveURL,
                                                             currentSubdir: "/folder/subdir/")
        let change = FileManagerArchiveChange(archiveURL: nonStandardArchiveURL,
                                              targetSubdir: "folder/subdir",
                                              selectingPaths: ["/folder/subdir/file.txt/", "folder/subdir/child/"],
                                              sourceIdentifier: ObjectIdentifier(source))

        let decision = FileManagerArchiveChangeCoordinator.handlingDecision(for: change,
                                                                            currentLocation: location,
                                                                            observerIdentifier: ObjectIdentifier(observer))

        XCTAssertEqual(decision, .reload(selectingPaths: ["folder/subdir/file.txt", "folder/subdir/child"]))
    }

    func testHandlingDecisionReloadsMatchingArchiveWithoutSelectionForDifferentSubdir() throws {
        let observer = NSObject()
        let source = NSObject()
        let archiveURL = try makeArchive(named: "reload-different-subdir",
                                         prefix: "ShichiZipArchiveChangeTests")
        let location = FileManagerCoordinatedArchiveLocation(archiveURL: archiveURL,
                                                             currentSubdir: "folder/other")
        let change = FileManagerArchiveChange(archiveURL: archiveURL,
                                              targetSubdir: "folder/subdir",
                                              selectingPaths: ["folder/subdir/file.txt"],
                                              sourceIdentifier: ObjectIdentifier(source))

        let decision = FileManagerArchiveChangeCoordinator.handlingDecision(for: change,
                                                                            currentLocation: location,
                                                                            observerIdentifier: ObjectIdentifier(observer))

        XCTAssertEqual(decision, .reload(selectingPaths: []))
    }

    func testHandlingDecisionReloadsWhenChangeHasNoSourceIdentifier() throws {
        let observer = NSObject()
        let archiveURL = try makeArchive(named: "reload-without-source-identifier",
                                         prefix: "ShichiZipArchiveChangeTests")
        let location = FileManagerCoordinatedArchiveLocation(archiveURL: archiveURL,
                                                             currentSubdir: "folder")
        let change = FileManagerArchiveChange(archiveURL: archiveURL,
                                              targetSubdir: "folder",
                                              selectingPaths: ["folder/file.txt"])

        let decision = FileManagerArchiveChangeCoordinator.handlingDecision(for: change,
                                                                            currentLocation: location,
                                                                            observerIdentifier: ObjectIdentifier(observer))

        XCTAssertEqual(decision, .reload(selectingPaths: ["folder/file.txt"]))
    }
}
