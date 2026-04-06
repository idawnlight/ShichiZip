// SZCallbacks.h — C++ callback classes for the 7-Zip bridge

#pragma once
#include "SZBridgeCommon.h"
#include "CPP/7zip/UI/Common/ArchiveExtractCallback.h"
#include "CPP/7zip/UI/Common/Update.h"
#include "CPP/7zip/UI/Common/UpdateCallback.h"
#include "CPP/7zip/UI/Common/EnumDirItems.h"

// ============================================================
// IOpenCallbackUI — for CArchiveLink::Open3()
// ============================================================
class SZOpenCallbackUI : public IOpenCallbackUI {
public:
    UString Password;
    bool PasswordIsDefined;

    SZOpenCallbackUI() : PasswordIsDefined(false) {}

    HRESULT Open_CheckBreak() override { return S_OK; }
    HRESULT Open_SetTotal(const UInt64 *, const UInt64 *) override { return S_OK; }
    HRESULT Open_SetCompleted(const UInt64 *, const UInt64 *) override { return S_OK; }
    HRESULT Open_Finished() override { return S_OK; }
#ifndef Z7_NO_CRYPTO
    HRESULT Open_CryptoGetTextPassword(BSTR *password) override {
        if (!PasswordIsDefined) {
            HRESULT hr = SZPromptForPassword(Password, PasswordIsDefined);
            if (hr != S_OK) return hr;
        }
        return StringToBstr(Password, password);
    }
#endif
};

// ============================================================
// IFolderArchiveExtractCallback — UI callback for extraction
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
    UInt32 NumErrors;
    bool PasswordWasWrong;

    SZFolderExtractCallback() : PasswordIsDefined(false), TotalSize(0),
        OverwriteMode(SZOverwriteModeAsk), Delegate(nil),
        NumErrors(0), PasswordWasWrong(false) {}

    Z7_COM_UNKNOWN_IMP_3(IFolderArchiveExtractCallback, IFolderArchiveExtractCallback2, ICryptoGetTextPassword)

    STDMETHOD(SetTotal)(UInt64 total) override;
    STDMETHOD(SetCompleted)(const UInt64 *completed) override;
    STDMETHOD(AskOverwrite)(
        const wchar_t *existName, const FILETIME *existTime, const UInt64 *existSize,
        const wchar_t *newName, const FILETIME *newTime, const UInt64 *newSize,
        Int32 *answer) override;
    STDMETHOD(PrepareOperation)(const wchar_t *name, Int32 isFolder, Int32 askExtractMode, const UInt64 *position) override;
    STDMETHOD(MessageError)(const wchar_t *message) override;
    STDMETHOD(SetOperationResult)(Int32 opRes, Int32 encrypted) override;
    STDMETHOD(ReportExtractResult)(Int32 opRes, Int32 encrypted, const wchar_t *name) override;
    STDMETHOD(CryptoGetTextPassword)(BSTR *pw) override;
};

// ============================================================
// IUpdateCallbackUI2 — UI callback for archive creation
// ============================================================
class SZUpdateCallbackUI : public IUpdateCallbackUI2 {
public:
    UString Password;
    bool PasswordIsDefined;
    UInt64 TotalSize;
    __unsafe_unretained id<SZProgressDelegate> Delegate;

    SZUpdateCallbackUI() : PasswordIsDefined(false), TotalSize(0), Delegate(nil) {}

    // IUpdateCallbackUI
    HRESULT WriteSfx(const wchar_t *, UInt64) override { return S_OK; }
    HRESULT SetTotal(UInt64 total) override;
    HRESULT SetCompleted(const UInt64 *completed) override;
    HRESULT SetRatioInfo(const UInt64 *, const UInt64 *) override { return S_OK; }
    HRESULT CheckBreak() override;
    HRESULT SetNumItems(const CArcToDoStat &) override { return S_OK; }
    HRESULT GetStream(const wchar_t *name, bool, bool, UInt32) override;
    HRESULT OpenFileError(const FString &, DWORD) override { return S_OK; }
    HRESULT ReadingFileError(const FString &, DWORD) override { return S_OK; }
    HRESULT SetOperationResult(Int32) override { return S_OK; }
    HRESULT ReportExtractResult(Int32, Int32, const wchar_t *) override { return S_OK; }
    HRESULT ReportUpdateOperation(UInt32, const wchar_t *, bool) override { return S_OK; }
    HRESULT CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password) override;
    HRESULT CryptoGetTextPassword(BSTR *password) override;
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
