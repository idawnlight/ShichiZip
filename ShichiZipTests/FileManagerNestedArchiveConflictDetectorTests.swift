import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class FileManagerNestedArchiveConflictDetectorTests: XCTestCase {
    func testNestedArchiveIdentityStandardizesDisplayPath() {
        let identity = makeIdentity(displayPath: "/tmp/root.7z/folder/../folder/inner.7z")

        XCTAssertEqual(identity.displayPath,
                       "/tmp/root.7z/folder/inner.7z")
    }

    func testNestedArchiveIdentityUsesRootAndEntryLineageInsteadOfDisplayPath() {
        let firstDuplicate = makeIdentity(archiveIndex: 4)
        let secondDuplicate = makeIdentity(archiveIndex: 9)

        XCTAssertNotEqual(firstDuplicate, secondDuplicate)
        XCTAssertEqual(firstDuplicate,
                       makeIdentity(archiveIndex: 4,
                                    displayPath: "/tmp/another-display-name"))
    }

    func testIgnoresSingleOpenInstance() {
        let archive = NSObject()
        let identity = makeIdentity()
        let snapshots = [
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(archive),
                                                 identity: identity,
                                                 isDirty: false),
        ]

        XCTAssertFalse(FileManagerNestedArchiveConflictDetector.hasConflictingOpenInstance(for: identity,
                                                                                           in: snapshots))
    }

    func testDetectsDistinctArchiveObjectsWithSameIdentity() {
        let firstArchive = NSObject()
        let secondArchive = NSObject()
        let identity = makeIdentity()
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

    func testIgnoresDifferentNestedIdentity() {
        let firstArchive = NSObject()
        let secondArchive = NSObject()
        let targetIdentity = makeIdentity()
        let snapshots = [
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(firstArchive),
                                                 identity: targetIdentity,
                                                 isDirty: true),
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(secondArchive),
                                                 identity: makeIdentity(archiveIndex: 2,
                                                                        entryPath: "folder/other.7z",
                                                                        displayPath: "/tmp/root.7z/folder/other.7z"),
                                                 isDirty: true),
        ]

        XCTAssertFalse(FileManagerNestedArchiveConflictDetector.hasConflictingOpenInstance(for: targetIdentity,
                                                                                           in: snapshots))
    }

    func testDetectsDirtyOpenInstanceWithSameIdentity() {
        let dirtyArchive = NSObject()
        let identity = makeIdentity()
        let snapshots = [
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(dirtyArchive),
                                                 identity: identity,
                                                 isDirty: true),
        ]

        XCTAssertTrue(FileManagerNestedArchiveConflictDetector.hasDirtyOpenInstance(for: identity,
                                                                                    in: snapshots))
    }

    func testIgnoresCleanOpenInstanceForDirtyCheck() {
        let cleanArchive = NSObject()
        let identity = makeIdentity()
        let snapshots = [
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(cleanArchive),
                                                 identity: identity,
                                                 isDirty: false),
        ]

        XCTAssertFalse(FileManagerNestedArchiveConflictDetector.hasDirtyOpenInstance(for: identity,
                                                                                     in: snapshots))
    }

    func testDuplicateDisplayPathsDoNotConflictWhenRawLineageDiffers() {
        let firstArchive = NSObject()
        let secondArchive = NSObject()
        let firstDuplicate = makeIdentity(archiveIndex: 4)
        let secondDuplicate = makeIdentity(archiveIndex: 9)
        let snapshots = [
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(firstArchive),
                                                 identity: firstDuplicate,
                                                 isDirty: true),
            FileManagerNestedArchiveOpenSnapshot(archiveIdentifier: ObjectIdentifier(secondArchive),
                                                 identity: secondDuplicate,
                                                 isDirty: true),
        ]

        XCTAssertFalse(FileManagerNestedArchiveConflictDetector.hasConflictingOpenInstance(for: firstDuplicate,
                                                                                           in: snapshots))
        XCTAssertFalse(FileManagerNestedArchiveConflictDetector.hasDirtyOpenInstance(for: makeIdentity(archiveIndex: 12),
                                                                                     in: snapshots))
    }

    func testRootIdentityConflictsWithAnyOpenNestedDescendant() {
        let nestedArchive = NSObject()
        let descendant = makeIdentity(archiveIndex: 4)
        let snapshots = [
            FileManagerNestedArchiveOpenSnapshot(
                archiveIdentifier: ObjectIdentifier(nestedArchive),
                identity: descendant,
                isDirty: false,
            ),
        ]
        let root = FileManagerNestedArchiveIdentity.root(
            topLevelArchiveURL: descendant.topLevelArchiveURL,
        )

        XCTAssertTrue(FileManagerNestedArchiveConflictDetector.hasConflictingOpenInstance(for: root,
                                                                                          in: snapshots))
        XCTAssertFalse(FileManagerNestedArchiveConflictDetector.hasDirtyOpenInstance(for: root,
                                                                                     in: snapshots))
    }

    func testRootIdentityDoesNotConflictWithDifferentTopLevelArchive() {
        let nestedArchive = NSObject()
        let snapshots = [
            FileManagerNestedArchiveOpenSnapshot(
                archiveIdentifier: ObjectIdentifier(nestedArchive),
                identity: makeIdentity(),
                isDirty: true,
            ),
        ]
        let otherRoot = FileManagerNestedArchiveIdentity.root(
            topLevelArchiveURL: URL(fileURLWithPath: "/tmp/other.7z"),
        )

        XCTAssertFalse(FileManagerNestedArchiveConflictDetector.hasConflictingOpenInstance(for: otherRoot,
                                                                                           in: snapshots))
        XCTAssertFalse(FileManagerNestedArchiveConflictDetector.hasDirtyOpenInstance(for: otherRoot,
                                                                                     in: snapshots))
    }

    private func makeIdentity(
        archiveIndex: Int = 1,
        entryPath: String = "folder/inner.7z",
        displayPath: String = "/tmp/root.7z/folder/inner.7z",
    ) -> FileManagerNestedArchiveIdentity {
        FileManagerNestedArchiveIdentity(
            topLevelArchiveURL: URL(fileURLWithPath: "/tmp/root.7z"),
            entryLineage: [
                FileManagerNestedArchiveIdentity.Entry(archiveIndex: archiveIndex,
                                                       path: entryPath,
                                                       isDirectory: false),
            ],
            displayPath: displayPath,
        )
    }
}
