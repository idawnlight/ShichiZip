import Foundation
import os
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerArchiveChangeCoordinatorTests: XCTestCase {
    func testArchiveOperationGateReportsActiveLeases() throws {
        let gate = FileManagerArchiveOperationGate()
        XCTAssertFalse(gate.hasActiveLeases)

        var firstLease: FileManagerArchiveOperationGate.Lease? = try XCTUnwrap(gate.acquireLease())
        XCTAssertNotNil(firstLease)
        XCTAssertTrue(gate.hasActiveLeases)

        var secondLease: FileManagerArchiveOperationGate.Lease? = try XCTUnwrap(gate.acquireLease())
        XCTAssertNotNil(secondLease)
        XCTAssertTrue(gate.hasActiveLeases)

        firstLease = nil
        XCTAssertTrue(gate.hasActiveLeases)

        secondLease = nil
        XCTAssertFalse(gate.hasActiveLeases)
    }

    func testArchiveOperationGateRejectsNewLeaseAfterClosingBegins() throws {
        let gate = FileManagerArchiveOperationGate()
        let lease = try XCTUnwrap(gate.acquireLease())

        gate.beginClosing()

        XCTAssertNil(gate.acquireLease())

        gate.cancelClosing()
        XCTAssertNotNil(gate.acquireLease())
        withExtendedLifetime(lease) {}
    }

    func testArchiveOperationGateWaitsForActiveLeaseBeforeClosing() throws {
        let gate = FileManagerArchiveOperationGate()
        var lease: FileManagerArchiveOperationGate.Lease? = try XCTUnwrap(gate.acquireLease())
        XCTAssertNotNil(lease)
        let didFinish = OSAllocatedUnfairLock(initialState: false)
        let closeFinished = expectation(description: "archive operation gate close finished")

        gate.beginClosing()
        DispatchQueue.global(qos: .userInitiated).async {
            gate.waitForLeasesToDrain()
            didFinish.withLock { $0 = true }
            closeFinished.fulfill()
        }

        let deadline = Date().addingTimeInterval(0.05)
        while Date() < deadline {
            if didFinish.withLock({ $0 }) {
                break
            }
            RunLoop.current.run(mode: .default,
                                before: Date().addingTimeInterval(0.005))
        }
        XCTAssertFalse(didFinish.withLock { $0 })

        lease = nil
        wait(for: [closeFinished], timeout: 1)
    }

    func testPublishPostsDecodableNotification() throws {
        let archiveURL = try makeArchive(named: "publish-decodable-notification",
                                         prefix: "ShichiZipArchiveChangeTests")
        let expectation = expectation(description: "archive change notification")
        let change = FileManagerArchiveChange(archiveURL: archiveURL,
                                              targetSubdir: "folder",
                                              selectingPaths: ["folder/file.txt"])
        let box = UncheckedSendableBox<FileManagerArchiveChange>()

        let observer = NotificationCenter.default.addObserver(forName: .fileManagerArchiveDidChange,
                                                              object: nil,
                                                              queue: nil)
        { notification in
            box.value = FileManagerArchiveChange(notification: notification)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        FileManagerArchiveChangeCoordinator.publish(change)

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(box.value, change)
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

    func testNestedArchiveIdentityStandardizesDisplayPath() {
        let identity = FileManagerNestedArchiveIdentity(displayPath: "/tmp/root.7z/folder/../folder/inner.7z")

        XCTAssertEqual(identity,
                       FileManagerNestedArchiveIdentity(displayPath: "/tmp/root.7z/folder/inner.7z"))
    }

    func testNestedArchiveConflictDetectorIgnoresSingleOpenInstance() {
        let archive = NSObject()
        let identity = FileManagerNestedArchiveIdentity(displayPath: "/tmp/root.7z/folder/inner.7z")
        let snapshots = [
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(archive),
                                                 identity: identity,
                                                 isDirty: false),
        ]

        XCTAssertFalse(FileManagerNestedArchiveConflictDetector.hasConflictingOpenInstance(for: identity,
                                                                                           in: snapshots))
    }

    func testNestedArchiveConflictDetectorDetectsDistinctArchiveObjectsWithSameIdentity() {
        let firstArchive = NSObject()
        let secondArchive = NSObject()
        let identity = FileManagerNestedArchiveIdentity(displayPath: "/tmp/root.7z/folder/inner.7z")
        let snapshots = [
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(firstArchive),
                                                 identity: identity,
                                                 isDirty: false),
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(secondArchive),
                                                 identity: identity,
                                                 isDirty: false),
        ]

        XCTAssertTrue(FileManagerNestedArchiveConflictDetector.hasConflictingOpenInstance(for: identity,
                                                                                          in: snapshots))
    }

    func testNestedArchiveConflictDetectorIgnoresDifferentNestedIdentity() {
        let firstArchive = NSObject()
        let secondArchive = NSObject()
        let targetIdentity = FileManagerNestedArchiveIdentity(displayPath: "/tmp/root.7z/folder/inner.7z")
        let snapshots = [
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(firstArchive),
                                                 identity: targetIdentity,
                                                 isDirty: true),
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(secondArchive),
                                                 identity: FileManagerNestedArchiveIdentity(displayPath: "/tmp/root.7z/folder/other.7z"),
                                                 isDirty: true),
        ]

        XCTAssertFalse(FileManagerNestedArchiveConflictDetector.hasConflictingOpenInstance(for: targetIdentity,
                                                                                           in: snapshots))
    }

    func testNestedArchiveConflictDetectorDetectsDirtyOpenInstanceWithSameIdentity() {
        let dirtyArchive = NSObject()
        let identity = FileManagerNestedArchiveIdentity(displayPath: "/tmp/root.7z/folder/inner.7z")
        let snapshots = [
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(dirtyArchive),
                                                 identity: identity,
                                                 isDirty: true),
        ]

        XCTAssertTrue(FileManagerNestedArchiveConflictDetector.hasDirtyOpenInstance(for: identity,
                                                                                    in: snapshots))
    }

    func testNestedArchiveConflictDetectorIgnoresCleanOpenInstanceForDirtyCheck() {
        let cleanArchive = NSObject()
        let identity = FileManagerNestedArchiveIdentity(displayPath: "/tmp/root.7z/folder/inner.7z")
        let snapshots = [
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(cleanArchive),
                                                 identity: identity,
                                                 isDirty: false),
        ]

        XCTAssertFalse(FileManagerNestedArchiveConflictDetector.hasDirtyOpenInstance(for: identity,
                                                                                     in: snapshots))
    }
}
