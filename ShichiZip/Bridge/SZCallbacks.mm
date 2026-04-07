// SZCallbacks.mm — Callback implementations for extract and create

#include "SZCallbacks.h"

// ============================================================
// SZOpenCallbackUI implementation
// ============================================================

SZOpenCallbackUI::SZOpenCallbackUI() :
    PasswordIsDefined(false),
    PasswordWasAsked(false),
    TotalValue(0),
    HasTotalValue(false),
    UsesBytesProgress(false),
    Delegate(nil) {}

HRESULT SZOpenCallbackUI::Open_CheckBreak() {
    id<SZProgressDelegate> d = Delegate;
    if (d && [d progressShouldCancel]) {
        return E_ABORT;
    }
    return S_OK;
}

HRESULT SZOpenCallbackUI::Open_SetTotal(const UInt64 *numFiles, const UInt64 *numBytes) {
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

    id<SZProgressDelegate> d = Delegate;
    if (d && HasTotalValue) {
        const UInt64 total = TotalValue;
        const bool useBytesProgress = UsesBytesProgress;
        dispatch_async(dispatch_get_main_queue(), ^{
            [d progressDidUpdate:0.0];
            if (useBytesProgress) {
                [d progressDidUpdateBytesCompleted:0 total:total];
            }
        });
    }

    return Open_CheckBreak();
}

HRESULT SZOpenCallbackUI::Open_SetCompleted(const UInt64 *numFiles, const UInt64 *numBytes) {
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
    const bool useBytesProgress = UsesBytesProgress;
    id<SZProgressDelegate> d = Delegate;
    if (d) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [d progressDidUpdate:fraction];
            if (useBytesProgress) {
                [d progressDidUpdateBytesCompleted:completed total:total];
            }
        });
    }

    return Open_CheckBreak();
}

HRESULT SZOpenCallbackUI::Open_Finished() {
    id<SZProgressDelegate> d = Delegate;
    if (d && HasTotalValue && TotalValue > 0) {
        const UInt64 total = TotalValue;
        const bool useBytesProgress = UsesBytesProgress;
        dispatch_async(dispatch_get_main_queue(), ^{
            [d progressDidUpdate:1.0];
            if (useBytesProgress) {
                [d progressDidUpdateBytesCompleted:total total:total];
            }
        });
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

Z7_COM7F_IMF(SZFolderExtractCallback::SetCompleted(const UInt64 *completed)) {
    if (completed && TotalSize > 0) {
        double f = (double)*completed / (double)TotalSize;
        UInt64 c = *completed, t = TotalSize;
        id<SZProgressDelegate> d = Delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d progressDidUpdate:f];
                [d progressDidUpdateBytesCompleted:c total:t];
            });
            if ([d progressShouldCancel]) return E_ABORT;
        }
    }
    return S_OK;
}

Z7_COM7F_IMF(SZFolderExtractCallback::AskOverwrite(
    const wchar_t *existName, const FILETIME *existTime, const UInt64 *existSize,
    const wchar_t *newName, const FILETIME *newTime, const UInt64 *newSize,
    Int32 *answer))
{
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
            NSString *existStr = existName ? ToNS(UString(existName)) : @"";
            NSString *newStr = newName ? ToNS(UString(newName)) : @"";

            void (^showDialog)(void) = ^{
                SZPrepareProgressForUserInteraction(Delegate);
                NSMutableString *info = [NSMutableString string];
                [info appendFormat:@"Would you like to replace the existing file:\n%@", existStr];
                if (existSize) {
                    [info appendFormat:@"\nSize: %@",
                        [NSByteCountFormatter stringFromByteCount:(long long)*existSize
                                                       countStyle:NSByteCountFormatterCountStyleFile]];
                }
                [info appendFormat:@"\n\nwith this one from the archive:\n%@", newStr];
                if (newSize) {
                    [info appendFormat:@"\nSize: %@",
                        [NSByteCountFormatter stringFromByteCount:(long long)*newSize
                                                       countStyle:NSByteCountFormatterCountStyleFile]];
                }

                NSInteger choice = [SZDialogPresenter runMessageWithStyle:SZDialogStyleWarning
                                                                     title:@"File already exists"
                                                                   message:info
                                                              buttonTitles:@[@"Yes", @"Yes to All", @"No", @"No to All", @"Auto Rename", @"Cancel"]];
                if (choice == 0) result = NOverwriteAnswer::kYes;
                else if (choice == 1) result = NOverwriteAnswer::kYesToAll;
                else if (choice == 2) result = NOverwriteAnswer::kNo;
                else if (choice == 3) result = NOverwriteAnswer::kNoToAll;
                else if (choice == 4) result = NOverwriteAnswer::kAutoRename;
                else result = NOverwriteAnswer::kCancel;
            };

            if ([NSThread isMainThread]) showDialog();
            else dispatch_sync(dispatch_get_main_queue(), showDialog);

            *answer = result;
            if (result == NOverwriteAnswer::kYesToAll) OverwriteMode = SZOverwriteModeOverwrite;
            else if (result == NOverwriteAnswer::kNoToAll) OverwriteMode = SZOverwriteModeSkip;
            return S_OK;
        }
    }
}

Z7_COM7F_IMF(SZFolderExtractCallback::PrepareOperation(const wchar_t *name, Int32 isFolder, Int32 askExtractMode, const UInt64 *position)) {
    if (name) {
        id<SZProgressDelegate> d = Delegate;
        if (d) {
            NSString *n = ToNS(UString(name));
            dispatch_async(dispatch_get_main_queue(), ^{
                [d progressDidUpdateFileName:n];
            });
        }
    }
    return S_OK;
}

Z7_COM7F_IMF(SZFolderExtractCallback::MessageError(const wchar_t *message)) {
    NumErrors++;
    if (message) {
        NSLog(@"[ShichiZip] Extract error: %@", ToNS(UString(message)));
    }
    return S_OK;
}

Z7_COM7F_IMF(SZFolderExtractCallback::SetOperationResult(Int32 opRes, Int32 encrypted)) {
    if (opRes != NArchive::NExtract::NOperationResult::kOK) {
        NumErrors++;
        if (opRes == NArchive::NExtract::NOperationResult::kWrongPassword ||
            (encrypted && opRes == NArchive::NExtract::NOperationResult::kCRCError) ||
            (encrypted && opRes == NArchive::NExtract::NOperationResult::kDataError)) {
            PasswordWasWrong = true;
            PasswordIsDefined = false;
            Password.Empty();
        }
    }
    return S_OK;
}

Z7_COM7F_IMF(SZFolderExtractCallback::ReportExtractResult(Int32 opRes, Int32 encrypted, const wchar_t *name)) {
    return S_OK;
}

Z7_COM7F_IMF(SZFolderExtractCallback::CryptoGetTextPassword(BSTR *pw)) {
    PasswordWasAsked = true;
    if (!PasswordIsDefined) {
        SZPrepareProgressForUserInteraction(Delegate);
        HRESULT hr = SZPromptForPassword(Password, PasswordIsDefined);
        if (hr != S_OK) return hr;
    }
    return StringToBstr(Password, pw);
}

// ============================================================
// SZUpdateCallbackUI implementation
// ============================================================

HRESULT SZUpdateCallbackUI::SetTotal(UInt64 total) {
    TotalSize = total;
    return S_OK;
}

HRESULT SZUpdateCallbackUI::SetCompleted(const UInt64 *completed) {
    if (completed && TotalSize > 0) {
        double f = (double)*completed / (double)TotalSize;
        UInt64 c = *completed, t = TotalSize;
        id<SZProgressDelegate> d = Delegate;
        if (d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [d progressDidUpdate:f];
                [d progressDidUpdateBytesCompleted:c total:t];
            });
            if ([d progressShouldCancel]) return E_ABORT;
        }
    }
    return S_OK;
}

HRESULT SZUpdateCallbackUI::CheckBreak() {
    id<SZProgressDelegate> d = Delegate;
    if (d && [d progressShouldCancel]) return E_ABORT;
    return S_OK;
}

HRESULT SZUpdateCallbackUI::GetStream(const wchar_t *name, bool, bool, UInt32) {
    if (name) {
        id<SZProgressDelegate> d = Delegate;
        if (d) {
            NSString *n = ToNS(UString(name));
            dispatch_async(dispatch_get_main_queue(), ^{
                [d progressDidUpdateFileName:n];
            });
        }
    }
    return S_OK;
}

HRESULT SZUpdateCallbackUI::CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password) {
    *passwordIsDefined = PasswordIsDefined ? 1 : 0;
    return StringToBstr(Password, password);
}

HRESULT SZUpdateCallbackUI::CryptoGetTextPassword(BSTR *password) {
    if (!PasswordIsDefined) return E_ABORT;
    return StringToBstr(Password, password);
}
