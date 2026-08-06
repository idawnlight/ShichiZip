import Foundation
import XCTest

/// A mutable box that can be captured in `@Sendable` closures.
/// Only for use in tests where the access pattern is sequential
/// (write in callback, read after `wait(for:)`).
final class UncheckedSendableBox<T>: @unchecked Sendable {
    var value: T?
}

extension XCTestCase {
    func skipIfAffectedByIsolatedDeinitTaskLocalRuntimeBug() throws {
        // https://github.com/swiftlang/swift/issues/85663
        // Fixed in https://github.com/swiftlang/swift/pull/85204 but only released with Swift 6.3+, so skip affected macOS 26.0-26.3 runtimes.
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion == 26, version.minorVersion < 4 else { return }
        throw XCTSkip("macOS 26.0-26.3 system Swift runtime crashes when isolated deinit tears down fallback task locals.")
    }

    @discardableResult
    func makeTemporaryDirectory(named name: String,
                                prefix: String = "ShichiZipTests") throws -> URL
    {
        let sanitizedName = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(sanitizedName)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func createArchive(at archiveURL: URL,
                       from sourceURLs: [URL],
                       format: SZArchiveFormat = .format7z,
                       pathMode: SZCompressionPathMode = .relativePaths,
                       password: String? = nil,
                       encryptFileNames: Bool = false) throws
    {
        let settings = SZCompressionSettings()
        settings.format = format
        settings.pathMode = pathMode
        settings.password = password
        settings.encryptFileNames = encryptFileNames

        try SZArchive.create(atPath: archiveURL.path,
                             fromPaths: sourceURLs.map(\.path),
                             settings: settings,
                             session: nil)
    }

    func createCpioFixture(at archiveURL: URL,
                           currentDirectory: URL,
                           entryPaths: [String]) throws
    {
        FileManager.default.createFile(atPath: archiveURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: archiveURL)
        defer { try? outputHandle.close() }

        let inputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/cpio")
        process.arguments = ["-o", "-H", "newc"]
        process.currentDirectoryURL = currentDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        try process.run()

        let input = Data((entryPaths.joined(separator: "\n") + "\n").utf8)
        try inputPipe.fileHandleForWriting.write(contentsOf: input)
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileWriteUnknown.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "/usr/bin/cpio failed to create fixture at \(archiveURL.path)",
                ],
            )
        }
    }

    func createArFixture(at archiveURL: URL,
                         currentDirectory: URL,
                         entryPaths: [String]) throws
    {
        // Write the short-name System V layout directly so entry order and
        // Debian main-subfile detection don't depend on the host ar variant.
        func field(_ value: String, width: Int) throws -> Data {
            let bytes = Data(value.utf8)
            guard bytes.count <= width else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            return bytes + Data(repeating: 0x20, count: width - bytes.count)
        }

        var archiveData = Data("!<arch>\n".utf8)
        for entryPath in entryPaths {
            let entryURL = currentDirectory.appendingPathComponent(entryPath)
            let contents = try Data(contentsOf: entryURL)
            archiveData += try field(entryURL.lastPathComponent, width: 16)
            archiveData += try field("0", width: 12)
            archiveData += try field("0", width: 6)
            archiveData += try field("0", width: 6)
            archiveData += try field("100644", width: 8)
            archiveData += try field(String(contents.count), width: 10)
            archiveData += Data("`\n".utf8)
            archiveData += contents
            if contents.count.isMultiple(of: 2) == false {
                archiveData.append(0x0A)
            }
        }
        try archiveData.write(to: archiveURL)
    }

    /// Creates ZIP fixtures whose stored entry names must be controlled exactly.
    /// Prefer `createArchive` for normal archive fixtures; it exercises ShichiZip's
    /// writer path, but it will not produce intentionally unusual names such as
    /// `../payload.txt` that are needed to test reader-side path handling.
    func createZipFixture(at archiveURL: URL,
                          currentDirectory: URL,
                          entryPaths: [String],
                          recursive: Bool = false,
                          preserveSymlinks: Bool = false) throws
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        var arguments = ["-q", "-X"]
        if preserveSymlinks {
            arguments.append("-y")
        }
        if recursive {
            arguments.append("-r")
        }
        process.arguments = arguments + [archiveURL.path] + entryPaths
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: "/usr/bin/zip failed to create fixture at \(archiveURL.path)"])
        }
    }

    /// Creates a TAR fixture while preserving entry order and allowing the
    /// same archive path to appear more than once.
    func createTarFixture(at archiveURL: URL,
                          entries: [(path: String, contents: String)]) throws
    {
        let sourceRoot = archiveURL.deletingLastPathComponent()
            .appendingPathComponent("tar-fixture-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot,
                                                withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        var arguments = ["-cf", archiveURL.path]
        for (index, entry) in entries.enumerated() {
            let entryRoot = sourceRoot.appendingPathComponent(String(index),
                                                              isDirectory: true)
            let entryURL = entryRoot.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(
                at: entryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try entry.contents.write(to: entryURL,
                                     atomically: true,
                                     encoding: .utf8)
            arguments.append(contentsOf: ["-C", entryRoot.path, entry.path])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: "/usr/bin/tar failed to create fixture at \(archiveURL.path)"])
        }
    }

    @discardableResult
    func makeArchive(named name: String,
                     prefix: String = "ShichiZipTests",
                     payloadFileName: String = "payload.txt",
                     payloadContents: String = "payload",
                     password: String? = nil,
                     encryptFileNames: Bool = false,
                     pathMode: SZCompressionPathMode = .relativePaths) throws -> URL
    {
        let tempRoot = try makeTemporaryDirectory(named: name, prefix: prefix)
        let payloadURL = tempRoot.appendingPathComponent(payloadFileName)
        try payloadContents.write(to: payloadURL, atomically: true, encoding: .utf8)

        let archiveURL = tempRoot.appendingPathComponent("\(name).7z")
        try createArchive(at: archiveURL,
                          from: [payloadURL],
                          pathMode: pathMode,
                          password: password,
                          encryptFileNames: encryptFileNames)
        return archiveURL
    }
}
