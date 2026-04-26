import AppKit
import CoreServices
import UniformTypeIdentifiers

enum FileManagerExternalOpenRouter {
    private static let archiveLikeExtensions: Set<String> = [
        "7z", "apk", "ar", "arj", "bz2", "cab", "cpio", "deb", "dmg", "gz", "gzip",
        "img", "ipa", "iso", "jar", "lz", "lzma", "pkg", "rar", "rpm", "tar", "tbz",
        "tbz2", "tgz", "txz", "war", "xar", "xz", "z", "zip",
    ]

    static func defaultExternalApplicationURL(for url: URL,
                                              workspace: NSWorkspace = .shared) -> URL?
    {
        defaultExternalApplicationURL(for: url,
                                      defaultApplicationURLProvider: { workspace.urlForApplication(toOpen: $0) })
    }

    static func defaultExternalApplicationURL(for url: URL,
                                              defaultApplicationURLProvider: (URL) -> URL?) -> URL?
    {
        defaultExternalApplicationURL(for: url,
                                      defaultApplicationURLProvider: defaultApplicationURLProvider,
                                      currentApplicationURL: currentApplicationURL())
    }

    static func defaultExternalApplicationURL(for url: URL,
                                              defaultApplicationURLProvider: (URL) -> URL?,
                                              currentApplicationURL: URL) -> URL?
    {
        normalizedExternalApplicationURL(defaultApplicationURLProvider(url),
                                         currentApplicationURL: currentApplicationURL)
    }

    static func defaultExternalApplicationURL(forArchiveItemPath path: String) -> URL? {
        guard let contentType = contentType(forPath: path),
              let unmanagedApplicationURL = LSCopyDefaultApplicationURLForContentType(contentType.identifier as CFString,
                                                                                      LSRolesMask.all,
                                                                                      nil)
        else {
            return nil
        }

        let applicationURL = unmanagedApplicationURL.takeRetainedValue() as URL
        return normalizedExternalApplicationURL(applicationURL,
                                                currentApplicationURL: currentApplicationURL())
    }

    static func shouldOpenExternallyBeforeArchiveAttempt(_ url: URL) -> Bool {
        guard let applicationURL = defaultExternalApplicationURL(for: url),
              let contentType = contentType(forPath: url.lastPathComponent)
        else {
            return false
        }

        return shouldPreferExternalOpen(for: contentType, applicationURL: applicationURL)
    }

    static func shouldOpenExternallyBeforeArchiveAttempt(archiveItemPath path: String) -> Bool {
        guard let contentType = contentType(forPath: path),
              let applicationURL = defaultExternalApplicationURL(forArchiveItemPath: path)
        else {
            return false
        }

        return shouldPreferExternalOpen(for: contentType, applicationURL: applicationURL)
    }

    static func shouldFallbackUnsupportedArchiveExternally(for url: URL) -> Bool {
        !isArchiveLikeURL(url)
    }

    private static func shouldPreferExternalOpen(for contentType: UTType, applicationURL: URL) -> Bool {
        guard applicationURL != currentApplicationURL() else {
            return false
        }

        return !contentType.conforms(to: .archive)
    }

    private static func contentType(forPath path: String) -> UTType? {
        let pathExtension = (path as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !pathExtension.isEmpty else {
            return nil
        }

        return UTType(filenameExtension: pathExtension)
    }

    private static func currentApplicationURL() -> URL {
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func normalizedExternalApplicationURL(_ applicationURL: URL?,
                                                         currentApplicationURL: URL) -> URL?
    {
        guard let applicationURL else {
            return nil
        }

        let normalizedURL = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        return normalizedURL != currentApplicationURL ? normalizedURL : nil
    }

    private static func isArchiveLikeURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !pathExtension.isEmpty else {
            return false
        }

        if archiveLikeExtensions.contains(pathExtension) {
            return true
        }

        guard let type = UTType(filenameExtension: pathExtension) else {
            return false
        }

        return type.conforms(to: .archive)
    }
}
