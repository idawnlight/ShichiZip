#import <Foundation/Foundation.h>

#define BOOL BOOL_7Z_COMPAT
#include "CPP/7zip/UI/Agent/Agent.h"
#include "CPP/7zip/UI/Common/ZipRegistry.h"
#undef BOOL

#define SZ_DEFINE_7ZIP_GUID(name, groupId, subId) \
    EXTERN_C const GUID name = { 0x23170F69, 0x40C1, 0x278A, { 0, 0, 0, groupId, 0, subId, 0, 0 } }

SZ_DEFINE_7ZIP_GUID(IID_IFolderFolder, 0x08, 0x00);
SZ_DEFINE_7ZIP_GUID(IID_IFolderWasChanged, 0x08, 0x04);
SZ_DEFINE_7ZIP_GUID(IID_IFolderGetSystemIconIndex, 0x08, 0x07);
SZ_DEFINE_7ZIP_GUID(IID_IFolderGetItemFullSize, 0x08, 0x08);
SZ_DEFINE_7ZIP_GUID(IID_IFolderClone, 0x08, 0x09);
SZ_DEFINE_7ZIP_GUID(IID_IFolderSetFlatMode, 0x08, 0x0A);
SZ_DEFINE_7ZIP_GUID(IID_IFolderOperationsExtractCallback, 0x08, 0x0B);
SZ_DEFINE_7ZIP_GUID(IID_IFolderProperties, 0x08, 0x0E);
SZ_DEFINE_7ZIP_GUID(IID_IFolderArcProps, 0x08, 0x10);
SZ_DEFINE_7ZIP_GUID(IID_IGetFolderArcProps, 0x08, 0x11);
SZ_DEFINE_7ZIP_GUID(IID_IFolderOperations, 0x08, 0x13);
SZ_DEFINE_7ZIP_GUID(IID_IFolderCalcItemFullSize, 0x08, 0x14);
SZ_DEFINE_7ZIP_GUID(IID_IFolderCompare, 0x08, 0x15);
SZ_DEFINE_7ZIP_GUID(IID_IFolderGetItemName, 0x08, 0x16);
SZ_DEFINE_7ZIP_GUID(IID_IFolderAltStreams, 0x08, 0x17);
SZ_DEFINE_7ZIP_GUID(IID_IFolderManager, 0x09, 0x05);

SZ_DEFINE_7ZIP_GUID(IID_IArchiveFolderInternal, 0x01, 0x0C);
SZ_DEFINE_7ZIP_GUID(IID_IArchiveFolder, 0x01, 0x0D);
SZ_DEFINE_7ZIP_GUID(IID_IInFolderArchive, 0x01, 0x0E);
SZ_DEFINE_7ZIP_GUID(IID_IFolderArchiveUpdateCallback, 0x01, 0x0B);
SZ_DEFINE_7ZIP_GUID(IID_IOutFolderArchive, 0x01, 0x0F);
SZ_DEFINE_7ZIP_GUID(IID_IFolderArchiveUpdateCallback2, 0x01, 0x10);
SZ_DEFINE_7ZIP_GUID(IID_IFolderScanProgress, 0x01, 0x11);
SZ_DEFINE_7ZIP_GUID(IID_IFolderSetZoneIdMode, 0x01, 0x12);
SZ_DEFINE_7ZIP_GUID(IID_IFolderSetZoneIdFile, 0x01, 0x13);
SZ_DEFINE_7ZIP_GUID(IID_IFolderArchiveUpdateCallback_MoveArc, 0x01, 0x14);

static NSString* const kSZWorkDirModePreferenceKey = @"WorkDirMode";
static NSString* const kSZWorkDirPathPreferenceKey = @"WorkDirPath";
static NSString* const kSZWorkDirRemovableOnlyPreferenceKey = @"WorkDirForRemovableOnly";

static UString SZToUString(NSString* string) {
    if (!string) {
        return UString();
    }
    const NSUInteger len = string.length;
    UString converted;
    converted.Empty();
    for (NSUInteger index = 0; index < len; index++)
        converted += (wchar_t)[string characterAtIndex:index];
    return converted;
}

static NSString* SZToNSString(const UString& string) {
    NSMutableString* converted = [NSMutableString stringWithCapacity:string.Len()];
    for (unsigned index = 0; index < string.Len(); index++) {
        const unichar character = (unichar)string[index];
        [converted appendString:[NSString stringWithCharacters:&character length:1]];
    }
    return converted;
}

bool SZWorkDirShouldUseConfiguredMode(const FString& path) {
    NSString* resolvedPath = SZToNSString(fs2us(path));
    if (resolvedPath.length == 0) {
        return false;
    }

    NSURL* url = [NSURL fileURLWithPath:resolvedPath];
    NSError* error = nil;
    NSNumber* isRemovable = nil;
    NSNumber* isEjectable = nil;
    [url getResourceValue:&isRemovable forKey:NSURLVolumeIsRemovableKey error:&error];
    [url getResourceValue:&isEjectable forKey:NSURLVolumeIsEjectableKey error:nil];
    return isRemovable.boolValue || isEjectable.boolValue;
}

namespace NWorkDir {

void CInfo::Save() const {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:(NSInteger)Mode forKey:kSZWorkDirModePreferenceKey];
    [defaults setObject:SZToNSString(fs2us(Path)) forKey:kSZWorkDirPathPreferenceKey];
    [defaults setBool:ForRemovableOnly forKey:kSZWorkDirRemovableOnlyPreferenceKey];
}

void CInfo::Load() {
    SetDefault();

    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kSZWorkDirModePreferenceKey] != nil) {
        const NSInteger storedMode = [defaults integerForKey:kSZWorkDirModePreferenceKey];
        switch (storedMode) {
        case NMode::kSystem:
        case NMode::kCurrent:
        case NMode::kSpecified:
            Mode = (NMode::EEnum)storedMode;
            break;
        default:
            break;
        }
    }

    NSString* path = [defaults stringForKey:kSZWorkDirPathPreferenceKey];
    if (path.length > 0) {
        Path = us2fs(SZToUString(path));
    } else if (Mode == NMode::kSpecified) {
        Mode = NMode::kSystem;
    }

    if ([defaults objectForKey:kSZWorkDirRemovableOnlyPreferenceKey] != nil) {
        ForRemovableOnly = [defaults boolForKey:kSZWorkDirRemovableOnlyPreferenceKey];
    }
}

}

int CompareFileNames_ForFolderList(const wchar_t* s1, const wchar_t* s2) {
    for (;;) {
        wchar_t c1 = *s1;
        wchar_t c2 = *s2;
        if ((c1 >= '0' && c1 <= '9') && (c2 >= '0' && c2 <= '9')) {
            for (; *s1 == '0'; s1++)
                ;
            for (; *s2 == '0'; s2++)
                ;
            size_t len1 = 0;
            size_t len2 = 0;
            for (; (s1[len1] >= '0' && s1[len1] <= '9'); len1++)
                ;
            for (; (s2[len2] >= '0' && s2[len2] <= '9'); len2++)
                ;
            if (len1 < len2)
                return -1;
            if (len1 > len2)
                return 1;
            for (; len1 > 0; s1++, s2++, len1--) {
                if (*s1 == *s2)
                    continue;
                return (*s1 < *s2) ? -1 : 1;
            }
            c1 = *s1;
            c2 = *s2;
        }
        s1++;
        s2++;
        if (c1 != c2) {
            const wchar_t u1 = MyCharUpper(c1);
            const wchar_t u2 = MyCharUpper(c2);
            if (u1 < u2)
                return -1;
            if (u1 > u2)
                return 1;
        }
        if (c1 == 0)
            return 0;
    }
}
