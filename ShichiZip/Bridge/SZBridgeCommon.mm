// SZBridgeCommon.mm — Shared bridge infrastructure (codecs, password, GUIDs)

// This TU defines INITGUID so all IID constants are instantiated here
#define INITGUID

#include "SZBridgeCommon.h"
#include <os/lock.h>

NSString* const SZArchiveErrorDomain = @"SZArchiveErrorDomain";
NSString* const SZArchiveMutationCommittedErrorKey = @"SZArchiveMutationCommitted";
NSString* const SZArchiveMutationReopenFailedErrorKey = @"SZArchiveMutationReopenFailed";

// ============================================================
// Shared preferences and localization
// ============================================================

NSUserDefaults* SZSharedNSUserDefaults(void) {
    static NSUserDefaults* defaults;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* appGroupIdentifier =
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"ShichiZipQuickActionAppGroupIdentifier"];
        if (appGroupIdentifier.length > 0) {
            defaults = [[NSUserDefaults alloc] initWithSuiteName:appGroupIdentifier];
        }
        if (!defaults) {
            defaults = [NSUserDefaults standardUserDefaults];
        }
    });
    return defaults;
}

NSBundle* SZLocalizationBundle(void) {
    static NSBundle* bundle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* identifier = @"ee.dawn.ShichiZip.Localization";
        bundle = [NSBundle bundleWithIdentifier:identifier];
        if (bundle) {
            return;
        }

        NSMutableArray<NSURL*>* candidateURLs = [NSMutableArray array];
        NSURL* privateFrameworksURL = [[NSBundle mainBundle] privateFrameworksURL];
        if (privateFrameworksURL) {
            [candidateURLs addObject:[privateFrameworksURL URLByAppendingPathComponent:@"ShichiZipLocalization.framework"
                                                                           isDirectory:YES]];
        }
        [candidateURLs addObject:[[[NSBundle mainBundle] bundleURL]
                                     URLByAppendingPathComponent:@"Contents/Frameworks/ShichiZipLocalization.framework"
                                                     isDirectory:YES]];
        [candidateURLs addObject:[[[[[NSBundle mainBundle] bundleURL] URLByDeletingLastPathComponent]
                                     URLByDeletingLastPathComponent]
                                     URLByAppendingPathComponent:@"Frameworks/ShichiZipLocalization.framework"
                                                     isDirectory:YES]];

        for (NSURL* candidateURL in candidateURLs) {
            NSBundle* candidateBundle = [NSBundle bundleWithURL:candidateURL];
            if ([candidateBundle.bundleIdentifier isEqualToString:identifier]) {
                bundle = candidateBundle;
                return;
            }
        }
        bundle = [NSBundle mainBundle];
    });
    return bundle;
}

static NSBundle* SZPreferredLocalizationBundle(NSBundle* baseBundle) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSString* cachedOverride;
    static NSBundle* cachedBundle;
    NSString* override = [SZSharedNSUserDefaults() stringForKey:@"LanguageOverride"] ?: @"";

    os_unfair_lock_lock(&lock);
    if (!cachedBundle || ![cachedOverride isEqualToString:override]) {
        cachedOverride = [override copy];
        cachedBundle = baseBundle;
        if (override.length > 0) {
            NSString* path = [baseBundle pathForResource:override ofType:@"lproj"];
            NSBundle* overrideBundle = path ? [NSBundle bundleWithPath:path] : nil;
            if (overrideBundle) {
                cachedBundle = overrideBundle;
            }
        }
    }
    NSBundle* bundle = cachedBundle;
    os_unfair_lock_unlock(&lock);
    return bundle;
}

NSString* SZLocalizedString(NSString* key) {
    NSBundle* baseBundle = SZLocalizationBundle();
    NSBundle* bundle = SZPreferredLocalizationBundle(baseBundle);
    NSString* appValue = [bundle localizedStringForKey:key value:nil table:@"App"];
    if (![appValue isEqualToString:key])
        return appValue;
    NSString* upstreamValue = [bundle localizedStringForKey:key value:nil table:@"Upstream"];
    if (![upstreamValue isEqualToString:key])
        return upstreamValue;
    if (bundle != baseBundle) {
        appValue = [baseBundle localizedStringForKey:key value:nil table:@"App"];
        if (![appValue isEqualToString:key])
            return appValue;
        upstreamValue = [baseBundle localizedStringForKey:key value:nil table:@"Upstream"];
        if (![upstreamValue isEqualToString:key])
            return upstreamValue;
    }

    if (baseBundle != [NSBundle mainBundle]) {
        appValue = [[NSBundle mainBundle] localizedStringForKey:key value:nil table:@"App"];
        if (![appValue isEqualToString:key])
            return appValue;
        upstreamValue = [[NSBundle mainBundle] localizedStringForKey:key value:nil table:@"Upstream"];
        if (![upstreamValue isEqualToString:key])
            return upstreamValue;
    }

    return key;
}

// ============================================================
// Codec manager singleton
// ============================================================

CCodecs* _Nullable SZGetCodecs() {
    static CCodecs* codecs = []() -> CCodecs* {
        CrcGenerateTable();

        CCodecs* loadedCodecs = new CCodecs;
        if (loadedCodecs->Load() != S_OK) {
            delete loadedCodecs;
            return nullptr;
        }

        return loadedCodecs;
    }();

    return codecs;
}
