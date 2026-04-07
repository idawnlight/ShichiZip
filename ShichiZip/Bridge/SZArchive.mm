// SZArchive.mm — Main archive interface implementation

#include "SZBridgeCommon.h"
#include "SZCallbacks.h"

#include "CPP/7zip/UI/Common/ArchiveExtractCallback.h"
#include "CPP/7zip/UI/Common/Extract.h"
#include "CPP/7zip/UI/Common/Update.h"
#include "CPP/7zip/UI/Common/UpdateCallback.h"
#include "CPP/7zip/UI/Common/EnumDirItems.h"
#include "CPP/7zip/UI/Common/SetProperties.h"
#include "CPP/7zip/UI/Common/Bench.h"
#include "CPP/7zip/UI/Common/HashCalc.h"
#include "CPP/Common/Wildcard.h"
#include "7zVersion.h"

#include <atomic>
#include <mutex>

// ============================================================
// ObjC model implementations
// ============================================================

@implementation SZCompressionSettings
- (instancetype)init {
    if ((self = [super init])) {
        _format = SZArchiveFormat7z; _level = SZCompressionLevelNormal;
        _method = SZCompressionMethodLZMA2; _encryption = SZEncryptionMethodNone;
        _solidMode = YES;
    }
    return self;
}
@end

@implementation SZExtractionSettings
- (instancetype)init {
    if ((self = [super init])) {
        _pathMode = SZPathModeFullPaths; _overwriteMode = SZOverwriteModeAsk;
    }
    return self;
}
@end

@implementation SZArchiveEntry @end
@implementation SZFormatInfo @end
@implementation SZBenchDisplayRow
- (instancetype)init {
    if ((self = [super init])) {
        _sizeText = @"...";
        _speedText = @"...";
        _usageText = @"...";
        _rpuText = @"...";
        _ratingText = @"...";
    }
    return self;
}
@end

@implementation SZBenchSnapshot
- (instancetype)init {
    if ((self = [super init])) {
        _passesCompleted = 0;
        _passesTotal = 1;
        _finished = NO;
        _logText = @"";
    }
    return self;
}
@end

// ============================================================
// SZArchive — main class
// ============================================================

@interface SZArchive () {
    CArchiveLink *_arcLink;
    BOOL _isOpen;
    NSString *_archivePath;
    NSString *_cachedPassword;
    BOOL _cachedPasswordIsDefined;
}
@end

@implementation SZArchive

- (void)clearCachedPassword {
    _cachedPassword = nil;
    _cachedPasswordIsDefined = NO;
}

- (void)storeCachedPassword:(const UString &)password defined:(bool)isDefined {
    if (isDefined) {
        _cachedPassword = ToNS(password);
        _cachedPasswordIsDefined = YES;
    } else {
        [self clearCachedPassword];
    }
}

- (void)configureExtractPasswordForCallback:(SZFolderExtractCallback *)callback explicitPassword:(NSString *)password {
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

- (void)updateCachedPasswordFromExtractCallback:(SZFolderExtractCallback *)callback result:(HRESULT)result {
    if (result == S_OK && callback->PasswordIsDefined) {
        [self storeCachedPassword:callback->Password defined:true];
        return;
    }

    if (callback->PasswordWasWrong || (callback->PasswordWasAsked && !callback->PasswordIsDefined)) {
        [self clearCachedPassword];
    }
}

- (instancetype)init {
    if ((self = [super init])) {
        _arcLink = new CArchiveLink;
        _isOpen = NO;
        _cachedPasswordIsDefined = NO;
    }
    return self;
}

- (void)dealloc { [self close]; delete _arcLink; _arcLink = nullptr; }

+ (NSString *)sevenZipVersionString {
    return @MY_VERSION;
}

// MARK: - Open / Close

- (BOOL)openAtPath:(NSString *)path error:(NSError **)error {
    return [self openAtPath:path password:nil session:nil error:error];
}

- (BOOL)openAtPath:(NSString *)path progress:(id<SZProgressDelegate>)progress error:(NSError **)error {
    return [self openAtPath:path password:nil progress:progress error:error];
}

- (BOOL)openAtPath:(NSString *)path session:(SZOperationSession *)session error:(NSError **)error {
    return [self openAtPath:path password:nil session:session error:error];
}

- (BOOL)openAtPath:(NSString *)path password:(NSString *)password error:(NSError **)error {
    return [self openAtPath:path password:password session:nil error:error];
}

- (BOOL)openAtPath:(NSString *)path password:(NSString *)password progress:(id<SZProgressDelegate>)progress error:(NSError **)error {
    return [self openAtPath:path password:password session:SZCreateDefaultOperationSession(progress) error:error];
}

- (BOOL)openAtPath:(NSString *)path password:(NSString *)password session:(SZOperationSession *)session error:(NSError **)error {
    CCodecs *codecs = SZGetCodecs();
    if (!codecs) { if (error) *error = SZMakeError(SZArchiveErrorCodeFailedToInitCodecs, @"Failed to init codecs"); return NO; }
    [self close];
    [self clearCachedPassword];
    _archivePath = [path copy];

    CObjectVector<COpenType> types;
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

    SZOperationSession *resolvedSession = session ?: SZCreateDefaultOperationSession(nil);
    SZOpenCallbackUI callbackUI;
    callbackUI.Session = resolvedSession;
    if (password) {
        callbackUI.PasswordIsDefined = true;
        callbackUI.Password = ToU(password);
    }

    HRESULT res = _arcLink->Open3(options, &callbackUI);
    if (res != S_OK) {
        NSInteger code;
        NSString *desc;
        if (res == S_FALSE && callbackUI.PasswordWasAsked) {
            code = SZArchiveErrorCodeWrongPassword;
            desc = @"Cannot open encrypted archive. Wrong password?";
        } else if (res == S_FALSE) {
            code = SZArchiveErrorCodeUnsupportedArchive;
            desc = @"Cannot open archive or unsupported format";
        } else if (res == E_ABORT) {
            code = SZArchiveErrorCodeUserCancelled;
            desc = @"Operation was cancelled";
        } else {
            code = res;
            desc = [NSString stringWithFormat:@"Failed to open archive (0x%08X)", (unsigned)res];
        }
        if (error) *error = SZMakeError(code, desc);
        return NO;
    }

    if (callbackUI.PasswordIsDefined) {
        [self storeCachedPassword:callbackUI.Password defined:true];
    }
    _isOpen = YES;
    return YES;
}

- (void)close {
    if (_isOpen) _arcLink->Close();
    _isOpen = NO;
    [self clearCachedPassword];
}

// MARK: - Properties

- (NSString *)formatName {
    if (!_isOpen) return nil;
    const CArc &arc = _arcLink->Arcs.Back();
    CCodecs *c = SZGetCodecs();
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
    const CArc &arc = _arcLink->Arcs.Back();
    UInt32 n = 0; archive->GetNumberOfItems(&n);
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:n];
    for (UInt32 i = 0; i < n; i++) {
        SZArchiveEntry *e = [SZArchiveEntry new];
        e.index = i;
        CReadArcItem item;
        const bool hasReadItem = (arc.GetItem(i, item) == S_OK);
        if (hasReadItem) {
            e.path = ToNS(item.Path);
            NSMutableArray<NSString *> *pathParts = [NSMutableArray arrayWithCapacity:item.PathParts.Size()];
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
        e.size = ItemU64(archive, i, kpidSize);
        e.packedSize = ItemU64(archive, i, kpidPackSize);
        e.crc = (uint32_t)ItemU64(archive, i, kpidCRC);
        e.isDirectory = hasReadItem ? item.IsDir : ItemBool(archive, i, kpidIsDir);
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

// MARK: - Extract helpers

static NExtract::NOverwriteMode::EEnum MapOverwriteMode(SZOverwriteMode m) {
    switch (m) {
        case SZOverwriteModeOverwrite: return NExtract::NOverwriteMode::kOverwrite;
        case SZOverwriteModeSkip: return NExtract::NOverwriteMode::kSkip;
        case SZOverwriteModeRename: return NExtract::NOverwriteMode::kRename;
        case SZOverwriteModeAsk: default: return NExtract::NOverwriteMode::kAsk;
    }
}

static NExtract::NPathMode::EEnum MapPathMode(SZPathMode m) {
    switch (m) {
        case SZPathModeCurrentPaths: return NExtract::NPathMode::kCurPaths;
        case SZPathModeNoPaths: return NExtract::NPathMode::kNoPaths;
        case SZPathModeAbsolutePaths: return NExtract::NPathMode::kAbsPaths;
        case SZPathModeFullPaths: default: return NExtract::NPathMode::kFullPaths;
    }
}

static UStringVector BuildRemovePathParts(NSString *pathPrefixToStrip) {
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

static BOOL CheckExtractResult(SZFolderExtractCallback *fae, HRESULT r, NSError **error) {
    if (r == S_OK && fae->PasswordWasWrong) {
        if (error) *error = SZMakeError(SZArchiveErrorCodeWrongPassword, @"Wrong password");
        return NO;
    }
    if (r == S_OK && fae->NumErrors > 0) {
        if (error) *error = SZMakeError(SZArchiveErrorCodePartialFailure, [NSString stringWithFormat:@"Completed with %u error(s)", fae->NumErrors]);
        return NO;
    }
    if (r != S_OK) {
        if (error) *error = SZMakeError(r == E_ABORT ? SZArchiveErrorCodeUserCancelled : SZArchiveErrorCodeExtractionFailed,
                                        r == E_ABORT ? @"Cancelled" : @"Extraction failed");
        return NO;
    }
    return YES;
}

// MARK: - Extract

- (BOOL)extractToPath:(NSString *)dest settings:(SZExtractionSettings *)s progress:(id<SZProgressDelegate>)p error:(NSError **)error {
    if (!_isOpen) { if (error) *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open"); return NO; }
    IInArchive *archive = _arcLink->GetArchive();
    const CArc &arc = _arcLink->Arcs.Back();
    NWindows::NFile::NDir::CreateComplexDir(us2fs(ToU(dest)));

    SZOperationSession *session = SZCreateDefaultOperationSession(p);
    SZFolderExtractCallback *faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Session = session;
    faeSpec->OverwriteMode = s.overwriteMode;
    [self configureExtractPasswordForCallback:faeSpec explicitPassword:s.password];

    CArchiveExtractCallback *ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);
    CExtractNtOptions ntOptions;
    UStringVector removePathParts = BuildRemovePathParts(s.pathPrefixToStrip);

    ecs->InitForMulti(false, MapPathMode(s.pathMode), MapOverwriteMode(s.overwriteMode),
        NExtract::NZoneIdMode::kNone, false);
    ecs->Init(ntOptions, NULL, &arc, faeCallback,
        false, false, us2fs(ToU(dest)), removePathParts, false, arc.GetEstmatedPhySize());

    HRESULT r = archive->Extract(nullptr, (UInt32)(Int32)-1, 0, ec);
    [self updateCachedPasswordFromExtractCallback:faeSpec result:r];
    return CheckExtractResult(faeSpec, r, error);
}

- (BOOL)extractEntries:(NSArray<NSNumber *> *)indices toPath:(NSString *)dest settings:(SZExtractionSettings *)s progress:(id<SZProgressDelegate>)p error:(NSError **)error {
    if (!_isOpen) { if (error) *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open"); return NO; }
    IInArchive *archive = _arcLink->GetArchive();
    const CArc &arc = _arcLink->Arcs.Back();
    NWindows::NFile::NDir::CreateComplexDir(us2fs(ToU(dest)));

    SZOperationSession *session = SZCreateDefaultOperationSession(p);
    SZFolderExtractCallback *faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Session = session;
    faeSpec->OverwriteMode = s.overwriteMode;
    [self configureExtractPasswordForCallback:faeSpec explicitPassword:s.password];

    CArchiveExtractCallback *ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);
    CExtractNtOptions ntOptions;
    UStringVector removePathParts = BuildRemovePathParts(s.pathPrefixToStrip);

    ecs->InitForMulti(false, MapPathMode(s.pathMode), MapOverwriteMode(s.overwriteMode),
        NExtract::NZoneIdMode::kNone, false);
    ecs->Init(ntOptions, NULL, &arc, faeCallback,
        false, false, us2fs(ToU(dest)), removePathParts, false, arc.GetEstmatedPhySize());

    std::vector<UInt32> ia; ia.reserve(indices.count);
    for (NSNumber *n in indices) ia.push_back([n unsignedIntValue]);
    HRESULT r = archive->Extract(ia.data(), (UInt32)ia.size(), 0, ec);
    [self updateCachedPasswordFromExtractCallback:faeSpec result:r];
    return CheckExtractResult(faeSpec, r, error);
}

- (BOOL)testWithProgress:(id<SZProgressDelegate>)p error:(NSError **)error {
    if (!_isOpen) { if (error) *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open"); return NO; }
    IInArchive *archive = _arcLink->GetArchive();
    const CArc &arc = _arcLink->Arcs.Back();

    SZOperationSession *session = SZCreateDefaultOperationSession(p);
    SZFolderExtractCallback *faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Session = session;
    [self configureExtractPasswordForCallback:faeSpec explicitPassword:nil];

    CArchiveExtractCallback *ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);
    CExtractNtOptions ntOptions;
    UStringVector removePathParts;

    ecs->InitForMulti(false, NExtract::NPathMode::kFullPaths,
        NExtract::NOverwriteMode::kOverwrite, NExtract::NZoneIdMode::kNone, false);
    ecs->Init(ntOptions, NULL, &arc, faeCallback,
        false, true, FString(), removePathParts, false, arc.GetEstmatedPhySize());

    HRESULT r = archive->Extract(nullptr, (UInt32)(Int32)-1, 1, ec);
    [self updateCachedPasswordFromExtractCallback:faeSpec result:r];
    return CheckExtractResult(faeSpec, r, error);
}

// MARK: - Create

+ (BOOL)createAtPath:(NSString *)archivePath fromPaths:(NSArray<NSString *> *)src settings:(SZCompressionSettings *)s progress:(id<SZProgressDelegate>)p error:(NSError **)error {
    CCodecs *codecs = SZGetCodecs();
    if (!codecs) { if (error) *error = SZMakeError(-1, @"Failed to init codecs"); return NO; }

    static const char *fmts[] = {"7z","zip","tar","gzip","bzip2","xz","wim","zstd"};
    int fi = (int)s.format; if (fi < 0 || fi >= 8) fi = 0;

    CUpdateOptions options;
    options.SetActionCommand_Add();

    UString fmtName;
    for (const char *c = fmts[fi]; *c; c++) fmtName += (wchar_t)(unsigned char)*c;
    int formatIndex = codecs->FindFormatForArchiveType(fmtName);
    if (formatIndex < 0) {
        NSString *ext = [[archivePath pathExtension] lowercaseString];
        formatIndex = codecs->FindFormatForExtension(ToU(ext));
    }
    if (formatIndex < 0) { if (error) *error = SZMakeError(-8, @"Unsupported format"); return NO; }
    options.MethodMode.Type.FormatIndex = formatIndex;

    // Set compression properties
    CProperty propLevel;
    propLevel.Name = L"x";
    wchar_t levelBuf[16];
    swprintf(levelBuf, 16, L"%d", (int)s.level);
    propLevel.Value = levelBuf;
    options.MethodMode.Properties.Add(propLevel);

    if (s.numThreads > 0) {
        CProperty p2; p2.Name = L"mt";
        wchar_t buf[16]; swprintf(buf, 16, L"%u", (unsigned)s.numThreads);
        p2.Value = buf;
        options.MethodMode.Properties.Add(p2);
    }
    if (s.format == SZArchiveFormat7z && s.solidMode) {
        CProperty p2; p2.Name = L"s"; p2.Value = L"on";
        options.MethodMode.Properties.Add(p2);
    }
    if (s.encryptFileNames && s.format == SZArchiveFormat7z) {
        CProperty p2; p2.Name = L"he"; p2.Value = L"on";
        options.MethodMode.Properties.Add(p2);
    }

    NWildcard::CCensor censor;
    for (NSString *srcPath in src) {
        NWildcard::CCensorPathProps pathProps;
        pathProps.Recursive = true;
        censor.AddItem(NWildcard::k_AbsPath, true, ToU(srcPath), pathProps);
    }

    SZOperationSession *session = SZCreateDefaultOperationSession(p);
    SZUpdateCallbackUI callbackUI;
    callbackUI.Session = session;
    if (s.password && s.encryption != SZEncryptionMethodNone) {
        callbackUI.PasswordIsDefined = true;
        callbackUI.Password = ToU(s.password);
    }

    SZOpenCallbackUI openCallbackUI;
    openCallbackUI.Session = session;
    CUpdateErrorInfo errorInfo;
    CObjectVector<COpenType> types;

    HRESULT r = UpdateArchive(codecs, types, ToU(archivePath), censor, options,
        errorInfo, &openCallbackUI, &callbackUI, true);

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

// MARK: - Formats

+ (NSArray<SZFormatInfo *> *)supportedFormats {
    CCodecs *codecs = SZGetCodecs(); if (!codecs) return @[];
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

// MARK: - Hash

+ (NSDictionary<NSString*,NSString*> *)calculateHashForPath:(NSString *)path error:(NSError **)error {
    CCodecs *codecs = SZGetCodecs();
    if (!codecs) { if (error) *error = SZMakeError(-1, @"Failed to init codecs"); return nil; }

    CHashOptions options;
    options.Methods.Add(UString(L"CRC32"));
    options.Methods.Add(UString(L"CRC64"));
    options.Methods.Add(UString(L"SHA256"));
    options.Methods.Add(UString(L"SHA1"));
    options.Methods.Add(UString(L"BLAKE2sp"));

    NWildcard::CCensor censor;
    NWildcard::CCensorPathProps props;
    props.Recursive = false;
    censor.AddItem(NWildcard::k_AbsPath, true, ToU(path), props);

    class HashCB : public IHashCallbackUI {
    public:
        NSMutableDictionary *results;
        HashCB() { results = [NSMutableDictionary dictionary]; }
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
                results[[NSString stringWithUTF8String:h.Name.Ptr()]] = [NSString stringWithUTF8String:hex];
            }
            return S_OK;
        }
        HRESULT AfterLastFile(CHashBundle &) override { return S_OK; }
        HRESULT ScanError(const FString &, DWORD) override { return S_OK; }
        HRESULT ScanProgress(const CDirItemsStat &, const FString &, bool) override { return S_OK; }
    };

    HashCB cb;
    AString errorInfo;
    HRESULT r = HashCalc(EXTERNAL_CODECS_LOC_VARS censor, options, errorInfo, &cb);
    if (r != S_OK) { if (error) *error = SZMakeError(r, @"Hash calculation failed"); return nil; }
    return cb.results;
}

// MARK: - Benchmark

static std::atomic_bool g_BenchStop(false);

namespace {

static const unsigned kRatingVector_NumBundlesMax = 20;

struct CTotalBenchRes2: public CTotalBenchRes
{
    UInt64 UnpackSize;

    void Init()
    {
        CTotalBenchRes::Init();
        UnpackSize = 0;
    }

    void SetFrom_BenchInfo(const CBenchInfo &info)
    {
        NumIterations2 = 1;
        Generate_From_BenchInfo(info);
        UnpackSize = info.Get_UnpackSize_Full();
    }

    void Update_With_Res2(const CTotalBenchRes2 &res)
    {
        Update_With_Res(res);
        UnpackSize += res.UnpackSize;
    }
};

struct CBenchPassResult
{
    CTotalBenchRes2 Enc;
    CTotalBenchRes2 Dec;
};

struct CBenchSyncState
{
    UInt64 DictSize;
    UInt32 PassesTotal;
    UInt32 PassesCompleted;
    UInt32 NumFreqThreadsPrev;
    int RatingVectorDeletedIndex;
    bool BenchWasFinished;
    UString FreqString_Sync;
    UString FreqString_GUI;
    CTotalBenchRes2 Enc_BenchRes_1;
    CTotalBenchRes2 Enc_BenchRes;
    CTotalBenchRes2 Dec_BenchRes_1;
    CTotalBenchRes2 Dec_BenchRes;
    std::vector<CBenchPassResult> RatingVector;
    CFAbsoluteTime LastProgressTime;

    void Init(UInt64 dictSize, UInt32 passesTotal)
    {
        DictSize = dictSize;
        PassesTotal = passesTotal;
        PassesCompleted = 0;
        NumFreqThreadsPrev = 0;
        RatingVectorDeletedIndex = -1;
        BenchWasFinished = false;
        FreqString_Sync.Empty();
        FreqString_GUI.Empty();
        Enc_BenchRes_1.Init();
        Enc_BenchRes.Init();
        Dec_BenchRes_1.Init();
        Dec_BenchRes.Init();
        RatingVector.clear();
        LastProgressTime = 0;
    }
};

struct CBenchSharedContext
{
    std::mutex Mutex;
    CBenchSyncState State;
};

#define SZ_UINT_TO_STR_3(s, val) { \
  s[0] = (wchar_t)('0' + (val) / 100); \
  s[1] = (wchar_t)('0' + (val) % 100 / 10); \
  s[2] = (wchar_t)('0' + (val) % 10); \
  s += 3; s[0] = 0; }

static WCHAR *SZBenchNumberToDot3(UInt64 value, WCHAR *dest)
{
    dest = ConvertUInt64ToString(value / 1000, dest);
    const UInt32 rem = (UInt32)(value % 1000);
    *dest++ = '.';
    SZ_UINT_TO_STR_3(dest, rem)
    return dest;
}

static UInt64 SZBenchGetMips(UInt64 ips)
{
    return (ips + 500000) / 1000000;
}

static UInt64 SZBenchGetUsagePercents(UInt64 usage)
{
    return Benchmark_GetUsage_Percents(usage);
}

static UInt32 SZBenchGetRating(const CTotalBenchRes &info)
{
    UInt64 numIterations = info.NumIterations2;
    if (numIterations == 0)
        numIterations = 1000000;
    const UInt64 rating64 = SZBenchGetMips(info.Rating / numIterations);
    UInt32 rating32 = (UInt32)rating64;
    if (rating32 != rating64)
        rating32 = (UInt32)(Int32)-1;
    return rating32;
}

static void SZBenchAddDot3String(UString &dest, UInt64 value)
{
    WCHAR temp[32];
    SZBenchNumberToDot3(value, temp);
    dest += temp;
}

static void SZBenchAddUsageString(UString &dest, const CTotalBenchRes &info)
{
    UInt64 numIterations = info.NumIterations2;
    if (numIterations == 0)
        numIterations = 1000000;
    const UInt64 usage = SZBenchGetUsagePercents(info.Usage / numIterations);

    wchar_t temp[32];
    wchar_t *ptr = ConvertUInt64ToString(usage, temp);
    ptr[0] = '%';
    ptr[1] = 0;

    unsigned len = (unsigned)(size_t)(ptr - temp);
    while (len < 5)
    {
        dest.Add_Space();
        len++;
    }
    dest += temp;
}

static void SZBenchAddRatingString(UString &dest, const CTotalBenchRes &info)
{
    SZBenchAddDot3String(dest, SZBenchGetRating(info));
}

static void SZBenchAddRatingsLine(UString &dest, const CTotalBenchRes &enc, const CTotalBenchRes &dec)
{
    SZBenchAddRatingString(dest, enc);
    dest += "  ";
    SZBenchAddRatingString(dest, dec);

    CTotalBenchRes total;
    total.SetSum(enc, dec);

    dest += "  ";
    SZBenchAddRatingString(dest, total);

    dest.Add_Space();
    SZBenchAddUsageString(dest, total);
}

static NSString *SZBenchFormatRating(UInt64 rating)
{
    WCHAR temp[64];
    MyStringCopy(SZBenchNumberToDot3(SZBenchGetMips(rating), temp), L" GIPS");
    return ToNS(UString(temp));
}

static NSString *SZBenchFormatUsage(UInt64 usage)
{
    return [NSString stringWithFormat:@"%llu%%", (unsigned long long)SZBenchGetUsagePercents(usage)];
}

static NSString *SZBenchFormatSpeed(const CTotalBenchRes2 &info)
{
    const UInt64 speed = (info.Speed >> 10) / info.NumIterations2;
    return [NSString stringWithFormat:@"%llu KB/s", (unsigned long long)speed];
}

static NSString *SZBenchFormatSize(UInt64 unpackSize)
{
    UInt64 value = unpackSize;
    NSString *suffix = @" MB";
    if (value >= ((UInt64)1 << 40))
    {
        value >>= 30;
        suffix = @" GB";
    }
    else
    {
        value >>= 20;
    }
    return [NSString stringWithFormat:@"%llu%@", (unsigned long long)value, suffix];
}

static SZBenchDisplayRow *SZBenchMakeRow(const CTotalBenchRes2 &info, bool includeSize, bool includeSpeed)
{
    if (info.NumIterations2 == 0)
        return nil;

    const UInt64 numIterations = info.NumIterations2;
    SZBenchDisplayRow *row = [[SZBenchDisplayRow alloc] init];
    row.usageText = SZBenchFormatUsage(info.Usage / numIterations);
    row.rpuText = SZBenchFormatRating(info.RPU / numIterations);
    row.ratingText = SZBenchFormatRating(info.Rating / numIterations);
    row.speedText = includeSpeed ? SZBenchFormatSpeed(info) : @"";
    row.sizeText = includeSize ? SZBenchFormatSize(info.UnpackSize) : @"";
    return row;
}

static NSString *SZBenchBuildLogText(const CBenchSyncState &state)
{
    UString text;
    text += state.FreqString_GUI;

    if (!state.RatingVector.empty())
    {
        if (!text.IsEmpty())
            text.Add_LF();
        text += "Compr Decompr Total   CPU";
        text.Add_LF();
    }

    for (size_t i = 0; i < state.RatingVector.size(); i++)
    {
        if (i != 0)
            text.Add_LF();
        if (state.RatingVectorDeletedIndex >= 0 && (int)i == state.RatingVectorDeletedIndex)
        {
            text += "...";
            text.Add_LF();
        }
        const CBenchPassResult &pair = state.RatingVector[i];
        SZBenchAddRatingsLine(text, pair.Enc, pair.Dec);
    }

    if (state.BenchWasFinished)
    {
        text.Add_LF();
        text += "-------------";
        text.Add_LF();
        SZBenchAddRatingsLine(text, state.Enc_BenchRes, state.Dec_BenchRes);
    }

    return ToNS(text);
}

static SZBenchSnapshot *SZBenchMakeSnapshot(const CBenchSyncState &state)
{
    SZBenchSnapshot *snapshot = [[SZBenchSnapshot alloc] init];
    snapshot.passesCompleted = state.PassesCompleted;
    snapshot.passesTotal = state.PassesTotal;
    snapshot.finished = state.BenchWasFinished;
    snapshot.logText = SZBenchBuildLogText(state);
    snapshot.encodeCurrent = SZBenchMakeRow(state.Enc_BenchRes_1, true, true);
    snapshot.encodeResult = SZBenchMakeRow(state.Enc_BenchRes, true, true);
    snapshot.decodeCurrent = SZBenchMakeRow(state.Dec_BenchRes_1, true, true);
    snapshot.decodeResult = SZBenchMakeRow(state.Dec_BenchRes, true, true);

    if (state.BenchWasFinished)
    {
        CTotalBenchRes2 total = state.Enc_BenchRes;
        total.Update_With_Res2(state.Dec_BenchRes);
        snapshot.totalResult = SZBenchMakeRow(total, false, false);
    }

    return snapshot;
}

static bool SZBenchShouldEmit(CBenchSyncState &state, bool force)
{
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!force && state.LastProgressTime != 0 && now - state.LastProgressTime < 0.25)
        return false;
    state.LastProgressTime = now;
    return true;
}

static void SZBenchDispatchSnapshot(void (^progress)(SZBenchSnapshot *), const CBenchSyncState &state)
{
    if (!progress)
        return;

    SZBenchSnapshot *snapshot = SZBenchMakeSnapshot(state);
    void (^progressBlock)(SZBenchSnapshot *) = progress;
    dispatch_async(dispatch_get_main_queue(), ^{
        progressBlock(snapshot);
    });
}

static NSString *SZBenchErrorMessage(HRESULT result)
{
    if (result == S_OK || result == E_ABORT)
        return nil;
    if (result == S_FALSE)
        return @"Decoding error";
    if (result == CLASS_E_CLASSNOTAVAILABLE)
        return @"Can't find 7-Zip codecs";
    return [NSString stringWithFormat:@"Benchmark failed (0x%08X).", (unsigned)result];
}

static CObjectVector<CProperty> SZBenchMakeProps(UInt64 dictionarySize, UInt32 numThreads)
{
    CObjectVector<CProperty> props;

    {
        CProperty prop;
        prop.Name = "mt";
        prop.Value.Add_UInt32(numThreads);
        props.Add(prop);
    }

    {
        CProperty prop;
        prop.Name = 'd';
        prop.Name.Add_UInt32((UInt32)(dictionarySize >> 10));
        prop.Name.Add_Char('k');
        props.Add(prop);
    }

    return props;
}

class BenchGuiCallback final : public IBenchCallback
{
public:
    UInt64 DictionarySize;
    CBenchSharedContext *Context;
    void (^Progress)(SZBenchSnapshot *);

    BenchGuiCallback(UInt64 dictionarySize, CBenchSharedContext *context, void (^progress)(SZBenchSnapshot *)):
        DictionarySize(dictionarySize),
        Context(context),
        Progress(progress ? [progress copy] : nil)
    {
    }

    HRESULT SetEncodeResult(const CBenchInfo &info, bool final) override
    {
        CBenchSyncState snapshotState;
        bool shouldEmit = false;

        {
            std::lock_guard<std::mutex> lock(Context->Mutex);
            if (g_BenchStop.load())
                return E_ABORT;

            CBenchSyncState &state = Context->State;
            CTotalBenchRes2 &benchRes = state.Enc_BenchRes_1;

            UInt64 dictSize = DictionarySize;
            if (!final && dictSize > info.UnpackSize)
                dictSize = info.UnpackSize;

            benchRes.Rating = info.GetRating_LzmaEnc(dictSize);
            benchRes.SetFrom_BenchInfo(info);

            if (final)
                state.Enc_BenchRes.Update_With_Res2(benchRes);

            shouldEmit = SZBenchShouldEmit(state, final);
            if (shouldEmit)
                snapshotState = state;
        }

        if (shouldEmit)
            SZBenchDispatchSnapshot(Progress, snapshotState);
        return S_OK;
    }

    HRESULT SetDecodeResult(const CBenchInfo &info, bool final) override
    {
        CBenchSyncState snapshotState;
        bool shouldEmit = false;

        {
            std::lock_guard<std::mutex> lock(Context->Mutex);
            if (g_BenchStop.load())
                return E_ABORT;

            CBenchSyncState &state = Context->State;
            CTotalBenchRes2 &benchRes = state.Dec_BenchRes_1;

            benchRes.Rating = info.GetRating_LzmaDec();
            benchRes.SetFrom_BenchInfo(info);

            if (final)
                state.Dec_BenchRes.Update_With_Res2(benchRes);

            shouldEmit = SZBenchShouldEmit(state, final);
            if (shouldEmit)
                snapshotState = state;
        }

        if (shouldEmit)
            SZBenchDispatchSnapshot(Progress, snapshotState);
        return S_OK;
    }
};

class BenchFreqCallback final : public IBenchFreqCallback
{
public:
    CBenchSharedContext *Context;
    void (^Progress)(SZBenchSnapshot *);

    BenchFreqCallback(CBenchSharedContext *context, void (^progress)(SZBenchSnapshot *)):
        Context(context),
        Progress(progress ? [progress copy] : nil)
    {
    }

    HRESULT AddCpuFreq(unsigned numThreads, UInt64 freq, UInt64 usage) override
    {
        std::lock_guard<std::mutex> lock(Context->Mutex);
        if (g_BenchStop.load())
            return E_ABORT;

        CBenchSyncState &state = Context->State;
        UString &text = state.FreqString_Sync;
        if (state.NumFreqThreadsPrev != numThreads)
        {
            state.NumFreqThreadsPrev = numThreads;
            if (!text.IsEmpty())
                text.Add_LF();
            text.Add_UInt32(numThreads);
            text += "T Frequency (MHz):";
            text.Add_LF();
        }

        text.Add_Space();
        if (numThreads != 1)
        {
            text.Add_UInt64(SZBenchGetUsagePercents(usage));
            text.Add_Char('%');
            text.Add_Space();
        }
        text.Add_UInt64(SZBenchGetMips(freq));
        return S_OK;
    }

    HRESULT FreqsFinished(unsigned /* numThreads */) override
    {
        CBenchSyncState snapshotState;
        {
            std::lock_guard<std::mutex> lock(Context->Mutex);
            if (g_BenchStop.load())
                return E_ABORT;

            Context->State.FreqString_GUI = Context->State.FreqString_Sync;
            SZBenchShouldEmit(Context->State, true);
            snapshotState = Context->State;
        }

        SZBenchDispatchSnapshot(Progress, snapshotState);
        return S_OK;
    }
};

} // namespace

+ (uint64_t)benchMemoryUsageForThreads:(uint32_t)threads dictionary:(uint64_t)dictSize {
    return GetBenchMemoryUsage(threads, -1, dictSize, false);
}

+ (void)stopBenchmark {
    g_BenchStop.store(true);
}

+ (void)runBenchmarkWithDictionary:(uint64_t)dictSize
                           threads:(uint32_t)threads
                            passes:(uint32_t)passes
                          progress:(void (^)(SZBenchSnapshot *snapshot))progress
                        completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion {
    CCodecs *codecs = SZGetCodecs();
    if (!codecs) {
        if (completion) {
            completion(NO, @"Failed to init codecs");
        }
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            g_BenchStop.store(false);

            const UInt32 passCount = passes == 0 ? 1 : passes;
            const UInt32 threadCount = threads == 0 ? 1 : threads;

            CBenchSharedContext context;
            context.State.Init(dictSize, passCount);

            void (^progressBlock)(SZBenchSnapshot *) = progress ? [progress copy] : nil;
            void (^completionBlock)(BOOL, NSString *) = completion ? [completion copy] : nil;

            if (progressBlock)
                SZBenchDispatchSnapshot(progressBlock, context.State);

            HRESULT finalResult = S_OK;

            for (UInt32 passIndex = 0; passIndex < passCount; passIndex++) {
                if (g_BenchStop.load()) {
                    finalResult = E_ABORT;
                    break;
                }

                BenchGuiCallback benchCallback(dictSize, &context, progressBlock);
                BenchFreqCallback freqCallback(&context, progressBlock);
                CObjectVector<CProperty> props = SZBenchMakeProps(dictSize, threadCount);

                HRESULT result = Bench(EXTERNAL_CODECS_LOC_VARS
                    NULL,
                    &benchCallback,
                    props,
                    1,
                    false,
                    passIndex == 0 ? &freqCallback : NULL);

                if (result != S_OK) {
                    finalResult = result;
                    break;
                }

                CBenchSyncState snapshotState;
                {
                    std::lock_guard<std::mutex> lock(context.Mutex);
                    CBenchSyncState &state = context.State;

                    state.PassesCompleted++;

                    CBenchPassResult pair;
                    pair.Enc = state.Enc_BenchRes_1;
                    pair.Dec = state.Dec_BenchRes_1;
                    state.RatingVector.push_back(pair);

                    if (state.RatingVector.size() > kRatingVector_NumBundlesMax) {
                        state.RatingVectorDeletedIndex = (int)(kRatingVector_NumBundlesMax / 4);
                        state.RatingVector.erase(state.RatingVector.begin() + state.RatingVectorDeletedIndex);
                    }

                    if (state.PassesCompleted >= state.PassesTotal)
                        state.BenchWasFinished = true;

                    SZBenchShouldEmit(state, true);
                    snapshotState = state;
                }

                if (progressBlock)
                    SZBenchDispatchSnapshot(progressBlock, snapshotState);
            }

            if (completionBlock) {
                NSString *errorMessage = SZBenchErrorMessage(finalResult);
                const BOOL success = (finalResult == S_OK);
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock(success, errorMessage);
                });
            }
        }
    });
}

@end
