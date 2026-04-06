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

// ============================================================
// SZArchive — main class
// ============================================================

@interface SZArchive () {
    CArchiveLink *_arcLink;
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

// MARK: - Open / Close

- (BOOL)openAtPath:(NSString *)path error:(NSError **)error {
    return [self openAtPath:path password:nil error:error];
}

- (BOOL)openAtPath:(NSString *)path password:(NSString *)password error:(NSError **)error {
    CCodecs *codecs = SZGetCodecs();
    if (!codecs) { if (error) *error = SZMakeError(-1, @"Failed to init codecs"); return NO; }
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
    if (_isOpen) _arcLink->Close();
    _isOpen = NO;
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
        case SZPathModeNoPaths: return NExtract::NPathMode::kNoPaths;
        case SZPathModeAbsolutePaths: return NExtract::NPathMode::kAbsPaths;
        case SZPathModeFullPaths: default: return NExtract::NPathMode::kFullPaths;
    }
}

static BOOL CheckExtractResult(SZFolderExtractCallback *fae, HRESULT r, NSError **error) {
    if (r == S_OK && fae->PasswordWasWrong) {
        if (error) *error = SZMakeError(-12, @"Wrong password");
        return NO;
    }
    if (r == S_OK && fae->NumErrors > 0) {
        if (error) *error = SZMakeError(-13, [NSString stringWithFormat:@"Completed with %u error(s)", fae->NumErrors]);
        return NO;
    }
    if (r != S_OK) {
        if (error) *error = SZMakeError(r == E_ABORT ? -5 : -6, r == E_ABORT ? @"Cancelled" : @"Extraction failed");
        return NO;
    }
    return YES;
}

// MARK: - Extract

- (BOOL)extractToPath:(NSString *)dest settings:(SZExtractionSettings *)s progress:(id<SZProgressDelegate>)p error:(NSError **)error {
    if (!_isOpen) { if (error) *error = SZMakeError(-4, @"No archive open"); return NO; }
    IInArchive *archive = _arcLink->GetArchive();
    const CArc &arc = _arcLink->Arcs.Back();
    NWindows::NFile::NDir::CreateComplexDir(us2fs(ToU(dest)));

    SZFolderExtractCallback *faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Delegate = p;
    faeSpec->OverwriteMode = s.overwriteMode;
    if (s.password) { faeSpec->PasswordIsDefined = true; faeSpec->Password = ToU(s.password); }

    CArchiveExtractCallback *ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);
    CExtractNtOptions ntOptions;
    UStringVector removePathParts;

    ecs->InitForMulti(false, MapPathMode(s.pathMode), MapOverwriteMode(s.overwriteMode),
        NExtract::NZoneIdMode::kNone, false);
    ecs->Init(ntOptions, NULL, &arc, faeCallback,
        false, false, us2fs(ToU(dest)), removePathParts, false, arc.GetEstmatedPhySize());

    HRESULT r = archive->Extract(nullptr, (UInt32)(Int32)-1, 0, ec);
    return CheckExtractResult(faeSpec, r, error);
}

- (BOOL)extractEntries:(NSArray<NSNumber *> *)indices toPath:(NSString *)dest settings:(SZExtractionSettings *)s progress:(id<SZProgressDelegate>)p error:(NSError **)error {
    if (!_isOpen) { if (error) *error = SZMakeError(-4, @"No archive open"); return NO; }
    IInArchive *archive = _arcLink->GetArchive();
    const CArc &arc = _arcLink->Arcs.Back();
    NWindows::NFile::NDir::CreateComplexDir(us2fs(ToU(dest)));

    SZFolderExtractCallback *faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Delegate = p;
    faeSpec->OverwriteMode = s.overwriteMode;
    if (s.password) { faeSpec->PasswordIsDefined = true; faeSpec->Password = ToU(s.password); }

    CArchiveExtractCallback *ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);
    CExtractNtOptions ntOptions;
    UStringVector removePathParts;

    ecs->InitForMulti(false, MapPathMode(s.pathMode), MapOverwriteMode(s.overwriteMode),
        NExtract::NZoneIdMode::kNone, false);
    ecs->Init(ntOptions, NULL, &arc, faeCallback,
        false, false, us2fs(ToU(dest)), removePathParts, false, arc.GetEstmatedPhySize());

    std::vector<UInt32> ia; ia.reserve(indices.count);
    for (NSNumber *n in indices) ia.push_back([n unsignedIntValue]);
    HRESULT r = archive->Extract(ia.data(), (UInt32)ia.size(), 0, ec);
    return CheckExtractResult(faeSpec, r, error);
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
        NExtract::NOverwriteMode::kOverwrite, NExtract::NZoneIdMode::kNone, false);
    ecs->Init(ntOptions, NULL, &arc, faeCallback,
        false, true, FString(), removePathParts, false, arc.GetEstmatedPhySize());

    HRESULT r = archive->Extract(nullptr, (UInt32)(Int32)-1, 1, ec);
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

    SZUpdateCallbackUI callbackUI;
    callbackUI.Delegate = p;
    if (s.password && s.encryption != SZEncryptionMethodNone) {
        callbackUI.PasswordIsDefined = true;
        callbackUI.Password = ToU(s.password);
    }

    SZOpenCallbackUI openCallbackUI;
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

+ (void)runBenchmarkWithIterations:(UInt32)numIterations
                          callback:(void (^)(NSString *line))printCallback
                        completion:(void (^)(BOOL success))completion {
    CCodecs *codecs = SZGetCodecs();
    if (!codecs) { if (completion) completion(NO); return; }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSLog(@"[ShichiZip] Benchmark starting...");

        class BenchPrint : public IBenchPrintCallback {
        public:
            void (^_Nonnull blk)(NSString *);
            NSMutableString *cur;
            BenchPrint(void (^_Nonnull b)(NSString *)) : blk([b copy]) { cur = [NSMutableString string]; }
            void Print(const char *s) override { if (s) [cur appendString:[NSString stringWithUTF8String:s]]; }
            void NewLine() override {
                NSString *line = [cur copy];
                void (^b)(NSString *) = blk;
                dispatch_async(dispatch_get_main_queue(), ^{ b(line); });
                cur = [NSMutableString string];
            }
            HRESULT CheckBreak() override { return S_OK; }
        };

        BenchPrint printCB(printCallback);
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
