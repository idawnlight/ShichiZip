import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
protocol FileAssociationWorkspace: AnyObject {
    func applicationURL(toOpen contentType: UTType) -> URL?
    func setDefaultApplication(at applicationURL: URL,
                               toOpen contentType: UTType) async throws
}

@MainActor
final class SystemFileAssociationWorkspace: FileAssociationWorkspace {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func applicationURL(toOpen contentType: UTType) -> URL? {
        workspace.urlForApplication(toOpen: contentType)
    }

    func setDefaultApplication(at applicationURL: URL,
                               toOpen contentType: UTType) async throws
    {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            workspace.setDefaultApplication(at: applicationURL, toOpen: contentType) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

struct FileAssociationUpdateFailure: Identifiable {
    let id = UUID()
    let count: Int
}

@MainActor
final class FileAssociationSettingsModel: ObservableObject {
    @Published private(set) var states: [String: FileAssociationState] = [:]
    @Published private(set) var updateFailure: FileAssociationUpdateFailure?

    let associations: [FileAssociation]

    private let workspace: any FileAssociationWorkspace
    private let currentApplicationURL: URL
    private let currentBundleIdentifier: String?
    private var pendingAssociationIDs: Set<String> = []
    private var updateTask: Task<Void, Never>?

    init(
        associations: [FileAssociation] = FileAssociation.registeredAssociations(),
        workspace: any FileAssociationWorkspace = SystemFileAssociationWorkspace(),
        currentBundle: Bundle = .main,
    ) {
        self.associations = associations
        self.workspace = workspace
        currentApplicationURL = currentBundle.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        currentBundleIdentifier = currentBundle.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    isolated deinit {
        updateTask?.cancel()
    }

    var canSetAllAsDefault: Bool {
        updateTask == nil
            && associations.contains { states[$0.id]?.isCurrentDefault != true }
    }

    func state(for association: FileAssociation) -> FileAssociationState {
        states[association.id] ?? FileAssociationState(
            displayStatus: .noDefaultApp,
            isCurrentDefault: false,
            isPendingUpdate: false,
        )
    }

    func refresh() {
        var updatedStates: [String: FileAssociationState] = [:]

        for association in associations {
            var defaultApplications: [(identity: String, url: URL)] = []
            var seenApplicationIdentities: Set<String> = []
            var isCurrentDefault = !association.contentTypes.isEmpty

            for contentType in association.contentTypes {
                guard let applicationURL = workspace.applicationURL(toOpen: contentType)?
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                else {
                    isCurrentDefault = false
                    continue
                }

                if !isCurrentApplication(applicationURL) {
                    isCurrentDefault = false
                }

                let identity = applicationIdentity(for: applicationURL)
                if seenApplicationIdentities.insert(identity).inserted {
                    defaultApplications.append((identity, applicationURL))
                }
            }

            let displayStatus: FileAssociationDisplayStatus = switch defaultApplications.count {
            case 0:
                .noDefaultApp
            case 1:
                .defaultApp(applicationDisplayName(at: defaultApplications[0].url))
            default:
                .multipleDefaultApps
            }

            updatedStates[association.id] = FileAssociationState(
                displayStatus: displayStatus,
                isCurrentDefault: isCurrentDefault,
                isPendingUpdate: pendingAssociationIDs.contains(association.id),
            )
        }

        states = updatedStates
    }

    @discardableResult
    func setDefaultApplication(
        for association: FileAssociation,
    ) -> Task<Void, Never>? {
        startUpdate(for: [association])
    }

    @discardableResult
    func setAllAsDefault() -> Task<Void, Never>? {
        let pendingAssociations = associations.filter {
            states[$0.id]?.isCurrentDefault != true
        }
        return startUpdate(for: pendingAssociations)
    }

    func cancelUpdates() {
        updateTask?.cancel()
    }

    func dismissUpdateFailure() {
        updateFailure = nil
    }

    private func startUpdate(
        for associations: [FileAssociation],
    ) -> Task<Void, Never>? {
        guard updateTask == nil, !associations.isEmpty else {
            return nil
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await performUpdate(for: associations)
        }
        updateTask = task
        return task
    }

    private func performUpdate(for associations: [FileAssociation]) async {
        let associationIDs = Set(associations.map(\.id))
        pendingAssociationIDs.formUnion(associationIDs)
        refresh()

        defer {
            pendingAssociationIDs.subtract(associationIDs)
            updateTask = nil
            refresh()
        }

        var failureCount = 0
        for association in associations {
            guard !Task.isCancelled else { return }
            failureCount += await updateDefaultApplications(for: association.contentTypes)
        }

        guard !Task.isCancelled, failureCount > 0 else { return }
        updateFailure = FileAssociationUpdateFailure(count: failureCount)
    }

    private func updateDefaultApplications(for contentTypes: [UTType]) async -> Int {
        var failureCount = 0

        for contentType in contentTypes {
            guard !Task.isCancelled else { break }

            do {
                try await workspace.setDefaultApplication(
                    at: currentApplicationURL,
                    toOpen: contentType,
                )
                guard !Task.isCancelled else { break }
            } catch {
                if error is CancellationError {
                    break
                }

                let nsError = error as NSError
                if nsError.code != NSUserCancelledError {
                    failureCount += 1
                }
            }
        }

        return failureCount
    }

    private func isCurrentApplication(_ applicationURL: URL) -> Bool {
        let normalizedURL = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        if normalizedURL == currentApplicationURL {
            return true
        }

        guard let currentBundleIdentifier,
              !currentBundleIdentifier.isEmpty,
              let candidateIdentifier = Bundle(url: normalizedURL)?.bundleIdentifier?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !candidateIdentifier.isEmpty
        else {
            return false
        }

        return candidateIdentifier == currentBundleIdentifier
    }

    private func applicationIdentity(for applicationURL: URL) -> String {
        let normalizedURL = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        if let bundleIdentifier = Bundle(url: normalizedURL)?.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleIdentifier.isEmpty
        {
            return "bundle:\(bundleIdentifier)"
        }

        return "path:\(normalizedURL.path)"
    }

    private func applicationDisplayName(at applicationURL: URL) -> String {
        let displayName = FileManager.default.displayName(atPath: applicationURL.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty
            ? applicationURL.deletingPathExtension().lastPathComponent
            : displayName
    }
}
