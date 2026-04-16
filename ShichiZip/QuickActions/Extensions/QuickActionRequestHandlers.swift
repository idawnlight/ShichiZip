import AppKit
import Foundation
import os.log
import UniformTypeIdentifiers

class ShichiZipQuickActionRequestHandler: NSObject, NSExtensionRequestHandling {
    private enum LoadedFileReference {
        case durable(URL)
        case temporary(URL)
    }

    class var quickAction: ShichiZipQuickAction {
        fatalError("Override quickAction in subclasses.")
    }

    private class func log(_ message: String) {
        // Quick-action log messages frequently interpolate file paths
        // and URLs (see the "resolved fileURLs=…" and "workspace open
        // … url=" call sites). Keep those out of the unified log stream
        // in Release; retain NSLog in Debug where the verbosity is
        // useful and developers already see user paths in Xcode.
        #if DEBUG
        NSLog("[QuickAction:%@] %@", quickAction.rawValue, message)
        #else
        os_log(.info, "[QuickAction:%{public}s] %{private}s",
               quickAction.rawValue, message)
        #endif
    }

    func beginRequest(with context: NSExtensionContext) {
        type(of: self).log("beginRequest inputItems=\(context.inputItems.count)")
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let handler = self
        Task {
            do {
                let fileURLs = try await Self.loadInputFileURLs(from: context)
                Self.log("resolved fileURLs=\(fileURLs.map(\.path).joined(separator: ", "))")
                let request = try handler.makeRequest(from: fileURLs)
                let launchURL = try ShichiZipQuickActionTransport.launchURL(for: request)

                let didLaunch = await MainActor.run {
                    NSWorkspace.shared.open(launchURL)
                }
                Self.log("workspace open success=\(didLaunch) url=\(launchURL.absoluteString)")

                if didLaunch {
                    await handler.completeRequest(on: context)
                } else {
                    ShichiZipQuickActionTransport.releasePayload(for: launchURL)
                    await handler.cancelRequest(on: context, error: ShichiZipQuickActionError.launchFailed)
                }
            } catch {
                Self.log("canceling with error=\(String(describing: error))")
                await handler.cancelRequest(on: context, error: error)
            }
        }
    }

    @MainActor
    private func completeRequest(on context: NSExtensionContext) {
        context.completeRequest(returningItems: nil, completionHandler: nil)
    }

    @MainActor
    private func cancelRequest(on context: NSExtensionContext, error: Error) {
        context.cancelRequest(withError: error)
    }

    func makeRequest(from fileURLs: [URL]) throws -> ShichiZipQuickActionRequest {
        guard !fileURLs.isEmpty else {
            throw ShichiZipQuickActionError.unsupportedSelection("Select one or more files or folders.")
        }

        return ShichiZipQuickActionRequest(action: Self.quickAction, fileURLs: fileURLs)
    }

    private class func loadInputFileURLs(from context: NSExtensionContext) async throws -> [URL] {
        let extensionItems = context.inputItems.compactMap { $0 as? NSExtensionItem }
        let itemProviders = extensionItems.flatMap { $0.attachments ?? [] }

        for (index, item) in extensionItems.enumerated() {
            let attachmentCount = item.attachments?.count ?? 0
            let userInfoKeys = item.userInfo?.keys.map { String(describing: $0) }.joined(separator: ", ") ?? ""
            let contentLength = item.attributedContentText?.length ?? 0
            log("inputItem[\(index)] attachments=\(attachmentCount) attributedTextLength=\(contentLength) userInfoKeys=[\(userInfoKeys)]")
        }

        guard !itemProviders.isEmpty else {
            log("no item providers in extension context")
            throw ShichiZipQuickActionError.unsupportedSelection("No files were provided to the Quick Action.")
        }

        var urls: [URL] = []
        for (index, itemProvider) in itemProviders.enumerated() {
            log("provider[\(index)] registeredTypeIdentifiers=\(itemProvider.registeredTypeIdentifiers.joined(separator: ", "))")
            try await urls.append(loadFileURL(from: itemProvider))
        }

        return urls.map(\.standardizedFileURL)
    }

    private class func loadFileURL(from itemProvider: NSItemProvider) async throws -> URL {
        if let objectURL = try await loadURLObject(from: itemProvider) {
            return objectURL
        }

        var firstError: Error?
        var temporaryRepresentationURL: URL?
        for typeIdentifier in candidateTypeIdentifiers(for: itemProvider) {
            do {
                if let fileReference = try await loadInPlaceFileURL(from: itemProvider, typeIdentifier: typeIdentifier) {
                    switch fileReference {
                    case let .durable(url):
                        return url
                    case let .temporary(url):
                        temporaryRepresentationURL = temporaryRepresentationURL ?? url
                    }
                }
            } catch {
                log("loadInPlace failed for type=\(typeIdentifier) error=\(String(describing: error))")
                firstError = firstError ?? error
            }

            do {
                if let fileReference = try await loadFileURLRepresentation(from: itemProvider, typeIdentifier: typeIdentifier) {
                    if case let .temporary(url) = fileReference {
                        temporaryRepresentationURL = temporaryRepresentationURL ?? url
                    }
                }
            } catch {
                log("loadFileRepresentation failed for type=\(typeIdentifier) error=\(String(describing: error))")
                firstError = firstError ?? error
            }

            do {
                if let itemURL = try await loadItemFileURL(from: itemProvider, typeIdentifier: typeIdentifier) {
                    return itemURL
                }
            } catch {
                log("loadItem failed for type=\(typeIdentifier) error=\(String(describing: error))")
                firstError = firstError ?? error
            }

            do {
                if let dataURL = try await loadDataFileURL(from: itemProvider, typeIdentifier: typeIdentifier) {
                    return dataURL
                }
            } catch {
                log("loadDataRepresentation failed for type=\(typeIdentifier) error=\(String(describing: error))")
                firstError = firstError ?? error
            }
        }

        if let temporaryRepresentationURL {
            log("rejecting temporary file representation path=\(temporaryRepresentationURL.path)")
            throw ShichiZipQuickActionError.temporaryRepresentationUnsupported(Self.quickAction)
        }

        throw firstError ?? ShichiZipQuickActionError.invalidPayload
    }

    private class func loadURLObject(from itemProvider: NSItemProvider) async throws -> URL? {
        guard itemProvider.canLoadObject(ofClass: NSURL.self) else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            itemProvider.loadObject(ofClass: NSURL.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let url = object as? URL else {
                    log("loadObject returned non-URL object type=\(String(describing: object.map { type(of: $0) }))")
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: url.standardizedFileURL)
            }
        }
    }

    private class func candidateTypeIdentifiers(for itemProvider: NSItemProvider) -> [String] {
        var identifiers = itemProvider.registeredTypeIdentifiers

        if itemProvider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           !identifiers.contains(UTType.fileURL.identifier)
        {
            identifiers.insert(UTType.fileURL.identifier, at: 0)
        }

        return identifiers
    }

    private class func loadInPlaceFileURL(from itemProvider: NSItemProvider,
                                          typeIdentifier: String) async throws -> LoadedFileReference?
    {
        try await withCheckedThrowingContinuation { continuation in
            itemProvider.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) { url, isInPlace, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                let standardizedURL = url.standardizedFileURL
                continuation.resume(returning: isInPlace ? .durable(standardizedURL) : .temporary(standardizedURL))
            }
        }
    }

    private class func loadFileURLRepresentation(from itemProvider: NSItemProvider,
                                                 typeIdentifier: String) async throws -> LoadedFileReference?
    {
        try await withCheckedThrowingContinuation { continuation in
            itemProvider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: url.map { .temporary($0.standardizedFileURL) })
            }
        }
    }

    private class func loadItemFileURL(from itemProvider: NSItemProvider,
                                       typeIdentifier: String) async throws -> URL?
    {
        try await withCheckedThrowingContinuation { continuation in
            itemProvider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                do {
                    let url = try parseFileURL(from: item)
                    continuation.resume(returning: url.standardizedFileURL)
                } catch {
                    let itemTypeDescription = item.map { String(describing: type(of: $0)) } ?? "nil"
                    log("loadItem returned unparseable item for type=\(typeIdentifier) itemType=\(itemTypeDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private class func loadDataFileURL(from itemProvider: NSItemProvider,
                                       typeIdentifier: String) async throws -> URL?
    {
        try await withCheckedThrowingContinuation { continuation in
            itemProvider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                do {
                    let url = try parseFileURL(from: data)
                    continuation.resume(returning: url.standardizedFileURL)
                } catch {
                    let byteCount = data?.count ?? 0
                    log("loadDataRepresentation returned unparseable data for type=\(typeIdentifier) bytes=\(byteCount)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private class func parseFileURL(from item: Any?) throws -> URL {
        if let url = item as? URL {
            return url
        }

        if let nsURL = item as? NSURL {
            return nsURL as URL
        }

        if let string = item as? String {
            if let url = URL(string: string), url.isFileURL {
                return url
            }

            return URL(fileURLWithPath: string)
        }

        if let array = item as? [Any] {
            for candidate in array {
                if let url = try? parseFileURL(from: candidate) {
                    return url
                }
            }
        }

        if let dictionary = item as? [AnyHashable: Any] {
            for value in dictionary.values {
                if let url = try? parseFileURL(from: value) {
                    return url
                }
            }
        }

        if let data = item as? Data,
           let url = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) as URL?
        {
            return url
        }

        if let data = item as? Data {
            var isStale = false
            if let bookmarkURL = try? URL(resolvingBookmarkData: data,
                                          options: [.withoutUI, .withoutMounting],
                                          relativeTo: nil,
                                          bookmarkDataIsStale: &isStale)
            {
                return bookmarkURL
            }

            if let string = String(data: data, encoding: .utf8) {
                return try parseFileURL(from: string)
            }
        }

        throw ShichiZipQuickActionError.invalidPayload
    }
}

final class ShowInFileManagerQuickActionHandler: ShichiZipQuickActionRequestHandler {
    override class var quickAction: ShichiZipQuickAction {
        .showInFileManager
    }
}

final class OpenInShichiZipQuickActionHandler: ShichiZipQuickActionRequestHandler {
    override class var quickAction: ShichiZipQuickAction {
        .openInShichiZip
    }

    override func makeRequest(from fileURLs: [URL]) throws -> ShichiZipQuickActionRequest {
        guard fileURLs.count == 1 else {
            throw ShichiZipQuickActionError.unsupportedSelection("Select a single file or folder to open in \(ShichiZipQuickActionAppInfo.hostAppDisplayName).")
        }

        return try super.makeRequest(from: fileURLs)
    }
}

final class SmartQuickExtractQuickActionHandler: ShichiZipQuickActionRequestHandler {
    override class var quickAction: ShichiZipQuickAction {
        .smartQuickExtract
    }

    override func makeRequest(from fileURLs: [URL]) throws -> ShichiZipQuickActionRequest {
        guard fileURLs.count == 1 else {
            throw ShichiZipQuickActionError.unsupportedSelection("Select a single archive to extract.")
        }

        return try super.makeRequest(from: fileURLs)
    }
}
