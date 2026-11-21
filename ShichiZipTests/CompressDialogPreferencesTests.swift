import Foundation
import XCTest
#if SHICHIZIP_ZS_VARIANT
    @testable import ShichiZip_ZS
#else
    @testable import ShichiZip
#endif

@MainActor
final class CompressDialogPreferencesTests: XCTestCase {
    func testSecondDialogPreservesSevenZipMethodAndCodecOptions() throws {
        let defaults = try makeIsolatedDefaults()
        let sourceURL = try makeSourceFile(named: "sample.txt")

        #if SHICHIZIP_ZS_VARIANT
            let chosenMethodName = "FLZMA2"
        #else
            let chosenMethodName = "LZMA"
        #endif

        let firstDialog = CompressDialogController(sourceURLs: [sourceURL],
                                                   preferenceDefaults: defaults)
        let firstContent = firstDialog.prepareContentController()
        firstContent.selectFormat(named: "7z")
        firstDialog.formatChanged(nil)

        firstContent.selectMethod(named: chosenMethodName)
        firstDialog.methodChanged(nil)
        firstContent.selectLevel(7)
        firstContent.selectDictionarySize(16 << 20)
        firstContent.selectWordSize(64)
        firstContent.selectSolidMode(false)
        firstContent.setThreadText("2")
        firstContent.setParameters("  mt=on  ")
        firstDialog.compressionSettingsChanged(nil)

        let firstResult = try firstDialog.commitCurrentSelectionForTesting()
        XCTAssertEqual(firstResult.settings.format, .format7z)
        XCTAssertEqual(firstResult.settings.methodName, chosenMethodName)
        XCTAssertEqual(firstResult.settings.levelValue, 7)
        XCTAssertEqual(firstResult.settings.dictionarySize, 16 << 20)
        XCTAssertEqual(firstResult.settings.wordSize, 64)
        XCTAssertFalse(firstResult.settings.solidMode)
        XCTAssertEqual(firstResult.settings.numThreads, 2)
        XCTAssertEqual(firstResult.settings.parameters, "mt=on")

        let secondDialog = CompressDialogController(sourceURLs: [sourceURL],
                                                    preferenceDefaults: defaults)
        let secondContent = secondDialog.prepareContentController()

        XCTAssertEqual(secondContent.selectedFormatOption()?.codecName, "7z")
        XCTAssertEqual(secondContent.selectedMethodOption()?.methodName, chosenMethodName)
        XCTAssertEqual(secondContent.selectedLevelOption()?.levelValue, 7)
        XCTAssertEqual(secondContent.selectedDictionaryOption()?.value, 16 << 20)
        XCTAssertEqual(secondContent.selectedWordOption()?.value, 64)
        XCTAssertEqual(secondContent.selectedSolidOption()?.value, false)
        XCTAssertEqual(secondContent.currentThreadText(), "2")
        XCTAssertEqual(secondContent.parametersValue, "mt=on")

        let secondResult = try secondDialog.commitCurrentSelectionForTesting()
        XCTAssertEqual(secondResult.settings.methodName, chosenMethodName)
        XCTAssertEqual(secondResult.settings.levelValue, 7)
        XCTAssertEqual(secondResult.settings.dictionarySize, 16 << 20)
        XCTAssertEqual(secondResult.settings.wordSize, 64)
        XCTAssertFalse(secondResult.settings.solidMode)
        XCTAssertEqual(secondResult.settings.numThreads, 2)
        XCTAssertEqual(secondResult.settings.parameters, "mt=on")
    }

    func testPerFormatPreferencesStayIsolatedAcrossFormatSwitches() throws {
        let defaults = try makeIsolatedDefaults()
        let sourceURL = try makeSourceFile(named: "report.txt")

        // 1. Save custom 7z options (PPMd + custom order/dictionary + non-solid).
        let sevenZipDialog = CompressDialogController(sourceURLs: [sourceURL],
                                                      preferenceDefaults: defaults)
        let sevenZipContent = sevenZipDialog.prepareContentController()
        sevenZipContent.selectFormat(named: "7z")
        sevenZipDialog.formatChanged(nil)
        sevenZipContent.selectMethod(named: "PPMd")
        sevenZipDialog.methodChanged(nil)
        sevenZipContent.selectLevel(9)
        sevenZipContent.selectDictionarySize(32 << 20)
        sevenZipContent.selectWordSize(16)
        sevenZipContent.selectSolidMode(false)
        sevenZipContent.setThreadText("1")
        sevenZipContent.setParameters("mem=32m")
        _ = try sevenZipDialog.commitCurrentSelectionForTesting()

        // 2. Save custom zip options (LZMA + AES-256 + level 7).
        let zipDialog = CompressDialogController(sourceURLs: [sourceURL],
                                                 preferenceDefaults: defaults)
        let zipContent = zipDialog.prepareContentController()
        zipContent.selectFormat(named: "zip")
        zipDialog.formatChanged(nil)
        zipContent.selectMethod(named: "LZMA")
        zipDialog.methodChanged(nil)
        zipContent.selectLevel(7)
        zipContent.selectDictionarySize(8 << 20)
        zipContent.selectWordSize(48)
        zipContent.selectEncryption(.AES256)
        zipContent.setThreadText("4")
        _ = try zipDialog.commitCurrentSelectionForTesting()

        // 3. Reopen dialog: starts on last-used format (zip) with zip's options.
        let reopenedDialog = CompressDialogController(sourceURLs: [sourceURL],
                                                      preferenceDefaults: defaults)
        let reopenedContent = reopenedDialog.prepareContentController()
        XCTAssertEqual(reopenedContent.selectedFormatOption()?.codecName, "zip")
        XCTAssertEqual(reopenedContent.selectedMethodOption()?.methodName, "LZMA")
        XCTAssertEqual(reopenedContent.selectedLevelOption()?.levelValue, 7)
        XCTAssertEqual(reopenedContent.selectedDictionaryOption()?.value, 8 << 20)
        XCTAssertEqual(reopenedContent.selectedWordOption()?.value, 48)
        XCTAssertEqual(reopenedContent.selectedEncryptionOption()?.value, .AES256)
        XCTAssertEqual(reopenedContent.currentThreadText(), "4")

        // Switch to 7z: restores 7z's independent saved options.
        reopenedContent.selectFormat(named: "7z")
        reopenedDialog.formatChanged(nil)
        XCTAssertEqual(reopenedContent.selectedMethodOption()?.methodName, "PPMd")
        XCTAssertEqual(reopenedContent.selectedLevelOption()?.levelValue, 9)
        XCTAssertEqual(reopenedContent.selectedDictionaryOption()?.value, 32 << 20)
        XCTAssertEqual(reopenedContent.selectedWordOption()?.value, 16)
        XCTAssertEqual(reopenedContent.selectedSolidOption()?.value, false)
        XCTAssertEqual(reopenedContent.currentThreadText(), "1")
        XCTAssertEqual(reopenedContent.parametersValue, "mem=32m")

        // Switch to tar (no saved preferences): uses tar's clean defaults.
        reopenedContent.selectFormat(named: "tar")
        reopenedDialog.formatChanged(nil)
        XCTAssertEqual(reopenedContent.selectedMethodOption()?.methodName, "GNU")
        XCTAssertEqual(reopenedContent.selectedLevelOption()?.levelValue, 0)
        XCTAssertEqual(reopenedContent.currentThreadText(), "Auto")
        XCTAssertEqual(reopenedContent.parametersValue, "")

        // Switch back to zip: still restores zip's saved options.
        reopenedContent.selectFormat(named: "zip")
        reopenedDialog.formatChanged(nil)
        XCTAssertEqual(reopenedContent.selectedMethodOption()?.methodName, "LZMA")
        XCTAssertEqual(reopenedContent.selectedLevelOption()?.levelValue, 7)
        XCTAssertEqual(reopenedContent.selectedEncryptionOption()?.value, .AES256)
        XCTAssertEqual(reopenedContent.currentThreadText(), "4")
    }

    func testSwitchingThroughNonSolidFormatRestoresDefaultSolidModeForSevenZip() throws {
        let defaults = try makeIsolatedDefaults()
        let sourceURL = try makeSourceFile(named: "solid-check.txt")

        let dialog = CompressDialogController(sourceURLs: [sourceURL],
                                              preferenceDefaults: defaults)
        let content = dialog.prepareContentController()
        XCTAssertEqual(content.selectedFormatOption()?.codecName, "7z")
        XCTAssertEqual(content.selectedSolidOption()?.value, true)

        content.selectFormat(named: "zip")
        dialog.formatChanged(nil)
        XCTAssertEqual(content.selectedSolidOption()?.value, false)

        content.selectFormat(named: "7z")
        dialog.formatChanged(nil)
        XCTAssertEqual(content.selectedSolidOption()?.value, true)
    }

    func testUnsupportedStoredFormatPreferencesFallBackToValidDefaults() throws {
        let defaults = try makeIsolatedDefaults()
        let sourceURL = try makeSourceFile(named: "fallback.txt")

        CompressDialogController.DialogPreferences.record(format: "7z",
                                                          updateMode: .add,
                                                          pathMode: .relativePaths,
                                                          openSharedFiles: false,
                                                          deleteAfterCompression: false,
                                                          encryptNames: false,
                                                          showPassword: false,
                                                          memoryUsage: "",
                                                          defaults: defaults)
        CompressDialogController.DialogPreferences.recordFormatPreferences(
            CompressDialogController.DialogPreferences.FormatPreferences(
                level: 999,
                methodName: "UnsupportedMethod",
                dictionarySize: 12345,
                wordSize: 777,
                solidMode: true,
                threadText: "invalid-threads",
                parameters: "",
                encryption: .zipCrypto,
            ),
            forFormatName: "7z",
            defaults: defaults,
        )

        let dialog = CompressDialogController(sourceURLs: [sourceURL],
                                              preferenceDefaults: defaults)
        let content = dialog.prepareContentController()

        XCTAssertEqual(content.selectedFormatOption()?.codecName, "7z")
        XCTAssertEqual(content.selectedMethodOption()?.methodName, "LZMA2")
        XCTAssertEqual(content.selectedLevelOption()?.levelValue, 5)
        XCTAssertEqual(content.selectedDictionaryOption()?.value, 0)
        XCTAssertEqual(content.selectedWordOption()?.value, 0)
        XCTAssertEqual(content.selectedSolidOption()?.value, true)
        XCTAssertEqual(content.currentThreadText(), "Auto")
        XCTAssertEqual(content.selectedEncryptionOption()?.value, .AES256)
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "CompressDialogPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeSourceFile(named fileName: String) throws -> URL {
        let directory = try makeTemporaryDirectory(named: "compress-prefs")
        let fileURL = directory.appendingPathComponent(fileName)
        try Data("hello shichizip".utf8).write(to: fileURL)
        return fileURL
    }
}
