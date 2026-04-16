// SZCallbacks.h — C++ callback classes for the 7-Zip bridge

#pragma once
#include "SZBridgeCommon.h"

// clang-format off
#include "CPP/7zip/UI/Agent/IFolderArchive.h"
#include "CPP/7zip/UI/Common/ArchiveExtractCallback.h"
#include "CPP/7zip/UI/Common/EnumDirItems.h"
#include "CPP/7zip/UI/Common/Update.h"
#include "CPP/7zip/UI/Common/UpdateCallback.h"
// clang-format on

static inline HRESULT SZRequestOperationPassword(SZOperationSession* session,
    UString& outPassword,
    bool& wasDefined,
    NSString* context = nil) {
    if (!session) {
        return E_ABORT;
    }

    NSString* message = context.length > 0
        ? [NSString stringWithFormat:@"Enter password for \"%@\".", context]
        : @"This archive is encrypted. Enter password.";
    NSString* initialValue = wasDefined ? ToNS(outPassword) : nil;
    NSString* resolvedPassword = nil;
    BOOL confirmed = [session requestPasswordWithTitle:@"Password Required"
                                               message:message
                                          initialValue:initialValue
                                              password:&resolvedPassword];
    if (!confirmed) {
        return E_ABORT;
    }

    outPassword = ToU(resolvedPassword ?: @"");
    wasDefined = true;
    return S_OK;
}

// ============================================================
// IOpenCallbackUI — for CArchiveLink::Open3()
// ============================================================
class SZOpenCallbackUI : public IOpenCallbackUI {
public:
    UString Password;
    bool PasswordIsDefined;
    bool PasswordWasAsked;
    UInt64 TotalValue;
    bool HasTotalValue;
    bool UsesBytesProgress;
    __weak SZOperationSession* Session;

    SZOpenCallbackUI();
    virtual ~SZOpenCallbackUI() {
        // Wipe the plaintext password from heap on destruction so a
        // core dump or swap inspection cannot recover it.
        Password.Wipe_and_Empty();
    }

    HRESULT Open_CheckBreak() override;
    HRESULT Open_SetTotal(const UInt64*, const UInt64*) override;
    HRESULT Open_SetCompleted(const UInt64*, const UInt64*) override;
    HRESULT Open_Finished() override;
#ifndef Z7_NO_CRYPTO
    HRESULT Open_CryptoGetTextPassword(BSTR* password) override {
        PasswordWasAsked = true;
        if (!PasswordIsDefined) {
            HRESULT hr = SZRequestOperationPassword(Session, Password, PasswordIsDefined);
            if (hr != S_OK)
                return hr;
        }
        return StringToBstr(Password, password);
    }
#endif
};

// ============================================================
// IFolderArchiveExtractCallback — UI callback for extraction
// ============================================================
class SZFolderExtractCallback final : public IFolderArchiveExtractCallback,
                                      public IFolderArchiveExtractCallback2,
                                      public ICryptoGetTextPassword,
                                      public IArchiveRequestMemoryUseCallback,
                                      public CMyUnknownImp {
public:
    UString Password;
    bool PasswordIsDefined;
    bool PasswordWasAsked;
    UInt64 TotalSize;
    SZOverwriteMode OverwriteMode;
    __weak SZOperationSession* Session;
    UInt32 NumErrors;
    UInt32 NumFilesCompleted;
    bool PasswordWasWrong;
    bool TestMode;
    bool IsFolder;
    bool RememberMemoryDecision;
    bool SkipMemoryArchive;
    UString ArchivePath;
    UString CurrentFilePath;
    UString LastErrorMessage;

    SZFolderExtractCallback()
        : PasswordIsDefined(false)
        , PasswordWasAsked(false)
        , TotalSize(0)
        , OverwriteMode(SZOverwriteModeAsk)
        , Session(nil)
        , NumErrors(0)
        , NumFilesCompleted(0)
        , PasswordWasWrong(false)
        , TestMode(false)
        , IsFolder(false)
        , RememberMemoryDecision(false)
        , SkipMemoryArchive(false) {
    }

    virtual ~SZFolderExtractCallback() {
        Password.Wipe_and_Empty();
    }

    Z7_COM_UNKNOWN_IMP_4(IFolderArchiveExtractCallback, IFolderArchiveExtractCallback2, ICryptoGetTextPassword, IArchiveRequestMemoryUseCallback)

    STDMETHOD(SetTotal)(UInt64 total) override;
    STDMETHOD(SetCompleted)(const UInt64* completed) override;
    STDMETHOD(AskOverwrite)(
        const wchar_t* existName, const FILETIME* existTime, const UInt64* existSize,
        const wchar_t* newName, const FILETIME* newTime, const UInt64* newSize,
        Int32* answer) override;
    STDMETHOD(PrepareOperation)(const wchar_t* name, Int32 isFolder, Int32 askExtractMode, const UInt64* position) override;
    STDMETHOD(MessageError)(const wchar_t* message) override;
    STDMETHOD(SetOperationResult)(Int32 opRes, Int32 encrypted) override;
    STDMETHOD(ReportExtractResult)(Int32 opRes, Int32 encrypted, const wchar_t* name) override;
    STDMETHOD(CryptoGetTextPassword)(BSTR* pw) override;
    STDMETHOD(RequestMemoryUse)(UInt32 flags, UInt32 indexType, UInt32 index, const wchar_t* path,
        UInt64 requiredSize, UInt64* allowedSize, UInt32* answerFlags) override;
};

// ============================================================
// IUpdateCallbackUI2 — UI callback for archive creation
// ============================================================
class SZUpdateCallbackUI : public IUpdateCallbackUI2 {
public:
    UString Password;
    bool PasswordIsDefined;
    UInt64 TotalSize;
    __weak SZOperationSession* Session;

    SZUpdateCallbackUI()
        : PasswordIsDefined(false)
        , TotalSize(0)
        , Session(nil) {
    }

    virtual ~SZUpdateCallbackUI() {
        Password.Wipe_and_Empty();
    }

    // IUpdateCallbackUI
    HRESULT WriteSfx(const wchar_t*, UInt64) override { return S_OK; }
    HRESULT SetTotal(UInt64 total) override;
    HRESULT SetCompleted(const UInt64* completed) override;
    HRESULT SetRatioInfo(const UInt64*, const UInt64*) override { return S_OK; }
    HRESULT CheckBreak() override;
    HRESULT SetNumItems(const CArcToDoStat&) override { return S_OK; }
    HRESULT GetStream(const wchar_t* name, bool, bool, UInt32) override;
    HRESULT OpenFileError(const FString&, DWORD) override { return S_OK; }
    HRESULT ReadingFileError(const FString&, DWORD) override { return S_OK; }
    HRESULT SetOperationResult(Int32) override { return S_OK; }
    HRESULT ReportExtractResult(Int32, Int32, const wchar_t*) override { return S_OK; }
    HRESULT ReportUpdateOperation(UInt32, const wchar_t*, bool) override { return S_OK; }
    HRESULT CryptoGetTextPassword2(Int32* passwordIsDefined, BSTR* password) override;
    HRESULT CryptoGetTextPassword(BSTR* password) override;
    HRESULT ShowDeleteFile(const wchar_t*, bool) override { return S_OK; }

    // IUpdateCallbackUI2
    HRESULT OpenResult(const CCodecs*, const CArchiveLink&, const wchar_t*, HRESULT) override { return S_OK; }
    HRESULT StartScanning() override;
    HRESULT FinishScanning(const CDirItemsStat&) override;
    HRESULT StartOpenArchive(const wchar_t*) override { return S_OK; }
    HRESULT StartArchive(const wchar_t*, bool) override { return S_OK; }
    HRESULT FinishArchive(const CFinishArchiveStat&) override { return S_OK; }
    HRESULT DeletingAfterArchiving(const FString&, bool) override { return S_OK; }
    HRESULT FinishDeletingAfterArchiving() override { return S_OK; }
    HRESULT MoveArc_Start(const wchar_t*, const wchar_t*, UInt64, Int32) override { return S_OK; }
    HRESULT MoveArc_Progress(UInt64, UInt64) override { return S_OK; }
    HRESULT MoveArc_Finish() override { return S_OK; }

    // IDirItemsCallback
    HRESULT ScanError(const FString&, DWORD) override { return S_OK; }
    HRESULT ScanProgress(const CDirItemsStat&, const FString&, bool) override;
};

// ============================================================
// IFolderArchiveUpdateCallback* — UI callback for in-place archive updates
// ============================================================
class SZAgentUpdateCallback final : public IFolderArchiveUpdateCallback,
                                    public IFolderArchiveUpdateCallback2,
                                    public IFolderArchiveUpdateCallback_MoveArc,
                                    public IFolderScanProgress,
                                    public ICryptoGetTextPassword2,
                                    public ICryptoGetTextPassword,
                                    public IArchiveOpenCallback,
                                    public ICompressProgressInfo,
                                    public CMyUnknownImp {
public:
    UString Password;
    bool PasswordIsDefined;
    bool PasswordWasAsked;
    UInt64 TotalSize;
    UInt64 OpenTotalValue;
    bool HasOpenTotalValue;
    bool UsesBytesProgress;
    UInt64 NumFilesCompleted;
    bool ArchiveWasReplaced;
    __weak SZOperationSession* Session;
    UString ArchivePath;
    UString LastErrorMessage;

    SZAgentUpdateCallback()
        : PasswordIsDefined(false)
        , PasswordWasAsked(false)
        , TotalSize(0)
        , OpenTotalValue(0)
        , HasOpenTotalValue(false)
        , UsesBytesProgress(false)
        , NumFilesCompleted(0)
        , ArchiveWasReplaced(false)
        , Session(nil) {
    }

    virtual ~SZAgentUpdateCallback() {
        Password.Wipe_and_Empty();
    }

    Z7_COM_UNKNOWN_IMP_8(IFolderArchiveUpdateCallback,
        IFolderArchiveUpdateCallback2,
        IFolderArchiveUpdateCallback_MoveArc,
        IFolderScanProgress,
        ICryptoGetTextPassword2,
        ICryptoGetTextPassword,
        IArchiveOpenCallback,
        ICompressProgressInfo)

    STDMETHOD(SetNumFiles)(UInt64 numFiles) override;
    STDMETHOD(SetTotal)(UInt64 total) override;
    STDMETHOD(SetCompleted)(const UInt64* completed) override;
    STDMETHOD(SetRatioInfo)(const UInt64* inSize, const UInt64* outSize) override;
    STDMETHOD(CompressOperation)(const wchar_t* name) override;
    STDMETHOD(DeleteOperation)(const wchar_t* name) override;
    STDMETHOD(OperationResult)(Int32 opRes) override;
    STDMETHOD(UpdateErrorMessage)(const wchar_t* message) override;
    STDMETHOD(OpenFileError)(const wchar_t* path, HRESULT errorCode) override;
    STDMETHOD(ReadingFileError)(const wchar_t* path, HRESULT errorCode) override;
    STDMETHOD(ReportExtractResult)(Int32 opRes, Int32 isEncrypted, const wchar_t* path) override;
    STDMETHOD(ReportUpdateOperation)(UInt32 notifyOp, const wchar_t* path, Int32 isDir) override;
    STDMETHOD(ScanError)(const wchar_t* path, HRESULT errorCode) override;
    STDMETHOD(ScanProgress)(UInt64 numFolders, UInt64 numFiles, UInt64 totalSize, const wchar_t* path, Int32 isDir) override;
    STDMETHOD(CryptoGetTextPassword2)(Int32* passwordIsDefined, BSTR* password) override;
    STDMETHOD(CryptoGetTextPassword)(BSTR* password) override;
    STDMETHOD(SetTotal)(const UInt64* files, const UInt64* bytes) override;
    STDMETHOD(SetCompleted)(const UInt64* files, const UInt64* bytes) override;
    STDMETHOD(MoveArc_Start)(const wchar_t* srcTempPath, const wchar_t* destFinalPath, UInt64 size, Int32 updateMode) override;
    STDMETHOD(MoveArc_Progress)(UInt64 totalSize, UInt64 currentSize) override;
    STDMETHOD(MoveArc_Finish)(void) override;
    STDMETHOD(Before_ArcReopen)(void) override;
};
