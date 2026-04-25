// SZCallbacks.mm — Callback implementations for extract and create

#include "SZCallbacks.h"

#import "../Dialogs/SZDialogPresenter.h"
#import "../Utilities/SZObjCLog.h"

static inline void SZDispatchSyncOnMainThread(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static void SZAppendErrorMessage(UString& storage, const UString& message) {
    if (message.IsEmpty()) {
        return;
    }

    if (!storage.IsEmpty()) {
        storage += UString(L"\n\n");
    }
    storage += message;
}

static void SZAppendErrorMessage(UString& storage, NSString* message) {
    if (!message || message.length == 0) {
        return;
    }

    SZAppendErrorMessage(storage, ToU(message));
}

static NSString* SZBuildMemoryLimitFailureReason(uint32_t requiredGB,
    uint32_t currentLimitGB,
    NSString* archivePath,
    NSString* filePath,
    BOOL archiveSkipped) {
    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    [lines addObject:SZLocalizedString(@"memory.requiresBigRAM")];
    [lines addObject:[NSString stringWithFormat:@"%@: %u GB", SZLocalizedString(@"memory.requiredSize"), requiredGB]];
    [lines addObject:[NSString stringWithFormat:@"%@: %u GB", SZLocalizedString(@"memory.allowedLimit"), currentLimitGB]];
    [lines addObject:[NSString stringWithFormat:@"%@: %u GB", SZLocalizedString(@"memory.ramSize"), SZRoundUpByteCountToGB([NSProcessInfo processInfo].physicalMemory)]];
    if (archivePath.length > 0) {
        [lines addObject:[NSString stringWithFormat:SZLocalizedString(@"app.fileManager.archiveTransfer.archive"), archivePath]];
    }
    if (filePath.length > 0) {
        [lines addObject:[NSString stringWithFormat:@"%@: %@", SZLocalizedString(@"menu.file"), filePath]];
    }
    if (archiveSkipped) {
        [lines addObject:SZLocalizedString(@"memory.skipped")];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static NSString* SZFormatFileTime(const FILETIME* ft) {
    if (!ft)
        return nil;
    // FILETIME is 100-nanosecond intervals since 1601-01-01.
    // NSDate reference is 2001-01-01. Difference is 12622780800 seconds.
    const int64_t ticks = ((int64_t)ft->dwHighDateTime << 32) | ft->dwLowDateTime;
    if (ticks <= 0)
        return nil;
    const NSTimeInterval seconds = (NSTimeInterval)ticks / 10000000.0 - 11644473600.0;
    NSDate* date = [NSDate dateWithTimeIntervalSince1970:seconds];
    static NSDateFormatter* formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterMediumStyle;
        formatter.timeStyle = NSDateFormatterMediumStyle;
    });
    return [formatter stringFromDate:date];
}

// ============================================================
// Extract error message builder (mirrors ExtractCallback.cpp SetExtractErrorMessage)
// ============================================================

static void SZBuildExtractErrorMessage(Int32 opRes, Int32 encrypted, const wchar_t* fileName, UString& s) {
    s.Empty();

    if (opRes == NArchive::NExtract::NOperationResult::kOK)
        return;

    switch (opRes) {
    case NArchive::NExtract::NOperationResult::kUnsupportedMethod:
        s += ToU(SZLocalizedString(@"error.unsupportedMethodGeneric"));
        break;
    case NArchive::NExtract::NOperationResult::kDataError:
        s += ToU(SZLocalizedString(@"error.dataErrorGeneric"));
        break;
    case NArchive::NExtract::NOperationResult::kCRCError:
        s += ToU(SZLocalizedString(@"error.crcFailedGeneric"));
        break;
    case NArchive::NExtract::NOperationResult::kUnavailable:
        s += ToU(SZLocalizedString(@"error.unavailableData"));
        break;
    case NArchive::NExtract::NOperationResult::kUnexpectedEnd:
        s += ToU(SZLocalizedString(@"error.unexpectedEnd"));
        break;
    case NArchive::NExtract::NOperationResult::kDataAfterEnd:
        s += ToU(SZLocalizedString(@"error.dataAfterPayload"));
        break;
    case NArchive::NExtract::NOperationResult::kIsNotArc:
        s += ToU(SZLocalizedString(@"error.isNotArchive"));
        break;
    case NArchive::NExtract::NOperationResult::kHeadersError:
        s += ToU(SZLocalizedString(@"error.headersError"));
        break;
    case NArchive::NExtract::NOperationResult::kWrongPassword:
        s += ToU(SZLocalizedString(@"error.wrongPasswordGeneric"));
        break;
    default:
        s += ToU(SZLocalizedString(@"app.archive.error.errorNumberPrefix"));
        s.Add_UInt32((UInt32)opRes);
        break;
    }

    if (encrypted && opRes != NArchive::NExtract::NOperationResult::kWrongPassword) {
        s += " : ";
        s += ToU(SZLocalizedString(@"error.wrongPassword"));
    }

    if (fileName && fileName[0] != 0) {
        s += " : ";
        s += fileName;
    }
}

void SetExtractErrorMessage(Int32 opRes, Int32 encrypted, const wchar_t* fileName, UString& s) {
    SZBuildExtractErrorMessage(opRes, encrypted, fileName, s);
}

static inline HRESULT SZAgentCheckBreak(SZOperationSession* session) {
    return (session && [session shouldCancel]) ? E_ABORT : S_OK;
}

static void SZReportAgentCurrentPath(SZOperationSession* session,
    NSString* prefix,
    const wchar_t* path) {
    if (!session) {
        return;
    }

    NSString* pathText = (path && path[0] != 0) ? ToNS(UString(path)) : @"";
    if (prefix.length > 0 && pathText.length > 0) {
        [session reportCurrentFileName:[NSString stringWithFormat:@"%@: %@", prefix, pathText]];
        return;
    }

    [session reportCurrentFileName:(pathText.length > 0 ? pathText : (prefix ?: @""))];
}

static void SZAppendHRESULTMessage(UString& storage, const wchar_t* path, HRESULT errorCode) {
    NSString* pathText = (path && path[0] != 0) ? ToNS(UString(path)) : nil;
    NSString* message = pathText.length > 0
        ? [NSString stringWithFormat:@"%@: 0x%08X", pathText, (unsigned)errorCode]
        : [NSString stringWithFormat:SZLocalizedString(@"app.archive.error.operationFailedFormat"), (unsigned)errorCode];
    SZAppendErrorMessage(storage, message);
}

// ============================================================
// SZOpenCallbackUI implementation
// ============================================================

SZOpenCallbackUI::SZOpenCallbackUI()
    : PasswordIsDefined(false)
    , PasswordWasAsked(false)
    , TotalValue(0)
    , HasTotalValue(false)
    , UsesBytesProgress(false)
    , Session(nil) {
}

HRESULT SZOpenCallbackUI::Open_CheckBreak() {
    SZOperationSession* session = Session;
    if (session && [session shouldCancel]) {
        return E_ABORT;
    }
    return S_OK;
}

HRESULT SZOpenCallbackUI::Open_SetTotal(const UInt64* numFiles, const UInt64* numBytes) {
    if (numBytes && *numBytes > 0) {
        TotalValue = *numBytes;
        HasTotalValue = true;
        UsesBytesProgress = true;
    } else if (numFiles && *numFiles > 0) {
        TotalValue = *numFiles;
        HasTotalValue = true;
        UsesBytesProgress = false;
    } else {
        TotalValue = 0;
        HasTotalValue = false;
    }

    SZOperationSession* session = Session;
    if (session && HasTotalValue) {
        const UInt64 total = TotalValue;
        const bool useBytesProgress = UsesBytesProgress;
        [session reportProgressFraction:0.0];
        if (useBytesProgress) {
            [session reportBytesCompleted:0 total:total];
        }
    }

    return Open_CheckBreak();
}

HRESULT SZOpenCallbackUI::Open_SetCompleted(const UInt64* numFiles, const UInt64* numBytes) {
    if (!HasTotalValue || TotalValue == 0) {
        return Open_CheckBreak();
    }

    UInt64 completed = 0;
    if (UsesBytesProgress && numBytes) {
        completed = *numBytes;
    } else if (!UsesBytesProgress && numFiles) {
        completed = *numFiles;
    }

    if (completed > TotalValue) {
        completed = TotalValue;
    }

    const UInt64 total = TotalValue;
    const double fraction = (double)completed / (double)total;
    SZOperationSession* session = Session;
    if (session) {
        [session reportProgressFraction:fraction];
        if (UsesBytesProgress) {
            [session reportBytesCompleted:completed total:total];
        }
    }

    return Open_CheckBreak();
}

HRESULT SZOpenCallbackUI::Open_Finished() {
    SZOperationSession* session = Session;
    if (session && HasTotalValue && TotalValue > 0) {
        const UInt64 total = TotalValue;
        [session reportProgressFraction:1.0];
        if (UsesBytesProgress) {
            [session reportBytesCompleted:total total:total];
        }
    }

    return Open_CheckBreak();
}

// ============================================================
// SZFolderExtractCallback implementation
// ============================================================

Z7_COM7F_IMF(SZFolderExtractCallback::SetTotal(UInt64 total)) {
    TotalSize = total;
    return S_OK;
}

Z7_COM7F_IMF(SZFolderExtractCallback::SetCompleted(const UInt64* completed)) {
    if (completed && TotalSize > 0) {
        double f = (double)*completed / (double)TotalSize;
        UInt64 c = *completed, t = TotalSize;
        SZOperationSession* session = Session;
        if (session) {
            [session reportProgressFraction:f];
            [session reportBytesCompleted:c total:t];
            if ([session shouldCancel])
                return E_ABORT;
        }
    }
    return S_OK;
}

Z7_COM7F_IMF(SZFolderExtractCallback::AskOverwrite(
    const wchar_t* existName, const FILETIME* existTime, const UInt64* existSize,
    const wchar_t* newName, const FILETIME* newTime, const UInt64* newSize,
    Int32* answer)) {
    switch (OverwriteMode) {
    case SZOverwriteModeOverwrite:
        *answer = NOverwriteAnswer::kYesToAll;
        return S_OK;
    case SZOverwriteModeSkip:
        *answer = NOverwriteAnswer::kNoToAll;
        return S_OK;
    case SZOverwriteModeRename:
        *answer = NOverwriteAnswer::kAutoRename;
        return S_OK;
    case SZOverwriteModeAsk:
    default: {
        __block Int32 result = NOverwriteAnswer::kYes;
        NSString* existStr = existName ? ToNS(UString(existName)) : @"";
        NSString* newStr = newName ? ToNS(UString(newName)) : @"";

        NSMutableString* info = [NSMutableString string];
        [info appendFormat:@"%@:\n%@", SZLocalizedString(@"replace.wouldYouLike"), existStr];
        if (existSize) {
            [info appendFormat:@"\n%@: %@", SZLocalizedString(@"column.size"),
                [NSByteCountFormatter stringFromByteCount:(long long)*existSize
                                               countStyle:NSByteCountFormatterCountStyleFile]];
        }
        NSString* existDateStr = SZFormatFileTime(existTime);
        if (existDateStr) {
            [info appendFormat:@"\n%@: %@", SZLocalizedString(@"column.modified"), existDateStr];
        }
        [info appendFormat:@"\n\n%@\n%@", SZLocalizedString(@"replace.withThisOne"), newStr];
        if (newSize) {
            [info appendFormat:@"\n%@: %@", SZLocalizedString(@"column.size"),
                [NSByteCountFormatter stringFromByteCount:(long long)*newSize
                                               countStyle:NSByteCountFormatterCountStyleFile]];
        }
        NSString* newDateStr = SZFormatFileTime(newTime);
        if (newDateStr) {
            [info appendFormat:@"\n%@: %@", SZLocalizedString(@"column.modified"), newDateStr];
        }

        NSInteger choice = Session
            ? [Session requestChoiceWithStyle:SZOperationPromptStyleWarning
                                        title:SZLocalizedString(@"replace.confirmTitle")
                                      message:info
                                 buttonTitles:@[ SZLocalizedString(@"common.yes"), SZLocalizedString(@"common.yesToAll"), SZLocalizedString(@"common.no"), SZLocalizedString(@"common.noToAll"), SZLocalizedString(@"replace.autoRename"), SZLocalizedString(@"common.cancel") ]]
            : 5;
        if (choice == 0)
            result = NOverwriteAnswer::kYes;
        else if (choice == 1)
            result = NOverwriteAnswer::kYesToAll;
        else if (choice == 2)
            result = NOverwriteAnswer::kNo;
        else if (choice == 3)
            result = NOverwriteAnswer::kNoToAll;
        else if (choice == 4)
            result = NOverwriteAnswer::kAutoRename;
        else
            result = NOverwriteAnswer::kCancel;

        *answer = result;
        if (result == NOverwriteAnswer::kYesToAll)
            OverwriteMode = SZOverwriteModeOverwrite;
        else if (result == NOverwriteAnswer::kNoToAll)
            OverwriteMode = SZOverwriteModeSkip;
        return S_OK;
    }
    }
}

Z7_COM7F_IMF(SZFolderExtractCallback::PrepareOperation(const wchar_t* name, Int32 isFolder, Int32 askExtractMode, const UInt64* position)) {
    CurrentFilePath.Empty();
    IsFolder = (isFolder != 0);
    if (name) {
        CurrentFilePath = name;
        SZOperationSession* session = Session;
        if (session) {
            NSString* prefix;
            switch (askExtractMode) {
            case NArchive::NExtract::NAskMode::kTest:
                prefix = SZLocalizedString(@"progress.testing");
                break;
            case NArchive::NExtract::NAskMode::kSkip:
                prefix = SZLocalizedString(@"progress.skipping");
                break;
            case NArchive::NExtract::NAskMode::kReadExternal:
                prefix = SZLocalizedString(@"progress.opening");
                break;
            default:
                prefix = nil;
                break;
            }
            NSString* n = ToNS(UString(name));
            if (prefix) {
                [session reportCurrentFileName:[NSString stringWithFormat:@"%@: %@", prefix, n]];
            } else {
                [session reportCurrentFileName:n];
            }
        }
    }
    return S_OK;
}

Z7_COM7F_IMF(SZFolderExtractCallback::MessageError(const wchar_t* message)) {
    NumErrors++;
    if (message) {
        UString extractedMessage(message);
        SZAppendErrorMessage(LastErrorMessage, extractedMessage);
        SZLogError(@"ShichiZip", @"Extract error: %@", ToNS(extractedMessage));
    }
    return S_OK;
}

Z7_COM7F_IMF(SZFolderExtractCallback::SetOperationResult(Int32 opRes, Int32 encrypted)) {
    if (opRes != NArchive::NExtract::NOperationResult::kOK) {
        NumErrors++;

        UString errorMessage;
        SZBuildExtractErrorMessage(opRes, encrypted, CurrentFilePath, errorMessage);
        SZAppendErrorMessage(LastErrorMessage, errorMessage);

        if (opRes == NArchive::NExtract::NOperationResult::kWrongPassword || (encrypted && opRes == NArchive::NExtract::NOperationResult::kCRCError) || (encrypted && opRes == NArchive::NExtract::NOperationResult::kDataError)) {
            PasswordWasWrong = true;
            PasswordIsDefined = false;
            Password.Empty();
        }
    }
    if (!IsFolder) {
        NumFilesCompleted++;
        SZOperationSession* session = Session;
        if (session) {
            [session reportFilesCompleted:NumFilesCompleted];
        }
    }
    CurrentFilePath.Empty();
    return S_OK;
}

Z7_COM7F_IMF(SZFolderExtractCallback::ReportExtractResult(Int32 opRes, Int32 encrypted, const wchar_t* name)) {
    if (opRes != NArchive::NExtract::NOperationResult::kOK) {
        NumErrors++;
        UString errorMessage;
        SZBuildExtractErrorMessage(opRes, encrypted, name, errorMessage);
        SZAppendErrorMessage(LastErrorMessage, errorMessage);
    }
    return S_OK;
}

Z7_COM7F_IMF(SZFolderExtractCallback::CryptoGetTextPassword(BSTR* pw)) {
    // Some callers free the out BSTR even on failure, so initialize it first.
    if (pw) {
        *pw = NULL;
    }
    PasswordWasAsked = true;
    if (!PasswordIsDefined) {
        HRESULT hr = SZRequestOperationPassword(Session, Password, PasswordIsDefined);
        if (hr != S_OK)
            return hr;
    }
    return StringToBstr(Password, pw);
}

Z7_COM7F_IMF(SZFolderExtractCallback::RequestMemoryUse(
    UInt32 flags, UInt32 indexType, UInt32 index, const wchar_t* path,
    UInt64 requiredSize, UInt64* allowedSize, UInt32* answerFlags)) {
    UNUSED_VAR(index)

    if (!allowedSize || !answerFlags) {
        return E_INVALIDARG;
    }

    UInt64 currentLimitBytes = *allowedSize;
    uint32_t currentLimitGB = SZRoundUpByteCountToGB(currentLimitBytes);

    if ((flags & NRequestMemoryUseFlags::k_IsReport) == 0) {
        if (SZExtractionMemoryLimitIsEnabled()) {
            const uint64_t configuredLimitBytes = SZConfiguredExtractionMemoryLimitBytes();
            if ((flags & NRequestMemoryUseFlags::k_AllowedSize_WasForced) == 0
                || currentLimitBytes < configuredLimitBytes) {
                currentLimitBytes = configuredLimitBytes;
                currentLimitGB = SZConfiguredExtractionMemoryLimitGB();
            }
        }

        *allowedSize = currentLimitBytes;
        if (requiredSize <= currentLimitBytes) {
            *answerFlags = NRequestMemoryAnswerFlags::k_Allow;
            return S_OK;
        }

        *answerFlags = NRequestMemoryAnswerFlags::k_Limit_Exceeded;
        if (flags & NRequestMemoryUseFlags::k_SkipArc_IsExpected) {
            *answerFlags |= NRequestMemoryAnswerFlags::k_SkipArc;
        }
    }

    const uint32_t requiredGB = SZRoundUpByteCountToGB(requiredSize);
    NSString* archivePath = ArchivePath.IsEmpty() ? nil : ToNS(ArchivePath);
    NSString* filePath = path ? ToNS(UString(path)) : nil;

    if ((flags & NRequestMemoryUseFlags::k_IsReport) == 0) {
        if (!RememberMemoryDecision) {
            __block BOOL confirmed = NO;
            __block SZMemoryLimitPromptResult* promptResult = nil;
            const BOOL showRemember = indexType != NArchive::NEventIndexType::kNoIndex || path != NULL;

            SZOperationSession* session = Session;
            if (session) {
                [session prepareForUserInteraction];
            }

            SZDispatchSyncOnMainThread(^{
                confirmed = [SZDialogPresenter promptForMemoryLimitWithRequiredBytes:requiredSize
                                                                   currentLimitBytes:currentLimitBytes
                                                                         archivePath:archivePath
                                                                            filePath:filePath
                                                                            testMode:TestMode
                                                                        showRemember:showRemember
                                                                              result:&promptResult];
            });

            if (session) {
                [session finishUserInteraction];
            }

            if (!confirmed) {
                *answerFlags = NRequestMemoryAnswerFlags::k_Stop;
                return E_ABORT;
            }

            if (promptResult.saveLimit) {
                currentLimitGB = promptResult.limitGB;
                currentLimitBytes = ((UInt64)promptResult.limitGB) << 30;
                SZPersistExtractionMemoryLimitGB(promptResult.limitGB);
            }

            if (promptResult.rememberChoice) {
                RememberMemoryDecision = true;
                SkipMemoryArchive = promptResult.skipArchive;
            }

            *allowedSize = currentLimitBytes;
            if (!promptResult.skipArchive) {
                *answerFlags = NRequestMemoryAnswerFlags::k_Allow;
                return S_OK;
            }

            *answerFlags = NRequestMemoryAnswerFlags::k_SkipArc | NRequestMemoryAnswerFlags::k_Limit_Exceeded;
            flags |= NRequestMemoryUseFlags::k_Report_SkipArc;
        } else {
            *allowedSize = currentLimitBytes;
            if (!SkipMemoryArchive) {
                *answerFlags = NRequestMemoryAnswerFlags::k_Allow;
                return S_OK;
            }

            *answerFlags = NRequestMemoryAnswerFlags::k_SkipArc | NRequestMemoryAnswerFlags::k_Limit_Exceeded;
            flags |= NRequestMemoryUseFlags::k_Report_SkipArc;
        }
    }

    if ((flags & NRequestMemoryUseFlags::k_NoErrorMessage) == 0) {
        const BOOL archiveSkipped = (flags & NRequestMemoryUseFlags::k_SkipArc_IsExpected)
            || (flags & NRequestMemoryUseFlags::k_Report_SkipArc);
        NSString* failureReason = SZBuildMemoryLimitFailureReason(requiredGB,
            currentLimitGB,
            archivePath,
            filePath,
            archiveSkipped);
        SZAppendErrorMessage(LastErrorMessage, failureReason);
        NumErrors++;
        SZLogError(@"ShichiZip", @"%@", failureReason);
    }

    return S_OK;
}

// ============================================================
// SZUpdateCallbackUI implementation
// ============================================================

HRESULT SZUpdateCallbackUI::SetTotal(UInt64 total) {
    TotalSize = total;
    SZOperationSession* session = Session;
    if (session && total > 0) {
        [session reportProgressFraction:0.0];
        [session reportBytesCompleted:0 total:total];
    }
    return S_OK;
}

HRESULT SZUpdateCallbackUI::SetCompleted(const UInt64* completed) {
    if (completed && TotalSize > 0) {
        double f = (double)*completed / (double)TotalSize;
        UInt64 c = *completed, t = TotalSize;
        SZOperationSession* session = Session;
        if (session) {
            [session reportProgressFraction:f];
            [session reportBytesCompleted:c total:t];
            if ([session shouldCancel])
                return E_ABORT;
        }
    }
    return S_OK;
}

HRESULT SZUpdateCallbackUI::CheckBreak() {
    SZOperationSession* session = Session;
    if (session && [session shouldCancel])
        return E_ABORT;
    return S_OK;
}

HRESULT SZUpdateCallbackUI::StartScanning() {
    SZOperationSession* session = Session;
    if (session) {
        [session reportProgressFraction:0.0];
        [session reportCurrentFileName:SZLocalizedString(@"progress.scanning")];
    }
    return CheckBreak();
}

HRESULT SZUpdateCallbackUI::FinishScanning(const CDirItemsStat&) {
    return CheckBreak();
}

HRESULT SZUpdateCallbackUI::ScanProgress(const CDirItemsStat&, const FString& path, bool) {
    SZOperationSession* session = Session;
    if (session && !path.IsEmpty()) {
        [session reportCurrentFileName:ToNS(fs2us(path))];
    }
    return CheckBreak();
}

HRESULT SZUpdateCallbackUI::GetStream(const wchar_t* name, bool, bool, UInt32) {
    if (name) {
        SZOperationSession* session = Session;
        if (session) {
            NSString* n = ToNS(UString(name));
            [session reportCurrentFileName:n];
        }
    }
    return S_OK;
}

HRESULT SZUpdateCallbackUI::CryptoGetTextPassword2(Int32* passwordIsDefined, BSTR* password) {
    // Initialize the out BSTR before any early return.
    if (password) {
        *password = NULL;
    }
    if (passwordIsDefined) {
        *passwordIsDefined = PasswordIsDefined ? 1 : 0;
    }
    if (!PasswordIsDefined) {
        return S_OK;
    }
    return StringToBstr(Password, password);
}

HRESULT SZUpdateCallbackUI::CryptoGetTextPassword(BSTR* password) {
    if (password) {
        *password = NULL;
    }
    if (!PasswordIsDefined)
        return E_ABORT;
    return StringToBstr(Password, password);
}

// ============================================================
// SZAgentUpdateCallback implementation
// ============================================================

Z7_COM7F_IMF(SZAgentUpdateCallback::SetNumFiles(UInt64 /* numFiles */)) {
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::SetTotal(UInt64 total)) {
    TotalSize = total;
    SZOperationSession* session = Session;
    if (session && total > 0) {
        [session reportProgressFraction:0.0];
        [session reportBytesCompleted:0 total:total];
    }
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::SetCompleted(const UInt64* completed)) {
    if (completed && TotalSize > 0) {
        const UInt64 current = MIN(*completed, TotalSize);
        const double fraction = (double)current / (double)TotalSize;
        SZOperationSession* session = Session;
        if (session) {
            [session reportProgressFraction:fraction];
            [session reportBytesCompleted:current total:TotalSize];
        }
    }
    return SZAgentCheckBreak(Session);
}

Z7_COM7F_IMF(SZAgentUpdateCallback::SetRatioInfo(const UInt64* /* inSize */, const UInt64* /* outSize */)) {
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::CompressOperation(const wchar_t* name)) {
    SZReportAgentCurrentPath(Session, SZLocalizedString(@"progress.updating"), name);
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::DeleteOperation(const wchar_t* name)) {
    SZReportAgentCurrentPath(Session, SZLocalizedString(@"progress.deleting"), name);
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::OperationResult(Int32 /* opRes */)) {
    SZOperationSession* session = Session;
    if (session) {
        [session reportFilesCompleted:++NumFilesCompleted];
    }
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::UpdateErrorMessage(const wchar_t* message)) {
    SZAppendErrorMessage(LastErrorMessage, UString(message ? message : L""));
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::OpenFileError(const wchar_t* path, HRESULT errorCode)) {
    SZAppendHRESULTMessage(LastErrorMessage, path, errorCode);
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::ReadingFileError(const wchar_t* path, HRESULT errorCode)) {
    SZAppendHRESULTMessage(LastErrorMessage, path, errorCode);
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::ReportExtractResult(Int32 opRes, Int32 isEncrypted, const wchar_t* path)) {
    if (opRes != NArchive::NExtract::NOperationResult::kOK) {
        UString message;
        SetExtractErrorMessage(opRes, isEncrypted, path, message);
        SZAppendErrorMessage(LastErrorMessage, message);
    }
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::ReportUpdateOperation(UInt32 /* notifyOp */, const wchar_t* path, Int32 /* isDir */)) {
    SZReportAgentCurrentPath(Session, SZLocalizedString(@"progress.updating"), path);
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::ScanError(const wchar_t* path, HRESULT errorCode)) {
    SZAppendHRESULTMessage(LastErrorMessage, path, errorCode);
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::ScanProgress(UInt64 /* numFolders */, UInt64 /* numFiles */, UInt64 /* totalSize */, const wchar_t* path, Int32 /* isDir */)) {
    SZReportAgentCurrentPath(Session, SZLocalizedString(@"progress.scanning"), path);
    return SZAgentCheckBreak(Session);
}

Z7_COM7F_IMF(SZAgentUpdateCallback::CryptoGetTextPassword2(Int32* passwordIsDefined, BSTR* password)) {
    *password = NULL;
    if (passwordIsDefined) {
        *passwordIsDefined = BoolToInt(PasswordIsDefined);
    }
    if (!PasswordIsDefined) {
        return S_OK;
    }
    return StringToBstr(Password, password);
}

Z7_COM7F_IMF(SZAgentUpdateCallback::CryptoGetTextPassword(BSTR* password)) {
    *password = NULL;
    if (!PasswordIsDefined) {
        PasswordWasAsked = true;
        HRESULT hr = SZRequestOperationPassword(Session,
            Password,
            PasswordIsDefined,
            ToNS(ArchivePath));
        if (hr != S_OK) {
            return hr;
        }
    }

    if (!PasswordIsDefined) {
        return E_ABORT;
    }
    return StringToBstr(Password, password);
}

Z7_COM7F_IMF(SZAgentUpdateCallback::SetTotal(const UInt64* files, const UInt64* bytes)) {
    if (bytes && *bytes > 0) {
        OpenTotalValue = *bytes;
        HasOpenTotalValue = true;
        UsesBytesProgress = true;
    } else if (files && *files > 0) {
        OpenTotalValue = *files;
        HasOpenTotalValue = true;
        UsesBytesProgress = false;
    } else {
        OpenTotalValue = 0;
        HasOpenTotalValue = false;
        UsesBytesProgress = false;
    }

    SZOperationSession* session = Session;
    if (session && HasOpenTotalValue) {
        [session reportProgressFraction:0.0];
        if (UsesBytesProgress) {
            [session reportBytesCompleted:0 total:OpenTotalValue];
        }
    }

    return SZAgentCheckBreak(session);
}

Z7_COM7F_IMF(SZAgentUpdateCallback::SetCompleted(const UInt64* files, const UInt64* bytes)) {
    if (!HasOpenTotalValue || OpenTotalValue == 0) {
        return SZAgentCheckBreak(Session);
    }

    UInt64 completed = 0;
    if (UsesBytesProgress && bytes) {
        completed = *bytes;
    } else if (!UsesBytesProgress && files) {
        completed = *files;
    }

    if (completed > OpenTotalValue) {
        completed = OpenTotalValue;
    }

    SZOperationSession* session = Session;
    if (session) {
        [session reportProgressFraction:(double)completed / (double)OpenTotalValue];
        if (UsesBytesProgress) {
            [session reportBytesCompleted:completed total:OpenTotalValue];
        }
    }

    return SZAgentCheckBreak(session);
}

Z7_COM7F_IMF(SZAgentUpdateCallback::MoveArc_Start(const wchar_t* /* srcTempPath */, const wchar_t* destFinalPath, UInt64 size, Int32 /* updateMode */)) {
    TotalSize = size;
    ArchiveWasReplaced = false;
    SZReportAgentCurrentPath(Session, SZLocalizedString(@"progress.repacking"), destFinalPath);
    SZOperationSession* session = Session;
    if (session && size > 0) {
        [session reportProgressFraction:0.0];
        [session reportBytesCompleted:0 total:size];
    }
    return S_OK;
}

Z7_COM7F_IMF(SZAgentUpdateCallback::MoveArc_Progress(UInt64 totalSize, UInt64 currentSize)) {
    if (totalSize > 0) {
        const UInt64 completed = MIN(currentSize, totalSize);
        SZOperationSession* session = Session;
        if (session) {
            [session reportProgressFraction:(double)completed / (double)totalSize];
            [session reportBytesCompleted:completed total:totalSize];
        }
    }
    return SZAgentCheckBreak(Session);
}

Z7_COM7F_IMF(SZAgentUpdateCallback::MoveArc_Finish()) {
    ArchiveWasReplaced = true;
    SZOperationSession* session = Session;
    if (session && TotalSize > 0) {
        [session reportProgressFraction:1.0];
        [session reportBytesCompleted:TotalSize total:TotalSize];
    }
    return SZAgentCheckBreak(session);
}

Z7_COM7F_IMF(SZAgentUpdateCallback::Before_ArcReopen()) {
    SZOperationSession* session = Session;
    if (session) {
        [session clearCancellationRequest];
    }
    return S_OK;
}
