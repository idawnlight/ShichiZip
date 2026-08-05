import Foundation
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif
import UniformTypeIdentifiers
import XCTest

final class SettingsFileAssociationTests: XCTestCase {
    func testIntegrationGroupsIncludeAlternateTypesAndMergeSharedUTIs() throws {
        let infoDictionary: [String: Any] = [
            "CFBundleDocumentTypes": [
                documentType(
                    name: "ISO Disk Image",
                    rank: "Alternate",
                    extensions: ["iso"],
                    contentTypes: ["public.iso-image"],
                ),
                documentType(
                    name: "JAR Archive",
                    rank: "Alternate",
                    extensions: ["jar"],
                    contentTypes: ["com.sun.java-archive"],
                ),
                documentType(
                    name: "WAR Archive",
                    rank: "Alternate",
                    extensions: ["war"],
                    contentTypes: ["com.sun.java-archive"],
                ),
                documentType(
                    name: "Catch All",
                    rank: "Default",
                    extensions: ["data"],
                    contentTypes: ["public.data"],
                ),
            ],
        ]

        let associations = FileAssociation.registeredAssociations(
            infoDictionary: infoDictionary,
        )

        XCTAssertEqual(associations.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(associations.first { $0.contentTypeIdentifiers == ["public.iso-image"] })
                .fileExtensions,
            ["iso"],
        )

        let javaAssociation = try XCTUnwrap(
            associations.first { $0.contentTypeIdentifiers == ["com.sun.java-archive"] },
        )
        XCTAssertEqual(javaAssociation.displayName, "JAR Archive / WAR Archive")
        XCTAssertEqual(javaAssociation.fileExtensions, ["jar", "war"])
        XCTAssertFalse(javaAssociation.isDefaultRanked)
    }

    func testIntegrationGroupsIncludeExtensionsFromTypeDeclarations() throws {
        let infoDictionary: [String: Any] = [
            "CFBundleDocumentTypes": [
                documentType(
                    name: "ZIP Archive",
                    rank: "Default",
                    extensions: ["zip"],
                    contentTypes: ["public.zip-archive", "public.zip-archive.first-part"],
                ),
            ],
            "UTImportedTypeDeclarations": [
                [
                    "UTTypeIdentifier": "public.zip-archive.first-part",
                    "UTTypeTagSpecification": [
                        "public.filename-extension": ["z01"],
                    ],
                ],
            ],
        ]

        let association = try XCTUnwrap(
            FileAssociation.registeredAssociations(
                infoDictionary: infoDictionary,
            ).first,
        )

        XCTAssertEqual(association.fileExtensions, ["zip", "z01"])
        XCTAssertEqual(association.extensionSummary, ".zip, .z01")
    }

    func testIssue38TypesAppearInIntegrationRegardlessOfHandlerRank() throws {
        let infoDictionary = try loadSourceInfoPlist()
        let associations = FileAssociation.registeredAssociations(
            infoDictionary: infoDictionary,
        )
        let displayedExtensions = Set(associations.flatMap(\.fileExtensions))

        XCTAssertTrue(displayedExtensions.isSuperset(of: ["iso", "udif", "deb", "rpm", "chm"]))
    }

    @MainActor
    func testViewModelSetsEveryTypeInAnAssociation() async {
        let association = FileAssociation(
            displayName: "Test Archive",
            handlerRank: "Default",
            fileExtensions: ["one", "two"],
            contentTypeIdentifiers: ["com.example.one", "com.example.two"],
        )
        let workspace = TestFileAssociationWorkspace()
        let model = FileAssociationSettingsModel(
            associations: [association],
            workspace: workspace,
        )

        model.refresh()
        XCTAssertFalse(model.state(for: association).isCurrentDefault)

        let updateTask = model.setDefaultApplication(for: association)
        XCTAssertNotNil(updateTask)
        await updateTask?.value

        XCTAssertEqual(
            workspace.updatedTypeIdentifiers,
            ["com.example.one", "com.example.two"],
        )
        XCTAssertTrue(model.state(for: association).isCurrentDefault)
    }

    @MainActor
    func testCancellingUpdateClearsPendingStateAndStopsRemainingTypes() async {
        let association = FileAssociation(
            displayName: "Test Archive",
            handlerRank: "Default",
            fileExtensions: ["one", "two"],
            contentTypeIdentifiers: ["com.example.one", "com.example.two"],
        )
        let workspace = DelayedFileAssociationWorkspace()
        let model = FileAssociationSettingsModel(
            associations: [association],
            workspace: workspace,
        )

        let updateTask = model.setDefaultApplication(for: association)
        XCTAssertNotNil(updateTask)

        while workspace.updatedTypeIdentifiers.isEmpty {
            await Task.yield()
        }

        model.cancelUpdates()
        await updateTask?.value

        XCTAssertEqual(workspace.updatedTypeIdentifiers, ["com.example.one"])
        XCTAssertFalse(model.state(for: association).isPendingUpdate)
        XCTAssertNil(model.updateFailure)
    }

    private func documentType(name: String,
                              rank: String,
                              extensions: [String],
                              contentTypes: [String]) -> [String: Any]
    {
        [
            "CFBundleTypeName": name,
            "LSHandlerRank": rank,
            "CFBundleTypeExtensions": extensions,
            "LSItemContentTypes": contentTypes,
        ]
    }

    private func loadSourceInfoPlist() throws -> [String: Any] {
        let infoPlistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ShichiZip/Resources/Info.plist")
        let infoPlistData = try Data(contentsOf: infoPlistURL)
        let propertyList = try PropertyListSerialization.propertyList(
            from: infoPlistData,
            options: [],
            format: nil,
        )
        return try XCTUnwrap(propertyList as? [String: Any])
    }
}

@MainActor
private final class TestFileAssociationWorkspace: FileAssociationWorkspace {
    private var applicationURLs: [String: URL] = [:]
    private(set) var updatedTypeIdentifiers: [String] = []

    func applicationURL(toOpen contentType: UTType) -> URL? {
        applicationURLs[contentType.identifier]
    }

    func setDefaultApplication(at applicationURL: URL,
                               toOpen contentType: UTType) async throws
    {
        updatedTypeIdentifiers.append(contentType.identifier)
        applicationURLs[contentType.identifier] = applicationURL
    }
}

@MainActor
private final class DelayedFileAssociationWorkspace: FileAssociationWorkspace {
    private(set) var updatedTypeIdentifiers: [String] = []

    func applicationURL(toOpen _: UTType) -> URL? {
        nil
    }

    func setDefaultApplication(at _: URL,
                               toOpen contentType: UTType) async throws
    {
        updatedTypeIdentifiers.append(contentType.identifier)
        try await Task.sleep(for: .seconds(1))
    }
}
