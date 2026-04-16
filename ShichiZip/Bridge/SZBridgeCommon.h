// SZBridgeCommon.h — Shared includes and helpers for the 7-Zip bridge
// All .mm files in Bridge/ should include this instead of duplicating setup

#pragma once

// Workaround for BOOL typedef conflict between 7-Zip (int) and ObjC (bool on arm64)
#import "SZArchive.h"
#import "SZOperationSession.h"
#import <Foundation/Foundation.h>

#ifdef __cplusplus
#define BOOL BOOL_7Z_COMPAT
#if __has_include("CPP/Common/MyWindows.h")
#include "C/7zCrc.h"
#include "CPP/7zip/Archive/IArchive.h"
#include "CPP/7zip/Common/FileStreams.h"
#include "CPP/7zip/Common/StreamObjects.h"
#include "CPP/7zip/ICoder.h"
#include "CPP/7zip/IPassword.h"
#include "CPP/7zip/PropID.h"
#include "CPP/7zip/UI/Common/IFileExtractCallback.h"
#include "CPP/7zip/UI/Common/LoadCodecs.h"
#include "CPP/7zip/UI/Common/OpenArchive.h"
#include "CPP/Common/IntToString.h"
#include "CPP/Common/MyString.h"
#include "CPP/Common/MyWindows.h"
#include "CPP/Windows/FileDir.h"
#include "CPP/Windows/FileFind.h"
#include "CPP/Windows/FileName.h"
#include "CPP/Windows/PropVariant.h"
#include "CPP/Windows/PropVariantConv.h"
#include "CPP/Windows/TimeUtils.h"
#elif __has_include("../../vendor/7zip/CPP/Common/MyWindows.h")
#include "../../vendor/7zip/C/7zCrc.h"
#include "../../vendor/7zip/CPP/7zip/Archive/IArchive.h"
#include "../../vendor/7zip/CPP/7zip/Common/FileStreams.h"
#include "../../vendor/7zip/CPP/7zip/Common/StreamObjects.h"
#include "../../vendor/7zip/CPP/7zip/ICoder.h"
#include "../../vendor/7zip/CPP/7zip/IPassword.h"
#include "../../vendor/7zip/CPP/7zip/PropID.h"
#include "../../vendor/7zip/CPP/7zip/UI/Common/IFileExtractCallback.h"
#include "../../vendor/7zip/CPP/7zip/UI/Common/LoadCodecs.h"
#include "../../vendor/7zip/CPP/7zip/UI/Common/OpenArchive.h"
#include "../../vendor/7zip/CPP/Common/IntToString.h"
#include "../../vendor/7zip/CPP/Common/MyString.h"
#include "../../vendor/7zip/CPP/Common/MyWindows.h"
#include "../../vendor/7zip/CPP/Windows/FileDir.h"
#include "../../vendor/7zip/CPP/Windows/FileFind.h"
#include "../../vendor/7zip/CPP/Windows/FileName.h"
#include "../../vendor/7zip/CPP/Windows/PropVariant.h"
#include "../../vendor/7zip/CPP/Windows/PropVariantConv.h"
#include "../../vendor/7zip/CPP/Windows/TimeUtils.h"
#elif __has_include("../../vendor/7zip-zstd/CPP/Common/MyWindows.h")
#include "../../vendor/7zip-zstd/C/7zCrc.h"
#include "../../vendor/7zip-zstd/CPP/7zip/Archive/IArchive.h"
#include "../../vendor/7zip-zstd/CPP/7zip/Common/FileStreams.h"
#include "../../vendor/7zip-zstd/CPP/7zip/Common/StreamObjects.h"
#include "../../vendor/7zip-zstd/CPP/7zip/ICoder.h"
#include "../../vendor/7zip-zstd/CPP/7zip/IPassword.h"
#include "../../vendor/7zip-zstd/CPP/7zip/PropID.h"
#include "../../vendor/7zip-zstd/CPP/7zip/UI/Common/IFileExtractCallback.h"
#include "../../vendor/7zip-zstd/CPP/7zip/UI/Common/LoadCodecs.h"
#include "../../vendor/7zip-zstd/CPP/7zip/UI/Common/OpenArchive.h"
#include "../../vendor/7zip-zstd/CPP/Common/IntToString.h"
#include "../../vendor/7zip-zstd/CPP/Common/MyString.h"
#include "../../vendor/7zip-zstd/CPP/Common/MyWindows.h"
#include "../../vendor/7zip-zstd/CPP/Windows/FileDir.h"
#include "../../vendor/7zip-zstd/CPP/Windows/FileFind.h"
#include "../../vendor/7zip-zstd/CPP/Windows/FileName.h"
#include "../../vendor/7zip-zstd/CPP/Windows/PropVariant.h"
#include "../../vendor/7zip-zstd/CPP/Windows/PropVariantConv.h"
#include "../../vendor/7zip-zstd/CPP/Windows/TimeUtils.h"
#else
#error "7-Zip headers not found"
#endif
#undef BOOL
#endif

NS_ASSUME_NONNULL_BEGIN

// ============================================================
// Error helpers
// ============================================================

extern NSString* const SZArchiveErrorDomain;

static inline NSError* SZMakeError(NSInteger code, NSString* desc) {
    return [NSError errorWithDomain:SZArchiveErrorDomain
                               code:code
                           userInfo:@ { NSLocalizedDescriptionKey : desc }];
}

static inline NSError* SZMakeDetailedError(NSInteger code, NSString* desc, NSString* _Nullable failureReason) {
    if (!failureReason || failureReason.length == 0) {
        return SZMakeError(code, desc);
    }

    return [NSError errorWithDomain:SZArchiveErrorDomain
                               code:code
                           userInfo:@ {
                               NSLocalizedDescriptionKey : desc,
                               NSLocalizedFailureReasonErrorKey : failureReason,
                           }];
}

/// Look up a localized string: checks App.strings first, then Upstream.strings.
/// Mirrors the SZL10n.string() Swift API for use in Objective-C bridge code.
static inline NSString* SZLocalizedString(NSString* key) {
    // Check override bundle from language preference
    NSString* override = [[NSUserDefaults standardUserDefaults] stringForKey:@"LanguageOverride"];
    NSBundle* bundle = [NSBundle mainBundle];
    if (override.length > 0) {
        NSString* lpath = [bundle pathForResource:override ofType:@"lproj"];
        if (lpath) {
            NSBundle* overrideBundle = [NSBundle bundleWithPath:lpath];
            if (overrideBundle)
                bundle = overrideBundle;
        }
    }
    // App table first
    NSString* appValue = [bundle localizedStringForKey:key value:nil table:@"App"];
    if (![appValue isEqualToString:key])
        return appValue;
    // Upstream table
    NSString* upstreamValue = [bundle localizedStringForKey:key value:nil table:@"Upstream"];
    if (![upstreamValue isEqualToString:key])
        return upstreamValue;
    // Fallback to main bundle if override was active
    if (bundle != [NSBundle mainBundle]) {
        appValue = [[NSBundle mainBundle] localizedStringForKey:key value:nil table:@"App"];
        if (![appValue isEqualToString:key])
            return appValue;
        upstreamValue = [[NSBundle mainBundle] localizedStringForKey:key value:nil table:@"Upstream"];
        if (![upstreamValue isEqualToString:key])
            return upstreamValue;
    }
    return key;
}

static NSString* const SZSettingsDidChangeNotificationName = @"SZSettingsDidChange";
static NSString* const SZSettingsDidChangeKeyUserInfoKey = @"key";
static NSString* const SZExtractionMemoryLimitEnabledPreferenceKey = @"MemLimitEnabled";
static NSString* const SZExtractionMemoryLimitGBPreferenceKey = @"MemLimitGB";

static inline uint32_t SZRoundUpByteCountToGB(uint64_t byteCount) {
    if (byteCount == 0) {
        return 1;
    }

    const uint64_t rounded = (byteCount + (((uint64_t)1 << 30) - 1)) >> 30;
    return rounded > UINT32_MAX ? UINT32_MAX : (uint32_t)rounded;
}

static inline BOOL SZExtractionMemoryLimitIsEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SZExtractionMemoryLimitEnabledPreferenceKey];
}

static inline uint32_t SZConfiguredExtractionMemoryLimitGB(void) {
    const NSInteger storedValue = [[NSUserDefaults standardUserDefaults] integerForKey:SZExtractionMemoryLimitGBPreferenceKey];
    return storedValue > 0 ? (uint32_t)storedValue : 4;
}

static inline uint64_t SZConfiguredExtractionMemoryLimitBytes(void) {
    return ((uint64_t)SZConfiguredExtractionMemoryLimitGB()) << 30;
}

static inline void SZPostSettingsDidChange(NSString* key) {
    [[NSNotificationCenter defaultCenter] postNotificationName:SZSettingsDidChangeNotificationName
                                                        object:nil
                                                      userInfo:@ { SZSettingsDidChangeKeyUserInfoKey : key }];
}

static inline void SZPersistExtractionMemoryLimitGB(uint32_t limitGB) {
    const NSInteger resolvedLimitGB = MAX((NSInteger)limitGB, 1);
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:SZExtractionMemoryLimitEnabledPreferenceKey];
    [defaults setInteger:resolvedLimitGB forKey:SZExtractionMemoryLimitGBPreferenceKey];
    SZPostSettingsDidChange(SZExtractionMemoryLimitEnabledPreferenceKey);
    SZPostSettingsDidChange(SZExtractionMemoryLimitGBPreferenceKey);
}

// ============================================================
// Codec manager singleton
// ============================================================

#ifdef __cplusplus
CCodecs* _Nullable SZGetCodecs(void);

// ============================================================
// String conversion: UString <-> NSString
// ============================================================
//
// UString on non-Windows stores wchar_t elements, which are 32-bit on
// macOS and are treated as Unicode codepoints. NSString internally
// stores UTF-16 code units. A naive loop that casts each `unichar` to
// `wchar_t` corrupts any non-BMP codepoint: the surrogate pair in the
// NSString becomes two isolated surrogate codepoints in the UString,
// which later serialize to invalid UTF-8 (emoji, CJK Ext B, etc.).
// The reverse `wchar_t -> unichar` cast truncates anything >= U+10000
// to a lone surrogate.
//
// Round-trip through NSUTF32LittleEndianStringEncoding so surrogate
// pairs collapse to one codepoint in the UString, and codepoints >=
// U+10000 expand back into proper surrogate pairs in the NSString.

static inline UString ToU(NSString* _Nullable s) {
    if (!s || s.length == 0)
        return UString();
    NSData* data = [s dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    if (!data || data.length == 0)
        return UString();
    const NSUInteger count = data.length / sizeof(wchar_t);
    const wchar_t* codepoints = (const wchar_t*)data.bytes;
    UString u;
    for (NSUInteger i = 0; i < count; i++) {
        u += codepoints[i];
    }
    return u;
}

static inline NSString* ToNS(const UString& u) {
    const unsigned len = u.Len();
    if (len == 0)
        return @"";
    NSData* data = [NSData dataWithBytes:u.Ptr()
                                  length:(NSUInteger)len * sizeof(wchar_t)];
    NSString* result = [[NSString alloc] initWithData:data
                                             encoding:NSUTF32LittleEndianStringEncoding];
    return result ?: @"";
}

// Convert a C string (typically from 7-Zip's AString) into NSString.
// Unlike +stringWithUTF8String:, this never returns nil: if the bytes
// are not valid UTF-8 it falls back to Mac Roman so the caller can
// still surface the message to the user. Safe to feed into
// dictionary literals that reject nil values.
static inline NSString* NSFromCString(const char* _Nullable cstr) {
    if (!cstr)
        return @"";
    NSString* utf8 = [[NSString alloc] initWithUTF8String:cstr];
    if (utf8)
        return utf8;
    NSString* fallback = [[NSString alloc] initWithCString:cstr
                                                  encoding:NSMacOSRomanStringEncoding];
    return fallback ?: @"";
}

// ============================================================
// Archive property helpers
// ============================================================

static inline NSString* _Nullable ItemStr(IInArchive* _Nonnull ar, UInt32 i, PROPID p) {
    NWindows::NCOM::CPropVariant v;
    if (ar->GetProperty(i, p, &v) != S_OK)
        return nil;
    if (v.vt == VT_BSTR && v.bstrVal)
        return ToNS(UString(v.bstrVal));
    return nil;
}

static inline uint64_t ItemU64(IInArchive* _Nonnull ar, UInt32 i, PROPID p) {
    NWindows::NCOM::CPropVariant v;
    if (ar->GetProperty(i, p, &v) != S_OK)
        return 0;
    if (v.vt == VT_UI8)
        return v.uhVal.QuadPart;
    if (v.vt == VT_UI4)
        return v.ulVal;
    return 0;
}

static inline int ItemBool(IInArchive* _Nonnull ar, UInt32 i, PROPID p) {
    NWindows::NCOM::CPropVariant v;
    if (ar->GetProperty(i, p, &v) != S_OK)
        return 0;
    return (v.vt == VT_BOOL && v.boolVal != VARIANT_FALSE) ? 1 : 0;
}

static inline NSDate* _Nullable ItemDate(IInArchive* _Nonnull ar, UInt32 i, PROPID p) {
    NWindows::NCOM::CPropVariant v;
    if (ar->GetProperty(i, p, &v) != S_OK || v.vt != VT_FILETIME)
        return nil;
    uint64_t ft = ((uint64_t)v.filetime.dwHighDateTime << 32) | v.filetime.dwLowDateTime;
    static const uint64_t EPOCH_DIFF = 116444736000000000ULL;
    if (ft < EPOCH_DIFF)
        return nil;
    return [NSDate dateWithTimeIntervalSince1970:(double)(ft - EPOCH_DIFF) / 10000000.0];
}
#endif

NS_ASSUME_NONNULL_END
