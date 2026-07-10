import Foundation
import UniformTypeIdentifiers

struct FileAssociation: Identifiable {
    let displayName: String
    let handlerRank: String
    let fileExtensions: [String]
    let contentTypeIdentifiers: [String]

    var id: String {
        contentTypeIdentifiers.sorted().joined(separator: "\u{1F}")
    }

    var primaryTypeIdentifier: String {
        contentTypeIdentifiers[0]
    }

    var contentTypes: [UTType] {
        contentTypeIdentifiers.map { UTType(importedAs: $0) }
    }

    var isDefaultRanked: Bool {
        handlerRank == "Default"
    }

    var extensionSummary: String {
        fileExtensions.map { ".\($0)" }.joined(separator: ", ")
    }

    var displayTitle: String {
        extensionSummary.isEmpty ? displayName : "\(displayName) (\(extensionSummary))"
    }

    private static let excludedTypeIdentifiers: Set<String> = [
        "public.data",
        "com.aone.keka-extraction",
    ]

    static func supportedDocumentTypes(bundle: Bundle = .main) -> [FileAssociation] {
        supportedDocumentTypes(infoDictionary: bundle.infoDictionary ?? [:])
    }

    static func supportedDocumentTypes(infoDictionary: [String: Any]) -> [FileAssociation] {
        guard let documentTypes = infoDictionary["CFBundleDocumentTypes"] as? [[String: Any]] else {
            return []
        }

        let declaredExtensions = declaredExtensionsByContentType(in: infoDictionary)
        return documentTypes.compactMap { documentType in
            guard let displayName = documentType["CFBundleTypeName"] as? String,
                  let declaredContentTypes = documentType["LSItemContentTypes"] as? [String]
            else {
                return nil
            }

            let contentTypeIdentifiers = declaredContentTypes.filter {
                !excludedTypeIdentifiers.contains($0)
            }
            guard !contentTypeIdentifiers.isEmpty else {
                return nil
            }

            let documentExtensions = documentType["CFBundleTypeExtensions"] as? [String] ?? []
            let contentTypeExtensions = contentTypeIdentifiers.flatMap {
                declaredExtensions[$0] ?? []
            }

            return FileAssociation(
                displayName: displayName,
                handlerRank: documentType["LSHandlerRank"] as? String ?? "Alternate",
                fileExtensions: unique(documentExtensions + contentTypeExtensions),
                contentTypeIdentifiers: contentTypeIdentifiers,
            )
        }
    }

    static func registeredAssociations(bundle: Bundle = .main) -> [FileAssociation] {
        groupedAssociations(supportedDocumentTypes(bundle: bundle))
    }

    static func registeredAssociations(infoDictionary: [String: Any]) -> [FileAssociation] {
        groupedAssociations(supportedDocumentTypes(infoDictionary: infoDictionary))
    }

    private static func declaredExtensionsByContentType(
        in infoDictionary: [String: Any],
    ) -> [String: [String]] {
        let declarationKeys = ["UTImportedTypeDeclarations", "UTExportedTypeDeclarations"]
        var extensionsByIdentifier: [String: [String]] = [:]

        for key in declarationKeys {
            let declarations = infoDictionary[key] as? [[String: Any]] ?? []
            for declaration in declarations {
                guard let identifier = declaration["UTTypeIdentifier"] as? String,
                      let tagSpecification = declaration["UTTypeTagSpecification"] as? [String: Any],
                      let extensions = tagSpecification["public.filename-extension"] as? [String]
                else {
                    continue
                }

                extensionsByIdentifier[identifier] = unique(
                    (extensionsByIdentifier[identifier] ?? []) + extensions,
                )
            }
        }

        return extensionsByIdentifier
    }

    private static func groupedAssociations(
        _ associations: [FileAssociation],
    ) -> [FileAssociation] {
        var groups: [FileAssociation] = []

        for association in associations {
            guard let firstMatch = groups.firstIndex(where: { overlaps($0, association) }) else {
                groups.append(association)
                continue
            }

            groups[firstMatch] = merged(groups[firstMatch], association)
            var index = groups.index(after: firstMatch)
            while index < groups.endIndex {
                if overlaps(groups[firstMatch], groups[index]) {
                    groups[firstMatch] = merged(groups[firstMatch], groups.remove(at: index))
                } else {
                    groups.formIndex(after: &index)
                }
            }
        }

        return groups
    }

    private static func overlaps(_ lhs: FileAssociation,
                                 _ rhs: FileAssociation) -> Bool
    {
        !Set(lhs.contentTypeIdentifiers).isDisjoint(with: rhs.contentTypeIdentifiers)
    }

    private static func merged(_ lhs: FileAssociation,
                               _ rhs: FileAssociation) -> FileAssociation
    {
        FileAssociation(
            displayName: unique([lhs.displayName, rhs.displayName]).joined(separator: " / "),
            handlerRank: lhs.isDefaultRanked || rhs.isDefaultRanked ? "Default" : "Alternate",
            fileExtensions: unique(lhs.fileExtensions + rhs.fileExtensions),
            contentTypeIdentifiers: unique(lhs.contentTypeIdentifiers + rhs.contentTypeIdentifiers),
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }
}

enum FileAssociationDisplayStatus {
    case noDefaultApp
    case defaultApp(String)
    case multipleDefaultApps
}

struct FileAssociationState {
    let displayStatus: FileAssociationDisplayStatus
    let isCurrentDefault: Bool
    let isPendingUpdate: Bool
}
