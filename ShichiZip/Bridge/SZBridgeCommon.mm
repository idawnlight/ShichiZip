// SZBridgeCommon.mm — Shared bridge infrastructure (codecs, password, GUIDs)

// This TU defines INITGUID so all IID constants are instantiated here
#define INITGUID

#include "SZBridgeCommon.h"
#import <Security/Security.h>
#include <os/lock.h>

extern "C" void SZSetWorkDirUserDefaultsProvider(NSUserDefaults* _Nonnull (* _Nullable provider)(void));

__attribute__((constructor))
static void SZRegisterWorkDirUserDefaultsProvider(void) {
    SZSetWorkDirUserDefaultsProvider(SZSharedNSUserDefaults);
}

NSString* const SZArchiveErrorDomain = @"SZArchiveErrorDomain";
NSString* const SZArchiveMutationCommittedErrorKey = @"SZArchiveMutationCommitted";
NSString* const SZArchiveMutationReopenFailedErrorKey = @"SZArchiveMutationReopenFailed";

// ============================================================
// Shared preferences and localization
// ============================================================

static NSString* _Nullable SZResolvedEntitledAppGroupIdentifier(void) {
    id rawIdentifier = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"ShichiZipQuickActionAppGroupIdentifier"];
    NSString* identifier = [rawIdentifier isKindOfClass:NSString.class]
        ? [rawIdentifier stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : nil;
    const NSRange dotRange = identifier ? [identifier rangeOfString:@"."] : NSMakeRange(NSNotFound, 0);
    if (dotRange.location == NSNotFound || dotRange.location == 0 || NSMaxRange(dotRange) >= identifier.length) {
        return nil;
    }

    SecCodeRef code = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) != errSecSuccess || !code) {
        return nil;
    }
    CFDictionaryRef signingInfoRef = NULL;
    const OSStatus status = SecCodeCopySigningInformation(code, kSecCSDefaultFlags, &signingInfoRef);
    CFRelease(code);
    if (status != errSecSuccess || !signingInfoRef) {
        return nil;
    }

    NSDictionary* signingInfo = CFBridgingRelease(signingInfoRef);
    id rawSigningID = signingInfo[(__bridge NSString*)kSecCodeInfoIdentifier];
    id rawFlags = signingInfo[(__bridge NSString*)kSecCodeInfoFlags];
    if (![rawSigningID isKindOfClass:NSString.class] || [(NSString*)rawSigningID length] == 0 ||
        ![rawFlags isKindOfClass:NSNumber.class] ||
        ([(NSNumber*)rawFlags unsignedIntValue] & kSecCodeSignatureAdhoc) != 0) {
        return nil;
    }

    id rawEntitlements = signingInfo[(__bridge NSString*)kSecCodeInfoEntitlementsDict];
    id rawGroups = [rawEntitlements isKindOfClass:NSDictionary.class]
        ? rawEntitlements[@"com.apple.security.application-groups"]
        : nil;
    return ([rawGroups isKindOfClass:NSArray.class] && [rawGroups containsObject:identifier]) ? identifier : nil;
}

NSUserDefaults* SZSharedNSUserDefaults(void) {
    static NSUserDefaults* defaults;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* appGroupIdentifier = SZResolvedEntitledAppGroupIdentifier();
        defaults = appGroupIdentifier ? [[NSUserDefaults alloc] initWithSuiteName:appGroupIdentifier] : nil;
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
