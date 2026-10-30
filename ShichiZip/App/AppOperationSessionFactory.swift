import Foundation

@MainActor
enum AppOperationSessionFactory {
    static func install() {
        SZOperationSession.defaultSessionFactory = makeSession
    }

    nonisolated static func makeSession() -> SZOperationSession {
        let session = SZOperationSession()
        configureHandlers(on: session)
        return session
    }

    nonisolated static func configureHandlers(
        on session: SZOperationSession,
        willPresentPrompt: (@MainActor @Sendable () -> Void)? = nil,
    ) {
        session.passwordRequestHandler = { title, message, initialValue, passwordPointer in
            if let willPresentPrompt {
                MainActor.assumeIsolated { willPresentPrompt() }
            }
            guard let password = szPromptForPasswordSync(title: title,
                                                         message: message,
                                                         initialValue: initialValue)
            else { return false }
            passwordPointer?.pointee = password as NSString
            return true
        }
        session.choiceRequestHandler = { request in
            if let willPresentPrompt {
                MainActor.assumeIsolated { willPresentPrompt() }
            }
            return szRunChoiceDialog(request)
        }
        session.updateEncryptionRequestHandler = { archivePath, defaultEncryption in
            MainActor.assumeIsolated {
                willPresentPrompt?()
                return ArchiveUpdateEncryptionDialog.runModal(forArchive: archivePath,
                                                              defaultEncryption: defaultEncryption)
            }
        }
        session.memoryLimitRequestHandler = { requiredBytes, currentLimitBytes, archivePath, filePath, testMode, showRemember in
            MainActor.assumeIsolated {
                willPresentPrompt?()
                return requestMemoryLimit(requiredBytes: requiredBytes,
                                          currentLimitBytes: currentLimitBytes,
                                          archivePath: archivePath,
                                          filePath: filePath,
                                          testMode: testMode,
                                          showRemember: showRemember)
            }
        }
    }

    static func requestMemoryLimit(requiredBytes: UInt64,
                                   currentLimitBytes: UInt64,
                                   archivePath: String?,
                                   filePath: String?,
                                   testMode: Bool,
                                   showRemember: Bool) -> SZMemoryLimitPromptResult?
    {
        var result: SZMemoryLimitPromptResult?
        let confirmed = SZDialogPresenter.promptForMemoryLimit(withRequiredBytes: requiredBytes,
                                                               currentLimitBytes: currentLimitBytes,
                                                               archivePath: archivePath,
                                                               filePath: filePath,
                                                               testMode: testMode,
                                                               showRemember: showRemember,
                                                               result: &result)
        return confirmed ? result : nil
    }
}
