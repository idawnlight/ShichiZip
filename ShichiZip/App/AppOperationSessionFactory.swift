import Foundation

@MainActor
enum AppOperationSessionFactory {
    static func install() {
        SZOperationSession.defaultSessionFactory = makeSession
    }

    nonisolated static func makeSession() -> SZOperationSession {
        let session = SZOperationSession()
        session.passwordRequestHandler = { title, message, initialValue, passwordPointer in
            guard let password = szPromptForPasswordSync(title: title,
                                                         message: message,
                                                         initialValue: initialValue)
            else { return false }
            passwordPointer?.pointee = password as NSString
            return true
        }
        session.choiceRequestHandler = { szRunChoiceDialog($0) }
        session.updateEncryptionRequestHandler = { archivePath, defaultEncryption in
            MainActor.assumeIsolated {
                ArchiveUpdateEncryptionDialog.runModal(forArchive: archivePath,
                                                        defaultEncryption: defaultEncryption)
            }
        }
        session.memoryLimitRequestHandler = { requiredBytes, currentLimitBytes, archivePath, filePath, testMode, showRemember in
            MainActor.assumeIsolated {
                requestMemoryLimit(requiredBytes: requiredBytes,
                                   currentLimitBytes: currentLimitBytes,
                                   archivePath: archivePath,
                                   filePath: filePath,
                                   testMode: testMode,
                                   showRemember: showRemember)
            }
        }
        return session
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
