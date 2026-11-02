// SZArchive.mm — Main archive interface implementation

#include "SZArchiveInternal.h"
#include "SZArchivePropertyMetadata.h"

#include <algorithm>
#include <memory>
#include <vector>

#import "../Utilities/SZObjCLog.h"

#ifdef __APPLE__
#include <sys/xattr.h>
#ifndef XATTR_NOFOLLOW
#define XATTR_NOFOLLOW 0x0001
#endif
#endif

#include "7zVersion.h"
#include "CPP/7zip/UI/Common/ArchiveExtractCallback.h"
#include "CPP/7zip/UI/Common/EnumDirItems.h"
#include "CPP/7zip/UI/Common/Extract.h"
#include "CPP/7zip/UI/Common/ExtractingFilePath.h"
#include "CPP/7zip/UI/Common/HashCalc.h"
#include "CPP/7zip/UI/Common/OpenArchive.h"
#include "CPP/7zip/UI/Common/Property.h"
#include "CPP/Common/MyString.h"
#include "CPP/Common/Wildcard.h"
#include "CPP/Windows/ErrorMsg.h"

extern bool g_CaseSensitive;

static NSData* SZQuarantineDataForArchivePath(NSString* archivePath) {
    if (!archivePath || archivePath.length == 0) {
        return nil;
    }

    const char* fsPath = archivePath.fileSystemRepresentation;
    if (!fsPath) {
        return nil;
    }

    static NSString* const quarantineAttributeName = @"com.apple.quarantine";
    const char* attrName = quarantineAttributeName.fileSystemRepresentation;
    if (!attrName) {
        return nil;
    }

    // Avoid a size-probe/read race by trying a fixed buffer first.
    char stackBuffer[1024];
    ssize_t read = getxattr(fsPath, attrName, stackBuffer, sizeof(stackBuffer), 0, XATTR_NOFOLLOW);
    if (read >= 0) {
        return [NSData dataWithBytes:stackBuffer length:(NSUInteger)read];
    }
    if (errno != ERANGE) {
        return nil;
    }

    // Rare fallback for larger xattrs.
    for (int attempt = 0; attempt < 4; attempt++) {
        const ssize_t probed = getxattr(fsPath, attrName, NULL, 0, 0, XATTR_NOFOLLOW);
        if (probed < 0) {
            return nil;
        }
        NSMutableData* data = [NSMutableData dataWithLength:(NSUInteger)probed];
        read = getxattr(fsPath, attrName, data.mutableBytes, data.length, 0, XATTR_NOFOLLOW);
        if (read >= 0) {
            data.length = (NSUInteger)read;
            return data;
        }
        if (errno != ERANGE) {
            return nil;
        }
    }
    return nil;
}

static BOOL SZOpenErrorFlagsIndicateWrongPassword(UInt32 errorFlags) {
    return (errorFlags & kpv_ErrorFlags_EncryptedHeadersError) != 0;
}

static BOOL SZOpenErrorFlagsIndicateUnsupportedArchive(UInt32 errorFlags) {
    return (errorFlags & (kpv_ErrorFlags_IsNotArc | kpv_ErrorFlags_UnsupportedMethod | kpv_ErrorFlags_UnsupportedFeature)) != 0;
}

static NSString* SZOpenArchiveFlagDetails(UInt32 errorFlags) {
    NSMutableArray<NSString*>* messages = [NSMutableArray array];

    const struct {
        UInt32 flag;
        NSString* key;
    } flagMessages[] = {
        { kpv_ErrorFlags_IsNotArc, @"error.isNotArchive" },
        { kpv_ErrorFlags_HeadersError, @"error.headersError" },
        { kpv_ErrorFlags_EncryptedHeadersError, @"error.headersError" },
        { kpv_ErrorFlags_UnavailableStart, @"error.unavailableStart" },
        { kpv_ErrorFlags_UnconfirmedStart, @"error.unconfirmedStart" },
        { kpv_ErrorFlags_UnexpectedEnd, @"error.unexpectedEnd" },
        { kpv_ErrorFlags_DataAfterEnd, @"error.dataAfterPayload" },
        { kpv_ErrorFlags_UnsupportedMethod, @"error.unsupportedMethodGeneric" },
        { kpv_ErrorFlags_UnsupportedFeature, @"error.unsupportedFeature" },
        { kpv_ErrorFlags_DataError, @"error.dataErrorGeneric" },
        { kpv_ErrorFlags_CrcError, @"error.crcFailedGeneric" },
    };

    for (size_t index = 0; index < sizeof(flagMessages) / sizeof(flagMessages[0]);
        index++) {
        const auto& entry = flagMessages[index];
        if ((errorFlags & entry.flag) == 0) {
            continue;
        }
        if (entry.flag == kpv_ErrorFlags_EncryptedHeadersError) {
            [messages addObject:[NSString stringWithFormat:@"%@ : %@",
                                    SZLocalizedString(entry.key),
                                    SZLocalizedString(@"error.wrongPassword")]];
        } else {
            [messages addObject:SZLocalizedString(entry.key)];
        }
    }

    return messages.count > 0 ? [messages componentsJoinedByString:@"\n"] : nil;
}

static NSString* SZOpenArchiveFailureReason(const CArcErrorInfo& errorInfo) {
    NSMutableArray<NSString*>* messages = [NSMutableArray array];

    NSString* flagDetails = SZOpenArchiveFlagDetails(errorInfo.GetErrorFlags());
    if (flagDetails.length > 0) {
        [messages addObject:flagDetails];
    }

    NSString* errorMessage = ToNS(errorInfo.ErrorMessage);
    if (errorMessage.length > 0 && ![messages containsObject:errorMessage]) {
        [messages addObject:errorMessage];
    }

    return messages.count > 0 ? [messages componentsJoinedByString:@"\n"] : nil;
}

NSError* SZOpenArchiveErrorFromPasswordContext(
    HRESULT result, const CArcErrorInfo& errorInfo, BOOL passwordWasAsked,
    NSString* archivePath) {
    if (result == E_ABORT) {
        return SZMakeError(SZArchiveErrorCodeUserCancelled,
            SZLocalizedString(@"app.archive.error.operationCancelled"));
    }

    if (result != S_FALSE) {
        return SZMakeError(
            result, [NSString stringWithFormat:SZLocalizedString(@"app.archive.error.failedToOpenFormat"), (unsigned)result]);
    }

    const UInt32 errorFlags = errorInfo.GetErrorFlags();
    const BOOL wrongPassword = passwordWasAsked
        || SZOpenErrorFlagsIndicateWrongPassword(errorFlags);
    if (wrongPassword) {
        return SZMakeDetailedError(SZArchiveErrorCodeWrongPassword,
            SZLocalizedStringWithFirstPlaceholder(@"archive.cannotOpenEncryptedWrongPassword", archivePath),
            SZOpenArchiveFailureReason(errorInfo));
    }

    if (SZOpenErrorFlagsIndicateUnsupportedArchive(errorFlags)) {
        return SZMakeDetailedError(SZArchiveErrorCodeUnsupportedArchive,
            SZLocalizedString(@"archive.unsupportedType"),
            SZOpenArchiveFailureReason(errorInfo));
    }

    if (!errorInfo.IsArc_After_NonOpen() && errorInfo.ErrorMessage.IsEmpty()) {
        return SZMakeDetailedError(SZArchiveErrorCodeUnsupportedArchive,
            SZLocalizedString(@"archive.unsupportedType"),
            SZOpenArchiveFailureReason(errorInfo));
    }

    return SZMakeDetailedError(SZArchiveErrorCodeInvalidArchive,
        SZLocalizedStringWithFirstPlaceholder(@"archive.cannotOpenFileAsArchive", archivePath),
        SZOpenArchiveFailureReason(errorInfo));
}

static NSError*
SZOpenArchiveErrorFromResult(HRESULT result, const CArcErrorInfo& errorInfo,
    const SZOpenCallbackUI& callbackUI,
    NSString* archivePath) {
    return SZOpenArchiveErrorFromPasswordContext(result, errorInfo,
        callbackUI.PasswordWasAsked, archivePath);
}

@interface SZArchive ()
- (BOOL)extractEntries:(NSArray<NSNumber*>*)indices
                toPath:(NSString*)destinationPath
              settings:(SZExtractionSettings*)settings
               session:(SZOperationSession*)session
           outputPaths:(FStringVector*)outputPaths
                 error:(NSError**)error;
@end

@implementation SZArchive

- (void)clearCachedPassword {
    _cachedPassword = nil;
    _cachedPasswordIsDefined = NO;
}

- (void)storeCachedPassword:(const UString&)password defined:(bool)isDefined {
    if (isDefined) {
        _cachedPassword = ToNS(password);
        _cachedPasswordIsDefined = YES;
    } else {
        [self clearCachedPassword];
    }
}

- (void)configureExtractPasswordForCallback:(SZFolderExtractCallback*)callback
                           explicitPassword:(NSString*)password {
    if (password) {
        callback->PasswordIsDefined = true;
        callback->Password = ToU(password);
        return;
    }

    if (_cachedPasswordIsDefined) {
        callback->PasswordIsDefined = true;
        callback->Password = ToU(_cachedPassword ?: @"");
    }
}

- (void)updateCachedPasswordFromExtractCallback:
            (SZFolderExtractCallback*)callback
                                         result:(HRESULT)result {
    if (result == S_OK && callback->PasswordIsDefined) {
        [self storeCachedPassword:callback->Password defined:true];
        return;
    }

    if (callback->PasswordWasWrong || (callback->PasswordWasAsked && !callback->PasswordIsDefined)) {
        [self clearCachedPassword];
    }
}

- (void)updateCachedPasswordFromZipEntriesWithResult:(HRESULT)result
                                            callback:(SZFolderExtractCallback*)callback {
    // Keep a single learned password as a read hint. ZIP content updates choose
    // their write password independently of this cache.
    if (const UString* password = _zipPasswords.SinglePassword()) {
        [self storeCachedPassword:*password defined:true];
    } else if (_zipPasswords.HasMultiplePasswords() || result != S_OK || callback->NumErrors > 0) {
        [self clearCachedPassword];
    }
}

- (BOOL)reopenAfterExternalMutationWithSession:(SZOperationSession*)session
                                         error:(NSError**)error {
    SZArchiveOperationGuard operationGuard(self);

    NSString* archivePath = [_archivePath copy];
    NSString* openType = [_openType copy];
    NSString* password = _cachedPasswordIsDefined ? [_cachedPassword copy] : nil;
    if (archivePath.length == 0) {
        if (error) {
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive,
                SZLocalizedString(@"app.fileManager.error.noArchiveOpen"));
        }
        return NO;
    }

    [self close];
    return [self openAtPath:archivePath
                   openType:openType
                   password:password
                    session:session
                      error:error];
}

- (instancetype)init {
    if ((self = [super init])) {
        _arcLink = std::make_unique<CArchiveLink>();
        _isOpen = NO;
        _cachedPasswordIsDefined = NO;
        _entrySnapshotIdentifier = nil;
    }
    return self;
}

- (void)dealloc {
    // Close early so upstream objects release before unique_ptr teardown.
    @try {
        [self close];
    } @catch (NSException* exception) {
        SZLogError(@"ShichiZip", @"SZArchive dealloc caught ObjC exception during close: %@", exception);
    }
    try {
        if (_arcLink) {
            _arcLink->Close();
        }
    } catch (...) {
        SZLogError(@"ShichiZip", @"SZArchive dealloc caught C++ exception during CArchiveLink::Close");
    }
}

+ (NSString*)sevenZipVersionString {
    return @MY_VERSION;
}

+ (NSString*)correctedFileSystemRelativePathForArchivePath:(NSString*)path
                                               isDirectory:(BOOL)isDirectory {
    UStringVector pathParts;
    SplitPathToParts(ToU(path), pathParts);
    Correct_FsPath(false, false, pathParts, isDirectory);
    return ToNS(MakePathFromParts(pathParts));
}

+ (NSData*)fileNameComparisonKeyForArchivePathComponent:(NSString*)component {
    const UString value = ToU(component);
    NSMutableData* key = [NSMutableData dataWithLength:(NSUInteger)value.Len() * sizeof(wchar_t)];
    wchar_t* output = (wchar_t*)key.mutableBytes;
    for (unsigned index = 0; index < value.Len(); index++) {
        const wchar_t character = value[index];
        output[index] = g_CaseSensitive ? character : MyCharUpper(character);
    }
    return key;
}

- (BOOL)openAtPath:(NSString*)path error:(NSError**)error {
    return [self openAtPath:path
                   openType:nil
                   password:nil
                    session:nil
                      error:error];
}

- (BOOL)openAtPath:(NSString*)path
           session:(SZOperationSession*)session
             error:(NSError**)error {
    return [self openAtPath:path openType:nil session:session error:error];
}

- (BOOL)openAtPath:(NSString*)path
          openType:(NSString*)openType
           session:(SZOperationSession*)session
             error:(NSError**)error {
    return [self openAtPath:path
                   openType:openType
                   password:nil
               progressMode:SZOpenProgressModePrelude
                    session:session
                      error:error];
}

- (BOOL)openAtPath:(NSString*)path
          openType:(NSString*)openType
      progressMode:(SZOpenProgressMode)progressMode
           session:(SZOperationSession*)session
             error:(NSError**)error {
    return [self openAtPath:path
                   openType:openType
                   password:nil
               progressMode:progressMode
                    session:session
                      error:error];
}

- (BOOL)openAtPath:(NSString*)path
          password:(NSString*)password
             error:(NSError**)error {
    return [self openAtPath:path password:password session:nil error:error];
}

- (BOOL)openAtPath:(NSString*)path
          password:(NSString*)password
           session:(SZOperationSession*)session
             error:(NSError**)error {
    return [self openAtPath:path
                   openType:nil
                   password:password
                    session:session
                      error:error];
}

- (BOOL)openAtPath:(NSString*)path
          openType:(NSString*)openType
          password:(NSString*)password
           session:(SZOperationSession*)session
             error:(NSError**)error {
    return [self openAtPath:path
                   openType:openType
                   password:password
               progressMode:SZOpenProgressModePrelude
                    session:session
                      error:error];
}

- (BOOL)openAtPath:(NSString*)path
          openType:(NSString*)openType
          password:(NSString*)password
      progressMode:(SZOpenProgressMode)progressMode
           session:(SZOperationSession*)session
             error:(NSError**)error {
    SZArchiveOperationGuard operationGuard(self);

    CCodecs* codecs = SZGetCodecs();
    if (!codecs) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeFailedToInitCodecs,
                SZLocalizedString(@"app.archive.error.failedToInitCodecs"));
        return NO;
    }
    [self close];
    [self clearCachedPassword];
    _archivePath = [path copy];

    CObjectVector<COpenType> types;
    if (openType.length > 0 && !ParseOpenTypes(*codecs, ToU(openType), types)) {
        if (error) {
            *error = SZMakeError(
                SZArchiveErrorCodeUnsupportedFormat,
                [NSString
                    stringWithFormat:SZLocalizedString(@"app.archive.error.invalidOpenType"), openType]);
        }
        return NO;
    }
    CIntVector excludedFormats;
    CObjectVector<CProperty> props;

    COpenOptions options;
    options.codecs = codecs;
    options.types = &types;
    options.excludedFormats = &excludedFormats;
    options.props = &props;
    options.stdInMode = false;
    options.stream = NULL;
    options.filePath = ToU(path);

    SZOperationSession* resolvedSession = session ?: [SZOperationSession makeDefaultSession];
    SZOpenCallbackUI callbackUI;
    callbackUI.Session = resolvedSession;
    callbackUI.ArchivePath = ToU(path ?: @"");
    callbackUI.OwnsProgress = (progressMode == SZOpenProgressModePrimary);
    if (password) {
        callbackUI.PasswordIsDefined = true;
        callbackUI.Password = ToU(password);
    }

    HRESULT res = _arcLink->Open3(options, &callbackUI);
    if (res != S_OK) {
        if (error) {
            *error = SZOpenArchiveErrorFromResult(res, _arcLink->NonOpen_ErrorInfo,
                callbackUI, _archivePath);
        }
        return NO;
    }

    if (callbackUI.PasswordIsDefined) {
        [self storeCachedPassword:callbackUI.Password defined:true];
    }
    _openType = [openType copy];
    _isOpen = YES;
    _entrySnapshotIdentifier = [NSUUID UUID];
    return YES;
}

- (void)close {
    SZArchiveOperationGuard operationGuard(self);

    if (_isOpen)
        _arcLink->Close();
    _isOpen = NO;
    _openType = nil;
    _entrySnapshotIdentifier = nil;
    _zipPasswords.Clear();
    [self clearCachedPassword];
}

// MARK: - Properties

- (NSString*)formatName {
    SZArchiveOperationGuard operationGuard(self);

    if (!_isOpen)
        return nil;
    const CArc& arc = _arcLink->Arcs.Back();
    CCodecs* c = SZGetCodecs();
    if (!c || arc.FormatIndex < 0)
        return nil;
    return ToNS(c->Formats[arc.FormatIndex].Name);
}

- (BOOL)canWrite {
    SZArchiveOperationGuard operationGuard(self);

    if (!_isOpen)
        return NO;
    const CArc& arc = _arcLink->Arcs.Back();
    CCodecs* c = SZGetCodecs();
    if (!c || arc.FormatIndex < 0)
        return NO;
    return c->Formats[arc.FormatIndex].UpdateEnabled;
}

- (NSArray<SZArchiveEntryProperty*>*)entryProperties {
    SZArchiveOperationGuard operationGuard(self);

    if (!_isOpen)
        return @[];
    IInArchive* archive = _arcLink->GetArchive();
    if (!archive)
        return @[];

    return SZCopyEntryProperties(archive);
}

- (NSArray<NSString*>*)entryPropertyKeys {
    NSMutableArray<NSString*>* keys = [NSMutableArray array];
    for (SZArchiveEntryProperty* property in self.entryProperties) {
        [keys addObject:property.key];
    }
    return keys;
}

- (uint64_t)archivePhysicalSize {
    SZArchiveOperationGuard operationGuard(self);

    if (!_isOpen)
        return 0;
    IInArchive* archive = _arcLink->GetArchive();
    if (!archive)
        return 0;

    NWindows::NCOM::CPropVariant value;
    if (archive->GetArchiveProperty(kpidPhySize, &value) != S_OK)
        return 0;

    if (value.vt == VT_UI8)
        return (uint64_t)value.uhVal.QuadPart;
    if (value.vt == VT_UI4)
        return (uint64_t)value.ulVal;
    if (value.vt == VT_I8)
        return value.hVal.QuadPart < 0 ? 0 : (uint64_t)value.hVal.QuadPart;
    if (value.vt == VT_I4)
        return value.lVal < 0 ? 0 : (uint64_t)value.lVal;
    return 0;
}

- (BOOL)isSolidArchive {
    SZArchiveOperationGuard operationGuard(self);

    if (!_isOpen)
        return NO;
    IInArchive* archive = _arcLink->GetArchive();
    if (!archive)
        return NO;

    NWindows::NCOM::CPropVariant value;
    if (archive->GetArchiveProperty(kpidSolid, &value) != S_OK)
        return NO;

    if (value.vt == VT_BOOL)
        return value.boolVal != VARIANT_FALSE;
    if (value.vt == VT_UI4)
        return value.ulVal != 0;
    if (value.vt == VT_I4)
        return value.lVal != 0;
    return NO;
}

- (NSUInteger)entryCount {
    SZArchiveOperationGuard operationGuard(self);

    if (!_isOpen)
        return 0;
    IInArchive* archive = _arcLink->GetArchive();
    if (!archive)
        return 0;
    UInt32 n = 0;
    archive->GetNumberOfItems(&n);
    return n;
}

- (NSUUID*)entrySnapshotIdentifier {
    SZArchiveOperationGuard operationGuard(self);
    return [_entrySnapshotIdentifier copy];
}

- (NSArray<SZArchiveEntry*>*)entries {
    return [self entriesWithSession:nil error:nil] ?: @[];
}

- (NSArray<SZArchiveEntry*>*)entriesWithSession:(SZOperationSession*)session
                                          error:(NSError**)error {
    SZArchiveOperationGuard operationGuard(self);

    if (!_isOpen)
        return @[];
    IInArchive* archive = _arcLink->GetArchive();
    if (!archive)
        return @[];
    const CArc& arc = _arcLink->Arcs.Back();
    UInt32 n = 0;
    archive->GetNumberOfItems(&n);
    NSArray<SZArchiveEntryProperty*>* properties = SZCopyEntryProperties(archive);
    NSMutableArray* arr = [NSMutableArray arrayWithCapacity:n];
    for (UInt32 i = 0; i < n; i++) {
        if (session && [session shouldCancel]) {
            if (error)
                *error = SZMakeError(SZArchiveErrorCodeUserCancelled,
                    SZLocalizedString(@"app.archive.error.cancelled"));
            return nil;
        }

        SZArchiveEntry* e = [SZArchiveEntry new];
        e.index = i;
        CReadArcItem item;
        const bool hasReadItem = (arc.GetItem(i, item) == S_OK);
        if (hasReadItem) {
            e.path = ToNS(item.Path);
            NSMutableArray<NSString*>* pathParts =
                [NSMutableArray arrayWithCapacity:item.PathParts.Size()];
            for (unsigned j = 0; j < item.PathParts.Size(); j++) {
                [pathParts addObject:ToNS(item.PathParts[j])];
            }
            e.pathParts = pathParts;
        } else {
            UString itemPath;
            if (arc.GetItem_Path(i, itemPath) == S_OK && !itemPath.IsEmpty())
                e.path = ToNS(itemPath);
            else
                e.path = ItemStr(archive, i, kpidPath) ?: @"";
            e.pathParts = @[];
        }
        e.size = ItemU64Number(archive, i, kpidSize);
        e.packedSize = ItemU64Number(archive, i, kpidPackSize);
        e.crc = (uint32_t)ItemU64(archive, i, kpidCRC);
        e.isDirectory = hasReadItem ? item.IsDir : ItemBool(archive, i, kpidIsDir);
        e.isEncrypted = ItemBool(archive, i, kpidEncrypted);
        e.isAnti = ItemBool(archive, i, kpidIsAnti);
        e.method = ItemStr(archive, i, kpidMethod);
        e.attributes = (uint32_t)ItemU64(archive, i, kpidAttrib);
        e.position = ItemU64(archive, i, kpidPosition);
        e.block = ItemU64(archive, i, kpidBlock);
        e.modifiedDate = ItemDate(archive, i, kpidMTime);
        e.createdDate = ItemDate(archive, i, kpidCTime);
        e.accessedDate = ItemDate(archive, i, kpidATime);
        e.comment = ItemStr(archive, i, kpidComment);
        NSMutableDictionary<NSString*, NSString*>* propertyValues = [NSMutableDictionary dictionaryWithCapacity:properties.count];
        for (SZArchiveEntryProperty* property in properties) {
            NSString* value = SZPropertyDisplayString(archive, i, (PROPID)property.propID);
            if (value)
                propertyValues[property.key] = value;
        }
        e.propertyValues = propertyValues;
        e.reference = [[SZArchiveItemReference alloc]
            initWithArchiveIndex:i
                            path:e.path
                     isDirectory:e.isDirectory
              snapshotIdentifier:_entrySnapshotIdentifier];
        [arr addObject:e];
    }
    return arr;
}

// MARK: - Extract helpers

static NExtract::NOverwriteMode::EEnum MapOverwriteMode(SZOverwriteMode m) {
    switch (m) {
    case SZOverwriteModeOverwrite:
        return NExtract::NOverwriteMode::kOverwrite;
    case SZOverwriteModeSkip:
        return NExtract::NOverwriteMode::kSkip;
    case SZOverwriteModeRename:
        return NExtract::NOverwriteMode::kRename;
    case SZOverwriteModeRenameExisting:
        return NExtract::NOverwriteMode::kRenameExisting;
    case SZOverwriteModeAsk:
    default:
        return NExtract::NOverwriteMode::kAsk;
    }
}

static NExtract::NPathMode::EEnum MapPathMode(SZPathMode m) {
    switch (m) {
    case SZPathModeCurrentPaths:
        return NExtract::NPathMode::kCurPaths;
    case SZPathModeNoPaths:
        return NExtract::NPathMode::kNoPaths;
    case SZPathModeAbsolutePaths:
        return NExtract::NPathMode::kAbsPaths;
    case SZPathModeFullPaths:
    default:
        return NExtract::NPathMode::kFullPaths;
    }
}

static UStringVector BuildRemovePathParts(NSString* pathPrefixToStrip) {
    UStringVector pathParts;
    if (!pathPrefixToStrip || pathPrefixToStrip.length == 0) {
        return pathParts;
    }

    UString path = ToU(pathPrefixToStrip);
    while (!path.IsEmpty()) {
        const wchar_t tail = path.Back();
        if (tail != L'/' && tail != L'\\') {
            break;
        }
        path.DeleteBack();
    }

    if (!path.IsEmpty()) {
        SplitPathToParts(path, pathParts);
    }
    return pathParts;
}

static constexpr unsigned kSZExtractSymLinksDangerousLevelAllowChains = 10;

static CExtractNtOptions SZExtractNtOptionsForSettings(SZExtractionSettings* settings) {
    CExtractNtOptions ntOptions;
    if (settings && settings.preserveNtSecurityInfo) {
        ntOptions.NtSecurity.Def = true;
        ntOptions.NtSecurity.Val = true;
    }

    // Level 10 is the lowest level that allows symlink chains while keeping
    // 7-Zip's lexical checks for paths that escape the extraction root, which
    // are bypassed only by level 20. macOS versioned frameworks rely on chains
    // such as Framework -> Versions/Current/Framework and Current -> A.
    ntOptions.SymLinks_DangerousLevel = kSZExtractSymLinksDangerousLevelAllowChains;
    return ntOptions;
}

static BOOL CheckExtractResult(SZFolderExtractCallback* fae, HRESULT r,
    NSError** error) {
    if (r == E_ABORT) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeUserCancelled,
                SZLocalizedString(@"app.archive.error.cancelled"));
        return NO;
    }
    if (fae->PasswordWasWrong) {
        if (error)
            *error = SZMakeDetailedError(SZArchiveErrorCodeWrongPassword, SZLocalizedString(@"error.wrongPasswordGeneric"),
                fae->LastErrorMessage.IsEmpty() ? nil : ToNS(fae->LastErrorMessage));
        return NO;
    }
    if (r == S_OK && fae->NumErrors > 0) {
        NSString* title = [NSString stringWithFormat:@"%@ %u",
            SZLocalizedString(@"progress.errors"), fae->NumErrors];
        NSString* failureReason = fae->LastErrorMessage.IsEmpty() ? nil : ToNS(fae->LastErrorMessage);
        if (error)
            *error = SZMakeDetailedError(SZArchiveErrorCodePartialFailure, title,
                failureReason);
        return NO;
    }
    if (r != S_OK) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeExtractionFailed,
                SZLocalizedString(@"app.archive.error.extractionFailed"));
        return NO;
    }
    return YES;
}

static BOOL EnsureExtractionDirectoryExists(NSString* dest, NSError** error) {
    if (NWindows::NFile::NDir::CreateComplexDir(us2fs(ToU(dest)))) {
        return YES;
    }

    if (error) {
        const DWORD lastError = GetLastError_noZero_HRESULT();
        NSString* failureReason = ToNS(NWindows::NError::MyFormatMessage(lastError));
        *error = SZMakeDetailedError(SZArchiveErrorCodeExtractionFailed,
            SZLocalizedString(@"create.errorFolder"),
            failureReason);
    }

    return NO;
}

static HRESULT SZExtractAndFinalize(IInArchive* archive,
    const UInt32* indices,
    UInt32 numItems,
    Int32 testMode,
    IArchiveExtractCallback* archiveExtractCallback,
    CArchiveExtractCallback* extractCallbackImpl) {
    CArchiveExtractCallback_Closer extractCallbackCloser(extractCallbackImpl);
    HRESULT result = archive->Extract(indices, numItems, testMode, archiveExtractCallback);
    const HRESULT closeResult = extractCallbackCloser.Close();
    if (result == S_OK) {
        result = closeResult;
    }
    return result;
}

// MARK: - Extract

- (BOOL)extractToPath:(NSString*)dest
             settings:(SZExtractionSettings*)s
              session:(SZOperationSession*)session
                error:(NSError**)error {
    return [self extractEntries:nil
                         toPath:dest
                       settings:s
                        session:session
                    outputPaths:NULL
                          error:error];
}

- (BOOL)extractEntries:(NSArray<NSNumber*>*)indices
                toPath:(NSString*)dest
              settings:(SZExtractionSettings*)s
               session:(SZOperationSession*)session
                 error:(NSError**)error {
    return [self extractEntries:indices
                         toPath:dest
                       settings:s
                        session:session
                    outputPaths:NULL
                          error:error];
}

- (NSArray<NSURL*>*)extractEntriesWithOutputURLs:(NSArray<NSNumber*>*)indices
                                          toPath:(NSString*)dest
                                        settings:(SZExtractionSettings*)s
                                         session:(SZOperationSession*)session
                                           error:(NSError**)error {
    FStringVector outputPaths;
    if (![self extractEntries:indices
                       toPath:dest
                     settings:s
                      session:session
                  outputPaths:&outputPaths
                        error:error]) {
        return nil;
    }

    NSMutableArray<NSURL*>* urls = [NSMutableArray arrayWithCapacity:outputPaths.Size()];
    FOR_VECTOR(i, outputPaths) {
        [urls addObject:[NSURL fileURLWithPath:ToNS(fs2us(outputPaths[i]))]];
    }
    return [urls copy];
}

- (BOOL)extractEntries:(NSArray<NSNumber*>*)indices
                toPath:(NSString*)dest
              settings:(SZExtractionSettings*)s
               session:(SZOperationSession*)session
           outputPaths:(FStringVector*)outputPaths
                 error:(NSError**)error {
    SZArchiveOperationGuard operationGuard(self);

    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive,
                SZLocalizedString(@"app.fileManager.error.noArchiveOpen"));
        return NO;
    }
    IInArchive* archive = _arcLink->GetArchive();
    const CArc& arc = _arcLink->Arcs.Back();
    SZOperationSession* resolvedSession = session ?: [SZOperationSession makeDefaultSession];
    SZFolderExtractCallback* faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Session = resolvedSession;
    faeSpec->OverwriteMode = s.overwriteMode;
    faeSpec->ArchivePath = ToU(_archivePath);
    faeSpec->TestMode = false;
    NSData* quarantineData = s.sourceArchivePathForQuarantine ? SZQuarantineDataForArchivePath(s.sourceArchivePathForQuarantine) : nil;
    [self configureExtractPasswordForCallback:faeSpec
                             explicitPassword:s.password];

    std::vector<UInt32> ia;
    ia.reserve(indices.count);
    for (NSNumber* n in indices)
        ia.push_back([n unsignedIntValue]);
    // UINT32_MAX is 7-Zip's "extract all" sentinel.
    if (ia.size() >= (size_t)UINT32_MAX) {
        if (error)
            *error = SZMakeError(E_INVALIDARG,
                SZLocalizedString(@"archive.tooManyItems"));
        return NO;
    }

    const bool isZip = [self.formatName.lowercaseString isEqualToString:@"zip"];
    SZZipExtractionProgress zipProgress;
    if (isZip) {
        UInt32 itemCount = 0;
        HRESULT r = archive->GetNumberOfItems(&itemCount);
        if (r != S_OK)
            return CheckExtractResult(faeSpec, r, error);
        if (!indices) {
            ia.reserve(itemCount);
            for (UInt32 index = 0; index < itemCount; ++index)
                ia.push_back(index);
        }
        for (NSNumber* index in indices) {
            if (index.longLongValue < 0 || index.unsignedLongLongValue >= itemCount) {
                if (error) {
                    *error = SZMakeError(E_INVALIDARG,
                        SZLocalizedString(@"app.archive.error.invalidItemSelection"));
                }
                return NO;
            }
        }
        std::vector<UInt32> verifiedIndices;
        r = SZPrepareZipPasswords(archive, ia, _zipPasswords, s.password,
            _cachedPasswordIsDefined ? _cachedPassword : nil,
            faeSpec, false, verifiedIndices, zipProgress);
        [self updateCachedPasswordFromZipEntriesWithResult:r callback:faeSpec];
        if (r != S_OK || faeSpec->NumErrors > 0)
            return CheckExtractResult(faeSpec, r, error);
    }

    // Resolve ZIP passwords before upstream opens/truncates any destination.
    if (!EnsureExtractionDirectoryExists(dest, error)) {
        return NO;
    }

    CArchiveExtractCallback* ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);
    CExtractNtOptions ntOptions = SZExtractNtOptionsForSettings(s);
    UStringVector removePathParts = BuildRemovePathParts(s.pathPrefixToStrip);

    ecs->InitForMulti(false, MapPathMode(s.pathMode),
        MapOverwriteMode(s.overwriteMode),
        NExtract::NZoneIdMode::kNone, false);
    if (quarantineData.length > 0) {
        ecs->ZoneBuf.CopyFrom((const Byte*)quarantineData.bytes, quarantineData.length);
    }
    ecs->Init(ntOptions, NULL, &arc, faeCallback, false, false, us2fs(ToU(dest)),
        removePathParts, false, arc.GetEstmatedPhySize());
    ecs->ExtractedPaths = outputPaths;

    CMyComPtr<IArchiveExtractCallback> passwordCallback;
    if (isZip)
        passwordCallback = SZZipExtractionCallback(ec, _zipPasswords, zipProgress);
    HRESULT r = SZExtractAndFinalize(archive,
        indices ? ia.data() : nullptr,
        indices ? (UInt32)ia.size() : UINT32_MAX, 0,
        isZip ? passwordCallback : ec, ecs);
    if (!isZip)
        [self updateCachedPasswordFromExtractCallback:faeSpec result:r];
    return CheckExtractResult(faeSpec, r, error);
}

- (BOOL)testWithSession:(SZOperationSession*)session error:(NSError**)error {
    SZArchiveOperationGuard operationGuard(self);

    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive,
                SZLocalizedString(@"app.fileManager.error.noArchiveOpen"));
        return NO;
    }
    IInArchive* archive = _arcLink->GetArchive();
    const CArc& arc = _arcLink->Arcs.Back();

    SZOperationSession* resolvedSession = session ?: [SZOperationSession makeDefaultSession];
    SZFolderExtractCallback* faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Session = resolvedSession;
    faeSpec->ArchivePath = ToU(_archivePath);
    faeSpec->TestMode = true;
    [self configureExtractPasswordForCallback:faeSpec explicitPassword:nil];

    const bool isZip = [self.formatName.lowercaseString isEqualToString:@"zip"];
    SZZipExtractionProgress zipProgress;
    std::vector<UInt32> testIndices;
    if (isZip) {
        UInt32 itemCount = 0;
        HRESULT r = archive->GetNumberOfItems(&itemCount);
        if (r != S_OK)
            return CheckExtractResult(faeSpec, r, error);
        testIndices.reserve(itemCount);
        for (UInt32 index = 0; index < itemCount; ++index)
            testIndices.push_back(index);
        std::vector<UInt32> verifiedIndices;
        r = SZPrepareZipPasswords(archive, testIndices, _zipPasswords, nil,
            _cachedPasswordIsDefined ? _cachedPassword : nil,
            faeSpec, true, verifiedIndices, zipProgress);
        [self updateCachedPasswordFromZipEntriesWithResult:r callback:faeSpec];
        if (r != S_OK || faeSpec->NumErrors > 0)
            return CheckExtractResult(faeSpec, r, error);
        // Encrypted entries have already been tested, including cached ones.
        std::sort(verifiedIndices.begin(), verifiedIndices.end());
        std::erase_if(testIndices, [&](UInt32 index) {
            return std::binary_search(verifiedIndices.begin(), verifiedIndices.end(), index);
        });
    }

    CArchiveExtractCallback* ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);
    CExtractNtOptions ntOptions = SZExtractNtOptionsForSettings(nil);
    UStringVector removePathParts;

    ecs->InitForMulti(false, NExtract::NPathMode::kFullPaths,
        NExtract::NOverwriteMode::kOverwrite,
        NExtract::NZoneIdMode::kNone, false);
    ecs->Init(ntOptions, NULL, &arc, faeCallback, false, true, FString(),
        removePathParts, false, arc.GetEstmatedPhySize());

    CMyComPtr<IArchiveExtractCallback> passwordCallback;
    if (isZip)
        passwordCallback = SZZipExtractionCallback(ec, _zipPasswords, zipProgress);
    HRESULT r = SZExtractAndFinalize(archive,
        isZip ? testIndices.data() : nullptr,
        isZip ? (UInt32)testIndices.size() : UINT32_MAX, 1,
        isZip ? passwordCallback : ec, ecs);
    if (!isZip)
        [self updateCachedPasswordFromExtractCallback:faeSpec result:r];
    return CheckExtractResult(faeSpec, r, error);
}

+ (NSArray<SZFormatInfo*>*)supportedFormats {
    CCodecs* codecs = SZGetCodecs();
    if (!codecs)
        return @[];
    NSMutableArray* arr = [NSMutableArray array];
    for (unsigned i = 0; i < codecs->Formats.Size(); i++) {
        const CArcInfoEx& ai = codecs->Formats[i];
        SZFormatInfo* info = [SZFormatInfo new];
        info.name = ToNS(ai.Name);
        NSMutableArray* exts = [NSMutableArray array];
        for (unsigned j = 0; j < ai.Exts.Size(); j++)
            [exts addObject:ToNS(ai.Exts[j].Ext)];
        info.extensions = exts;
        info.canWrite = ai.UpdateEnabled;
        info.supportsSymbolicLinks = ai.Flags_SymLinks();
        info.supportsHardLinks = ai.Flags_HardLinks();
        info.supportsAlternateDataStreams = ai.Flags_AltStreams();
        info.supportsFileSecurity = ai.Flags_NtSecurity();
        info.supportsModificationTime = ai.Flags_MTime();
        info.supportsCreationTime = ai.Flags_CTime();
        info.supportsAccessTime = ai.Flags_ATime();
        info.defaultsModificationTime = ai.Flags_MTime_Default();
        info.defaultsCreationTime = ai.Flags_CTime_Default();
        info.defaultsAccessTime = ai.Flags_ATime_Default();
        info.keepsName = ai.Flags_KeepName();

        UInt32 defaultTimePrecision = ai.Get_DefaultTimePrec();
        if (ai.Is_GZip()) {
            defaultTimePrecision = (UInt32)SZCompressionTimePrecisionUnix;
        }

        UInt32 supportedTimePrecisionMask = ai.Get_TimePrecFlags();
        if (defaultTimePrecision < 32) {
            supportedTimePrecisionMask |= ((UInt32)1 << defaultTimePrecision);
        }
        info.supportedTimePrecisionMask = supportedTimePrecisionMask;
        if (defaultTimePrecision <= (UInt32)SZCompressionTimePrecisionLinux) {
            info.defaultTimePrecision = (SZCompressionTimePrecision)defaultTimePrecision;
        } else {
            info.defaultTimePrecision = SZCompressionTimePrecisionAutomatic;
        }

        [arr addObject:info];
    }
    return arr;
}

// MARK: - Hash

+ (NSDictionary<NSString*, NSString*>*)calculateHashForPath:(NSString*)path
                                                      error:
                                                          (NSError**)error {
    return [self calculateHashForPath:path session:nil error:error];
}

+ (NSDictionary<NSString*, NSString*>*)
    calculateHashForPath:(NSString*)path
                 session:(SZOperationSession*)session
                   error:(NSError**)error {
    return [self calculateHashForPath:path methods:@[] session:session error:error];
}

+ (NSDictionary<NSString*, NSString*>*)
    calculateHashForPath:(NSString*)path
                 methods:(NSArray<NSString*>*)methods
                 session:(SZOperationSession*)session
                   error:(NSError**)error {
    CCodecs* codecs = SZGetCodecs();
    if (!codecs) {
        if (error)
            *error = SZMakeError(-1, SZLocalizedString(@"app.archive.error.failedToInitCodecs"));
        return nil;
    }

    NSArray<NSString*>* effectiveMethods = methods.count > 0 ? methods : @[
        @"CRC32", @"CRC64", @"XXH64", @"MD5", @"SHA1",
        @"SHA256", @"SHA384", @"SHA512", @"SHA3-256", @"BLAKE2sp"
    ];
    CHashOptions options;
    for (NSString* method in effectiveMethods) {
        options.Methods.Add(ToU(method));
    }

    NWildcard::CCensor censor;
    NWildcard::CCensorPathProps props;
    props.Recursive = false;
    censor.AddItem(NWildcard::k_AbsPath, true, ToU(path), props);

    class HashCB : public IHashCallbackUI {
    public:
        __weak SZOperationSession* session;
        NSMutableDictionary* results;
        UString failureDescription;
        UString failureReason;
        HRESULT failureResult;
        UInt64 totalSize;

        HashCB(SZOperationSession* resolvedSession)
            : session(resolvedSession)
            , results([NSMutableDictionary dictionary])
            , failureResult(S_OK)
            , totalSize(0) {
        }

        bool HasFailure() const { return failureResult != S_OK; }

        HRESULT StartScanning() override {
            if (session) {
                [session reportPhase:SZOperationPhaseScanning];
            }
            return CheckBreak();
        }
        HRESULT FinishScanning(const CDirItemsStat&) override {
            return CheckBreak();
        }
        HRESULT SetNumFiles(UInt64) override { return CheckBreak(); }
        HRESULT SetTotal(UInt64 size) override {
            totalSize = size;
            if (session && size > 0) {
                [session reportProgressFraction:0.0];
                [session reportBytesCompleted:0 total:size];
            }
            return CheckBreak();
        }
        HRESULT SetCompleted(const UInt64* completed) override {
            if (session && completed && totalSize > 0) {
                UInt64 value = *completed;
                if (value > totalSize) {
                    value = totalSize;
                }
                [session reportProgressFraction:(double)value / (double)totalSize];
                [session reportBytesCompleted:value total:totalSize];
            }
            return CheckBreak();
        }
        HRESULT CheckBreak() override {
            return (session && [session shouldCancel]) ? E_ABORT : S_OK;
        }
        HRESULT BeforeFirstFile(const CHashBundle&) override {
            return CheckBreak();
        }
        HRESULT GetStream(const wchar_t* name, bool) override {
            if (session) {
                [session reportPhase:SZOperationPhaseReading];
                if (name) {
                    [session reportCurrentFileName:ToNS(UString(name))];
                }
            }
            return CheckBreak();
        }
        HRESULT OpenFileError(const FString& path, DWORD errorCode) override {
            RecordFailure(SZLocalizedString(@"app.archive.error.hashOpenFailed"), path, errorCode);
            return S_FALSE;
        }
        HRESULT SetOperationResult(UInt64, const CHashBundle& hb, bool) override {
            for (unsigned i = 0; i < hb.Hashers.Size(); i++) {
                const CHasherState& h = hb.Hashers[i];
                char hex[256];
                HashHexToString(hex, h.Digests[0], h.DigestSize);
                results[NSFromCString(h.Name.Ptr())] = NSFromCString(hex);
            }
            return S_OK;
        }
        HRESULT AfterLastFile(CHashBundle&) override {
            if (session && totalSize > 0) {
                [session reportProgressFraction:1.0];
                [session reportBytesCompleted:totalSize total:totalSize];
            }
            return CheckBreak();
        }
        HRESULT ScanError(const FString& path, DWORD errorCode) override {
            RecordFailure(SZLocalizedString(@"app.archive.error.hashScanFailed"), path, errorCode);
            return S_FALSE;
        }
        HRESULT ScanProgress(const CDirItemsStat&, const FString& path,
            bool) override {
            if (session && !path.IsEmpty()) {
                [session reportCurrentFileName:ToNS(fs2us(path))];
            }
            return CheckBreak();
        }

    private:
        void RecordFailure(NSString* description, const FString& path,
            DWORD errorCode) {
            if (HasFailure()) {
                return;
            }

            failureDescription = ToU(description ?: @"");
            failureReason = fs2us(path);

            const UString systemMessage = NWindows::NError::MyFormatMessage(errorCode);
            if (!failureReason.IsEmpty() && !systemMessage.IsEmpty()) {
                failureReason += L"\n\n";
            }
            failureReason += systemMessage;
            failureResult = (errorCode == 0) ? E_FAIL : HRESULT_FROM_WIN32(errorCode);
        }
    };

    HashCB cb(session);
    AString errorInfo;
    HRESULT r = HashCalc(EXTERNAL_CODECS_LOC_VARS censor, options, errorInfo, &cb);

    if (cb.HasFailure()) {
        if (error) {
            NSString* description = cb.failureDescription.IsEmpty()
                ? SZLocalizedString(@"app.archive.error.hashFailed")
                : ToNS(cb.failureDescription);
            NSString* reason = cb.failureReason.IsEmpty() ? nil : ToNS(cb.failureReason);
            *error = SZMakeDetailedError(cb.failureResult, description, reason);
        }
        return nil;
    }

    if (r != S_OK) {
        NSString* reason = errorInfo.IsEmpty()
            ? nil
            : NSFromCString(errorInfo.Ptr());
        if (error)
            *error = SZMakeDetailedError(r,
                SZLocalizedString(@"app.archive.error.hashFailed"), reason);
        return nil;
    }

    return cb.results;
}

@end
