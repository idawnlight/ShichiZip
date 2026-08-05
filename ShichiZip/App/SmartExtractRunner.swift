import Cocoa

/// Shared smart extraction used by Quick Actions, menus, and launch-open HUD.
enum SmartExtractRunner {
    private static let uniqueDestinationFailureDescription = "A unique extraction destination could not be created."

    private struct Plan {
        let destinationURL: URL
        let pathPrefixToStrip: String?
        let extractionMode: ExtractionMode
    }

    private enum ExtractionMode {
        case fullArchive
        case singleFile(index: Int, archivedLeafName: String)
    }

    @MainActor
    static func extract(archiveURL: URL,
                        defaults: ExtractQuickActionDefaults,
                        parentWindow: NSWindow?,
                        shouldRevealDestination: @escaping @MainActor () -> Bool,
                        completion: (@MainActor (URL?) -> Void)? = nil)
    {
        Task { @MainActor in
            do {
                let plan = try await ArchiveOperationRunner.run(operationTitle: SZL10n.string("progress.extracting"),
                                                                initialFileName: archiveURL.lastPathComponent,
                                                                parentWindow: parentWindow,
                                                                deferredDisplay: false)
                { session in
                    let archive = SZArchive()
                    try archive.open(atPath: archiveURL.path, session: session)
                    defer { archive.close() }

                    let archiveItems = try archive.entries(with: session).map(ArchiveItem.init)
                    let plan = try Self.plan(for: archiveURL,
                                             archiveItems: archiveItems,
                                             eliminateDuplicates: defaults.eliminateDuplicates)
                    let settings = extractionSettings(defaults: defaults,
                                                      archiveURL: archiveURL,
                                                      plan: plan)
                    try extract(archive,
                                to: plan.destinationURL,
                                settings: settings,
                                session: session,
                                mode: plan.extractionMode)
                    return plan
                }

                let postProcessError = finalizeExtraction(archiveURL: archiveURL,
                                                          defaults: defaults)
                if shouldRevealDestination() {
                    revealDestination(plan.destinationURL,
                                      archiveURL: archiveURL)
                }

                completion?(plan.destinationURL)

                if let postProcessError {
                    szPresentError(postProcessError, for: parentWindow)
                }
            } catch {
                completion?(nil)
                szPresentError(error, for: parentWindow)
            }
        }
    }

    private static func extractionSettings(defaults: ExtractQuickActionDefaults,
                                           archiveURL: URL,
                                           plan: Plan) -> SZExtractionSettings
    {
        let settings = SZExtractionSettings()
        settings.overwriteMode = defaults.overwriteMode
        settings.pathMode = .fullPaths
        settings.preserveNtSecurityInfo = defaults.preserveNtSecurityInfo
        settings.pathPrefixToStrip = plan.pathPrefixToStrip
        if defaults.inheritDownloadedFileQuarantine {
            settings.sourceArchivePathForQuarantine = archiveURL.path
        }

        return settings
    }

    private static func extract(_ archive: SZArchive,
                                to destinationURL: URL,
                                settings: SZExtractionSettings,
                                session: SZOperationSession?,
                                mode: ExtractionMode) throws
    {
        switch mode {
        case .fullArchive:
            try FileManagerArchiveExtraction.performFullArchiveExtraction(archive,
                                                                          to: destinationURL,
                                                                          settings: settings,
                                                                          session: session)

        case let .singleFile(index, archivedLeafName):
            settings.pathMode = .noPaths
            try FileManagerArchiveExtraction.performSingleFileExtraction(archive,
                                                                         entryIndex: NSNumber(value: index),
                                                                         archivedLeafName: archivedLeafName,
                                                                         to: destinationURL,
                                                                         settings: settings,
                                                                         session: session)
        }
    }

    private static func finalizeExtraction(archiveURL: URL,
                                           defaults: ExtractQuickActionDefaults) -> Error?
    {
        do {
            _ = try ArchiveExtractionPostProcessor.finalizeExtraction(sourceArchiveURL: archiveURL,
                                                                      moveSourceArchiveToTrash: defaults.moveArchiveToTrashAfterExtraction)
            return nil
        } catch {
            return error
        }
    }

    @MainActor
    private static func revealDestination(_ destinationURL: URL,
                                          archiveURL: URL)
    {
        let baseDirectory = archiveURL.deletingLastPathComponent().standardizedFileURL
        if destinationURL != baseDirectory {
            NSWorkspace.shared.selectFile(destinationURL.path,
                                          inFileViewerRootedAtPath: baseDirectory.path)
        } else {
            NSWorkspace.shared.open(destinationURL)
        }
    }

    private static func plan(for archiveURL: URL,
                             archiveItems: [ArchiveItem],
                             eliminateDuplicates: Bool) throws -> Plan
    {
        let baseDestinationURL = archiveURL.deletingLastPathComponent().standardizedFileURL
        let suggestedFolderName = archiveURL.deletingPathExtension().lastPathComponent
        let topLevelNames = Set(archiveItems.compactMap(\.pathParts.first).filter { !$0.isEmpty })
        let singleTopLevelName = topLevelNames.count == 1 ? topLevelNames.first : nil
        let singleTopLevelSurvivesPathCorrection = singleTopLevelName.map {
            SZArchive.correctedFileSystemRelativePath(forArchivePath: $0,
                                                      isDirectory: true) == $0
        } ?? false

        if let topLevelName = singleTopLevelName,
           singleTopLevelSurvivesPathCorrection
        {
            let topLevelItems = archiveItems.filter { $0.pathParts.first == topLevelName }
            let topLevelIsDirectory = topLevelItems.contains { $0.isDirectory || $0.pathParts.count > 1 }
            if topLevelIsDirectory {
                let desiredDestinationURL = baseDestinationURL.appendingPathComponent(topLevelName,
                                                                                      isDirectory: true)
                let destinationURL = try FileManager.default.szUniqueDestinationURL(
                    for: desiredDestinationURL,
                    isDirectory: true,
                    failureDescription: uniqueDestinationFailureDescription,
                )
                return Plan(destinationURL: destinationURL,
                            pathPrefixToStrip: topLevelName,
                            extractionMode: .fullArchive)
            }
            let topLevelFiles = topLevelItems.filter { !$0.isDirectory && $0.pathParts.count == 1 && $0.index >= 0 }
            if topLevelFiles.count == 1,
               let fileItem = topLevelFiles.first
            {
                let desiredDestinationURL = baseDestinationURL.appendingPathComponent(topLevelName,
                                                                                      isDirectory: false)
                let destinationURL = try FileManager.default.szUniqueDestinationURL(
                    for: desiredDestinationURL,
                    isDirectory: false,
                    failureDescription: uniqueDestinationFailureDescription,
                )
                return Plan(destinationURL: destinationURL,
                            pathPrefixToStrip: nil,
                            extractionMode: .singleFile(index: fileItem.index,
                                                        archivedLeafName: fileItem.name))
            }
        }

        let usesArchiveNamedDestination = topLevelNames.count > 1
            || (singleTopLevelName != nil && !singleTopLevelSurvivesPathCorrection)
        let desiredDestinationURL = usesArchiveNamedDestination
            ? baseDestinationURL.appendingPathComponent(suggestedFolderName, isDirectory: true).standardizedFileURL
            : baseDestinationURL
        let destinationURL = usesArchiveNamedDestination
            ? try FileManager.default.szUniqueDestinationURL(
                for: desiredDestinationURL,
                isDirectory: true,
                failureDescription: uniqueDestinationFailureDescription,
            )
            : desiredDestinationURL
        let pathPrefixToStrip: String? = if topLevelNames.count > 1, eliminateDuplicates {
            ArchiveItem.duplicateRootPrefixToStrip(for: archiveItems,
                                                   destinationLeafName: destinationURL.lastPathComponent)
        } else {
            nil
        }
        return Plan(destinationURL: destinationURL,
                    pathPrefixToStrip: pathPrefixToStrip,
                    extractionMode: .fullArchive)
    }
}
