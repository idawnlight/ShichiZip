import Foundation
import XCTest

/// A mutable box that can be captured in `@Sendable` closures.
/// Only for use in tests where the access pattern is sequential
/// (write in callback, read after `wait(for:)`).
final class UncheckedSendableBox<T>: @unchecked Sendable {
    var value: T?
}

/// Values from the ZIP central-directory "version made by" host OS byte.
enum ZipFixtureHostOS: UInt8 {
    case fat = 0
    case unix = 3
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
        /// Write the short-name System V layout directly so entry order and
        /// Debian main-subfile detection don't depend on the host ar variant.
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

    /// Rewrites a single-entry ZIP so its local and central names use backslashes.
    func createZipFixtureWithBackslashPath(at archiveURL: URL,
                                           currentDirectory: URL,
                                           entryPath: String,
                                           hostOS: ZipFixtureHostOS) throws
    {
        guard entryPath.contains("/"), !entryPath.contains("\\") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        try createZipFixture(at: archiveURL,
                             currentDirectory: currentDirectory,
                             entryPaths: [entryPath])

        var data = try Data(contentsOf: archiveURL)

        func hasSignature(_ signature: [UInt8], at offset: Int) -> Bool {
            guard offset >= 0, offset + signature.count <= data.count else {
                return false
            }
            return signature.indices.allSatisfy { data[offset + $0] == signature[$0] }
        }

        func readUInt16(at offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }

        func readUInt32(at offset: Int) throws -> Int {
            guard offset >= 0, offset + 4 <= data.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Int(data[offset])
                | Int(data[offset + 1]) << 8
                | Int(data[offset + 2]) << 16
                | Int(data[offset + 3]) << 24
        }

        guard data.count >= 22 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let endSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var endOffset: Int?
        for offset in stride(from: data.count - 22, through: 0, by: -1) {
            if hasSignature(endSignature, at: offset) {
                endOffset = offset
                break
            }
        }
        guard let endOffset else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let centralOffset = try readUInt32(at: endOffset + 16)
        guard hasSignature([0x50, 0x4B, 0x01, 0x02], at: centralOffset) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let localOffset = try readUInt32(at: centralOffset + 42)
        guard hasSignature([0x50, 0x4B, 0x03, 0x04], at: localOffset) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let centralNameLength = try readUInt16(at: centralOffset + 28)
        let localNameLength = try readUInt16(at: localOffset + 26)
        let centralNameRange = (centralOffset + 46) ..< (centralOffset + 46 + centralNameLength)
        let localNameRange = (localOffset + 30) ..< (localOffset + 30 + localNameLength)
        let expectedName = Data(entryPath.utf8)

        guard centralNameRange.upperBound <= data.count,
              localNameRange.upperBound <= data.count,
              Data(data[centralNameRange]) == expectedName,
              Data(data[localNameRange]) == expectedName
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        for index in centralNameRange where data[index] == 0x2F {
            data[index] = 0x5C
        }
        for index in localNameRange where data[index] == 0x2F {
            data[index] = 0x5C
        }
        data[centralOffset + 5] = hostOS.rawValue
        try data.write(to: archiveURL, options: .atomic)
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
