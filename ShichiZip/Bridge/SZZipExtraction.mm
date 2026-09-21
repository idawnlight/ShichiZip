#include "SZZipExtraction.h"
#include "SZCallbacks.h"

#include <algorithm>
#include <set>

namespace {

using namespace NArchive::NExtract;

// CObjectVector keeps each string at a stable address while the pool grows.
class SZPasswordCandidates final {
public:
    CObjectVector<UString> Values;

    ~SZPasswordCandidates() {
        FOR_VECTOR(i, Values) {
            Values[i].Wipe_and_Empty();
        }
    }

    void Add(const UString& password) {
        FOR_VECTOR(i, Values) {
            if (Values[i] == password)
                return;
        }
        Values.Add(password);
    }

    void Add(NSString* password) {
        if (password) {
            UString value = ToU(password);
            Add(value);
            value.Wipe_and_Empty();
        }
    }
};

struct SZEncryptedZipEntry {
    UInt32 Index;
    UString Path;
    UInt64 Size;
};

static HRESULT CheckCancellation(SZFolderExtractCallback* ui) {
    return [ui->Session shouldCancel] ? E_ABORT : S_OK;
}

static UInt64 AddProgressBytes(UInt64 first, UInt64 second) {
    return first + std::min(second, UINT64_MAX - first);
}

// The ZIP handler decodes to a null sink in test mode, including authentication
// and CRC checks. No filesystem callback runs until all passwords are resolved.
class SZZipPasswordTestCallback final : public IArchiveExtractCallback,
                                        public ICryptoGetTextPassword,
                                        public IArchiveRequestMemoryUseCallback,
                                        public CMyUnknownImp {
public:
    SZZipPasswordTestCallback(SZFolderExtractCallback* ui,
        const UString& password, UInt64 completedBeforeEntry,
        UInt64 entrySize, UInt64& entryProgress)
        : UI(ui), Password(password), CompletedBeforeEntry(completedBeforeEntry),
          EntrySize(entrySize), EntryProgress(entryProgress) {}

    Int32 Result = NOperationResult::kDataError;
    bool ResultWasReported = false;
    bool PasswordWasAsked = false;

    Z7_COM_UNKNOWN_IMP_3(IArchiveExtractCallback, ICryptoGetTextPassword,
        IArchiveRequestMemoryUseCallback)

    STDMETHOD(SetTotal)(UInt64) override { return CheckCancellation(UI); }

    STDMETHOD(SetCompleted)(const UInt64* completed) override {
        RINOK(CheckCancellation(UI))
        if (completed && !(ResultWasReported && Result != NOperationResult::kOK)) {
            EntryProgress = std::max(EntryProgress, std::min(*completed, EntrySize));
            const UInt64 progress = AddProgressBytes(CompletedBeforeEntry, EntryProgress);
            return static_cast<IFolderArchiveExtractCallback*>(UI)->SetCompleted(&progress);
        }
        return S_OK;
    }

    STDMETHOD(GetStream)(UInt32, ISequentialOutStream** stream, Int32) override {
        *stream = NULL;
        return CheckCancellation(UI);
    }

    STDMETHOD(PrepareOperation)(Int32) override { return CheckCancellation(UI); }

    STDMETHOD(SetOperationResult)(Int32 result) override {
        Result = result;
        ResultWasReported = true;
        return CheckCancellation(UI);
    }

    STDMETHOD(CryptoGetTextPassword)(BSTR* password) override {
        *password = NULL;
        RINOK(CheckCancellation(UI))
        PasswordWasAsked = true;
        return StringToBstr(Password, password);
    }

    STDMETHOD(RequestMemoryUse)(UInt32 flags, UInt32 indexType, UInt32 index,
        const wchar_t* path, UInt64 requiredSize, UInt64* allowedSize,
        UInt32* answerFlags) override {
        RINOK(CheckCancellation(UI))
        return static_cast<IArchiveRequestMemoryUseCallback*>(UI)->RequestMemoryUse(flags, indexType, index, path,
            requiredSize, allowedSize, answerFlags);
    }

private:
    SZFolderExtractCallback* UI;
    const UString& Password;
    UInt64 CompletedBeforeEntry;
    UInt64 EntrySize;
    UInt64& EntryProgress;
};

static bool IsPasswordFailure(Int32 result) {
    // ZipCrypto and AES have short password verifiers. A wrong password can
    // pass that check, then fail decoding or the final integrity check.
    return result == NOperationResult::kWrongPassword
        || result == NOperationResult::kCRCError
        || result == NOperationResult::kDataError;
}

static HRESULT ReportValidationFailure(SZFolderExtractCallback* ui,
    const UString& path, Int32 result, bool passwordWasValidated) {
    if (passwordWasValidated && (result == NOperationResult::kCRCError
        || result == NOperationResult::kDataError)) {
        // An entry-bound password is already proven. Preserve the integrity
        // error rather than letting the legacy callback label it wrong password.
        UString message = ToU(SZLocalizedString(result == NOperationResult::kCRCError
            ? @"error.crcFailedGeneric" : @"error.dataErrorGeneric"));
        message += " : ";
        message += path;
        return static_cast<IFolderArchiveExtractCallback*>(ui)->MessageError(message);
    }
    return static_cast<IFolderArchiveExtractCallback*>(ui)->SetOperationResult(result, 1);
}

class SZZipEntryExtractionCallback final : public IArchiveExtractCallback,
                                          public ICryptoGetTextPassword,
                                          public CMyUnknownImp {
public:
    SZZipEntryExtractionCallback(IArchiveExtractCallback* inner,
        const SZZipPasswordCache& passwords, const SZZipExtractionProgress& progress)
        : Inner(inner), Passwords(passwords), Progress(progress) {}

    STDMETHOD(QueryInterface)(REFGUID iid, void** object) override {
        *object = NULL;
        if (iid == IID_IUnknown || iid == IID_IArchiveExtractCallback)
            *object = static_cast<IArchiveExtractCallback*>(this);
        else if (iid == IID_IProgress)
            *object = static_cast<IProgress*>(this);
        else if (iid == IID_ICryptoGetTextPassword)
            *object = static_cast<ICryptoGetTextPassword*>(this);
        else
            return Inner->QueryInterface(iid, object);
        AddRef();
        return S_OK;
    }

    Z7_COM_ADDREF_RELEASE

    STDMETHOD(SetTotal)(UInt64) override {
        // Preparation already established the whole operation's total. This
        // callback is used for one archive, so upstream's per-pass total is not
        // needed for its multi-archive progress conversion. Forwarding it would
        // reset the UI to zero after password validation.
        return S_OK;
    }
    STDMETHOD(SetCompleted)(const UInt64* completed) override {
        if (!completed)
            return Inner->SetCompleted(NULL);
        const UInt64 operationCompleted = std::min(Progress.TotalBytes,
            AddProgressBytes(Progress.PasswordValidationBytes, *completed));
        return Inner->SetCompleted(&operationCompleted);
    }
    STDMETHOD(GetStream)(UInt32 index, ISequentialOutStream** stream,
        Int32 askMode) override {
        Password = Passwords.PasswordForEntry(index);
        return Inner->GetStream(index, stream, askMode);
    }
    STDMETHOD(PrepareOperation)(Int32 askMode) override {
        return Inner->PrepareOperation(askMode);
    }
    STDMETHOD(SetOperationResult)(Int32 result) override {
        return Inner->SetOperationResult(result);
    }
    STDMETHOD(CryptoGetTextPassword)(BSTR* password) override {
        *password = NULL;
        if (Password)
            return StringToBstr(*Password, password);
        CMyComPtr<ICryptoGetTextPassword> fallback;
        RINOK(Inner.QueryInterface(IID_ICryptoGetTextPassword, &fallback))
        return fallback->CryptoGetTextPassword(password);
    }

private:
    CMyComPtr<IArchiveExtractCallback> Inner;
    const SZZipPasswordCache& Passwords;
    SZZipExtractionProgress Progress;
    const UString* Password = nullptr;
};

} // namespace

SZZipPasswordCache::~SZZipPasswordCache() { Clear(); }

void SZZipPasswordCache::Clear() {
    Entries.clear();
    FOR_VECTOR(i, Passwords) {
        Passwords[i].Wipe_and_Empty();
    }
    Passwords.Clear();
}

const UString* SZZipPasswordCache::PasswordForEntry(UInt32 index) const {
    const auto entry = Entries.find(index);
    return entry == Entries.end() ? nullptr : &Passwords[entry->second];
}

const UString* SZZipPasswordCache::SinglePassword() const {
    const UString* password = nullptr;
    for (const auto& entry : Entries) {
        const UString* candidate = &Passwords[entry.second];
        if (password && password != candidate)
            return nullptr;
        password = candidate;
    }
    return password;
}

bool SZZipPasswordCache::HasMultiplePasswords() const {
    return !Entries.empty() && !SinglePassword();
}

void SZZipPasswordCache::Remember(UInt32 index, const UString& password) {
    FOR_VECTOR(i, Passwords) {
        if (Passwords[i] == password) {
            Entries[index] = i;
            return;
        }
    }
    Entries[index] = Passwords.Add(password);
}

void SZZipPasswordCache::ForgetEntry(UInt32 index) { Entries.erase(index); }

HRESULT SZPrepareZipPasswords(IInArchive* archive,
    const std::vector<UInt32>& requestedIndices,
    SZZipPasswordCache& passwords,
    NSString* explicitPassword,
    NSString* archivePassword,
    SZFolderExtractCallback* ui,
    bool forceValidation,
    std::vector<UInt32>& verifiedEncryptedIndices,
    SZZipExtractionProgress& progress) {
    verifiedEncryptedIndices.clear();
    progress = {};
    RINOK(CheckCancellation(ui))
    IFolderArchiveExtractCallback* extractionUI = ui;
    UInt32 itemCount;
    RINOK(archive->GetNumberOfItems(&itemCount))
    std::vector<SZEncryptedZipEntry> entries;
    std::set<UInt32> seen;
    UInt64 requestedBytes = 0;
    for (UInt32 index : requestedIndices) {
        RINOK(CheckCancellation(ui))
        if (index >= itemCount)
            return E_INVALIDARG;
        NWindows::NCOM::CPropVariant value;
        RINOK(archive->GetProperty(index, kpidSize, &value))
        const UInt64 size = value.vt == VT_UI8 ? value.uhVal.QuadPart : 0;
        requestedBytes = AddProgressBytes(requestedBytes, size);
        if (!seen.insert(index).second)
            continue;
        RINOK(archive->GetProperty(index, kpidEncrypted, &value))
        if (value.vt != VT_BOOL || value.boolVal == VARIANT_FALSE)
            continue;
        RINOK(archive->GetProperty(index, kpidIsDir, &value))
        if (value.vt == VT_BOOL && value.boolVal != VARIANT_FALSE)
            continue;
        if (!forceValidation && passwords.PasswordForEntry(index))
            continue;
        SZEncryptedZipEntry entry;
        entry.Index = index;
        RINOK(archive->GetProperty(index, kpidPath, &value))
        if (value.vt == VT_BSTR)
            entry.Path = value.bstrVal;
        else {
            entry.Path = '#';
            entry.Path.Add_UInt32(index);
        }
        entry.Size = size;
        progress.PasswordValidationBytes = AddProgressBytes(
            progress.PasswordValidationBytes, size);
        entries.push_back(entry);
    }

    // A test reads each entry once. Extraction also includes the initial
    // validation pass for entries whose password is not yet known.
    progress.TotalBytes = forceValidation ? requestedBytes
        : AddProgressBytes(requestedBytes, progress.PasswordValidationBytes);
    RINOK(extractionUI->SetTotal(progress.TotalBytes))
    UInt64 completedBeforeEntry = 0;
    for (const SZEncryptedZipEntry& entry : entries) {
        RINOK(CheckCancellation(ui))
        RINOK(extractionUI->PrepareOperation(entry.Path, 0, NAskMode::kTest, NULL))
        const UString* boundPassword = passwords.PasswordForEntry(entry.Index);
        SZPasswordCandidates candidates;
        if (boundPassword)
            candidates.Add(*boundPassword);
        candidates.Add(explicitPassword);
        candidates.Add(archivePassword);
        FOR_VECTOR(i, passwords.Candidates()) {
            candidates.Add(passwords.Candidates()[i]);
        }

        unsigned nextCandidate = 0;
        UInt64 entryProgress = 0;
        Int32 lastResult = NOperationResult::kWrongPassword;
        for (;;) {
            RINOK(CheckCancellation(ui))
            if (nextCandidate == candidates.Values.Size()) {
                SZOperationSession* session = ui->Session;
                if (!session.passwordRequestHandler) {
                    if (nextCandidate == 0)
                        return E_ABORT;
                    return ReportValidationFailure(ui, entry.Path, lastResult, false);
                }
                NSString* password = nil;
                NSString* message = [NSString stringWithFormat:
                    SZLocalizedString(@"app.archive.password.enterForEntry"),
                    ToNS(ui->ArchivePath), ToNS(entry.Path)];
                if (nextCandidate > 0) {
                    message = [NSString stringWithFormat:@"%@\n\n%@",
                        SZLocalizedString(@"error.wrongPasswordGeneric"), message];
                }
                if (![session requestPasswordWithTitle:SZLocalizedString(@"password.enterPassword")
                        message:message initialValue:nil password:&password])
                    return E_ABORT;
                // A repeated answer may be a user correcting their next input;
                // prompt again without needlessly decoding with a failed secret.
                candidates.Add(password ?: @"");
                if (nextCandidate == candidates.Values.Size())
                    continue;
            }

            const UString& candidate = candidates.Values[nextCandidate++];
            SZZipPasswordTestCallback* callback = new SZZipPasswordTestCallback(ui,
                candidate, completedBeforeEntry, entry.Size, entryProgress);
            CMyComPtr<IArchiveExtractCallback> callbackRef(callback);
            RINOK(archive->Extract(&entry.Index, 1, 1, callbackRef))
            if (!callback->ResultWasReported)
                return E_FAIL;
            lastResult = callback->Result;
            if (lastResult == NOperationResult::kOK) {
                if (callback->PasswordWasAsked)
                    passwords.Remember(entry.Index, candidate);
                verifiedEncryptedIndices.push_back(entry.Index);
                if (forceValidation)
                    RINOK(extractionUI->SetOperationResult(NOperationResult::kOK, 1))
                break;
            }

            const bool wasBound = boundPassword && *boundPassword == candidate;
            if (!IsPasswordFailure(lastResult)
                || (wasBound && lastResult != NOperationResult::kWrongPassword))
                return ReportValidationFailure(ui, entry.Path, lastResult, wasBound);
            if (wasBound)
                passwords.ForgetEntry(entry.Index);
        }
        completedBeforeEntry = AddProgressBytes(completedBeforeEntry, entry.Size);
        RINOK(extractionUI->SetCompleted(&completedBeforeEntry))
    }
    return S_OK;
}

CMyComPtr<IArchiveExtractCallback> SZZipExtractionCallback(
    IArchiveExtractCallback* inner, const SZZipPasswordCache& passwords,
    const SZZipExtractionProgress& progress) {
    return CMyComPtr<IArchiveExtractCallback>(new SZZipEntryExtractionCallback(inner, passwords, progress));
}
