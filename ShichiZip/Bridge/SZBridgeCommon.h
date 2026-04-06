// SZBridgeCommon.h — Shared includes and helpers for the 7-Zip bridge
// All .mm files in Bridge/ should include this instead of duplicating setup

#pragma once

// Workaround for BOOL typedef conflict between 7-Zip (int) and ObjC (bool on arm64)
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "SZArchive.h"

#define BOOL BOOL_7Z_COMPAT
#include "CPP/Common/MyWindows.h"
#undef BOOL

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
#include "CPP/7zip/UI/Common/IFileExtractCallback.h"
#include "CPP/7zip/PropID.h"
#include "CPP/Windows/TimeUtils.h"
#include "C/7zCrc.h"

#include <string>
#include <vector>

// ============================================================
// Error helpers
// ============================================================

extern NSString * const SZArchiveErrorDomain;

static inline NSError *SZMakeError(NSInteger code, NSString *desc) {
    return [NSError errorWithDomain:SZArchiveErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: desc}];
}

// ============================================================
// Codec manager singleton
// ============================================================

CCodecs *SZGetCodecs(void);

// ============================================================
// String conversion: UString <-> NSString
// ============================================================

static inline UString ToU(NSString *s) {
    if (!s) return UString();
    NSUInteger len = [s length];
    UString u;
    u.Empty();
    for (NSUInteger i = 0; i < len; i++) {
        u += (wchar_t)[s characterAtIndex:i];
    }
    return u;
}

static inline NSString *ToNS(const UString &u) {
    NSMutableString *s = [NSMutableString stringWithCapacity:u.Len()];
    for (unsigned i = 0; i < u.Len(); i++) {
        unichar ch = (unichar)u[i];
        [s appendString:[NSString stringWithCharacters:&ch length:1]];
    }
    return s;
}

// ============================================================
// Archive property helpers
// ============================================================

static inline NSString *ItemStr(IInArchive *ar, UInt32 i, PROPID p) {
    NWindows::NCOM::CPropVariant v;
    if (ar->GetProperty(i, p, &v) != S_OK) return nil;
    if (v.vt == VT_BSTR && v.bstrVal) return ToNS(UString(v.bstrVal));
    return nil;
}

static inline uint64_t ItemU64(IInArchive *ar, UInt32 i, PROPID p) {
    NWindows::NCOM::CPropVariant v;
    if (ar->GetProperty(i, p, &v) != S_OK) return 0;
    if (v.vt == VT_UI8) return v.uhVal.QuadPart;
    if (v.vt == VT_UI4) return v.ulVal;
    return 0;
}

static inline int ItemBool(IInArchive *ar, UInt32 i, PROPID p) {
    NWindows::NCOM::CPropVariant v;
    if (ar->GetProperty(i, p, &v) != S_OK) return 0;
    return (v.vt == VT_BOOL && v.boolVal != VARIANT_FALSE) ? 1 : 0;
}

static inline NSDate *ItemDate(IInArchive *ar, UInt32 i, PROPID p) {
    NWindows::NCOM::CPropVariant v;
    if (ar->GetProperty(i, p, &v) != S_OK || v.vt != VT_FILETIME) return nil;
    uint64_t ft = ((uint64_t)v.filetime.dwHighDateTime << 32) | v.filetime.dwLowDateTime;
    static const uint64_t EPOCH_DIFF = 116444736000000000ULL;
    if (ft < EPOCH_DIFF) return nil;
    return [NSDate dateWithTimeIntervalSince1970:(double)(ft - EPOCH_DIFF) / 10000000.0];
}

// ============================================================
// Password prompt — shows dialog, safe from any thread
// ============================================================

HRESULT SZPromptForPassword(UString &outPassword, bool &wasDefined, NSString *context = nil);
