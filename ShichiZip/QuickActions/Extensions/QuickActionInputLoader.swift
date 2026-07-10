import Foundation
import UniformTypeIdentifiers

enum ShichiZipQuickActionInputError: Error, Sendable {
    case emptyExtensionContext
}

@MainActor
enum ShichiZipQuickActionInputLoader {
    private enum LoadedFileReference {
        case durable(URL)
        case temporary(URL)
    }

    private static let maxConcurrentProviderLoads = 32

    static func fileURLs(from context: NSExtensionContext,
                         action: ShichiZipQuickAction) async throws -> [URL]
    {
        let logger = ShichiZipQuickActionLogger(action: action)
        let extensionItems = context.inputItems.compactMap { $0 as? NSExtensionItem }
        let itemProviders = extensionItems.flatMap { $0.attachments ?? [] }

        for (index, item) in extensionItems.enumerated() {
            let attachmentCount = item.attachments?.count ?? 0
            let userInfoKeys = item.userInfo?.keys.map { String(describing: $0) }.joined(separator: ", ") ?? ""
            let contentLength = item.attributedContentText?.length ?? 0
            logger.log("inputItem[\(index)] attachments=\(attachmentCount) attributedTextLength=\(contentLength) userInfoKeys=[\(userInfoKeys)]")
        }

        guard !itemProviders.isEmpty else {
            logger.log("no item providers in extension context")
            if !extensionItems.isEmpty {
                throw ShichiZipQuickActionInputError.emptyExtensionContext
            }
            throw ShichiZipQuickActionError.unsupportedSelection("No files were provided to the Quick Action.")
        }

        let urls = try await shichiZipBoundedConcurrentMap(itemProviders,
                                                           maxConcurrentTasks: maxConcurrentProviderLoads)
        { itemProvider in
            try await loadFileURL(from: itemProvider,
                                  action: action)
        }

        return urls.map(\.standardizedFileURL)
    }

    private static func loadFileURL(from itemProvider: NSItemProvider,
                                    action: ShichiZipQuickAction) async throws -> URL
    {
        let logger = ShichiZipQuickActionLogger(action: action)
        if let objectURL = try await loadURLObject(from: itemProvider,
                                                   logger: logger)
        {
            return objectURL
        }

        var firstError: Error?
        var temporaryRepresentationURL: URL?
        for typeIdentifier in candidateTypeIdentifiers(for: itemProvider) {
            do {
                if let fileReference = try await loadInPlaceFileURL(from: itemProvider,
                                                                    typeIdentifier: typeIdentifier)
                {
                    switch fileReference {
                    case let .durable(url):
                        return url
                    case let .temporary(url):
                        temporaryRepresentationURL = temporaryRepresentationURL ?? url
                    }
                }
            } catch {
                logger.log("loadInPlace failed for type=\(typeIdentifier) error=\(String(describing: error))")
                firstError = firstError ?? error
            }

            do {
                if let fileReference = try await loadFileURLRepresentation(from: itemProvider,
                                                                           typeIdentifier: typeIdentifier),
                    case let .temporary(url) = fileReference
                {
                    temporaryRepresentationURL = temporaryRepresentationURL ?? url
                }
            } catch {
                logger.log("loadFileRepresentation failed for type=\(typeIdentifier) error=\(String(describing: error))")
                firstError = firstError ?? error
            }

            do {
                if let dataURL = try await loadDataFileURL(from: itemProvider,
                                                           typeIdentifier: typeIdentifier,
                                                           logger: logger)
                {
                    return dataURL
                }
            } catch {
                logger.log("loadDataRepresentation failed for type=\(typeIdentifier) error=\(String(describing: error))")
                firstError = firstError ?? error
            }
        }

        do {
            if let stringObjectURL = try await loadStringObjectFileURL(from: itemProvider,
                                                                       logger: logger)
            {
                return stringObjectURL
            }
        } catch {
            logger.log("loadObject(NSString) failed error=\(String(describing: error))")
            firstError = firstError ?? error
        }

        if let temporaryRepresentationURL {
            logger.log("rejecting temporary file representation path=\(temporaryRepresentationURL.path)")
            throw ShichiZipQuickActionError.temporaryRepresentationUnsupported(action)
        }

        throw firstError ?? ShichiZipQuickActionError.invalidPayload
    }

    private static func loadURLObject(from itemProvider: NSItemProvider,
                                      logger: ShichiZipQuickActionLogger) async throws -> URL?
    {
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
                    logger.log("loadObject returned non-URL object type=\(String(describing: object.map { type(of: $0) }))")
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: url.standardizedFileURL)
            }
        }
    }

    private static func candidateTypeIdentifiers(for itemProvider: NSItemProvider) -> [String] {
        var identifiers = itemProvider.registeredTypeIdentifiers

        if itemProvider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           !identifiers.contains(UTType.fileURL.identifier)
        {
            identifiers.insert(UTType.fileURL.identifier, at: 0)
        }

        return identifiers
    }

    private static func loadInPlaceFileURL(from itemProvider: NSItemProvider,
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

    private static func loadFileURLRepresentation(from itemProvider: NSItemProvider,
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

    private static func loadStringObjectFileURL(from itemProvider: NSItemProvider,
                                                logger: ShichiZipQuickActionLogger) async throws -> URL?
    {
        guard itemProvider.canLoadObject(ofClass: NSString.self) else {
            return nil
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            itemProvider.loadObject(ofClass: NSString.self) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let string = item as? String else {
                    let itemTypeDescription = item.map { String(describing: type(of: $0)) } ?? "nil"
                    logger.log("loadObject(NSString) returned unparseable item itemType=\(itemTypeDescription)")
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: fileURL(from: string).standardizedFileURL)
            }
        }
    }

    private static func loadDataFileURL(from itemProvider: NSItemProvider,
                                        typeIdentifier: String,
                                        logger: ShichiZipQuickActionLogger) async throws -> URL?
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
                    logger.log("loadDataRepresentation returned unparseable data for type=\(typeIdentifier) bytes=\(byteCount)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private nonisolated static func parseFileURL(from item: Any?) throws -> URL {
        guard let item else {
            throw ShichiZipQuickActionError.invalidPayload
        }

        // Iterative DFS over nested array/dictionary payloads so a deeply nested
        // item-provider value can't overflow the call stack.
        var stack: [Any] = [item]
        while let candidate = stack.popLast() {
            if let url = scalarFileURL(from: candidate) {
                return url
            }

            if let array = candidate as? [Any] {
                stack.append(contentsOf: array.reversed())
            } else if let dictionary = candidate as? [AnyHashable: Any] {
                stack.append(contentsOf: dictionary.values.reversed())
            }
        }

        throw ShichiZipQuickActionError.invalidPayload
    }

    private nonisolated static func scalarFileURL(from item: Any) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let nsURL = item as? NSURL {
            return nsURL as URL
        }

        if let string = item as? String {
            return fileURL(from: string)
        }

        if let data = item as? Data {
            return fileURL(from: data)
        }

        return nil
    }

    private nonisolated static func fileURL(from string: String) -> URL {
        if let url = URL(string: string), url.isFileURL {
            return url
        }

        return URL(fileURLWithPath: string)
    }

    private nonisolated static func fileURL(from data: Data) -> URL? {
        if let url = try? (NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) as URL?) {
            return url
        }

        var isStale = false
        if let bookmarkURL = try? URL(resolvingBookmarkData: data,
                                      options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale)
        {
            return bookmarkURL
        }

        if let string = String(data: data, encoding: .utf8) {
            return fileURL(from: string)
        }

        return nil
    }
}
