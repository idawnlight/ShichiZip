// Entry-scoped ZIP passwords. Associations are valid only for one open snapshot.

#pragma once

#include "SZBridgeCommon.h"

#include <map>
#include <vector>

class SZFolderExtractCallback;

struct SZZipExtractionProgress {
    UInt64 TotalBytes = 0;
    UInt64 PasswordValidationBytes = 0;
};

class SZZipPasswordCache final {
public:
    SZZipPasswordCache() = default;
    SZZipPasswordCache(const SZZipPasswordCache&) = delete;
    SZZipPasswordCache& operator=(const SZZipPasswordCache&) = delete;
    ~SZZipPasswordCache();

    void Clear();
    const UString* PasswordForEntry(UInt32 index) const;
    // Only current entry associations count; rejected or superseded candidates
    // must not determine an archive's write password.
    const UString* SinglePassword() const;
    bool HasMultiplePasswords() const;
    const CObjectVector<UString>& Candidates() const { return Passwords; }
    void Remember(UInt32 index, const UString& password);
    void ForgetEntry(UInt32 index);

private:
    CObjectVector<UString> Passwords;
    std::map<UInt32, unsigned> Entries;
};

// Validates without creating destination streams. Failures are recorded in ui;
// cancellation and engine failures are returned as HRESULTs. In test mode,
// successfully validated entries are counted once and can be omitted from the
// caller's remaining test pass.
// First extraction decodes unknown encrypted entries twice. Validation precedes
// overwrite decisions, so even entries later skipped must first be unlocked.
HRESULT SZPrepareZipPasswords(IInArchive* archive,
    const std::vector<UInt32>& requestedIndices,
    SZZipPasswordCache& passwords,
    NSString* explicitPassword,
    NSString* archivePassword,
    SZFolderExtractCallback* ui,
    bool forceValidation,
    std::vector<UInt32>& verifiedEncryptedIndices,
    SZZipExtractionProgress& progress);

// Preserves the standard single-archive extraction callback's filesystem
// handling while selecting a validated password by entry index. Both extract
// and test passes use this adapter to continue preparation's combined progress.
CMyComPtr<IArchiveExtractCallback> SZZipExtractionCallback(
    IArchiveExtractCallback* inner, const SZZipPasswordCache& passwords,
    const SZZipExtractionProgress& progress);
