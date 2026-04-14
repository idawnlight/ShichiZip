import Foundation
import XCTest

/// A mutable box that can be captured in `@Sendable` closures.
/// Only for use in tests where the access pattern is sequential
/// (write in callback, read after `wait(for:)`).
final class UncheckedSendableBox<T>: @unchecked Sendable {
    var value: T?
}

extension XCTestCase {
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
                       pathMode: SZCompressionPathMode = .relativePaths,
                       password: String? = nil,
                       encryptFileNames: Bool = false) throws
    {
        let settings = SZCompressionSettings()
        settings.pathMode = pathMode
        settings.password = password
        settings.encryptFileNames = encryptFileNames

        try SZArchive.create(atPath: archiveURL.path,
                             fromPaths: sourceURLs.map(\.path),
                             settings: settings,
                             session: nil)
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
