// SZArchive.mm — 7-Zip core bridge for ShichiZip
// This file must be compiled as Objective-C++ (.mm)

// Workaround for BOOL typedef conflict between 7-Zip (int) and ObjC (bool on arm64)
// Strategy: Let ObjC define BOOL first, then redirect 7-Zip's typedef to a dummy name

#import <Foundation/Foundation.h>
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
// Open callback
// ============================================================
class SZOpenCallback final : public IArchiveOpenCallback, public ICryptoGetTextPassword, public CMyUnknownImp {
public:
    UString Password; bool PasswordIsDefined;
    SZOpenCallback() : PasswordIsDefined(false) {}
    Z7_COM_UNKNOWN_IMP_2(IArchiveOpenCallback, ICryptoGetTextPassword)
    STDMETHOD(SetTotal)(const UInt64*, const UInt64*) override { return S_OK; }
    STDMETHOD(SetCompleted)(const UInt64*, const UInt64*) override { return S_OK; }
    STDMETHOD(CryptoGetTextPassword)(BSTR *pw) override {
        if (!PasswordIsDefined) return E_ABORT;
        return StringToBstr(Password, pw);
    }
};

// ============================================================
// Extract callback
// ============================================================
class SZExtractCallback final : public IArchiveExtractCallback, public ICryptoGetTextPassword, public CMyUnknownImp {
public:
    UString Password; bool PasswordIsDefined;
    UString DestPath; UInt64 TotalSize;
    IInArchive *Archive; bool TestMode;
    __unsafe_unretained id<SZProgressDelegate> Delegate;

    SZExtractCallback() : PasswordIsDefined(false), TotalSize(0), Archive(nullptr), TestMode(false), Delegate(nil) {}

    Z7_COM_UNKNOWN_IMP_2(IArchiveExtractCallback, ICryptoGetTextPassword)

    STDMETHOD(SetTotal)(UInt64 t) override { TotalSize = t; return S_OK; }
    STDMETHOD(SetCompleted)(const UInt64 *cv) override {
        if (cv && TotalSize > 0) {
            double f = (double)*cv / (double)TotalSize;
            UInt64 c = *cv, t = TotalSize;
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
    STDMETHOD(GetStream)(UInt32 idx, ISequentialOutStream **out, Int32 mode) override {
        *out = nullptr;
        if (mode != NArchive::NExtract::NAskMode::kExtract) return S_OK;

        NSString *pathStr = ItemStr(Archive, idx, kpidPath) ?: @"unknown";
        int isDir = ItemBool(Archive, idx, kpidIsDir);

        id<SZProgressDelegate> d = Delegate;
        if (d) { NSString *n = pathStr; dispatch_async(dispatch_get_main_queue(), ^{ [d progressDidUpdateFileName:n]; }); }
        if (TestMode) return S_OK;

        UString fullPath = DestPath;
        if (!fullPath.IsEmpty() && fullPath.Back() != '/') fullPath.Add_PathSepar();
        fullPath += ToU(pathStr);

        if (isDir) { NWindows::NFile::NDir::CreateComplexDir(us2fs(fullPath)); return S_OK; }

        int sp = (int)fullPath.ReverseFind_PathSepar();
        if (sp >= 0) NWindows::NFile::NDir::CreateComplexDir(us2fs(fullPath.Left(sp)));

        COutFileStream *spec = new COutFileStream;
        CMyComPtr<ISequentialOutStream> loc(spec);
        if (!spec->Create_ALWAYS(us2fs(fullPath))) return E_FAIL;
        *out = loc.Detach();
        return S_OK;
    }
    STDMETHOD(PrepareOperation)(Int32) override { return S_OK; }
    STDMETHOD(SetOperationResult)(Int32) override { return S_OK; }
    STDMETHOD(CryptoGetTextPassword)(BSTR *pw) override {
        if (!PasswordIsDefined) return E_ABORT;
        return StringToBstr(Password, pw);
    }
};

// ============================================================
// Update callback
// ============================================================
struct UpdItem { UString path, archPath; bool isDir; UInt64 size; FILETIME mt, ct; UInt32 winAttr; };

class SZUpdateCallback final : public IArchiveUpdateCallback2, public ICryptoGetTextPassword2, public CMyUnknownImp {
public:
    CObjectVector<UpdItem> Items;
    UString Password; bool PasswordIsDefined, EncryptHeaders;
    UInt64 TotalSize;
    __unsafe_unretained id<SZProgressDelegate> Delegate;

    SZUpdateCallback() : PasswordIsDefined(false), EncryptHeaders(false), TotalSize(0), Delegate(nil) {}

    Z7_COM_UNKNOWN_IMP_2(IArchiveUpdateCallback2, ICryptoGetTextPassword2)

    STDMETHOD(SetTotal)(UInt64 t) override { TotalSize = t; return S_OK; }
    STDMETHOD(SetCompleted)(const UInt64 *cv) override {
        if (cv && TotalSize > 0) {
            double f = (double)*cv / (double)TotalSize;
            UInt64 c = *cv, t = TotalSize;
            id<SZProgressDelegate> d = Delegate;
            if (d) {
                dispatch_async(dispatch_get_main_queue(), ^{ [d progressDidUpdate:f]; [d progressDidUpdateBytesCompleted:c total:t]; });
                if ([d progressShouldCancel]) return E_ABORT;
            }
        }
        return S_OK;
    }
    STDMETHOD(GetUpdateItemInfo)(UInt32, Int32 *nd, Int32 *np, UInt32 *iia) override {
        if (nd) *nd = 1; if (np) *np = 1; if (iia) *iia = (UInt32)(Int32)-1; return S_OK;
    }
    STDMETHOD(GetProperty)(UInt32 i, PROPID pid, PROPVARIANT *val) override {
        NWindows::NCOM::CPropVariant p;
        if (i >= (UInt32)Items.Size()) return E_INVALIDARG;
        const auto &it = Items[i];
        switch (pid) {
            case kpidIsAnti: p = false; break;
            case kpidPath: p = it.archPath; break;
            case kpidIsDir: p = it.isDir; break;
            case kpidSize: p = it.size; break;
            case kpidMTime: p = it.mt; break;
            case kpidCTime: p = it.ct; break;
            case kpidAttrib: p = it.winAttr; break;
        }
        p.Detach(val); return S_OK;
    }
    STDMETHOD(GetStream)(UInt32 i, ISequentialInStream **in) override {
        *in = nullptr;
        if (i >= (UInt32)Items.Size()) return E_INVALIDARG;
        const auto &it = Items[i];
        if (it.isDir) return S_OK;
        id<SZProgressDelegate> d = Delegate;
        if (d) { NSString *n = ToNS(it.archPath); dispatch_async(dispatch_get_main_queue(), ^{ [d progressDidUpdateFileName:n]; }); }
        CInFileStream *spec = new CInFileStream;
        CMyComPtr<ISequentialInStream> loc(spec);
        if (!spec->Open(us2fs(it.path))) return S_FALSE;
        *in = loc.Detach(); return S_OK;
    }
    STDMETHOD(SetOperationResult)(Int32) override { return S_OK; }
    STDMETHOD(GetVolumeSize)(UInt32, UInt64*) override { return S_FALSE; }
    STDMETHOD(GetVolumeStream)(UInt32, ISequentialOutStream**) override { return S_FALSE; }
    STDMETHOD(CryptoGetTextPassword2)(Int32 *def, BSTR *pw) override {
        *def = PasswordIsDefined ? 1 : 0;
        return StringToBstr(Password, pw);
    }
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
    if ((self = [super init])) { _pathMode = SZPathModeFullPaths; _overwriteMode = SZOverwriteModeOverwrite; }
    return self;
}
@end
@implementation SZArchiveEntry @end
@implementation SZFormatInfo @end

@interface SZArchive () { CMyComPtr<IInArchive> _archive; int _formatIndex; BOOL _isOpen; NSString *_archivePath; }
@end

@implementation SZArchive
- (instancetype)init { if ((self = [super init])) { _formatIndex = -1; _isOpen = NO; } return self; }
- (void)dealloc { [self close]; }

- (BOOL)openAtPath:(NSString *)path error:(NSError **)error {
    return [self openAtPath:path password:nil error:error];
}

- (BOOL)openAtPath:(NSString *)path password:(NSString *)password error:(NSError **)error {
    CCodecs *codecs = GetCodecs();
    if (!codecs) { if (error) *error = SZMakeError(-1, @"Failed to init codecs"); return NO; }
    _archivePath = [path copy];

    CInFileStream *fss = new CInFileStream;
    CMyComPtr<IInStream> fs(fss);
    if (!fss->Open(us2fs(ToU(path)))) { if (error) *error = SZMakeError(-2, @"Cannot open file"); return NO; }

    SZOpenCallback *ocs = new SZOpenCallback;
    CMyComPtr<IArchiveOpenCallback> oc(ocs);
    if (password) { ocs->PasswordIsDefined = true; ocs->Password = ToU(password); }

    for (unsigned i = 0; i < codecs->Formats.Size(); i++) {
        CMyComPtr<IInArchive> ar;
        if (codecs->CreateInArchive(i, ar) != S_OK || !ar) continue;
        const UInt64 scan = 1 << 23;
        if (ar->Open(fs, &scan, oc) == S_OK) {
            _archive = ar; _formatIndex = i; _isOpen = YES; return YES;
        }
        ar->Close(); fs->Seek(0, STREAM_SEEK_SET, nullptr);
    }
    if (error) *error = SZMakeError(-3, @"Cannot open archive or unsupported format");
    return NO;
}

- (void)close { if (_archive) { _archive->Close(); _archive.Release(); } _isOpen = NO; _formatIndex = -1; }

- (NSString *)formatName {
    if (!_isOpen || _formatIndex < 0) return nil;
    CCodecs *c = GetCodecs(); return c ? ToNS(c->Formats[_formatIndex].Name) : nil;
}

- (NSUInteger)entryCount {
    if (!_isOpen || !_archive) return 0;
    UInt32 n = 0; _archive->GetNumberOfItems(&n); return n;
}

- (NSArray<SZArchiveEntry *> *)entries {
    if (!_isOpen || !_archive) return @[];
    UInt32 n = 0; _archive->GetNumberOfItems(&n);
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:n];
    for (UInt32 i = 0; i < n; i++) {
        SZArchiveEntry *e = [SZArchiveEntry new];
        e.index = i;
        e.path = ItemStr(_archive, i, kpidPath) ?: @"";
        e.size = ItemU64(_archive, i, kpidSize);
        e.packedSize = ItemU64(_archive, i, kpidPackSize);
        e.crc = (uint32_t)ItemU64(_archive, i, kpidCRC);
        e.isDirectory = ItemBool(_archive, i, kpidIsDir);
        e.isEncrypted = ItemBool(_archive, i, kpidEncrypted);
        e.method = ItemStr(_archive, i, kpidMethod);
        e.attributes = (uint32_t)ItemU64(_archive, i, kpidAttrib);
        e.modifiedDate = ItemDate(_archive, i, kpidMTime);
        e.createdDate = ItemDate(_archive, i, kpidCTime);
        e.comment = ItemStr(_archive, i, kpidComment);
        [arr addObject:e];
    }
    return arr;
}

- (BOOL)extractToPath:(NSString *)dest settings:(SZExtractionSettings *)s progress:(id<SZProgressDelegate>)p error:(NSError **)error {
    if (!_isOpen || !_archive) { if (error) *error = SZMakeError(-4, @"No archive open"); return NO; }
    NWindows::NFile::NDir::CreateComplexDir(us2fs(ToU(dest)));
    SZExtractCallback *cb = new SZExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(cb);
    cb->Archive = _archive; cb->DestPath = ToU(dest); cb->Delegate = p;
    if (s.password) { cb->PasswordIsDefined = true; cb->Password = ToU(s.password); }
    HRESULT r = _archive->Extract(nullptr, (UInt32)(Int32)-1, 0, ec);
    if (r != S_OK) { if (error) *error = SZMakeError(r == E_ABORT ? -5 : -6, r == E_ABORT ? @"Cancelled" : @"Failed"); return NO; }
    return YES;
}

- (BOOL)extractEntries:(NSArray<NSNumber *> *)indices toPath:(NSString *)dest settings:(SZExtractionSettings *)s progress:(id<SZProgressDelegate>)p error:(NSError **)error {
    if (!_isOpen || !_archive) { if (error) *error = SZMakeError(-4, @"No archive open"); return NO; }
    NWindows::NFile::NDir::CreateComplexDir(us2fs(ToU(dest)));
    SZExtractCallback *cb = new SZExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(cb);
    cb->Archive = _archive; cb->DestPath = ToU(dest); cb->Delegate = p;
    if (s.password) { cb->PasswordIsDefined = true; cb->Password = ToU(s.password); }
    std::vector<UInt32> ia; ia.reserve(indices.count);
    for (NSNumber *n in indices) ia.push_back([n unsignedIntValue]);
    HRESULT r = _archive->Extract(ia.data(), (UInt32)ia.size(), 0, ec);
    if (r != S_OK) { if (error) *error = SZMakeError(r == E_ABORT ? -5 : -6, r == E_ABORT ? @"Cancelled" : @"Failed"); return NO; }
    return YES;
}

- (BOOL)testWithProgress:(id<SZProgressDelegate>)p error:(NSError **)error {
    if (!_isOpen || !_archive) { if (error) *error = SZMakeError(-4, @"No archive open"); return NO; }
    SZExtractCallback *cb = new SZExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(cb);
    cb->Archive = _archive; cb->Delegate = p; cb->TestMode = true;
    HRESULT r = _archive->Extract(nullptr, (UInt32)(Int32)-1, 1, ec);
    if (r != S_OK) { if (error) *error = SZMakeError(-7, @"Archive test failed"); return NO; }
    return YES;
}

+ (BOOL)createAtPath:(NSString *)archivePath fromPaths:(NSArray<NSString *> *)src settings:(SZCompressionSettings *)s progress:(id<SZProgressDelegate>)p error:(NSError **)error {
    CCodecs *codecs = GetCodecs();
    if (!codecs) { if (error) *error = SZMakeError(-1, @"Failed to init codecs"); return NO; }
    static const char *fmts[] = {"7z","zip","tar","gzip","bzip2","xz","wim","zstd"};
    int fi = (int)s.format; if (fi < 0 || fi >= 8) fi = 0;
    int formatIndex = -1;
    for (unsigned i = 0; i < codecs->Formats.Size(); i++)
        if (codecs->Formats[i].Name.IsEqualTo_Ascii_NoCase(fmts[fi])) { formatIndex = (int)i; break; }
    if (formatIndex < 0) { if (error) *error = SZMakeError(-8, @"Unsupported format"); return NO; }

    CMyComPtr<IOutArchive> oa;
    if (codecs->CreateOutArchive((unsigned)formatIndex, oa) != S_OK || !oa)
        { if (error) *error = SZMakeError(-9, @"Cannot create handler"); return NO; }

    CMyComPtr<ISetProperties> sp; oa.QueryInterface(IID_ISetProperties, (void**)&sp);
    if (sp) {
        const wchar_t *names[] = {L"x"}; NWindows::NCOM::CPropVariant vals[1];
        vals[0] = (UInt32)s.level; sp->SetProperties(names, vals, 1);
    }

    SZUpdateCallback *cb = new SZUpdateCallback;
    CMyComPtr<IArchiveUpdateCallback2> uc(cb); cb->Delegate = p;
    if (s.password && s.encryption != SZEncryptionMethodNone) {
        cb->PasswordIsDefined = true; cb->Password = ToU(s.password); cb->EncryptHeaders = s.encryptFileNames;
    }

    for (NSString *srcPath in src) {
        NWindows::NFile::NFind::CFileInfo fi2; if (!fi2.Find(us2fs(ToU(srcPath)))) continue;
        FILETIME fmt, fct;
        FiTime_To_FILETIME(fi2.MTime, fmt);
        FiTime_To_FILETIME(fi2.CTime, fct);
        UInt32 wattr = fi2.GetWinAttrib();
        if (fi2.IsDir()) {
            UpdItem d; d.path = ToU(srcPath); d.archPath = ToU([srcPath lastPathComponent]);
            d.isDir = true; d.size = 0; d.mt = fmt; d.ct = fct; d.winAttr = wattr;
            cb->Items.Add(d);
            NSFileManager *fm = [NSFileManager defaultManager];
            NSDirectoryEnumerator *de = [fm enumeratorAtPath:srcPath]; NSString *rp;
            while ((rp = [de nextObject])) {
                NSString *fp = [srcPath stringByAppendingPathComponent:rp];
                NWindows::NFile::NFind::CFileInfo sf; if (!sf.Find(us2fs(ToU(fp)))) continue;
                FILETIME smt, sct;
                FiTime_To_FILETIME(sf.MTime, smt);
                FiTime_To_FILETIME(sf.CTime, sct);
                UpdItem it; it.path = ToU(fp);
                it.archPath = ToU([[srcPath lastPathComponent] stringByAppendingPathComponent:rp]);
                it.isDir = sf.IsDir(); it.size = sf.IsDir() ? 0 : sf.Size;
                it.mt = smt; it.ct = sct; it.winAttr = sf.GetWinAttrib(); cb->Items.Add(it);
            }
        } else {
            UpdItem it; it.path = ToU(srcPath); it.archPath = ToU([srcPath lastPathComponent]);
            it.isDir = false; it.size = fi2.Size; it.mt = fmt; it.ct = fct; it.winAttr = wattr;
            cb->Items.Add(it);
        }
    }

    COutFileStream *ofs = new COutFileStream;
    CMyComPtr<ISequentialOutStream> os(ofs);
    if (!ofs->Create_ALWAYS(us2fs(ToU(archivePath)))) { if (error) *error = SZMakeError(-10, @"Cannot create file"); return NO; }
    HRESULT r = oa->UpdateItems(os, (UInt32)cb->Items.Size(), uc);
    if (r != S_OK) { if (error) *error = SZMakeError(r == E_ABORT ? -5 : -11, r == E_ABORT ? @"Cancelled" : @"Failed"); return NO; }
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

+ (NSDictionary<NSString*,NSString*> *)calculateHashForPath:(NSString *)path algorithm:(NSString *)alg error:(NSError **)error {
    (void)path; (void)alg; if (error) *error = nil; return @{@"status": @"TODO"};
}
@end
