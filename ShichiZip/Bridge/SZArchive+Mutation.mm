// SZArchive+Mutation.mm — Archive updates and compression creation

#import "SZArchiveInternal.h"
#include "SZCallbacks.h"
#include "SZCompressionEstimate.h"

#include <algorithm>
#include <functional>
#include <vector>

#include "CPP/7zip/UI/Agent/Agent.h"
#include "CPP/7zip/UI/Common/EnumDirItems.h"
#include "CPP/7zip/UI/Common/SetProperties.h"
#include "CPP/7zip/UI/Common/Update.h"
#include "CPP/7zip/UI/Common/UpdateCallback.h"
#include "CPP/7zip/UI/Common/WorkDir.h"
#include "CPP/Common/StringToInt.h"
#include "CPP/Common/Wildcard.h"
#include "CPP/Windows/ErrorMsg.h"

static NSString* SZNormalizeArchiveRelativePath(NSString* path) {
    NSString* normalized = [path copy] ?: @"";
    while (normalized.length > 0 && [normalized hasSuffix:@"/"]) {
        normalized = [normalized substringToIndex:normalized.length - 1];
    }
    return normalized;
}

static NSArray<NSString*>* SZArchivePathComponents(NSString* path) {
    NSString* normalized = SZNormalizeArchiveRelativePath(path);
    if (normalized.length == 0) {
        return @[];
    }

    NSMutableArray<NSString*>* components = [NSMutableArray array];
    for (NSString* component in [normalized componentsSeparatedByString:@"/"]) {
        if (component.length > 0) {
            [components addObject:component];
        }
    }
    return components;
}

static NSString* SZArchiveParentPath(NSString* path) {
    NSArray<NSString*>* components = SZArchivePathComponents(path);
    if (components.count <= 1) {
        return @"";
    }
    return [[components subarrayWithRange:NSMakeRange(0, components.count - 1)]
        componentsJoinedByString:@"/"];
}

static NSString* SZArchiveLeafName(NSString* path) {
    return SZArchivePathComponents(path).lastObject ?: @"";
}

static NSString* SZFolderItemName(IFolderFolder* folder, UInt32 index) {
    NWindows::NCOM::CPropVariant value;
    if (folder->GetProperty(index, kpidName, &value) != S_OK) {
        return nil;
    }
    if (value.vt == VT_BSTR && value.bstrVal) {
        return ToNS(UString(value.bstrVal));
    }
    return nil;
}

static bool SZFolderItemIsDirectory(IFolderFolder* folder, UInt32 index,
    bool& isDirectory) {
    NWindows::NCOM::CPropVariant value;
    if (folder->GetProperty(index, kpidIsDir, &value) != S_OK
        || value.vt != VT_BOOL) {
        return false;
    }
    isDirectory = value.boolVal != VARIANT_FALSE;
    return true;
}

static bool SZArchivePathsEqual(NSString* lhs, NSString* rhs) {
    const UString lhsValue = ToU(lhs);
    const UString rhsValue = ToU(rhs);
    return CompareFileNames(lhsValue, rhsValue) == 0;
}

static bool SZItemReferencesMatchSnapshot(
    NSArray<SZArchiveItemReference*>* itemReferences,
    NSUUID* snapshotIdentifier) {
    if (itemReferences.count == 0 || !snapshotIdentifier) {
        return false;
    }

    for (SZArchiveItemReference* itemReference in itemReferences) {
        if (![itemReference.snapshotIdentifier
                isEqual:snapshotIdentifier]) {
            return false;
        }
        if (!itemReference.hasArchiveIndex && !itemReference.isDirectory) {
            return false;
        }
        if (itemReference.hasArchiveIndex
            && itemReference.archiveIndex > (NSUInteger)INT_MAX) {
            return false;
        }
    }
    return true;
}

static HRESULT SZBindFolderToArchiveSubdir(IFolderFolder* rootFolder,
    NSString* archiveSubdir,
    IFolderFolder** resultFolder) {
    CMyComPtr<IFolderFolder> currentFolder = rootFolder;
    for (NSString* component in SZArchivePathComponents(archiveSubdir)) {
        CMyComPtr<IFolderFolder> nextFolder;
        RINOK(currentFolder->BindToFolder(ToU(component), &nextFolder))
        if (!nextFolder) {
            return E_INVALIDARG;
        }
        currentFolder = nextFolder;
    }

    *resultFolder = currentFolder.Detach();
    return S_OK;
}

static HRESULT SZResolveFolderItemReferences(IFolderFolder* folder,
    NSArray<SZArchiveItemReference*>* itemReferences,
    NSString* archiveSubdir,
    std::vector<UInt32>& indices) {
    indices.clear();

    NSString* normalizedSubdir = SZNormalizeArchiveRelativePath(archiveSubdir);
    UInt32 numItems = 0;
    RINOK(folder->GetNumberOfItems(&numItems))

    CMyComPtr<IFolderFolder> owningFolder(folder);
    CMyComPtr<IArchiveFolderInternal> internalFolder;
    RINOK(owningFolder.QueryInterface(
        IID_IArchiveFolderInternal, &internalFolder))
    if (!internalFolder) {
        return E_NOINTERFACE;
    }

    CAgentFolder* agentFolder = NULL;
    RINOK(internalFolder->GetAgentFolder(&agentFolder))
    if (!agentFolder) {
        return E_FAIL;
    }

    for (SZArchiveItemReference* itemReference in itemReferences) {
        NSString* normalizedPath = SZNormalizeArchiveRelativePath(itemReference.path);
        if (!SZArchivePathsEqual(
                SZArchiveParentPath(normalizedPath), normalizedSubdir)) {
            return E_INVALIDARG;
        }

        NSString* expectedName = SZArchiveLeafName(normalizedPath);
        if (expectedName.length == 0) {
            return E_INVALIDARG;
        }

        UInt32 resolvedIndex = 0;
        unsigned matchCount = 0;
        for (UInt32 index = 0; index < numItems; index++) {
            if (itemReference.hasArchiveIndex) {
                const int realIndex = agentFolder->GetRealIndex(index);
                if (realIndex < 0
                    || (NSUInteger)(unsigned)realIndex
                        != itemReference.archiveIndex) {
                    continue;
                }
            }

            NSString* itemName = SZFolderItemName(folder, index);
            if (!itemName || !SZArchivePathsEqual(itemName, expectedName)) {
                continue;
            }

            bool isDirectory = false;
            if (!SZFolderItemIsDirectory(folder, index, isDirectory)
                || isDirectory != (bool)itemReference.isDirectory) {
                continue;
            }

            resolvedIndex = index;
            matchCount++;
        }

        if (matchCount != 1
            || std::find(indices.begin(), indices.end(), resolvedIndex)
                != indices.end()) {
            return E_INVALIDARG;
        }
        indices.push_back(resolvedIndex);
    }

    return S_OK;
}

static HRESULT SZOpenAgentFolder(NSString* archivePath, NSString* openType,
    SZAgentUpdateCallback* callback,
    NSString* archiveSubdir,
    CMyComPtr<IInFolderArchive>& agentOut,
    CAgent*& agentSpecOut,
    CMyComPtr<IFolderFolder>& folderOut) {
    CAgent* agentSpec = new CAgent();
    agentOut = agentSpec;
    agentSpecOut = agentSpec;

    UString openTypeText = openType.length > 0 ? ToU(openType) : UString();
    const wchar_t* arcFormat = openTypeText.IsEmpty() ? L"" : openTypeText.Ptr();
    RINOK(agentOut->Open(NULL, ToU(archivePath), arcFormat, NULL, callback))

    CMyComPtr<IFolderFolder> rootFolder;
    RINOK(agentOut->BindToRootFolder(&rootFolder))

    if (archiveSubdir.length == 0) {
        folderOut = rootFolder;
        return S_OK;
    }

    return SZBindFolderToArchiveSubdir(rootFolder, archiveSubdir, &folderOut);
}

static NSError* SZArchiveMutationError(
    NSError* error, bool archiveWasReplaced) {
    if (!archiveWasReplaced) {
        return error;
    }

    NSMutableDictionary* userInfo = [error.userInfo mutableCopy]
        ?: [NSMutableDictionary dictionary];
    userInfo[SZArchiveMutationCommittedErrorKey] = @YES;
    return [NSError errorWithDomain:error.domain
                               code:error.code
                           userInfo:userInfo];
}

static NSError* SZArchiveMutationReopenError(
    NSError* error, bool archiveWasReplaced) {
    NSError* mutationError = SZArchiveMutationError(error, archiveWasReplaced);
    if (!archiveWasReplaced) {
        return mutationError;
    }

    NSMutableDictionary* userInfo = [mutationError.userInfo mutableCopy]
        ?: [NSMutableDictionary dictionary];
    userInfo[SZArchiveMutationReopenFailedErrorKey] = @YES;
    return [NSError errorWithDomain:mutationError.domain
                               code:mutationError.code
                           userInfo:userInfo];
}

static SZArchiveUpdateOutcome* SZArchiveUpdateOutcomeFromDiagnostics(
    const SZUpdateDiagnostics& diagnostics,
    bool archiveCommitted) {
    const bool hasWarnings = diagnostics.HasIssues();
    return [[SZArchiveUpdateOutcome alloc]
        initWithCompletion:(hasWarnings
                                   ? SZArchiveUpdateCompletionCompletedWithWarnings
                                   : SZArchiveUpdateCompletionComplete)
          archiveCommitted:archiveCommitted
                    issues:diagnostics.MakeIssues()
           totalIssueCount:diagnostics.TotalIssueCount()
           issuesTruncated:diagnostics.IsTruncated()];
}

static UString SZUpdateErrorInfoSummary(const CUpdateErrorInfo& errorInfo) {
    UString summary;
    if (!errorInfo.Message.IsEmpty()) {
        summary = ToU(NSFromCString(errorInfo.Message.Ptr()));
    }
    FOR_VECTOR(i, errorInfo.FileNames) {
        if (!summary.IsEmpty()) {
            summary += L"\n";
        }
        summary += fs2us(errorInfo.FileNames[i]);
    }
    if (errorInfo.SystemError != 0) {
        const UString systemMessage = NWindows::NError::MyFormatMessage(errorInfo.Get_HRESULT_Error());
        if (!systemMessage.IsEmpty()) {
            if (!summary.IsEmpty()) {
                summary += L"\n";
            }
            summary += systemMessage;
        }
    }
    return summary;
}

static NSError* SZArchiveUpdateErrorFromResult(HRESULT result,
    NSString* fallbackDescription,
    const UString& errorMessage,
    bool archiveWasReplaced = false) {
    if (result == E_ABORT) {
        return SZArchiveMutationError(
            SZMakeError(SZArchiveErrorCodeUserCancelled,
                SZLocalizedString(@"app.archive.error.operationCancelled")),
            archiveWasReplaced);
    }

    if (result == E_NOTIMPL) {
        return SZArchiveMutationError(
            SZMakeError(
                SZArchiveErrorCodeUnsupportedFormat,
                SZLocalizedString(@"archive.updateUnsupported")),
            archiveWasReplaced);
    }

    if (result == E_INVALIDARG && errorMessage.IsEmpty()) {
        return SZArchiveMutationError(
            SZMakeError(result,
                SZLocalizedString(@"app.archive.error.invalidItemSelection")),
            archiveWasReplaced);
    }

    if (result == (HRESULT)ERROR_ALREADY_EXISTS || result == HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)) {
        return SZArchiveMutationError(
            SZMakeError(
                result, SZLocalizedString(@"app.archive.error.itemAlreadyExists")),
            archiveWasReplaced);
    }

    NSString* details = ToNS(errorMessage);
    if (details.length > 0) {
        return SZArchiveMutationError(
            SZMakeDetailedError(result, fallbackDescription, details),
            archiveWasReplaced);
    }

    return SZArchiveMutationError(
        SZMakeError(result,
            [NSString stringWithFormat:@"%@ (0x%08X)",
                fallbackDescription, (unsigned)result]),
        archiveWasReplaced);
}

static SZArchiveUpdateOutcome* SZFinalizeAgentUpdateResult(
    HRESULT result,
    NSString* failureDescription,
    SZAgentUpdateCallback* callback,
    NSError** error) {
    if (result != S_OK) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(
                result,
                failureDescription,
                callback->Diagnostics.MakeSummary(),
                callback->ArchiveWasReplaced);
        }
        return nil;
    }

    return SZArchiveUpdateOutcomeFromDiagnostics(
        callback->Diagnostics, callback->ArchiveWasReplaced);
}

static BOOL SZConfigureZipContentUpdate(CAgent* agent,
    NSString* archivePath,
    SZAgentUpdateCallback* callback,
    SZOperationSession* session,
    NSError** error) {
    IInArchive* archive = agent->_archiveLink.GetArchive();
    UInt32 numItems = 0;
    HRESULT result = archive->GetNumberOfItems(&numItems);
    SZEncryptionMethod defaultEncryption = SZEncryptionMethodNone;
    for (UInt32 index = 0; result == S_OK && index < numItems; index++) {
        if ([session shouldCancel]) {
            result = E_ABORT;
            break;
        }
        NWindows::NCOM::CPropVariant isDirectory;
        result = archive->GetProperty(index, kpidIsDir, &isDirectory);
        if (result != S_OK) {
            break;
        }
        if (isDirectory.vt != VT_BOOL) {
            result = E_FAIL;
            break;
        }
        if (isDirectory.boolVal != VARIANT_FALSE) {
            continue;
        }
        NWindows::NCOM::CPropVariant encrypted;
        result = archive->GetProperty(index, kpidEncrypted, &encrypted);
        if (result != S_OK) {
            break;
        }
        if (encrypted.vt != VT_BOOL) {
            result = E_FAIL;
            break;
        }
        if (encrypted.boolVal != VARIANT_FALSE) {
            // The ZIP handler prefixes kpidMethod with the encryption name.
            // Use the first encrypted file in archive order, even if its
            // encryption is unknown and the default must remain None.
            NSString* encryptionName = [ItemStr(archive, index, kpidMethod) componentsSeparatedByString:@" "].firstObject;
            if ([encryptionName isEqualToString:@"ZipCrypto"]) {
                defaultEncryption = SZEncryptionMethodZipCrypto;
            } else if ([encryptionName isEqualToString:@"AES-128"]
                || [encryptionName isEqualToString:@"AES-192"]
                || [encryptionName isEqualToString:@"AES-256"]) {
                defaultEncryption = SZEncryptionMethodAES256;
            }
            break;
        }
    }

    CMyComPtr<ISetProperties> handlerProperties;
    if (result == S_OK) {
        archive->QueryInterface(IID_ISetProperties, (void**)&handlerProperties);
        if (!handlerProperties) {
            result = E_NOTIMPL;
        }
    }
    if (result != S_OK) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(result,
                SZLocalizedStringWithFirstPlaceholder(@"archive.cannotUpdateFile", archivePath), UString());
        }
        return NO;
    }

    SZArchiveUpdateEncryption* selection = [session requestUpdateEncryptionForArchive:archivePath
                                                                    defaultEncryption:defaultEncryption];
    if (!selection || [session shouldCancel]) {
        if (error) {
            *error = SZMakeError(SZArchiveErrorCodeUserCancelled,
                SZLocalizedString(@"app.archive.error.operationCancelled"));
        }
        return NO;
    }
    if (![selection validateWithError:error]) {
        return NO;
    }

    const wchar_t* propertyName = L"em";
    NWindows::NCOM::CPropVariant propertyValue(
        selection.encryption == SZEncryptionMethodAES256 ? L"AES256" : L"ZipCrypto");
    // CopyFrom reapplies the agent properties; CopyFromFile uses the handler
    // directly. Configure both so neither path infers a mode from old entries.
    result = static_cast<ISetProperties*>(agent)->SetProperties(&propertyName, &propertyValue, 1);
    if (result == S_OK) {
        result = handlerProperties->SetProperties(&propertyName, &propertyValue, 1);
    }
    if (result != S_OK) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(result,
                SZLocalizedStringWithFirstPlaceholder(@"archive.cannotUpdateFile", archivePath), UString());
        }
        return NO;
    }

    // An undefined password controls plain output, including an explicit None
    // choice. Read-password hints never participate in this write policy.
    callback->PasswordIsDefined = selection.encryption != SZEncryptionMethodNone;
    callback->Password = callback->PasswordIsDefined ? ToU(selection.password) : UString();
    return YES;
}

static bool SZIsCorrectArchiveMutationName(NSString* name) {
    const UString value = ToU(name);
    const UString lastPart = value.Ptr((unsigned)(value.ReverseFind_PathSepar() + 1));
    return !lastPart.IsEqualTo(".") && !lastPart.IsEqualTo("..");
}

static BOOL SZValidateArchiveMutationName(NSString* name, NSError** error) {
    if (SZIsCorrectArchiveMutationName(name)) {
        return YES;
    }
    if (error) {
        *error = SZMakeError(E_INVALIDARG,
            SZLocalizedString(@"app.archive.error.invalidItemName"));
    }
    return NO;
}

static NSString* SZArchiveCodecNameForCreateFormat(SZArchiveFormat format) {
    switch (format) {
    case SZArchiveFormat7z:
        return @"7z";
    case SZArchiveFormatZip:
        return @"zip";
    case SZArchiveFormatTar:
        return @"tar";
    case SZArchiveFormatGZip:
        return @"gzip";
    case SZArchiveFormatBZip2:
        return @"bzip2";
    case SZArchiveFormatXz:
        return @"xz";
    case SZArchiveFormatWim:
        return @"wim";
#if SHICHIZIP_ZS_VARIANT
    case SZArchiveFormatZstd:
        return @"zstd";
    case SZArchiveFormatBrotli:
        return @"brotli";
    case SZArchiveFormatLizard:
        return @"lizard";
    case SZArchiveFormatLz4:
        return @"lz4";
    case SZArchiveFormatLz5:
        return @"lz5";
#endif
    default:
        return nil;
    }
}

static UString SZCompressionMethodSpec(SZCompressionSettings* settings) {
    if (settings.methodName.length > 0) {
        return ToU(settings.methodName);
    }

    switch (settings.method) {
    case SZCompressionMethodLZMA:
        return UString(L"LZMA");
    case SZCompressionMethodLZMA2:
        return UString(L"LZMA2");
    case SZCompressionMethodPPMd:
        return UString(L"PPMd");
    case SZCompressionMethodBZip2:
        return UString(L"BZip2");
    case SZCompressionMethodDeflate:
        return UString(L"Deflate");
    case SZCompressionMethodDeflate64:
        return UString(L"Deflate64");
    case SZCompressionMethodCopy:
        return UString(L"Copy");
    }
}

static bool SZCompressionMethodUsesOrderMode(const UString& methodSpec) {
    return methodSpec.IsEqualTo_Ascii_NoCase("PPMd");
}

static UString
SZCompressionEncryptionProperty(SZCompressionSettings* settings) {
    if (settings.password.length == 0) {
        return UString();
    }

    if (settings.format == SZArchiveFormatZip) {
        // Zip should only use an explicit encryption mode when a password is set.
        switch (settings.encryption) {
        case SZEncryptionMethodAES256:
            return UString(L"AES256");
        case SZEncryptionMethodZipCrypto:
            return UString(L"ZipCrypto");
        case SZEncryptionMethodNone:
            // Let createAtPath: reject password + no explicit zip mode.
            return UString();
        }
    }

    return UString();
}

static const NUpdateArchive::CActionSet&
SZCompressionActionSetForMode(SZCompressionUpdateMode mode) {
    switch (mode) {
    case SZCompressionUpdateModeUpdate:
        return NUpdateArchive::k_ActionSet_Update;
    case SZCompressionUpdateModeFresh:
        return NUpdateArchive::k_ActionSet_Fresh;
    case SZCompressionUpdateModeSync:
        return NUpdateArchive::k_ActionSet_Sync;
    case SZCompressionUpdateModeAdd:
    default:
        return NUpdateArchive::k_ActionSet_Add;
    }
}

static NWildcard::ECensorPathMode
SZMapCompressionPathMode(SZCompressionPathMode mode) {
    switch (mode) {
    case SZCompressionPathModeFullPaths:
        return NWildcard::k_FullPath;
    case SZCompressionPathModeAbsolutePaths:
        return NWildcard::k_AbsPath;
    case SZCompressionPathModeRelativePaths:
    default:
        return NWildcard::k_RelatPath;
    }
}

static NSString* SZDirectoryPathWithTrailingSeparator(NSString* path) {
    if (path.length == 0 || [path hasSuffix:@"/"]) {
        return path;
    }
    return [path stringByAppendingString:@"/"];
}

static NSString* SZStandardizedSourcePath(NSString* path) {
    return [NSURL fileURLWithPath:path].standardizedURL.path;
}

static BOOL SZBuildRelativeCompressionSourceMap(
    NSArray<NSString*>* sourcePaths,
    NSString* __autoreleasing* commonDirectoryOut,
    NSArray<NSString*>* __autoreleasing* relativePathsOut) {
    if (sourcePaths.count == 0) {
        return NO;
    }

    NSMutableArray<NSArray<NSString*>*>* sourceComponents =
        [NSMutableArray arrayWithCapacity:sourcePaths.count];
    NSMutableArray<NSString*>* commonParentComponents = nil;

    for (NSString* sourcePath in sourcePaths) {
        if (![sourcePath isAbsolutePath]) {
            return NO;
        }

        NSString* standardizedPath = SZStandardizedSourcePath(sourcePath);
        NSArray<NSString*>* components = standardizedPath.pathComponents;
        [sourceComponents addObject:components];

        NSArray<NSString*>* parentComponents =
            [standardizedPath.stringByDeletingLastPathComponent pathComponents];
        if (!commonParentComponents) {
            commonParentComponents = [parentComponents mutableCopy];
            continue;
        }

        NSUInteger commonCount = 0;
        NSUInteger upperBound = MIN(commonParentComponents.count, parentComponents.count);
        while (commonCount < upperBound
            && [commonParentComponents[commonCount] isEqualToString:parentComponents[commonCount]]) {
            commonCount++;
        }
        [commonParentComponents removeObjectsInRange:
                NSMakeRange(commonCount, commonParentComponents.count - commonCount)];
    }

    if (!commonParentComponents) {
        return NO;
    }

    NSMutableArray<NSString*>* relativePaths = [NSMutableArray arrayWithCapacity:sourcePaths.count];
    for (NSArray<NSString*>* components in sourceComponents) {
        NSArray<NSString*>* relativeComponents =
            [components subarrayWithRange:NSMakeRange(commonParentComponents.count,
                                              components.count - commonParentComponents.count)];
        if (relativeComponents.count == 0) {
            return NO;
        }
        [relativePaths addObject:[NSString pathWithComponents:relativeComponents]];
    }

    NSString* commonDirectory = [NSString pathWithComponents:commonParentComponents];
    if (commonDirectoryOut) {
        *commonDirectoryOut = commonDirectory;
    }
    if (relativePathsOut) {
        *relativePathsOut = relativePaths;
    }
    return YES;
}

static void SZAddNoWildcardCensorItem(NWildcard::CPair& pair, NSString* relativePath) {
    NWildcard::CItem item;
    SplitPathToParts(ToU(relativePath), item.PathParts);
    item.Recursive = false;
    item.ForFile = true;
    item.ForDir = true;
    item.WildcardMatching = false;
    pair.Head.AddItem(true, item);
}

static void SZAddCompressionSourcesToCensor(
    NWildcard::CCensor& censor,
    NSArray<NSString*>* sourcePaths,
    SZCompressionPathMode pathMode) {
    NSString* commonDirectory = nil;
    NSArray<NSString*>* relativePaths = nil;
    if (pathMode == SZCompressionPathModeRelativePaths
        && SZBuildRelativeCompressionSourceMap(sourcePaths, &commonDirectory, &relativePaths)) {
        NWildcard::CPair& pair = censor.Pairs.AddNew();
        pair.Prefix = ToU(SZDirectoryPathWithTrailingSeparator(commonDirectory));
        for (NSString* relativePath in relativePaths) {
            SZAddNoWildcardCensorItem(pair, relativePath);
        }
        return;
    }

    for (NSString* sourcePath in sourcePaths) {
        censor.AddPreItem_NoWildcard(ToU(sourcePath));
    }
}

static void SZAddCompressionProperty(CObjectVector<CProperty>& properties,
    const wchar_t* name,
    const UString& value) {
    CProperty property;
    property.Name = name;
    property.Value = value;
    properties.Add(property);
}

static void SZAddCompressionPropertyUInt32(CObjectVector<CProperty>& properties,
    const wchar_t* name, UInt32 value) {
    UString text;
    text.Add_UInt32(value);
    SZAddCompressionProperty(properties, name, text);
}

static void SZAddCompressionPropertySize(CObjectVector<CProperty>& properties,
    const wchar_t* name, UInt64 value) {
    UString text;
    text.Add_UInt64(value);
    text.Add_Char('b');
    SZAddCompressionProperty(properties, name, text);
}

static void SZAddCompressionPropertyBool(CObjectVector<CProperty>& properties,
    const wchar_t* name, bool value) {
    SZAddCompressionProperty(properties, name, UString(value ? L"on" : L"off"));
}

static CBoolPair SZCompressionBoolPair(SZCompressionBoolSetting setting) {
    CBoolPair pair;
    if (setting != SZCompressionBoolSettingNotDefined) {
        pair.Def = true;
        pair.Val = (setting == SZCompressionBoolSettingOn);
    }
    return pair;
}

static bool SZLocateBundledWindowsSfxModule(FString& sfxModule) {
    NSString* path = [[NSBundle mainBundle] pathForResource:@"7z" ofType:@"sfx"];
    if (path.length == 0) {
        return false;
    }

    sfxModule = us2fs(ToU(path));
    return true;
}

static void SZSplitOptionsToStrings(const UString& src,
    UStringVector& strings) {
    SplitString(src, strings);
    FOR_VECTOR(i, strings) {
        UString& option = strings[i];
        if (option.Len() > 2 && option[0] == '-' && MyCharLower_Ascii(option[1]) == 'm') {
            option.DeleteFrontal(2);
        }
    }
}

static void SZAddCensorExclude(NWildcard::CCensor& censor, const wchar_t* path,
    bool recursive, bool wildcardMatching,
    Byte markMode) {
    NWildcard::CCensorPathProps props;
    props.Recursive = recursive;
    props.WildcardMatching = wildcardMatching;
    props.MarkMode = markMode;
    censor.AddPreItem(false, UString(path), props);
}

static void SZAddMacResourceFileExcludes(NWildcard::CCensor& censor) {
    SZAddCensorExclude(censor, L".DS_Store", true, false,
        NWildcard::kMark_StrictFile);
    SZAddCensorExclude(censor, L"._*", true, true, NWildcard::kMark_StrictFile);
    SZAddCensorExclude(censor, L"Icon\r", true, false,
        NWildcard::kMark_StrictFile);
    SZAddCensorExclude(censor, L".VolumeIcon.icns", true, false,
        NWildcard::kMark_StrictFile);
    SZAddCensorExclude(censor, L".apdisk", true, false,
        NWildcard::kMark_StrictFile);

    SZAddCensorExclude(censor, L"__MACOSX/", true, false,
        NWildcard::kMark_FileOrDir);
    SZAddCensorExclude(censor, L".Spotlight-V100/", true, false,
        NWildcard::kMark_FileOrDir);
    SZAddCensorExclude(censor, L".Trashes/", true, false,
        NWildcard::kMark_FileOrDir);
    SZAddCensorExclude(censor, L".fseventsd/", true, false,
        NWildcard::kMark_FileOrDir);
    SZAddCensorExclude(censor, L".TemporaryItems/", true, false,
        NWildcard::kMark_FileOrDir);
    SZAddCensorExclude(censor, L".DocumentRevisions-V100/", true, false,
        NWildcard::kMark_FileOrDir);
}

// Lock/owner files that office suites drop next to an open document:
// Microsoft Office ("~$Report.docx"), WPS Office (".~Report.docx") and
// LibreOffice (".~lock.Report.docx#").
static void SZAddOfficeLockFileExcludes(NWildcard::CCensor& censor) {
    SZAddCensorExclude(censor, L"~$*", true, true, NWildcard::kMark_StrictFile);
    SZAddCensorExclude(censor, L".~*", true, true, NWildcard::kMark_StrictFile);
}

static bool SZHasMethodOverride(bool is7z, const UStringVector& strings) {
    FOR_VECTOR(i, strings) {
        const UString& option = strings[i];
        if (is7z) {
            const wchar_t* end = NULL;
            const UInt64 number = ConvertStringToUInt64(option, &end);
            if (number == 0 && *end == L'=') {
                return true;
            }
        } else if (option.Len() > 1 && option[0] == L'm' && option[1] == L'=') {
            return true;
        }
    }

    return false;
}

static void
SZParseAndAddCompressionProperties(CObjectVector<CProperty>& properties,
    const UStringVector& strings) {
    FOR_VECTOR(i, strings) {
        const UString& option = strings[i];
        CProperty property;
        const int separatorIndex = option.Find(L'=');
        if (separatorIndex < 0) {
            property.Name = option;
        } else {
            property.Name.SetFrom(option, (unsigned)separatorIndex);
            property.Value = option.Ptr(separatorIndex + 1);
        }
        properties.Add(property);
    }
}

static bool SZParseVolumeSizes(const UString& text,
    CRecordVector<UInt64>& values) {
    values.Clear();
    bool previousTokenWasNumber = false;

    for (unsigned index = 0; index < text.Len();) {
        wchar_t character = text[index++];
        if (character == L' ') {
            continue;
        }
        if (character == L'-') {
            return true;
        }

        if (previousTokenWasNumber) {
            previousTokenWasNumber = false;
            unsigned shiftBits = 0;
            switch (MyCharLower_Ascii(character)) {
            case 'b':
                continue;
            case 'k':
                shiftBits = 10;
                break;
            case 'm':
                shiftBits = 20;
                break;
            case 'g':
                shiftBits = 30;
                break;
            case 't':
                shiftBits = 40;
                break;
            }

            if (shiftBits != 0) {
                UInt64& value = values.Back();
                if (value >= ((UInt64)1 << (64 - shiftBits))) {
                    return false;
                }
                value <<= shiftBits;

                for (; index < text.Len(); index++) {
                    if (text[index] == L' ') {
                        break;
                    }
                }
                continue;
            }
        }

        index--;
        const wchar_t* start = text.Ptr(index);
        const wchar_t* end = NULL;
        const UInt64 value = ConvertStringToUInt64(start, &end);
        if (start == end || value == 0) {
            return false;
        }
        values.Add(value);
        previousTokenWasNumber = true;
        index += (unsigned)(end - start);
    }

    return true;
}

static BOOL SZResolveConfiguredWorkDirForPath(NSString* path, FString& workDir, NSError** error) {
    workDir.Empty();
    NWorkDir::CInfo workDirInfo;
    workDirInfo.Load();
    if (workDirInfo.Mode == NWorkDir::NMode::kCurrent) {
        return YES;
    }

    FString fullPath;
    if (!NWindows::NFile::NDir::MyGetFullPathName(us2fs(ToU(path)), fullPath)) {
        if (error) {
            const HRESULT result = GetLastError_noZero_HRESULT();
            NSString* failureReason = ToNS(NWindows::NError::MyFormatMessage(result));
            *error = SZMakeDetailedError(result, SZLocalizedString(@"create.errorFolder"), failureReason);
        }
        return NO;
    }

    FString fileName;
    workDir = GetWorkDir(workDirInfo, fullPath, fileName);
    if (NWindows::NFile::NDir::CreateComplexDir(workDir)) {
        return YES;
    }

    if (error) {
        const HRESULT result = GetLastError_noZero_HRESULT();
        NSString* failureReason = ToNS(NWindows::NError::MyFormatMessage(result));
        *error = SZMakeDetailedError(result, SZLocalizedString(@"create.errorFolder"), failureReason);
    }
    return NO;
}

struct SZArchiveMutationOptions {
    bool configuresZipEncryption = false;
    SZUpdateInputErrorPolicy inputErrorPolicy = SZUpdateInputErrorPolicy::ContinueWithWarnings;
};

using SZArchiveMutationPreflight = std::function<BOOL(IFolderFolder*, NSError**)>;
using SZArchiveMutationValidation = std::function<BOOL(NSError**)>;
using SZArchiveMutationOperation = std::function<HRESULT(IFolderOperations*, IFolderArchiveUpdateCallback*)>;

@interface SZArchive (MutationPrivate)
- (void)syncCachedPasswordFromUpdateCallback:(SZAgentUpdateCallback*)callback
                                      result:(HRESULT)result;
- (BOOL)reopenAfterMutationResult:(HRESULT)result
               archiveWasReplaced:(BOOL)archiveWasReplaced
                            error:(NSError**)error;
- (SZArchiveUpdateOutcome*)performMutationInArchiveSubdir:(NSString*)archiveSubdir
                                                  session:(SZOperationSession*)session
                                                  options:(const SZArchiveMutationOptions&)options
                                         beforeOperations:(const SZArchiveMutationPreflight&)beforeOperations
                                              beforeWrite:(const SZArchiveMutationValidation&)beforeWrite
                                                operation:(const SZArchiveMutationOperation&)operation
                                       failureDescription:(NSString*)failureDescription
                                                    error:(NSError**)error;
@end

@implementation SZArchive (Mutation)

// Keep the cached password in sync after an in-place mutation.
- (void)syncCachedPasswordFromUpdateCallback:(SZAgentUpdateCallback*)callback
                                      result:(HRESULT)result {
    if (result != S_OK && !callback->ArchiveWasReplaced) {
        return;
    }
    if ([self.formatName.lowercaseString isEqualToString:@"zip"]) {
        // A ZIP update can mix untouched read passwords with the new write
        // password. Reopening must resolve each entry's read password afresh.
        [self clearCachedPassword];
    } else if (callback->PasswordIsDefined) {
        [self storeCachedPassword:callback->Password defined:true];
    } else {
        [self clearCachedPassword];
    }
}

- (BOOL)reopenAfterMutationResult:(HRESULT)result
               archiveWasReplaced:(BOOL)archiveWasReplaced
                            error:(NSError**)error {
    if (result != S_OK && !archiveWasReplaced) {
        return YES;
    }

    NSString* archivePath = [_archivePath copy];
    NSError* reopenError = nil;
    if ([self reopenAfterExternalMutationWithSession:nil
                                               error:&reopenError]) {
        return YES;
    }

    if (error) {
        NSError* resolvedError = reopenError
            ?: SZMakeError(
                   -1,
                   SZLocalizedStringWithFirstPlaceholder(
                       @"archive.cannotOpenFileAsArchive", archivePath));
        *error = SZArchiveMutationReopenError(
            resolvedError, archiveWasReplaced);
    }
    return NO;
}

// Resolve selection before querying update support; check size limits after.
// Share agent lifetime and finalization without changing early-error precedence.
- (SZArchiveUpdateOutcome*)performMutationInArchiveSubdir:(NSString*)archiveSubdir
                                                  session:(SZOperationSession*)session
                                                  options:(const SZArchiveMutationOptions&)options
                                         beforeOperations:(const SZArchiveMutationPreflight&)beforeOperations
                                              beforeWrite:(const SZArchiveMutationValidation&)beforeWrite
                                                operation:(const SZArchiveMutationOperation&)operation
                                       failureDescription:(NSString*)failureDescription
                                                    error:(NSError**)error {
    SZOperationSession* resolvedSession = session ?: [SZOperationSession makeDefaultSession];
    SZAgentUpdateCallback* updateSpec = new SZAgentUpdateCallback;
    CMyComPtr<IFolderArchiveUpdateCallback> updateCallback(updateSpec);
    updateSpec->Session = resolvedSession;
    updateSpec->InputErrorPolicy = options.inputErrorPolicy;
    updateSpec->ArchivePath = ToU(_archivePath ?: @"");
    const bool configuresZipEncryption = options.configuresZipEncryption
        && [self.formatName.lowercaseString isEqualToString:@"zip"];
    if (!configuresZipEncryption && _cachedPasswordIsDefined) {
        updateSpec->PasswordIsDefined = true;
        updateSpec->Password = ToU(_cachedPassword ?: @"");
    }

    CMyComPtr<IInFolderArchive> agent;
    CAgent* agentSpec = NULL;
    CMyComPtr<IFolderFolder> folder;
    HRESULT result = SZOpenAgentFolder(_archivePath, _openType, updateSpec,
        archiveSubdir, agent, agentSpec, folder);
    if (result != S_OK) {
        if (error) {
            const CArcErrorInfo errorInfo = agentSpec ? agentSpec->_archiveLink.NonOpen_ErrorInfo
                                                      : CArcErrorInfo();
            *error = SZOpenArchiveErrorFromPasswordContext(
                result, errorInfo, updateSpec->PasswordWasAsked, _archivePath);
        }
        return nil;
    }

    if (beforeOperations && !beforeOperations(folder, error)) {
        return nil;
    }

    CMyComPtr<IFolderOperations> folderOperations;
    folder.QueryInterface(IID_IFolderOperations, &folderOperations);
    if (!folderOperations) {
        if (error) {
            *error = SZMakeError(SZArchiveErrorCodeUnsupportedFormat,
                SZLocalizedString(@"archive.updateUnsupported"));
        }
        return nil;
    }

    if (beforeWrite && !beforeWrite(error)) {
        return nil;
    }
    if (configuresZipEncryption
        && !SZConfigureZipContentUpdate(agentSpec, _archivePath, updateSpec, resolvedSession, error)) {
        return nil;
    }
    result = operation(folderOperations, updateCallback);

    [self syncCachedPasswordFromUpdateCallback:updateSpec result:result];
    if (![self reopenAfterMutationResult:result
                      archiveWasReplaced:updateSpec->ArchiveWasReplaced
                                   error:error]) {
        return nil;
    }
    return SZFinalizeAgentUpdateResult(result, failureDescription, updateSpec, error);
}

- (SZArchiveUpdateOutcome*)createFolderNamed:(NSString*)folderName
                             inArchiveSubdir:(NSString*)archiveSubdir
                                     session:(SZOperationSession*)session
                                       error:(NSError**)error {
    SZArchiveOperationGuard operationGuard(self);

    if (!SZValidateArchiveMutationName(folderName, error)) {
        return nil;
    }

    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive,
                SZLocalizedString(@"app.fileManager.error.noArchiveOpen"));
        return nil;
    }
    return [self performMutationInArchiveSubdir:archiveSubdir
        session:session
        options:SZArchiveMutationOptions { }
        beforeOperations:nullptr
        beforeWrite:nullptr
        operation:[&](IFolderOperations* operations, IFolderArchiveUpdateCallback* callback) {
            return operations->CreateFolder(ToU(folderName), callback);
        }
        failureDescription:SZLocalizedString(@"create.errorFolder")
        error:error];
}

- (SZArchiveUpdateOutcome*)renameItemAtReference:(SZArchiveItemReference*)itemReference
                                 inArchiveSubdir:(NSString*)archiveSubdir
                                         newName:(NSString*)newName
                                         session:(SZOperationSession*)session
                                           error:(NSError**)error {
    SZArchiveOperationGuard operationGuard(self);

    if (!SZValidateArchiveMutationName(newName, error)) {
        return nil;
    }

    if (!SZItemReferencesMatchSnapshot(
            @[ itemReference ], _entrySnapshotIdentifier)) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(
                E_INVALIDARG, SZLocalizedString(@"fileop.errorRenaming"),
                UString());
        }
        return nil;
    }

    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive,
                SZLocalizedString(@"app.fileManager.error.noArchiveOpen"));
        return nil;
    }
    std::vector<UInt32> indices;
    return [self performMutationInArchiveSubdir:archiveSubdir
        session:session
        options:SZArchiveMutationOptions { }
        beforeOperations:[&](IFolderFolder* folder, NSError** error) -> BOOL {
            const HRESULT result = SZResolveFolderItemReferences(
                folder, @[ itemReference ], archiveSubdir, indices);
            if (result != S_OK || indices.size() != 1) {
                if (error) {
                    *error = SZArchiveUpdateErrorFromResult(
                        E_INVALIDARG, SZLocalizedString(@"fileop.errorRenaming"), UString());
                }
                return NO;
            }
            return YES;
        }
        beforeWrite:nullptr
        operation:[&](IFolderOperations* operations, IFolderArchiveUpdateCallback* callback) {
            return operations->Rename(indices[0], ToU(newName), callback);
        }
        failureDescription:SZLocalizedString(@"fileop.errorRenaming")
        error:error];
}

- (SZArchiveUpdateOutcome*)deleteItemsAtReferences:
                               (NSArray<SZArchiveItemReference*>*)itemReferences
                                   inArchiveSubdir:(NSString*)archiveSubdir
                                           session:(SZOperationSession*)session
                                             error:(NSError**)error {
    SZArchiveOperationGuard operationGuard(self);

    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive,
                SZLocalizedString(@"app.fileManager.error.noArchiveOpen"));
        return nil;
    }

    if (!SZItemReferencesMatchSnapshot(
            itemReferences, _entrySnapshotIdentifier)) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(
                E_INVALIDARG, SZLocalizedString(@"delete.errorDeleting"),
                UString());
        }
        return nil;
    }
    std::vector<UInt32> indices;
    return [self performMutationInArchiveSubdir:archiveSubdir
        session:session
        options:SZArchiveMutationOptions { }
        beforeOperations:[&](IFolderFolder* folder, NSError** error) -> BOOL {
            const HRESULT result = SZResolveFolderItemReferences(
                folder, itemReferences, archiveSubdir, indices);
            if (result != S_OK || indices.empty()) {
                if (error) {
                    *error = SZArchiveUpdateErrorFromResult(
                        E_INVALIDARG, SZLocalizedString(@"delete.errorDeleting"), UString());
                }
                return NO;
            }
            return YES;
        }
        beforeWrite:[&](NSError** error) -> BOOL {
            if (indices.size() > (size_t)UINT32_MAX) {
                if (error) {
                    *error = SZMakeError(E_INVALIDARG,
                        SZLocalizedString(@"archive.tooManyItems"));
                }
                return NO;
            }
            return YES;
        }
        operation:[&](IFolderOperations* operations, IFolderArchiveUpdateCallback* callback) {
            return operations->Delete(indices.data(), (UInt32)indices.size(),
                callback);
        }
        failureDescription:SZLocalizedString(@"delete.errorDeleting")
        error:error];
}

- (SZArchiveUpdateOutcome*)addPaths:(NSArray<NSString*>*)sourcePaths
                    toArchiveSubdir:(NSString*)archiveSubdir
                           moveMode:(BOOL)moveMode
                            session:(SZOperationSession*)session
                              error:(NSError**)error {
    SZArchiveOperationGuard operationGuard(self);

    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive,
                SZLocalizedString(@"app.fileManager.error.noArchiveOpen"));
        return nil;
    }
    if (sourcePaths.count == 0) {
        SZUpdateDiagnostics diagnostics;
        return SZArchiveUpdateOutcomeFromDiagnostics(diagnostics, false);
    }

    NSMutableArray<NSString*>* normalizedPaths =
        [NSMutableArray arrayWithCapacity:sourcePaths.count];
    NSString* folderPrefix = nil;
    std::vector<UString> pathStorage;
    pathStorage.reserve(sourcePaths.count);

    for (NSString* sourcePath in sourcePaths) {
        NSString* standardizedPath =
            [NSURL fileURLWithPath:sourcePath].standardizedURL.path;
        NSString* parentPath = [standardizedPath stringByDeletingLastPathComponent];
        NSString* leafName = [standardizedPath lastPathComponent];
        if (leafName.length == 0) {
            if (error) {
                *error = SZMakeError(E_INVALIDARG,
                    SZLocalizedString(@"app.archive.error.invalidSourcePath"));
            }
            return nil;
        }

        if (!folderPrefix) {
            folderPrefix = parentPath;
        } else if (![folderPrefix isEqualToString:parentPath]) {
            if (error) {
                *error = SZMakeError(E_INVALIDARG,
                    SZLocalizedString(@"app.archive.error.addSourcesDifferentFolders"));
            }
            return nil;
        }

        [normalizedPaths addObject:standardizedPath];
        pathStorage.push_back(ToU(leafName));
    }

    std::vector<const wchar_t*> pathPointers;
    pathPointers.reserve(pathStorage.size());
    for (const UString& path : pathStorage) {
        pathPointers.push_back(path.Ptr());
    }

    SZArchiveMutationOptions options;
    options.configuresZipEncryption = true;
    // CopyFrom can replace an existing same-name member. Fail closed before
    // publication because input-open warnings may be destructive.
    options.inputErrorPolicy = SZUpdateInputErrorPolicy::StopOnInputError;
    return [self performMutationInArchiveSubdir:archiveSubdir
        session:session
        options:options
        beforeOperations:nullptr
        beforeWrite:[&](NSError** error) -> BOOL {
            if (pathPointers.size() > (size_t)UINT32_MAX) {
                if (error) {
                    *error = SZMakeError(E_INVALIDARG,
                        SZLocalizedString(@"archive.tooManyItems"));
                }
                return NO;
            }
            return YES;
        }
        operation:[&](IFolderOperations* operations, IFolderArchiveUpdateCallback* callback) {
            return operations->CopyFrom(
                moveMode ? 1 : 0, ToU(folderPrefix ?: @"").Ptr(), pathPointers.data(),
                (UInt32)pathPointers.size(), callback);
        }
        failureDescription:SZLocalizedStringWithFirstPlaceholder(@"archive.cannotUpdateFile", _archivePath)
        error:error];
}

- (SZArchiveUpdateOutcome*)replaceItemAtReference:(SZArchiveItemReference*)itemReference
                                  inArchiveSubdir:(NSString*)archiveSubdir
                                   withFileAtPath:(NSString*)sourceFilePath
                                          session:(SZOperationSession*)session
                                            error:(NSError**)error {
    SZArchiveOperationGuard operationGuard(self);

    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive,
                SZLocalizedString(@"app.fileManager.error.noArchiveOpen"));
        return nil;
    }

    if (!SZItemReferencesMatchSnapshot(
            @[ itemReference ], _entrySnapshotIdentifier)) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(
                E_INVALIDARG,
                SZLocalizedStringWithFirstPlaceholder(
                    @"archive.cannotUpdateFile", itemReference.path),
                UString());
        }
        return nil;
    }
    NSString* standardizedSourcePath =
        [NSURL fileURLWithPath:sourceFilePath].standardizedURL.path;
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:standardizedSourcePath]) {
        if (error) {
            *error = SZMakeError(E_INVALIDARG,
                SZLocalizedString(@"app.archive.error.missingNestedArchive"));
        }
        return nil;
    }
    SZArchiveMutationOptions options;
    options.configuresZipEncryption = true;
    options.inputErrorPolicy = SZUpdateInputErrorPolicy::StopOnInputError;
    std::vector<UInt32> indices;
    return [self performMutationInArchiveSubdir:archiveSubdir
        session:session
        options:options
        beforeOperations:[&](IFolderFolder* folder, NSError** error) -> BOOL {
            const HRESULT result = SZResolveFolderItemReferences(
                folder, @[ itemReference ], archiveSubdir, indices);
            if (result != S_OK || indices.size() != 1) {
                if (error) {
                    *error = SZArchiveUpdateErrorFromResult(
                        E_INVALIDARG, SZLocalizedStringWithFirstPlaceholder(@"archive.cannotUpdateFile", itemReference.path),
                        UString());
                }
                return NO;
            }
            return YES;
        }
        beforeWrite:nullptr
        operation:[&](IFolderOperations* operations, IFolderArchiveUpdateCallback* callback) {
            return operations->CopyFromFile(
                indices[0], ToU(standardizedSourcePath).Ptr(), callback);
        }
        failureDescription:SZLocalizedStringWithFirstPlaceholder(@"archive.cannotUpdateFile", itemReference.path)
        error:error];
}

// MARK: - Create

+ (SZArchiveUpdateOutcome*)createAtPath:(NSString*)archivePath
                              fromPaths:(NSArray<NSString*>*)src
                               settings:(SZCompressionSettings*)s
                                session:(SZOperationSession*)session
                                  error:(NSError**)error {
    CCodecs* codecs = SZGetCodecs();
    if (!codecs) {
        if (error)
            *error = SZMakeError(-1, SZLocalizedString(@"app.archive.error.failedToInitCodecs"));
        return nil;
    }

    const int methodID = SZCompressionEstimateMethodID(s);

    NSString* formatName = SZArchiveCodecNameForCreateFormat(s.format);
    if (formatName.length == 0) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeUnsupportedFormat,
                SZLocalizedString(@"archive.unsupportedType"));
        return nil;
    }

    // Reject zip passwords without an explicit encryption mode.
    if (s.format == SZArchiveFormatZip
        && s.password.length > 0
        && s.encryption == SZEncryptionMethodNone) {
        if (error) {
            *error = SZMakeError(E_INVALIDARG,
                SZLocalizedString(@"app.archive.error.zipPasswordRequiresEncryption"));
        }
        return nil;
    }

    CUpdateOptions options;
    options.Commands.Clear();
    CUpdateArchiveCommand command;
    command.ActionSet = SZCompressionActionSetForMode(s.updateMode);
    options.Commands.Add(command);
    options.PathMode = SZMapCompressionPathMode(s.pathMode);
    options.OpenShareForWrite = s.openSharedFiles;
    options.DeleteAfterCompressing = s.deleteAfterCompression;
    options.SfxMode = s.createSFX;
    const bool destinationExists =
        [[NSFileManager defaultManager] fileExistsAtPath:archivePath];
    const bool stopOnInputError = destinationExists
        || s.deleteAfterCompression
        || s.updateMode != SZCompressionUpdateModeAdd;
    options.StopAfterOpenError = stopOnInputError;

    if (s.createSFX) {
        const int sfxMethodID = methodID;
        if (s.format != SZArchiveFormat7z || !SZCompressionEstimateMethodSupportsSFX(sfxMethodID)) {
            if (error)
                *error = SZMakeError(-8,
                    SZLocalizedString(@"app.archive.error.sfxUnsupportedMethod"));
            return nil;
        }
        if (!SZLocateBundledWindowsSfxModule(options.SfxModule)) {
            if (error)
                *error = SZMakeError(
                    -1,
                    SZLocalizedString(@"app.archive.error.missingWindowsSFX"));
            return nil;
        }
    }

    options.SymLinks = SZCompressionBoolPair(s.storeSymbolicLinks);
    options.HardLinks = SZCompressionBoolPair(s.storeHardLinks);
    options.AltStreams = SZCompressionBoolPair(s.storeAlternateDataStreams);
    options.NtSecurity = SZCompressionBoolPair(s.storeFileSecurity);
    if (s.preserveSourceAccessTime != SZCompressionBoolSettingNotDefined) {
        options.PreserveATime = (s.preserveSourceAccessTime == SZCompressionBoolSettingOn);
    }
    if (s.setArchiveTimeToLatestFile != SZCompressionBoolSettingNotDefined) {
        options.SetArcMTime = (s.setArchiveTimeToLatestFile == SZCompressionBoolSettingOn);
    }

    const UString fmtName = ToU(formatName);
    int formatIndex = codecs->FindFormatForArchiveType(fmtName);
    if (formatIndex < 0) {
        NSString* ext = [[archivePath pathExtension] lowercaseString];
        formatIndex = codecs->FindFormatForExtension(ToU(ext));
    }
    if (formatIndex < 0) {
        if (error)
            *error = SZMakeError(-8, SZLocalizedString(@"archive.unsupportedType"));
        return nil;
    }
    options.MethodMode.Type.FormatIndex = formatIndex;
    options.MethodMode.Type_Defined = true;

    const CArcInfoEx& formatInfo = codecs->Formats[(unsigned)formatIndex];
    const bool is7z = formatInfo.Is_7z();
    const UString methodSpec = SZCompressionMethodSpec(s);
    const bool usesOrderMode = SZCompressionMethodUsesOrderMode(methodSpec);

    UStringVector optionStrings;
    if (s.parameters.length > 0) {
        SZSplitOptionsToStrings(ToU(s.parameters), optionStrings);
    }
    const bool methodOverride = SZHasMethodOverride(is7z, optionStrings);

    // Match upstream 7-Zip ZS GUI encoding for ZSTD fast levels.
    SZAddCompressionPropertyUInt32(
        options.MethodMode.Properties, L"x",
        SZCompressionLevelPropertyValue(methodID, s.levelValue));

    if (!methodSpec.IsEmpty() && !methodOverride) {
        SZAddCompressionProperty(options.MethodMode.Properties, is7z ? L"0" : L"m",
            methodSpec);
    }

    if (s.dictionarySize > 0) {
        const wchar_t* propertyName = usesOrderMode ? (is7z ? L"0mem" : L"mem") : (is7z ? L"0d" : L"d");
        SZAddCompressionPropertySize(options.MethodMode.Properties, propertyName,
            (UInt64)s.dictionarySize);
    }

    if (s.wordSize > 0) {
        const wchar_t* propertyName = usesOrderMode ? (is7z ? L"0o" : L"o") : (is7z ? L"0fb" : L"fb");
        SZAddCompressionPropertyUInt32(options.MethodMode.Properties, propertyName,
            s.wordSize);
    }

    const UString encryptionProperty = SZCompressionEncryptionProperty(s);
    if (!encryptionProperty.IsEmpty()) {
        SZAddCompressionProperty(options.MethodMode.Properties, L"em",
            encryptionProperty);
    }

    if (s.numThreads > 0) {
        CProperty p2;
        p2.Name = L"mt";
        wchar_t buf[16];
        swprintf(buf, 16, L"%u", (unsigned)s.numThreads);
        p2.Value = buf;
        options.MethodMode.Properties.Add(p2);
    }
    if ((s.format == SZArchiveFormat7z || s.format == SZArchiveFormatXz) && s.solidMode) {
        CProperty p2;
        p2.Name = L"s";
        p2.Value = L"on";
        options.MethodMode.Properties.Add(p2);
    }
    if (s.encryptFileNames && s.format == SZArchiveFormat7z && s.password.length > 0) {
        CProperty p2;
        p2.Name = L"he";
        p2.Value = L"on";
        options.MethodMode.Properties.Add(p2);
    }

    if (s.storeModificationTime != SZCompressionBoolSettingNotDefined) {
        SZAddCompressionPropertyBool(options.MethodMode.Properties, L"tm",
            s.storeModificationTime == SZCompressionBoolSettingOn);
    }
    if (s.storeCreationTime != SZCompressionBoolSettingNotDefined) {
        SZAddCompressionPropertyBool(options.MethodMode.Properties, L"tc",
            s.storeCreationTime == SZCompressionBoolSettingOn);
    }
    if (s.storeAccessTime != SZCompressionBoolSettingNotDefined) {
        SZAddCompressionPropertyBool(options.MethodMode.Properties, L"ta",
            s.storeAccessTime == SZCompressionBoolSettingOn);
    }
    if (s.timePrecision != SZCompressionTimePrecisionAutomatic) {
        SZAddCompressionPropertyUInt32(options.MethodMode.Properties, L"tp",
            (UInt32)s.timePrecision);
    }
    if (s.memoryUsage.length > 0) {
        SZAddCompressionProperty(options.MethodMode.Properties, L"memuse",
            ToU(s.memoryUsage));
    }

    if (optionStrings.Size() > 0) {
        SZParseAndAddCompressionProperties(options.MethodMode.Properties,
            optionStrings);
    }

    if (s.splitVolumes.length > 0) {
        if (!SZParseVolumeSizes(ToU(s.splitVolumes), options.VolumesSizes)) {
            if (error)
                *error = SZMakeError(-1,
                    SZLocalizedString(@"split.incorrectVolumeSize"));
            return nil;
        }
    } else if (s.splitVolumeSize > 0) {
        options.VolumesSizes.Add(s.splitVolumeSize);
    }

    if (s.createSFX && options.VolumesSizes.Size() > 0) {
        if (error)
            *error = SZMakeError(
                -1, SZLocalizedString(@"app.archive.error.sfxCannotSplitVolumes"));
        return nil;
    }

    NWildcard::CCensor censor;
    SZAddCompressionSourcesToCensor(censor, src, s.pathMode);
    if (s.excludeMacResourceFiles) {
        SZAddMacResourceFileExcludes(censor);
    }
    if (s.excludeOfficeLockFiles) {
        SZAddOfficeLockFileExcludes(censor);
    }

    SZOperationSession* resolvedSession = session ?: [SZOperationSession makeDefaultSession];
    SZUpdateCallbackUI callbackUI;
    callbackUI.Session = resolvedSession;
    callbackUI.InputErrorPolicy = stopOnInputError
        ? SZUpdateInputErrorPolicy::StopOnInputError
        : SZUpdateInputErrorPolicy::ContinueWithWarnings;
    if (s.password.length > 0) {
        callbackUI.PasswordIsDefined = true;
        callbackUI.Password = ToU(s.password);
    }

    SZOpenCallbackUI openCallbackUI;
    openCallbackUI.Session = resolvedSession;
    openCallbackUI.ArchivePath = ToU(archivePath ?: @"");
    // Reopen encrypted archives with the write password to avoid a second prompt.
    if (callbackUI.PasswordIsDefined) {
        openCallbackUI.PasswordIsDefined = true;
        openCallbackUI.Password = callbackUI.Password;
    }
    CUpdateErrorInfo errorInfo;
    CObjectVector<COpenType> types;

    if (!SZResolveConfiguredWorkDirForPath(archivePath, options.WorkingDir, error)) {
        return nil;
    }

    NSString* compressionFailedDescription = [NSString
        stringWithFormat:SZLocalizedString(@"app.archive.error.compressionFailedFormat"),
        (unsigned)E_FAIL];
    HRESULT r;
    try {
        r = UpdateArchive(codecs, types, ToU(archivePath), censor, options,
            errorInfo, &openCallbackUI, &callbackUI, true);
    } catch (const UString& message) {
        if (error)
            *error = SZMakeDetailedError(E_FAIL,
                compressionFailedDescription,
                ToNS(message));
        return nil;
    } catch (const char* message) {
        if (error)
            *error = SZMakeDetailedError(E_FAIL,
                compressionFailedDescription,
                NSFromCString(message));
        return nil;
    } catch (...) {
        if (error)
            *error = SZMakeError(E_FAIL,
                compressionFailedDescription);
        return nil;
    }

    if (r != S_OK || errorInfo.ThereIsError()) {
        const HRESULT failureResult = r != S_OK
            ? r
            : errorInfo.Get_HRESULT_Error();
        UString details = callbackUI.Diagnostics.MakeSummary();
        const UString updateDetails = SZUpdateErrorInfoSummary(errorInfo);
        if (!updateDetails.IsEmpty()) {
            if (!details.IsEmpty()) {
                details += L"\n\n";
            }
            details += updateDetails;
        }
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(
                failureResult,
                compressionFailedDescription,
                details,
                callbackUI.ArchiveWasReplaced);
        }
        return nil;
    }

    return SZArchiveUpdateOutcomeFromDiagnostics(
        callbackUI.Diagnostics, true);
}

@end
