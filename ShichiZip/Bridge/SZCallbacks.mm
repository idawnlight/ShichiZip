// SZCallbacks.mm — Callback implementations for extract and create

#include "SZCallbacks.h"

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
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"File already exists";
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
                alert.informativeText = info;
                alert.alertStyle = NSAlertStyleWarning;
                [alert addButtonWithTitle:@"Yes"];
                [alert addButtonWithTitle:@"Yes to All"];
                [alert addButtonWithTitle:@"No"];
                [alert addButtonWithTitle:@"No to All"];
                [alert addButtonWithTitle:@"Auto Rename"];
                NSModalResponse resp = [alert runModal];
                if (resp == NSAlertFirstButtonReturn) result = NOverwriteAnswer::kYes;
                else if (resp == NSAlertFirstButtonReturn + 1) result = NOverwriteAnswer::kYesToAll;
                else if (resp == NSAlertFirstButtonReturn + 2) result = NOverwriteAnswer::kNo;
                else if (resp == NSAlertFirstButtonReturn + 3) result = NOverwriteAnswer::kNoToAll;
                else if (resp == NSAlertFirstButtonReturn + 4) result = NOverwriteAnswer::kAutoRename;
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
    if (!PasswordIsDefined) {
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
