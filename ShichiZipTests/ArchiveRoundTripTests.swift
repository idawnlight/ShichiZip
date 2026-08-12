// ArchiveRoundTripTests.swift
//
// End-to-end create/open/extract coverage, plus encrypted-listing and
// cancellation checks.

import os

#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import XCTest

final class ArchiveRoundTripTests: XCTestCase {
    private static let password = "round-trip-pw"

    // MARK: - Helpers

    private func writePayloads(_ payloads: [String: String],
                               into root: URL) throws -> [URL]
    {
        var urls: [URL] = []
        for (relPath, contents) in payloads.sorted(by: { $0.key < $1.key }) {
            let fileURL = root.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            urls.append(fileURL)
        }
        return urls
    }

    private func createVersionedFrameworkZipFixture(at archiveURL: URL,
                                                    in tempRoot: URL) throws -> String
    {
        let bundleName = "Payload.app"
        let frameworkRoot = tempRoot.appendingPathComponent(bundleName)
            .appendingPathComponent("Contents/Frameworks/Example.framework", isDirectory: true)
        let versionRoot = frameworkRoot.appendingPathComponent("Versions/A", isDirectory: true)
        let resourcesRoot = versionRoot.appendingPathComponent("Resources", isDirectory: true)

        try FileManager.default.createDirectory(at: resourcesRoot,
                                                withIntermediateDirectories: true)
        try "framework-binary".write(to: versionRoot.appendingPathComponent("Example"),
                                     atomically: true,
                                     encoding: .utf8)
        try "resource".write(to: resourcesRoot.appendingPathComponent("asset.txt"),
                             atomically: true,
                             encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: frameworkRoot.appendingPathComponent("Versions/Current").path,
                                                   withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: frameworkRoot.appendingPathComponent("Example").path,
                                                   withDestinationPath: "Versions/Current/Example")
        try FileManager.default.createSymbolicLink(atPath: frameworkRoot.appendingPathComponent("Resources").path,
                                                   withDestinationPath: "Versions/Current/Resources")

        let frameworkEntryPath = "\(bundleName)/Contents/Frameworks/Example.framework"
        try createZipFixture(at: archiveURL,
                             currentDirectory: tempRoot,
                             entryPaths: [
                                 bundleName,
                                 "\(bundleName)/Contents",
                                 "\(bundleName)/Contents/Frameworks",
                                 frameworkEntryPath,
                             ])
        try createZipFixture(at: archiveURL,
                             currentDirectory: tempRoot,
                             entryPaths: ["\(frameworkEntryPath)/Versions"],
                             recursive: true,
                             preserveSymlinks: true)
        try createZipFixture(at: archiveURL,
                             currentDirectory: tempRoot,
                             entryPaths: [
                                 "\(frameworkEntryPath)/Example",
                                 "\(frameworkEntryPath)/Resources",
                             ],
                             preserveSymlinks: true)

        return bundleName
    }

    private func assertVersionedFrameworkSymlinksPreserved(in extractedRoot: URL,
                                                           bundleName: String) throws
    {
        let frameworkRoot = extractedRoot.appendingPathComponent(bundleName)
            .appendingPathComponent("Contents/Frameworks/Example.framework", isDirectory: true)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: frameworkRoot.appendingPathComponent("Example").path),
                       "Versions/Current/Example")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: frameworkRoot.appendingPathComponent("Resources").path),
                       "Versions/Current/Resources")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: frameworkRoot.appendingPathComponent("Versions/Current").path),
                       "A")

        let binary = try String(contentsOf: frameworkRoot.appendingPathComponent("Example"),
                                encoding: .utf8)
        XCTAssertEqual(binary, "framework-binary")
    }

    private func withCompressionWorkDir(mode: Int,
                                        path: String,
                                        removableOnly: Bool,
                                        _ body: () throws -> Void) throws
    {
        let defaults = SZSharedUserDefaults.defaults
        let keys: [SZSettingsKey] = [.workDirMode, .workDirPath, .workDirRemovableOnly]
        let previousValues = keys.map { ($0.rawValue, defaults.object(forKey: $0.rawValue)) }
        defaults.set(mode, forKey: SZSettingsKey.workDirMode.rawValue)
        defaults.set(path, forKey: SZSettingsKey.workDirPath.rawValue)
        defaults.set(removableOnly, forKey: SZSettingsKey.workDirRemovableOnly.rawValue)
        defer {
            for (key, value) in previousValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }

    // MARK: - Unencrypted round-trip

    func testUnencrypted7zRoundTripPreservesPayloadBytes() throws {
        let tempRoot = try makeTemporaryDirectory(named: "roundtrip-7z")
        // Build the source tree inside a single subdirectory so the
        // archive preserves the hierarchy under a stable root. Passing
        // individual files would flatten them under .relativePaths.
        let sourceRoot = tempRoot.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot,
                                                withIntermediateDirectories: true)
        let payloads = [
            "a.txt": "first payload",
            "nested/b.txt": "second payload — with unicode é 🔒",
        ]
        _ = try writePayloads(payloads, into: sourceRoot)
        let archiveURL = tempRoot.appendingPathComponent("out.7z")

        try createArchive(at: archiveURL, from: [sourceRoot])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let listedPaths = Set(archive.entries().map(\.path))
        let expected: Set = ["src/a.txt", "src/nested/b.txt"]
        XCTAssertTrue(listedPaths.isSuperset(of: expected),
                      "listing must contain every payload we wrote; got \(listedPaths)")

        let extractDir = tempRoot.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let settings = SZExtractionSettings()
        settings.pathMode = .fullPaths
        try archive.extract(toPath: extractDir.path,
                            settings: settings,
                            session: nil)

        for (relPath, contents) in payloads {
            let extractedURL = extractDir.appendingPathComponent("src")
                .appendingPathComponent(relPath)
            let roundTripped = try String(contentsOf: extractedURL, encoding: .utf8)
            XCTAssertEqual(roundTripped, contents,
                           "byte-for-byte mismatch on extracted src/\(relPath)")
        }
    }

    func testCreatingArchiveCreatesSpecifiedWorkingDirectory() throws {
        let tempRoot = try makeTemporaryDirectory(named: "roundtrip-create-workdir")
        let sourceRoot = tempRoot.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot,
                                                withIntermediateDirectories: true)
        try "payload".write(to: sourceRoot.appendingPathComponent("payload.txt"),
                            atomically: true,
                            encoding: .utf8)
        let archiveURL = tempRoot.appendingPathComponent("out.7z")
        let workingDir = tempRoot
            .appendingPathComponent("configured-workdir", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)

        try withCompressionWorkDir(mode: 2,
                                   path: workingDir.path,
                                   removableOnly: false)
        {
            try createArchive(at: archiveURL, from: [sourceRoot])
        }

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingDir.path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testCreatingArchiveFailsWhenSpecifiedWorkingDirectoryCannotBeCreated() throws {
        let tempRoot = try makeTemporaryDirectory(named: "roundtrip-create-invalid-workdir")
        let sourceRoot = tempRoot.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot,
                                                withIntermediateDirectories: true)
        try "payload".write(to: sourceRoot.appendingPathComponent("payload.txt"),
                            atomically: true,
                            encoding: .utf8)
        let archiveURL = tempRoot.appendingPathComponent("out.7z")
        let blockingFile = tempRoot.appendingPathComponent("not-a-directory")
        try "blocker".write(to: blockingFile, atomically: true, encoding: .utf8)
        let invalidWorkingDir = blockingFile.appendingPathComponent("child", isDirectory: true)

        try withCompressionWorkDir(mode: 2,
                                   path: invalidWorkingDir.path,
                                   removableOnly: false)
        {
            XCTAssertThrowsError(try createArchive(at: archiveURL, from: [sourceRoot]))
        }
    }

    func testCreatingArchiveFromAbsoluteSourcesPreservesCommonParentRelativePaths() throws {
        let tempRoot = try makeTemporaryDirectory(named: "roundtrip-create-common-parent")
        let sourceURLs = try writePayloads([
            "folder-a/alpha.txt": "alpha",
            "folder-a/payload.txt": "first",
            "folder-b/payload.txt": "second",
        ], into: tempRoot)
        let archiveURL = tempRoot.appendingPathComponent("out.7z")

        let settings = SZCompressionSettings()
        settings.pathMode = .relativePaths

        try SZArchive.create(atPath: archiveURL.path,
                             fromPaths: sourceURLs.map(\.path),
                             settings: settings,
                             session: nil)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let listedPaths = Set(archive.entries().map(\.path))
        XCTAssertTrue(listedPaths.contains("folder-a/alpha.txt"),
                      "unique leaves from nested parents should retain their parent path; got \(listedPaths)")
        XCTAssertTrue(listedPaths.contains("folder-a/payload.txt"),
                      "first duplicate leaf should retain enough parent path; got \(listedPaths)")
        XCTAssertTrue(listedPaths.contains("folder-b/payload.txt"),
                      "second duplicate leaf should retain enough parent path; got \(listedPaths)")

        let extractDir = tempRoot.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let extractionSettings = SZExtractionSettings()
        extractionSettings.pathMode = .fullPaths
        try archive.extract(toPath: extractDir.path,
                            settings: extractionSettings,
                            session: nil)

        XCTAssertEqual(try String(contentsOf: extractDir.appendingPathComponent("folder-a/alpha.txt"),
                                  encoding: .utf8),
                       "alpha")
        XCTAssertEqual(try String(contentsOf: extractDir.appendingPathComponent("folder-a/payload.txt"),
                                  encoding: .utf8),
                       "first")
        XCTAssertEqual(try String(contentsOf: extractDir.appendingPathComponent("folder-b/payload.txt"),
                                  encoding: .utf8),
                       "second")
    }

    func testFATZipBackslashesCreatePathComponentsAndDirectories() throws {
        let tempRoot = try makeTemporaryDirectory(named: "roundtrip-fat-zip-backslashes")
        let entryPath = "root/nested/payload.txt"
        let sourceURL = tempRoot.appendingPathComponent(entryPath)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "payload".write(to: sourceURL, atomically: true, encoding: .utf8)

        let archiveURL = tempRoot.appendingPathComponent("fat-backslashes.zip")
        try createZipFixtureWithBackslashPath(at: archiveURL,
                                              currentDirectory: tempRoot,
                                              entryPath: entryPath,
                                              hostOS: .fat)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let entries = archive.entries()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.path, entryPath)
        XCTAssertEqual(entry.pathParts, ["root", "nested", "payload.txt"])

        let item = ArchiveItem(from: entry)
        XCTAssertEqual(item.name, "payload.txt")
        let hierarchy = ArchiveHierarchy(records: [
            ArchiveHierarchyRecord(itemIndex: 0,
                                   pathParts: item.pathParts,
                                   isDirectory: item.isDirectory),
        ])
        XCTAssertNotNil(hierarchy.directory(at: ["root", "nested"]))

        let extractDir = tempRoot.appendingPathComponent("extract-fat", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let settings = SZExtractionSettings()
        settings.pathMode = .fullPaths
        try archive.extract(toPath: extractDir.path,
                            settings: settings,
                            session: nil)

        XCTAssertEqual(
            try String(contentsOf: extractDir.appendingPathComponent(entryPath),
                       encoding: .utf8),
            "payload",
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: extractDir.appendingPathComponent("root\\nested\\payload.txt").path,
        ))
    }

    func testUnixZipBackslashesRemainLiteralFilenameCharacters() throws {
        let tempRoot = try makeTemporaryDirectory(named: "roundtrip-unix-zip-backslashes")
        let sourceEntryPath = "root/nested/payload.txt"
        let storedEntryPath = "root\\nested\\payload.txt"
        let sourceURL = tempRoot.appendingPathComponent(sourceEntryPath)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "payload".write(to: sourceURL, atomically: true, encoding: .utf8)

        let archiveURL = tempRoot.appendingPathComponent("unix-backslashes.zip")
        try createZipFixtureWithBackslashPath(at: archiveURL,
                                              currentDirectory: tempRoot,
                                              entryPath: sourceEntryPath,
                                              hostOS: .unix)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let entries = archive.entries()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.path, storedEntryPath)
        XCTAssertEqual(entry.pathParts, [storedEntryPath])

        let item = ArchiveItem(from: entry)
        XCTAssertEqual(item.name, storedEntryPath)
        let hierarchy = ArchiveHierarchy(records: [
            ArchiveHierarchyRecord(itemIndex: 0,
                                   pathParts: item.pathParts,
                                   isDirectory: item.isDirectory),
        ])
        XCTAssertNil(hierarchy.directory(at: ["root"]))

        let extractDir = tempRoot.appendingPathComponent("extract-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let settings = SZExtractionSettings()
        settings.pathMode = .fullPaths
        try archive.extract(toPath: extractDir.path,
                            settings: settings,
                            session: nil)

        XCTAssertEqual(
            try String(contentsOf: extractDir.appendingPathComponent(storedEntryPath),
                       encoding: .utf8),
            "payload",
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: extractDir.appendingPathComponent(sourceEntryPath).path,
        ))
    }

    func testExtractingZipPreservesVersionedFrameworkSymlinks() throws {
        let tempRoot = try makeTemporaryDirectory(named: "roundtrip-zip-framework-symlinks")
        let archiveURL = tempRoot.appendingPathComponent("framework.zip")
        let bundleName = try createVersionedFrameworkZipFixture(at: archiveURL,
                                                                in: tempRoot)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let extractDir = tempRoot.appendingPathComponent("extract-all", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let settings = SZExtractionSettings()
        settings.pathMode = .fullPaths
        try archive.extract(toPath: extractDir.path,
                            settings: settings,
                            session: nil)

        try assertVersionedFrameworkSymlinksPreserved(in: extractDir,
                                                      bundleName: bundleName)
    }

    func testExtractingSelectedZipEntriesPreservesVersionedFrameworkSymlinks() throws {
        let tempRoot = try makeTemporaryDirectory(named: "roundtrip-zip-selected-framework-symlinks")
        let archiveURL = tempRoot.appendingPathComponent("framework.zip")
        let bundleName = try createVersionedFrameworkZipFixture(at: archiveURL,
                                                                in: tempRoot)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let extractDir = tempRoot.appendingPathComponent("extract-selected", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let settings = SZExtractionSettings()
        settings.pathMode = .fullPaths
        let indices = archive.entries().map { NSNumber(value: $0.index) }
        try archive.extractEntries(indices,
                                   toPath: extractDir.path,
                                   settings: settings,
                                   session: nil)

        try assertVersionedFrameworkSymlinksPreserved(in: extractDir,
                                                      bundleName: bundleName)
    }

    func testExtractingZipRejectsUnsafeParentTraversalSymlink() throws {
        let tempRoot = try makeTemporaryDirectory(named: "roundtrip-zip-unsafe-symlink")
        let archiveURL = tempRoot.appendingPathComponent("unsafe.zip")
        let bundleName = "Payload.app"
        let bundleRoot = tempRoot.appendingPathComponent(bundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bundleRoot.appendingPathComponent("traversal-link").path,
                                                   withDestinationPath: "../../shichizip-unsafe-target")
        try createZipFixture(at: archiveURL,
                             currentDirectory: tempRoot,
                             entryPaths: [bundleName],
                             recursive: true,
                             preserveSymlinks: true)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let extractDir = tempRoot.appendingPathComponent("extract-unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let settings = SZExtractionSettings()
        settings.pathMode = .fullPaths
        XCTAssertThrowsError(try archive.extract(toPath: extractDir.path,
                                                 settings: settings,
                                                 session: nil))
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(
            atPath: extractDir.appendingPathComponent(bundleName)
                .appendingPathComponent("traversal-link").path,
        ))
    }

    func testOpeningAndExtractingZipPreservesNonBMPFilenames() throws {
        let tempRoot = try makeTemporaryDirectory(named: "roundtrip-nonbmp-zip")
        let sourceRoot = tempRoot.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot,
                                                withIntermediateDirectories: true)
        let payloads = [
            "emoji-🔒.txt": "emoji filename payload",
            "nested/han-𠜎.txt": "han extension-b filename payload",
        ]
        _ = try writePayloads(payloads, into: sourceRoot)
        let archiveURL = tempRoot.appendingPathComponent("out.zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-X", "-r", archiveURL.path, "src"]
        process.currentDirectoryURL = tempRoot
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "/usr/bin/zip failed to create the test fixture")

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: nil)
        defer { archive.close() }

        let listedPaths = Set(archive.entries().map(\.path))
        let expected: Set = ["src/emoji-🔒.txt", "src/nested/han-𠜎.txt"]
        XCTAssertTrue(listedPaths.isSuperset(of: expected),
                      "listing must preserve non-BMP file names; got \(listedPaths)")

        let extractDir = tempRoot.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir,
                                                withIntermediateDirectories: true)
        let settings = SZExtractionSettings()
        settings.pathMode = .fullPaths
        try archive.extract(toPath: extractDir.path,
                            settings: settings,
                            session: nil)

        for (relPath, contents) in payloads {
            let extractedURL = extractDir.appendingPathComponent("src")
                .appendingPathComponent(relPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: extractedURL.path),
                          "expected extracted file at \(extractedURL.path)")
            let roundTripped = try String(contentsOf: extractedURL, encoding: .utf8)
            XCTAssertEqual(roundTripped, contents,
                           "byte-for-byte mismatch on extracted src/\(relPath)")
        }
    }

    // MARK: - Positive-password open

    /// Covers the positive password path, not just wrong-password errors.
    func testOpeningEncrypted7zWithCorrectPasswordSucceeds() throws {
        let archiveURL = try makeArchive(named: "pos-open",
                                         payloadFileName: "hello.txt",
                                         payloadContents: "hello world",
                                         password: Self.password)

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path,
                         password: Self.password,
                         session: nil)
        defer { archive.close() }

        XCTAssertEqual(archive.entryCount, 1)
        let entries = archive.entries()
        XCTAssertEqual(entries.first?.path, "hello.txt")
        XCTAssertTrue(entries.first?.isEncrypted ?? false,
                      "payload in a password-protected 7z must be marked encrypted")
    }

    // MARK: - Encrypted-filenames listing

    /// `encryptFileNames` archives need a password before listing entries.
    func testEncryptedFileNamesListingRequiresPassword() throws {
        let archiveURL = try makeArchive(named: "enc-filenames",
                                         payloadFileName: "top-secret.txt",
                                         payloadContents: "classified",
                                         password: Self.password,
                                         encryptFileNames: true)

        // Use an empty session so the test never opens a UI prompt.
        do {
            let archive = SZArchive()
            let headlessSession = SZOperationSession()
            XCTAssertThrowsError(
                try archive.open(atPath: archiveURL.path,
                                 session: headlessSession),
                "opening an encryptFileNames=true archive without a password must error",
            )
            archive.close()
        }

        // Keep this headless too so any stray re-prompts fail instead of showing UI.
        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path,
                         password: Self.password,
                         session: SZOperationSession())
        defer { archive.close() }

        let names = archive.entries().map(\.path)
        XCTAssertEqual(names, ["top-secret.txt"])
        XCTAssertTrue(archive.entries().allSatisfy(\.isEncrypted),
                      "every entry in an encryptFileNames archive must be marked encrypted")
    }

    // MARK: - Session cancellation

    private enum CancellationTestFailure: Error {
        case cancellationNotObserved
    }

    /// requestCancel should flip the flag immediately and keep it set until cleared.
    func testSessionCancellationFlagIsSetSynchronouslyAndCleared() {
        let session = SZOperationSession()
        XCTAssertFalse(session.shouldCancel(),
                       "fresh session must not report cancellation")
        XCTAssertFalse(session.isCancellationRequested)

        session.requestCancel()
        XCTAssertTrue(session.shouldCancel(),
                      "shouldCancel must flip synchronously after requestCancel")
        XCTAssertTrue(session.isCancellationRequested)

        // requestCancel is idempotent and thread-safe.
        session.requestCancel()
        XCTAssertTrue(session.shouldCancel())

        session.clearCancellationRequest()
        XCTAssertFalse(session.shouldCancel(),
                       "clearCancellationRequest must reset shouldCancel")
        XCTAssertFalse(session.isCancellationRequested)
    }

    /// Cancellation should be visible across threads without a main-queue hop.
    func testSessionCancellationIsVisibleAcrossThreads() {
        let session = SZOperationSession()
        let observed = expectation(description: "reader saw cancellation")

        let reader = DispatchQueue.global(qos: .userInitiated)
        reader.async {
            // Spin for at most 2 seconds waiting for the flag.
            let deadline = Date(timeIntervalSinceNow: 2)
            while Date() < deadline {
                if session.shouldCancel() {
                    observed.fulfill()
                    return
                }
            }
        }

        // Give the reader a head start, then flip the flag from a
        // different queue.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.02) {
            session.requestCancel()
        }

        wait(for: [observed], timeout: 3.0)
    }

    func testTaskCancellationRequestsOperationSessionCancellation() async {
        let workStarted = expectation(description: "archive operation work started")
        let workDidStart = OSAllocatedUnfairLock(initialState: false)
        let cancellationCheckGate = DispatchSemaphore(value: 0)

        let task = Task { @MainActor in
            try await ArchiveOperationRunner.run(operationTitle: "Testing cancellation",
                                                 deferredDisplay: true)
            { session in
                workDidStart.withLock { $0 = true }
                workStarted.fulfill()
                cancellationCheckGate.wait()

                guard session.shouldCancel() else {
                    throw CancellationTestFailure.cancellationNotObserved
                }
                throw CancellationError()
            }
        }

        await fulfillment(of: [workStarted], timeout: 10)
        guard workDidStart.withLock({ $0 }) else {
            task.cancel()
            cancellationCheckGate.signal()
            _ = try? await task.value
            return
        }

        task.cancel()
        cancellationCheckGate.signal()

        do {
            try await task.value
            XCTFail("cancelled archive operation unexpectedly completed")
        } catch is CancellationError {
            // Expected: the worker observed the session cancellation requested by the Swift task.
        } catch {
            XCTFail("cancelled archive operation failed with unexpected error: \(error)")
        }
    }

    #if SHICHIZIP_ZS_VARIANT
        func testNestedZstdPayloadCanBeExtractedRepeatedly() throws {
            let tempRoot = try makeTemporaryDirectory(named: "nested-zstd-repeat-extract")
            let sourceRoot = tempRoot.appendingPathComponent("source", isDirectory: true)
            let payloadURL = sourceRoot.appendingPathComponent("payload.txt")
            let cpioURL = tempRoot.appendingPathComponent("payload.cpio")
            let zstdURL = tempRoot.appendingPathComponent("data.tar.zst")
            let debianBinaryURL = tempRoot.appendingPathComponent("debian-binary")
            let debURL = tempRoot.appendingPathComponent("payload.deb")
            try FileManager.default.createDirectory(at: sourceRoot,
                                                    withIntermediateDirectories: true)
            try "payload".write(to: payloadURL,
                                atomically: true,
                                encoding: .utf8)
            try createCpioFixture(at: cpioURL,
                                  currentDirectory: sourceRoot,
                                  entryPaths: ["payload.txt"])
            // The test bridging header doesn't inherit the Swift-only ZS condition.
            let zstdFormat = try XCTUnwrap(
                SZArchiveFormat(rawValue: SZArchiveFormat.formatWim.rawValue + 1),
            )
            try createArchive(at: zstdURL,
                              from: [cpioURL],
                              format: zstdFormat)
            try "2.0\n".write(to: debianBinaryURL,
                              atomically: true,
                              encoding: .utf8)
            try createArFixture(at: debURL,
                                currentDirectory: tempRoot,
                                entryPaths: [
                                    debianBinaryURL.lastPathComponent,
                                    zstdURL.lastPathComponent,
                                ])

            let parentArchive = SZArchive()
            try parentArchive.open(atPath: debURL.path,
                                   session: SZOperationSession())
            defer { parentArchive.close() }
            let entry = try XCTUnwrap(parentArchive.entries().first)
            XCTAssertEqual(parentArchive.formatName?.lowercased(), "zstd")
            XCTAssertEqual(parentArchive.entryCount, 1)

            for iteration in 1 ... 2 {
                let extractionRoot = tempRoot.appendingPathComponent(
                    "extract-\(iteration)",
                    isDirectory: true,
                )
                let settings = SZExtractionSettings()
                settings.pathMode = .fullPaths
                try parentArchive.extractEntries(
                    [NSNumber(value: entry.index)],
                    toPath: extractionRoot.path,
                    settings: settings,
                    session: SZOperationSession(),
                )

                let extractedURL = extractionRoot.appendingPathComponent(entry.path)
                let extractedSize = try Data(contentsOf: extractedURL).count
                let nestedArchive = SZArchive()
                do {
                    try nestedArchive.open(atPath: extractedURL.path,
                                           session: SZOperationSession())
                } catch {
                    XCTFail(
                        "Extraction \(iteration) produced \(extractedSize) bytes that could not be opened: \(error)",
                    )
                    return
                }
                let nestedPaths = Set(nestedArchive.entries().map(\.path))
                nestedArchive.close()
                XCTAssertTrue(nestedPaths.contains("payload.txt"))
            }
        }

    #endif

    func testEntryMaterializationHonorsCancelledSession() throws {
        let tempRoot = try makeTemporaryDirectory(named: "entry-materialization-cancel")
        let payloadURL = tempRoot.appendingPathComponent("payload.txt")
        let archiveURL = tempRoot.appendingPathComponent("payload.7z")
        try "payload".write(to: payloadURL, atomically: true, encoding: .utf8)
        try createArchive(at: archiveURL, from: [payloadURL])

        let archive = SZArchive()
        try archive.open(atPath: archiveURL.path, session: SZOperationSession())
        defer { archive.close() }

        let listingSession = SZOperationSession()
        listingSession.requestCancel()

        XCTAssertThrowsError(try archive.entries(with: listingSession)) { error in
            XCTAssertTrue(szIsUserCancellation(error), "expected user cancellation, got \(error)")
        }
    }
}
