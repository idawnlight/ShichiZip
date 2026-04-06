// SZArchive.mm — 7-Zip core bridge for ShichiZip
// This file must be compiled as Objective-C++ (.mm)

// Workaround for BOOL typedef conflict between 7-Zip (int) and ObjC (bool on arm64)
// Strategy: Let ObjC define BOOL first, then redirect 7-Zip's typedef to a dummy name

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "SZArchive.h"

// Define INITGUID to make this TU define the IID constants
#define INITGUID

// Before including MyWindows.h, redirect BOOL so 7-Zip's typedef creates a harmless alias
#define BOOL BOOL_7Z_COMPAT
#include "CPP/Common/MyWindows.h"
#undef BOOL
// Now BOOL refers to ObjC's bool type, and BOOL_7Z_COMPAT is typedef'd to int

#include "CPP/Common/MyString.h"
#include "CPP/Common/IntToString.h"
#include "CPP/Windows/FileDir.h"
#include "CPP/Windows/FileFind.h"
#include "CPP/Windows/FileName.h"
#include "CPP/Windows/PropVariant.h"
#include "CPP/Windows/PropVariantConv.h"
#include "CPP/7zip/Common/FileStreams.h"
#include "CPP/7zip/Common/StreamObjects.h"
#include "CPP/7zip/Archive/IArchive.h"
#include "CPP/7zip/IPassword.h"
#include "CPP/7zip/ICoder.h"
#include "CPP/7zip/UI/Common/LoadCodecs.h"
#include "CPP/7zip/UI/Common/OpenArchive.h"
#include "CPP/7zip/UI/Common/ArchiveExtractCallback.h"
#include "CPP/7zip/UI/Common/Extract.h"
#include "CPP/7zip/UI/Common/Update.h"
#include "CPP/7zip/UI/Common/UpdateCallback.h"
#include "CPP/7zip/UI/Common/EnumDirItems.h"
#include "CPP/7zip/UI/Common/SetProperties.h"
#include "CPP/7zip/UI/Common/Bench.h"
#include "CPP/7zip/UI/Common/HashCalc.h"
#include "CPP/7zip/UI/Common/IFileExtractCallback.h"
#include "CPP/Common/Wildcard.h"
#include "CPP/7zip/PropID.h"
#include "CPP/Windows/TimeUtils.h"
#include "C/7zCrc.h"

#include <string>
#include <vector>

NSString * const SZArchiveErrorDomain = @"SZArchiveErrorDomain";

static NSError *SZMakeError(NSInteger code, NSString *desc) {
    return [NSError errorWithDomain:SZArchiveErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: desc}];
}

// Codec manager singleton
static CCodecs *g_Codecs = nullptr;
static bool g_CodecsInitialized = false;

static CCodecs *GetCodecs() {
    if (!g_CodecsInitialized) {
        CrcGenerateTable();
        g_Codecs = new CCodecs;
        if (g_Codecs->Load() != S_OK) { delete g_Codecs; g_Codecs = nullptr; }
        g_CodecsInitialized = true;
    }
    return g_Codecs;
}

// UString <-> NSString using NSString's own UTF-8 facilities
static UString ToU(NSString *s) {
    if (!s) return UString();
    // Convert via wchar_t
    NSUInteger len = [s length];
    UString u;
    u.Empty();
    for (NSUInteger i = 0; i < len; i++) {
        unichar ch = [s characterAtIndex:i];
        u += (wchar_t)ch;
    }
    return u;
}
static NSString *ToNS(const UString &u) {
    NSMutableString *s = [NSMutableString stringWithCapacity:u.Len()];
    for (unsigned i = 0; i < u.Len(); i++) {
        unichar ch = (unichar)u[i];
        [s appendString:[NSString stringWithCharacters:&ch length:1]];
    }
    return s;
}

// Property helpers
static NSString *ItemStr(IInArchive *ar, UInt32 i, PROPID p) {
    NWindows::NCOM::CPropVariant v;
    if (ar->GetProperty(i, p, &v) != S_OK) return nil;
    if (v.vt == VT_BSTR && v.bstrVal) return ToNS(UString(v.bstrVal));
    return nil;
}
static uint64_t ItemU64(IInArchive *ar, UInt32 i, PROPID p) {
    NWindows::NCOM::CPropVariant v;
    if (ar->GetProperty(i, p, &v) != S_OK) return 0;
    if (v.vt == VT_UI8) return v.uhVal.QuadPart;
    if (v.vt == VT_UI4) return v.ulVal;
    return 0;
}
static int ItemBool(IInArchive *ar, UInt32 i, PROPID p) {
    NWindows::NCOM::CPropVariant v;
    if (ar->GetProperty(i, p, &v) != S_OK) return 0;
    return (v.vt == VT_BOOL && v.boolVal != VARIANT_FALSE) ? 1 : 0;
}
static NSDate *ItemDate(IInArchive *ar, UInt32 i, PROPID p) {
    NWindows::NCOM::CPropVariant v;
    if (ar->GetProperty(i, p, &v) != S_OK || v.vt != VT_FILETIME) return nil;
    uint64_t ft = ((uint64_t)v.filetime.dwHighDateTime << 32) | v.filetime.dwLowDateTime;
    static const uint64_t EPOCH_DIFF = 116444736000000000ULL;
    if (ft < EPOCH_DIFF) return nil;
    return [NSDate dateWithTimeIntervalSince1970:(double)(ft - EPOCH_DIFF) / 10000000.0];
}

// ============================================================
// Password prompt helper — shows dialog, blocks until answered
// Safe to call from any thread (avoids deadlock if already on main)
// ============================================================
static HRESULT PromptForPassword(UString &outPassword, bool &wasDefined, NSString *context = nil) {
    __block NSString *result = nil;

    void (^showDialog)(void) = ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Password Required";
        alert.informativeText = context
            ? [NSString stringWithFormat:@"Enter password for \"%@\":", context]
            : @"This archive is encrypted. Enter password:";
        alert.alertStyle = NSAlertStyleInformational;
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];

        NSSecureTextField *input = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
        input.placeholderString = @"Password";
        alert.accessoryView = input;
        [alert.window setInitialFirstResponder:input];

        NSModalResponse resp = [alert runModal];
        if (resp == NSAlertFirstButtonReturn) {
            result = input.stringValue;
        }
    };

    if ([NSThread isMainThread]) {
        showDialog();
    } else {
        dispatch_sync(dispatch_get_main_queue(), showDialog);
    }

    if (result && result.length > 0) {
        outPassword = ToU(result);
        wasDefined = true;
        return S_OK;
    }
    return E_ABORT;
}

// ============================================================
// IFolderArchiveExtractCallback — our UI callback, used by CArchiveExtractCallback
// This matches the pattern from ExtractCallbackConsole.cpp
// ============================================================
class SZFolderExtractCallback final :
    public IFolderArchiveExtractCallback,
    public IFolderArchiveExtractCallback2,
    public ICryptoGetTextPassword,
    public CMyUnknownImp
{
public:
    UString Password;
    bool PasswordIsDefined;
    UInt64 TotalSize;
    SZOverwriteMode OverwriteMode;
    __unsafe_unretained id<SZProgressDelegate> Delegate;

    SZFolderExtractCallback() : PasswordIsDefined(false), TotalSize(0),
        OverwriteMode(SZOverwriteModeAsk), Delegate(nil),
        NumErrors(0), PasswordWasWrong(false) {}

    // Error tracking
    UInt32 NumErrors;
    bool PasswordWasWrong;

    Z7_COM_UNKNOWN_IMP_3(IFolderArchiveExtractCallback, IFolderArchiveExtractCallback2, ICryptoGetTextPassword)

    // IProgress
    STDMETHOD(SetTotal)(UInt64 total) override {
        TotalSize = total;
        return S_OK;
    }
    STDMETHOD(SetCompleted)(const UInt64 *completed) override {
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

    // IFolderArchiveExtractCallback
    STDMETHOD(AskOverwrite)(
        const wchar_t *existName, const FILETIME *existTime, const UInt64 *existSize,
        const wchar_t *newName, const FILETIME *newTime, const UInt64 *newSize,
        Int32 *answer) override
    {
        // Map our SZOverwriteMode to 7-Zip's NOverwriteAnswer
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
                // Ask user on main thread with file details
                __block Int32 result = NOverwriteAnswer::kYes;
                NSString *existStr = existName ? ToNS(UString(existName)) : @"";
                NSString *newStr = newName ? ToNS(UString(newName)) : @"";
                dispatch_sync(dispatch_get_main_queue(), ^{
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
                });
                *answer = result;
                // If user chose "to all", update the mode for subsequent files
                if (result == NOverwriteAnswer::kYesToAll) OverwriteMode = SZOverwriteModeOverwrite;
                else if (result == NOverwriteAnswer::kNoToAll) OverwriteMode = SZOverwriteModeSkip;
                return S_OK;
            }
        }
    }

    STDMETHOD(PrepareOperation)(const wchar_t *name, Int32 isFolder, Int32 askExtractMode, const UInt64 *position) override {
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

    STDMETHOD(MessageError)(const wchar_t *message) override {
        NumErrors++;
        if (message) {
            NSString *msg = ToNS(UString(message));
            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"[ShichiZip] Extract error: %@", msg);
            });
        }
        return S_OK;
    }

    STDMETHOD(SetOperationResult)(Int32 opRes, Int32 encrypted) override {
        if (opRes != NArchive::NExtract::NOperationResult::kOK) {
            NumErrors++;
            if (opRes == NArchive::NExtract::NOperationResult::kWrongPassword ||
                (encrypted && opRes == NArchive::NExtract::NOperationResult::kCRCError) ||
                (encrypted && opRes == NArchive::NExtract::NOperationResult::kDataError)) {
                PasswordWasWrong = true;
                // Clear cached password so next attempt will prompt again
                PasswordIsDefined = false;
                Password.Empty();
            }
        }
        return S_OK;
    }

    // IFolderArchiveExtractCallback2
    STDMETHOD(ReportExtractResult)(Int32 opRes, Int32 encrypted, const wchar_t *name) override {
        return S_OK;
    }

    // ICryptoGetTextPassword (called during extraction when encrypted data is encountered)
    STDMETHOD(CryptoGetTextPassword)(BSTR *pw) override {
        if (!PasswordIsDefined) {
            // No password provided — prompt user
            HRESULT hr = PromptForPassword(Password, PasswordIsDefined);
            if (hr != S_OK) return hr;
        }
        return StringToBstr(Password, pw);
    }
};

// ============================================================
// IUpdateCallbackUI2 - our UI callback for archive creation
// Matches pattern from UpdateCallbackConsole.cpp
// ============================================================
class SZUpdateCallbackUI :
    public IUpdateCallbackUI2
{
public:
    UString Password;
    bool PasswordIsDefined;
    UInt64 TotalSize;
    __unsafe_unretained id<SZProgressDelegate> Delegate;

    SZUpdateCallbackUI() : PasswordIsDefined(false), TotalSize(0), Delegate(nil) {}

    // IUpdateCallbackUI
    HRESULT WriteSfx(const wchar_t *, UInt64) override { return S_OK; }
    HRESULT SetTotal(UInt64 total) override {
        TotalSize = total;
        return S_OK;
    }
    HRESULT SetCompleted(const UInt64 *completed) override {
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
    HRESULT SetRatioInfo(const UInt64 *, const UInt64 *) override { return S_OK; }
    HRESULT CheckBreak() override {
        id<SZProgressDelegate> d = Delegate;
        if (d && [d progressShouldCancel]) return E_ABORT;
        return S_OK;
    }
    HRESULT SetNumItems(const CArcToDoStat &) override { return S_OK; }
    HRESULT GetStream(const wchar_t *name, bool, bool, UInt32) override {
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
    HRESULT OpenFileError(const FString &, DWORD) override { return S_OK; }
    HRESULT ReadingFileError(const FString &, DWORD) override { return S_OK; }
    HRESULT SetOperationResult(Int32) override { return S_OK; }
    HRESULT ReportExtractResult(Int32, Int32, const wchar_t *) override { return S_OK; }
    HRESULT ReportUpdateOperation(UInt32, const wchar_t *, bool) override { return S_OK; }
    HRESULT CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password) override {
        *passwordIsDefined = PasswordIsDefined ? 1 : 0;
        return StringToBstr(Password, password);
    }
    HRESULT CryptoGetTextPassword(BSTR *password) override {
        if (!PasswordIsDefined) return E_ABORT;
        return StringToBstr(Password, password);
    }
    HRESULT ShowDeleteFile(const wchar_t *, bool) override { return S_OK; }

    // IUpdateCallbackUI2
    HRESULT OpenResult(const CCodecs *, const CArchiveLink &, const wchar_t *, HRESULT) override { return S_OK; }
    HRESULT StartScanning() override { return S_OK; }
    HRESULT FinishScanning(const CDirItemsStat &) override { return S_OK; }
    HRESULT StartOpenArchive(const wchar_t *) override { return S_OK; }
    HRESULT StartArchive(const wchar_t *, bool) override { return S_OK; }
    HRESULT FinishArchive(const CFinishArchiveStat &) override { return S_OK; }
    HRESULT DeletingAfterArchiving(const FString &, bool) override { return S_OK; }
    HRESULT FinishDeletingAfterArchiving() override { return S_OK; }
    HRESULT MoveArc_Start(const wchar_t *, const wchar_t *, UInt64, Int32) override { return S_OK; }
    HRESULT MoveArc_Progress(UInt64, UInt64) override { return S_OK; }
    HRESULT MoveArc_Finish() override { return S_OK; }

    // IDirItemsCallback
    HRESULT ScanError(const FString &, DWORD) override { return S_OK; }
    HRESULT ScanProgress(const CDirItemsStat &, const FString &, bool) override { return S_OK; }
};

// ============================================================
// ObjC implementations
// ============================================================
@implementation SZCompressionSettings
- (instancetype)init {
    if ((self = [super init])) { _format = SZArchiveFormat7z; _level = SZCompressionLevelNormal; _method = SZCompressionMethodLZMA2; _encryption = SZEncryptionMethodNone; _solidMode = YES; }
    return self;
}
@end
@implementation SZExtractionSettings
- (instancetype)init {
    if ((self = [super init])) { _pathMode = SZPathModeFullPaths; _overwriteMode = SZOverwriteModeAsk; }
    return self;
}
@end
@implementation SZArchiveEntry @end
@implementation SZFormatInfo @end

// ============================================================
// IOpenCallbackUI implementation (matches OpenCallbackConsole pattern)
// ============================================================
class SZOpenCallbackUI : public IOpenCallbackUI {
public:
    UString Password;
    bool PasswordIsDefined;
    __unsafe_unretained id<SZProgressDelegate> Delegate;

    SZOpenCallbackUI() : PasswordIsDefined(false), Delegate(nil) {}

    HRESULT Open_CheckBreak() override { return S_OK; }
    HRESULT Open_SetTotal(const UInt64 *, const UInt64 *) override { return S_OK; }
    HRESULT Open_SetCompleted(const UInt64 *, const UInt64 *) override { return S_OK; }
    HRESULT Open_Finished() override { return S_OK; }
#ifndef Z7_NO_CRYPTO
    HRESULT Open_CryptoGetTextPassword(BSTR *password) override {
        if (!PasswordIsDefined) {
            // No password provided — prompt user
            HRESULT hr = PromptForPassword(Password, PasswordIsDefined);
            if (hr != S_OK) return hr;
        }
        return StringToBstr(Password, password);
    }
#endif
};

@interface SZArchive () {
    CArchiveLink *_arcLink;  // Use official CArchiveLink instead of raw IInArchive
    BOOL _isOpen;
    NSString *_archivePath;
}
@end

@implementation SZArchive
- (instancetype)init {
    if ((self = [super init])) {
        _arcLink = new CArchiveLink;
        _isOpen = NO;
    }
    return self;
}
- (void)dealloc { [self close]; delete _arcLink; _arcLink = nullptr; }

- (BOOL)openAtPath:(NSString *)path error:(NSError **)error {
    return [self openAtPath:path password:nil error:error];
}

- (BOOL)openAtPath:(NSString *)path password:(NSString *)password error:(NSError **)error {
    CCodecs *codecs = GetCodecs();
    if (!codecs) { if (error) *error = SZMakeError(-1, @"Failed to init codecs"); return NO; }
    _archivePath = [path copy];

    // Use CArchiveLink::Open3() — the same code path as real 7-Zip
    CObjectVector<COpenType> types;  // empty = auto-detect all formats
    CIntVector excludedFormats;      // empty = don't exclude any
    CObjectVector<CProperty> props;  // empty = no special properties

    COpenOptions options;
    options.codecs = codecs;
    options.types = &types;
    options.excludedFormats = &excludedFormats;
    options.props = &props;
    options.stdInMode = false;
    options.stream = NULL;  // CArchiveLink will create its own stream from filePath
    options.filePath = ToU(path);

    SZOpenCallbackUI callbackUI;
    if (password) {
        callbackUI.PasswordIsDefined = true;
        callbackUI.Password = ToU(password);
    }

    HRESULT res = _arcLink->Open3(options, &callbackUI);

    if (res != S_OK) {
        NSString *desc;
        if (res == S_FALSE) desc = @"Cannot open archive or unsupported format";
        else if (res == E_ABORT) desc = @"Operation was cancelled";
        else desc = [NSString stringWithFormat:@"Failed to open archive (0x%08X)", (unsigned)res];
        if (error) *error = SZMakeError(res, desc);
        return NO;
    }

    _isOpen = YES;
    return YES;
}

- (void)close {
    if (_isOpen) {
        _arcLink->Close();
    }
    _isOpen = NO;
}

- (NSString *)formatName {
    if (!_isOpen) return nil;
    const CArc &arc = _arcLink->Arcs.Back();
    CCodecs *c = GetCodecs();
    if (!c || arc.FormatIndex < 0) return nil;
    return ToNS(c->Formats[arc.FormatIndex].Name);
}

- (NSUInteger)entryCount {
    if (!_isOpen) return 0;
    IInArchive *archive = _arcLink->GetArchive();
    if (!archive) return 0;
    UInt32 n = 0; archive->GetNumberOfItems(&n); return n;
}

- (NSArray<SZArchiveEntry *> *)entries {
    if (!_isOpen) return @[];
    IInArchive *archive = _arcLink->GetArchive();
    if (!archive) return @[];
    UInt32 n = 0; archive->GetNumberOfItems(&n);
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:n];
    for (UInt32 i = 0; i < n; i++) {
        SZArchiveEntry *e = [SZArchiveEntry new];
        e.index = i;
        e.path = ItemStr(archive, i, kpidPath) ?: @"";
        e.size = ItemU64(archive, i, kpidSize);
        e.packedSize = ItemU64(archive, i, kpidPackSize);
        e.crc = (uint32_t)ItemU64(archive, i, kpidCRC);
        e.isDirectory = ItemBool(archive, i, kpidIsDir);
        e.isEncrypted = ItemBool(archive, i, kpidEncrypted);
        e.method = ItemStr(archive, i, kpidMethod);
        e.attributes = (uint32_t)ItemU64(archive, i, kpidAttrib);
        e.modifiedDate = ItemDate(archive, i, kpidMTime);
        e.createdDate = ItemDate(archive, i, kpidCTime);
        e.comment = ItemStr(archive, i, kpidComment);
        [arr addObject:e];
    }
    return arr;
}

- (BOOL)extractToPath:(NSString *)dest settings:(SZExtractionSettings *)s progress:(id<SZProgressDelegate>)p error:(NSError **)error {
    if (!_isOpen) { if (error) *error = SZMakeError(-4, @"No archive open"); return NO; }
    IInArchive *archive = _arcLink->GetArchive();
    const CArc &arc = _arcLink->Arcs.Back();
    NWindows::NFile::NDir::CreateComplexDir(us2fs(ToU(dest)));

    // Map SZOverwriteMode → NExtract::NOverwriteMode
    NExtract::NOverwriteMode::EEnum owMode = NExtract::NOverwriteMode::kAsk;
    switch (s.overwriteMode) {
        case SZOverwriteModeOverwrite: owMode = NExtract::NOverwriteMode::kOverwrite; break;
        case SZOverwriteModeSkip: owMode = NExtract::NOverwriteMode::kSkip; break;
        case SZOverwriteModeRename: owMode = NExtract::NOverwriteMode::kRename; break;
        case SZOverwriteModeAsk: default: owMode = NExtract::NOverwriteMode::kAsk; break;
    }

    // Map SZPathMode → NExtract::NPathMode
    NExtract::NPathMode::EEnum pathMode = NExtract::NPathMode::kFullPaths;
    switch (s.pathMode) {
        case SZPathModeNoPaths: pathMode = NExtract::NPathMode::kNoPaths; break;
        case SZPathModeAbsolutePaths: pathMode = NExtract::NPathMode::kAbsPaths; break;
        case SZPathModeFullPaths: default: pathMode = NExtract::NPathMode::kFullPaths; break;
    }

    // Create our UI callback (IFolderArchiveExtractCallback)
    SZFolderExtractCallback *faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Delegate = p;
    faeSpec->OverwriteMode = s.overwriteMode;
    if (s.password) { faeSpec->PasswordIsDefined = true; faeSpec->Password = ToU(s.password); }

    // Create the official CArchiveExtractCallback (handles file creation, attrs, timestamps)
    CArchiveExtractCallback *ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);

    CExtractNtOptions ntOptions;
    UStringVector removePathParts;

    ecs->InitForMulti(false, pathMode, owMode,
        NExtract::NZoneIdMode::kNone, false);

    ecs->Init(ntOptions, NULL, &arc, faeCallback,
        false /* stdOutMode */, s == nil ? false : false /* testMode */,
        us2fs(ToU(dest)), removePathParts, false,
        arc.GetEstmatedPhySize());

    HRESULT r = archive->Extract(nullptr, (UInt32)(Int32)-1, 0, ec);
    if (r == S_OK && faeSpec->PasswordWasWrong) {
        if (error) *error = SZMakeError(-12, @"Wrong password");
        return NO;
    }
    if (r == S_OK && faeSpec->NumErrors > 0) {
        if (error) *error = SZMakeError(-13, [NSString stringWithFormat:@"Extraction completed with %u error(s)", faeSpec->NumErrors]);
        return NO;
    }
    if (r != S_OK) { if (error) *error = SZMakeError(r == E_ABORT ? -5 : -6, r == E_ABORT ? @"Cancelled" : @"Extraction failed"); return NO; }
    return YES;
}

- (BOOL)extractEntries:(NSArray<NSNumber *> *)indices toPath:(NSString *)dest settings:(SZExtractionSettings *)s progress:(id<SZProgressDelegate>)p error:(NSError **)error {
    if (!_isOpen) { if (error) *error = SZMakeError(-4, @"No archive open"); return NO; }
    IInArchive *archive = _arcLink->GetArchive();
    const CArc &arc = _arcLink->Arcs.Back();
    NWindows::NFile::NDir::CreateComplexDir(us2fs(ToU(dest)));

    NExtract::NOverwriteMode::EEnum owMode = NExtract::NOverwriteMode::kAsk;
    switch (s.overwriteMode) {
        case SZOverwriteModeOverwrite: owMode = NExtract::NOverwriteMode::kOverwrite; break;
        case SZOverwriteModeSkip: owMode = NExtract::NOverwriteMode::kSkip; break;
        case SZOverwriteModeRename: owMode = NExtract::NOverwriteMode::kRename; break;
        default: break;
    }
    NExtract::NPathMode::EEnum pathMode = NExtract::NPathMode::kFullPaths;
    switch (s.pathMode) {
        case SZPathModeNoPaths: pathMode = NExtract::NPathMode::kNoPaths; break;
        case SZPathModeAbsolutePaths: pathMode = NExtract::NPathMode::kAbsPaths; break;
        default: break;
    }

    SZFolderExtractCallback *faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Delegate = p;
    faeSpec->OverwriteMode = s.overwriteMode;
    if (s.password) { faeSpec->PasswordIsDefined = true; faeSpec->Password = ToU(s.password); }

    CArchiveExtractCallback *ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);

    CExtractNtOptions ntOptions;
    UStringVector removePathParts;

    ecs->InitForMulti(false, pathMode, owMode,
        NExtract::NZoneIdMode::kNone, false);
    ecs->Init(ntOptions, NULL, &arc, faeCallback,
        false, false, us2fs(ToU(dest)), removePathParts, false,
        arc.GetEstmatedPhySize());

    std::vector<UInt32> ia; ia.reserve(indices.count);
    for (NSNumber *n in indices) ia.push_back([n unsignedIntValue]);
    HRESULT r = archive->Extract(ia.data(), (UInt32)ia.size(), 0, ec);
    if (r == S_OK && faeSpec->PasswordWasWrong) {
        if (error) *error = SZMakeError(-12, @"Wrong password");
        return NO;
    }
    if (r == S_OK && faeSpec->NumErrors > 0) {
        if (error) *error = SZMakeError(-13, [NSString stringWithFormat:@"Extraction completed with %u error(s)", faeSpec->NumErrors]);
        return NO;
    }
    if (r != S_OK) { if (error) *error = SZMakeError(r == E_ABORT ? -5 : -6, r == E_ABORT ? @"Cancelled" : @"Extraction failed"); return NO; }
    return YES;
}

- (BOOL)testWithProgress:(id<SZProgressDelegate>)p error:(NSError **)error {
    if (!_isOpen) { if (error) *error = SZMakeError(-4, @"No archive open"); return NO; }
    IInArchive *archive = _arcLink->GetArchive();
    const CArc &arc = _arcLink->Arcs.Back();

    SZFolderExtractCallback *faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Delegate = p;

    CArchiveExtractCallback *ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);

    CExtractNtOptions ntOptions;
    UStringVector removePathParts;

    ecs->InitForMulti(false, NExtract::NPathMode::kFullPaths,
        NExtract::NOverwriteMode::kOverwrite,
        NExtract::NZoneIdMode::kNone, false);
    ecs->Init(ntOptions, NULL, &arc, faeCallback,
        false, true /* testMode */, FString(), removePathParts, false,
        arc.GetEstmatedPhySize());

    HRESULT r = archive->Extract(nullptr, (UInt32)(Int32)-1, 1 /* test */, ec);
    if (r == S_OK && faeSpec->PasswordWasWrong) {
        if (error) *error = SZMakeError(-12, @"Wrong password");
        return NO;
    }
    if (r == S_OK && faeSpec->NumErrors > 0) {
        if (error) *error = SZMakeError(-13, [NSString stringWithFormat:@"Test completed with %u error(s)", faeSpec->NumErrors]);
        return NO;
    }
    if (r != S_OK) { if (error) *error = SZMakeError(-7, @"Archive test failed"); return NO; }
    return YES;
}

+ (BOOL)createAtPath:(NSString *)archivePath fromPaths:(NSArray<NSString *> *)src settings:(SZCompressionSettings *)s progress:(id<SZProgressDelegate>)p error:(NSError **)error {
    CCodecs *codecs = GetCodecs();
    if (!codecs) { if (error) *error = SZMakeError(-1, @"Failed to init codecs"); return NO; }

    // Map format enum to format name
    static const char *fmts[] = {"7z","zip","tar","gzip","bzip2","xz","wim","zstd"};
    int fi = (int)s.format; if (fi < 0 || fi >= 8) fi = 0;

    // Set up update options — matches how CompressDialog/UpdateGUI does it
    CUpdateOptions options;
    options.SetActionCommand_Add();

    // Find format index
    UString fmtName;
    for (const char *c = fmts[fi]; *c; c++) fmtName += (wchar_t)(unsigned char)*c;
    int formatIndex = codecs->FindFormatForArchiveType(fmtName);
    if (formatIndex < 0) {
        // Try by extension from the archive path
        NSString *ext = [[archivePath pathExtension] lowercaseString];
        formatIndex = codecs->FindFormatForExtension(ToU(ext));
    }
    if (formatIndex < 0) { if (error) *error = SZMakeError(-8, @"Unsupported format"); return NO; }

    options.MethodMode.Type.FormatIndex = formatIndex;

    // Set compression properties (like SetOutProperties in UpdateGUI.cpp)
    CProperty propLevel;
    propLevel.Name = L"x";
    wchar_t levelBuf[16];
    swprintf(levelBuf, 16, L"%d", (int)s.level);
    propLevel.Value = levelBuf;
    options.MethodMode.Properties.Add(propLevel);

    if (s.numThreads > 0) {
        CProperty propMt;
        propMt.Name = L"mt";
        wchar_t mtBuf[16];
        swprintf(mtBuf, 16, L"%u", (unsigned)s.numThreads);
        propMt.Value = mtBuf;
        options.MethodMode.Properties.Add(propMt);
    }

    if (s.format == SZArchiveFormat7z && s.solidMode) {
        CProperty propSolid;
        propSolid.Name = L"s";
        propSolid.Value = L"on";
        options.MethodMode.Properties.Add(propSolid);
    }

    if (s.encryptFileNames && s.format == SZArchiveFormat7z) {
        CProperty propHe;
        propHe.Name = L"he";
        propHe.Value = L"on";
        options.MethodMode.Properties.Add(propHe);
    }

    // Password is handled via callback's CryptoGetTextPassword2()

    // Set up wildcard censor — add each source path
    NWildcard::CCensor censor;
    for (NSString *srcPath in src) {
        NWildcard::CCensorPathProps props;
        props.Recursive = true;
        censor.AddItem(NWildcard::k_AbsPath, true /* include */, ToU(srcPath), props);
    }

    // Set up callbacks
    SZUpdateCallbackUI callbackUI;
    callbackUI.Delegate = p;
    if (s.password && s.encryption != SZEncryptionMethodNone) {
        callbackUI.PasswordIsDefined = true;
        callbackUI.Password = ToU(s.password);
    }

    SZOpenCallbackUI openCallbackUI;

    CUpdateErrorInfo errorInfo;
    CObjectVector<COpenType> types;

    // THE CALL — same as 7-Zip Console/GUI
    HRESULT r = UpdateArchive(
        codecs,
        types,
        ToU(archivePath),
        censor,
        options,
        errorInfo,
        &openCallbackUI,
        &callbackUI,
        true /* needSetPath */
    );

    if (r != S_OK) {
        NSString *desc;
        if (r == E_ABORT) desc = @"Compression was cancelled";
        else if (errorInfo.Message.Len() > 0)
            desc = [NSString stringWithUTF8String:errorInfo.Message.Ptr()];
        else desc = [NSString stringWithFormat:@"Compression failed (0x%08X)", (unsigned)r];
        if (error) *error = SZMakeError(r, desc);
        return NO;
    }
    return YES;
}

+ (NSArray<SZFormatInfo *> *)supportedFormats {
    CCodecs *codecs = GetCodecs(); if (!codecs) return @[];
    NSMutableArray *arr = [NSMutableArray array];
    for (unsigned i = 0; i < codecs->Formats.Size(); i++) {
        const CArcInfoEx &ai = codecs->Formats[i];
        SZFormatInfo *info = [SZFormatInfo new]; info.name = ToNS(ai.Name);
        NSMutableArray *exts = [NSMutableArray array];
        for (unsigned j = 0; j < ai.Exts.Size(); j++) [exts addObject:ToNS(ai.Exts[j].Ext)];
        info.extensions = exts; info.canWrite = ai.UpdateEnabled; [arr addObject:info];
    }
    return arr;
}

+ (NSDictionary<NSString*,NSString*> *)calculateHashForPath:(NSString *)path error:(NSError **)error {
    CCodecs *codecs = GetCodecs();
    if (!codecs) { if (error) *error = SZMakeError(-1, @"Failed to init codecs"); return nil; }

    // Set up hash options with all algorithms
    CHashOptions options;
    options.Methods.Add(UString(L"CRC32"));
    options.Methods.Add(UString(L"CRC64"));
    options.Methods.Add(UString(L"SHA256"));
    options.Methods.Add(UString(L"SHA1"));
    options.Methods.Add(UString(L"BLAKE2sp"));

    // Set up censor for the single path
    NWildcard::CCensor censor;
    NWildcard::CCensorPathProps props;
    props.Recursive = false;
    censor.AddItem(NWildcard::k_AbsPath, true, ToU(path), props);

    // Hash callback that collects results
    class HashCallback : public IHashCallbackUI {
    public:
        NSMutableDictionary *results;
        HashCallback() { results = [NSMutableDictionary dictionary]; }

        HRESULT StartScanning() override { return S_OK; }
        HRESULT FinishScanning(const CDirItemsStat &) override { return S_OK; }
        HRESULT SetNumFiles(UInt64) override { return S_OK; }
        HRESULT SetTotal(UInt64) override { return S_OK; }
        HRESULT SetCompleted(const UInt64 *) override { return S_OK; }
        HRESULT CheckBreak() override { return S_OK; }
        HRESULT BeforeFirstFile(const CHashBundle &) override { return S_OK; }
        HRESULT GetStream(const wchar_t *, bool) override { return S_OK; }
        HRESULT OpenFileError(const FString &, DWORD) override { return S_OK; }
        HRESULT SetOperationResult(UInt64, const CHashBundle &hb, bool) override {
            for (unsigned i = 0; i < hb.Hashers.Size(); i++) {
                const CHasherState &h = hb.Hashers[i];
                char hex[256];
                HashHexToString(hex, h.Digests[0], h.DigestSize);
                NSString *name = [NSString stringWithUTF8String:h.Name.Ptr()];
                NSString *digest = [NSString stringWithUTF8String:hex];
                results[name] = digest;
            }
            return S_OK;
        }
        HRESULT AfterLastFile(CHashBundle &) override { return S_OK; }
        HRESULT ScanError(const FString &, DWORD) override { return S_OK; }
        HRESULT ScanProgress(const CDirItemsStat &, const FString &, bool) override { return S_OK; }
    };

    HashCallback callback;
    AString errorInfo;
    HRESULT r = HashCalc(EXTERNAL_CODECS_LOC_VARS censor, options, errorInfo, &callback);
    if (r != S_OK) {
        if (error) *error = SZMakeError(r, @"Hash calculation failed");
        return nil;
    }
    return callback.results;
}

+ (void)runBenchmarkWithIterations:(UInt32)numIterations
                          callback:(void (^)(NSString *line))printCallback
                        completion:(void (^)(BOOL success))completion {
    CCodecs *codecs = GetCodecs();
    if (!codecs) {
        if (completion) completion(NO);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSLog(@"[ShichiZip] Benchmark starting...");

        // Print callback that forwards to the block
        class SZBenchPrint : public IBenchPrintCallback {
        public:
            void (^_Nonnull printBlock)(NSString *);
            NSMutableString *currentLine;

            SZBenchPrint(void (^_Nonnull block)(NSString *)) : printBlock([block copy]) {
                currentLine = [NSMutableString string];
            }
            void Print(const char *s) override {
                if (s) [currentLine appendString:[NSString stringWithUTF8String:s]];
            }
            void NewLine() override {
                NSString *line = [currentLine copy];
                void (^blk)(NSString *) = printBlock;
                dispatch_async(dispatch_get_main_queue(), ^{ blk(line); });
                currentLine = [NSMutableString string];
            }
            HRESULT CheckBreak() override { return S_OK; }
        };

        SZBenchPrint printCB(printCallback);
        CObjectVector<CProperty> props;

        UInt32 iters = numIterations > 0 ? numIterations : 1;
        NSLog(@"[ShichiZip] Calling Bench() with %u iterations", iters);
        HRESULT r = Bench(EXTERNAL_CODECS_LOC_VARS &printCB, NULL, props, iters, false, NULL);
        NSLog(@"[ShichiZip] Bench() returned 0x%08X", (unsigned)r);

        BOOL success = (r == S_OK);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
        }
    });
}

@end
