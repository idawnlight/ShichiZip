// SZArchive.mm — Main archive interface implementation

#include "SZBridgeCommon.h"
#include "SZCallbacks.h"

#include <string>
#include <vector>

#ifdef __APPLE__
#include <sys/xattr.h>
#ifndef XATTR_NOFOLLOW
#define XATTR_NOFOLLOW 0x0001
#endif
#endif

#import "../Utilities/SZOperationSessionDefaults.h"

#include "7zVersion.h"
#include "CPP/7zip/Common/MethodProps.h"
#include "CPP/7zip/UI/Agent/Agent.h"
#include "CPP/7zip/UI/Common/ArchiveExtractCallback.h"
#include "CPP/7zip/UI/Common/EnumDirItems.h"
#include "CPP/7zip/UI/Common/Extract.h"
#include "CPP/7zip/UI/Common/HashCalc.h"
#include "CPP/7zip/UI/Common/OpenArchive.h"
#include "CPP/7zip/UI/Common/SetProperties.h"
#include "CPP/7zip/UI/Common/Update.h"
#include "CPP/7zip/UI/Common/UpdateCallback.h"
#include "CPP/Common/MyString.h"
#include "CPP/Common/StringToInt.h"
#include "CPP/Common/Wildcard.h"
#include "CPP/Windows/ErrorMsg.h"
#include "CPP/Windows/System.h"

// ============================================================
// ObjC model implementations
// ============================================================

@implementation SZCompressionSettings
- (instancetype)init {
    if ((self = [super init])) {
        _format = SZArchiveFormat7z;
        _level = SZCompressionLevelNormal;
        _levelValue = SZCompressionLevelNormal;
        _method = SZCompressionMethodLZMA2;
        _encryption = SZEncryptionMethodNone;
        _updateMode = SZCompressionUpdateModeAdd;
        _pathMode = SZCompressionPathModeRelativePaths;
        _methodName = @"LZMA2";
        _solidMode = YES;
        _openSharedFiles = NO;
        _deleteAfterCompression = NO;
        _storeSymbolicLinks = SZCompressionBoolSettingNotDefined;
        _storeHardLinks = SZCompressionBoolSettingNotDefined;
        _storeAlternateDataStreams = SZCompressionBoolSettingNotDefined;
        _storeFileSecurity = SZCompressionBoolSettingNotDefined;
        _preserveSourceAccessTime = SZCompressionBoolSettingNotDefined;
        _storeModificationTime = SZCompressionBoolSettingNotDefined;
        _storeCreationTime = SZCompressionBoolSettingNotDefined;
        _storeAccessTime = SZCompressionBoolSettingNotDefined;
        _setArchiveTimeToLatestFile = SZCompressionBoolSettingNotDefined;
        _timePrecision = SZCompressionTimePrecisionAutomatic;
    }
    return self;
}
@end

@implementation SZExtractionSettings
- (instancetype)init {
    if ((self = [super init])) {
        _pathMode = SZPathModeFullPaths;
        _overwriteMode = SZOverwriteModeAsk;
        _preserveNtSecurityInfo = NO;
    }
    return self;
}
@end

static NSData* SZQuarantineDataForArchivePath(NSString* archivePath) {
    if (!archivePath || archivePath.length == 0) {
        return nil;
    }

    static NSString* const quarantineAttributeName = @"com.apple.quarantine";
    const ssize_t size = archivePath.fileSystemRepresentation
        ? quarantineAttributeName.fileSystemRepresentation
            ? getxattr(archivePath.fileSystemRepresentation,
                  quarantineAttributeName.fileSystemRepresentation,
                  nil,
                  0,
                  0,
                  XATTR_NOFOLLOW)
            : -1
        : -1;

    if (size < 0) {
        return nil;
    }

    NSMutableData* data = [NSMutableData dataWithLength:(NSUInteger)size];
    const ssize_t result = getxattr(archivePath.fileSystemRepresentation,
        quarantineAttributeName.fileSystemRepresentation,
        data.mutableBytes,
        data.length,
        0,
        XATTR_NOFOLLOW);
    if (result < 0) {
        return nil;
    }

    return data;
}

@implementation SZArchiveEntry
@end
@implementation SZFormatInfo
@end
@implementation SZCompressionResourceInfo
@end
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

namespace {

enum SZCompressionEstimateMethodID {
    kSZCompressionEstimateCopy,
    kSZCompressionEstimateLZMA,
    kSZCompressionEstimateLZMA2,
    kSZCompressionEstimatePPMd,
    kSZCompressionEstimateBZip2,
    kSZCompressionEstimateDeflate,
    kSZCompressionEstimateDeflate64,
    kSZCompressionEstimatePPMdZip,
#if SHICHIZIP_ZS_VARIANT
    kSZCompressionEstimateFastLzma2,
    kSZCompressionEstimateZstd,
    kSZCompressionEstimateBrotli,
    kSZCompressionEstimateLz4,
    kSZCompressionEstimateLz5,
    kSZCompressionEstimateLizardFastLz4,
    kSZCompressionEstimateLizardLizV1,
    kSZCompressionEstimateLizardFastLz4Huffman,
    kSZCompressionEstimateLizardLizV1Huffman,
#endif
    kSZCompressionEstimateGnu,
    kSZCompressionEstimatePosix,
};

static const UInt32 kSZCompressionEstimateLzmaMaxDictSize = (UInt32)15 << 28;
#if SHICHIZIP_ZS_VARIANT
static const NSInteger kSZCompressionZstdFastLevelIncrement = 32;
static const NSInteger kSZCompressionZstdUltimateLevel = 255;
#endif

struct SZCompressionEstimateRamInfo {
    bool IsDefined;
    UInt64 RamSizeReduced;
    UInt64 UsageAuto;
};

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

static bool SZCompressionEstimateMethodSupportsSFX(int methodID) {
    switch (methodID) {
    case kSZCompressionEstimateCopy:
    case kSZCompressionEstimateLZMA:
    case kSZCompressionEstimateLZMA2:
    case kSZCompressionEstimatePPMd:
#if SHICHIZIP_ZS_VARIANT
    case kSZCompressionEstimateFastLzma2:
    case kSZCompressionEstimateZstd:
#endif
        return true;
    default:
        return false;
    }
}

static bool SZCompressionEstimateFormatSupportsFilters(SZArchiveFormat format) {
    return format == SZArchiveFormat7z;
}

static bool SZCompressionEstimateFormatSupportsThreads(SZArchiveFormat format) {
    switch (format) {
    case SZArchiveFormat7z:
    case SZArchiveFormatZip:
    case SZArchiveFormatBZip2:
    case SZArchiveFormatXz:
#if SHICHIZIP_ZS_VARIANT
    case SZArchiveFormatZstd:
    case SZArchiveFormatBrotli:
    case SZArchiveFormatLizard:
    case SZArchiveFormatLz4:
    case SZArchiveFormatLz5:
#endif
        return true;
    default:
        return false;
    }
}

static bool
SZCompressionEstimateFormatSupportsMemoryUse(SZArchiveFormat format) {
    switch (format) {
    case SZArchiveFormat7z:
    case SZArchiveFormatZip:
    case SZArchiveFormatGZip:
    case SZArchiveFormatBZip2:
    case SZArchiveFormatXz:
#if SHICHIZIP_ZS_VARIANT
    case SZArchiveFormatZstd:
    case SZArchiveFormatBrotli:
    case SZArchiveFormatLizard:
    case SZArchiveFormatLz4:
    case SZArchiveFormatLz5:
#endif
        return true;
    default:
        return false;
    }
}

static bool SZCompressionEstimateIsZipFormat(SZArchiveFormat format) {
    return format == SZArchiveFormatZip;
}

static bool SZCompressionEstimateIsXzFormat(SZArchiveFormat format) {
    return format == SZArchiveFormatXz;
}

static int SZCompressionEstimateLevel(SZCompressionSettings* settings) {
    return (int)settings.levelValue;
}

#if SHICHIZIP_ZS_VARIANT
static bool SZCompressionEstimateIsZstdFastLevel(int level) {
    return level < 0;
}

static UInt32 SZCompressionEstimateZstdFastLevel(int level) {
    return level < 0 ? (UInt32)(-level) : 0;
}
#endif

static UInt32 SZCompressionLevelPropertyValue(int methodID,
    NSInteger levelValue) {
#if SHICHIZIP_ZS_VARIANT
    if (methodID == kSZCompressionEstimateZstd && levelValue < 0) {
        return (UInt32)(kSZCompressionZstdFastLevelIncrement - levelValue);
    }
#endif
    return (UInt32)levelValue;
}

static int SZCompressionEstimateMethodID(SZCompressionSettings* settings) {
    NSString* methodName = settings.methodName ? settings.methodName.lowercaseString : @"";
    if (methodName.length > 0) {
        if ([methodName isEqualToString:@"copy"]) {
            return kSZCompressionEstimateCopy;
        }
        if ([methodName isEqualToString:@"lzma"]) {
            return kSZCompressionEstimateLZMA;
        }
        if ([methodName isEqualToString:@"lzma2"]) {
            return kSZCompressionEstimateLZMA2;
        }
        if ([methodName isEqualToString:@"ppmd"]) {
            return settings.format == SZArchiveFormatZip
                ? kSZCompressionEstimatePPMdZip
                : kSZCompressionEstimatePPMd;
        }
        if ([methodName isEqualToString:@"bzip2"]) {
            return kSZCompressionEstimateBZip2;
        }
        if ([methodName isEqualToString:@"deflate"]) {
            return kSZCompressionEstimateDeflate;
        }
        if ([methodName isEqualToString:@"deflate64"]) {
            return kSZCompressionEstimateDeflate64;
        }
#if SHICHIZIP_ZS_VARIANT
        if ([methodName isEqualToString:@"flzma2"]) {
            return kSZCompressionEstimateFastLzma2;
        }
        if ([methodName isEqualToString:@"zstd"]) {
            return kSZCompressionEstimateZstd;
        }
        if ([methodName isEqualToString:@"brotli"]) {
            return kSZCompressionEstimateBrotli;
        }
        if ([methodName isEqualToString:@"lz4"]) {
            return kSZCompressionEstimateLz4;
        }
        if ([methodName isEqualToString:@"lz5"]) {
            return kSZCompressionEstimateLz5;
        }
        if ([methodName isEqualToString:@"lizard-fastlz4"]) {
            return kSZCompressionEstimateLizardFastLz4;
        }
        if ([methodName isEqualToString:@"lizard-lizv1"]) {
            return kSZCompressionEstimateLizardLizV1;
        }
        if ([methodName isEqualToString:@"lizard-fastlz4-huffman"]) {
            return kSZCompressionEstimateLizardFastLz4Huffman;
        }
        if ([methodName isEqualToString:@"lizard-lizv1-huffman"]) {
            return kSZCompressionEstimateLizardLizV1Huffman;
        }
#endif
        if ([methodName isEqualToString:@"gnu"]) {
            return kSZCompressionEstimateGnu;
        }
        if ([methodName isEqualToString:@"posix"]) {
            return kSZCompressionEstimatePosix;
        }
    }

    switch (settings.format) {
    case SZArchiveFormatGZip:
        return kSZCompressionEstimateDeflate;
    case SZArchiveFormatBZip2:
        return kSZCompressionEstimateBZip2;
    case SZArchiveFormatXz:
        return kSZCompressionEstimateLZMA2;
#if SHICHIZIP_ZS_VARIANT
    case SZArchiveFormatZstd:
        return kSZCompressionEstimateZstd;
    case SZArchiveFormatBrotli:
        return kSZCompressionEstimateBrotli;
    case SZArchiveFormatLizard:
        return kSZCompressionEstimateLizardFastLz4;
    case SZArchiveFormatLz4:
        return kSZCompressionEstimateLz4;
    case SZArchiveFormatLz5:
        return kSZCompressionEstimateLz5;
#endif
    default:
        break;
    }

    switch (settings.method) {
    case SZCompressionMethodLZMA:
        return kSZCompressionEstimateLZMA;
    case SZCompressionMethodLZMA2:
        return kSZCompressionEstimateLZMA2;
    case SZCompressionMethodPPMd:
        return settings.format == SZArchiveFormatZip ? kSZCompressionEstimatePPMdZip
                                                     : kSZCompressionEstimatePPMd;
    case SZCompressionMethodBZip2:
        return kSZCompressionEstimateBZip2;
    case SZCompressionMethodDeflate:
        return kSZCompressionEstimateDeflate;
    case SZCompressionMethodDeflate64:
        return kSZCompressionEstimateDeflate64;
    case SZCompressionMethodCopy:
        return kSZCompressionEstimateCopy;
    }

    return -1;
}

static SZCompressionEstimateRamInfo SZCompressionEstimateGetRamInfo() {
    size_t size = (size_t)sizeof(size_t) << 29;
    const bool isDefined = NWindows::NSystem::GetRamSize(size);

    if (sizeof(size_t) * 8 == 32) {
        const UInt32 limit2 = (UInt32)7 << 28;
        if (size > limit2) {
            size = limit2;
        }
    }

    const size_t kMinUseSize = (size_t)1 << 26;
    if (size < kMinUseSize) {
        size = kMinUseSize;
    }

    SZCompressionEstimateRamInfo info;
    info.IsDefined = isDefined;
    info.RamSizeReduced = size;
    info.UsageAuto = Calc_From_Val_Percents(size, 80);
    return info;
}

static bool SZCompressionEstimateGetMemoryUsageLimit(
    SZCompressionSettings* settings,
    const SZCompressionEstimateRamInfo& ramInfo, UInt64& memoryUsageLimit) {
    memoryUsageLimit = ramInfo.UsageAuto;
    bool isDefined = ramInfo.IsDefined;

    if (settings.memoryUsage.length > 0) {
        NSString* spec = [[settings.memoryUsage
            stringByTrimmingCharactersInSet:NSCharacterSet
                                                .whitespaceAndNewlineCharacterSet]
            lowercaseString];
        if (spec.length > 0) {
            UInt64 parsedLimit = 0;
            bool parsed = false;

            if ([spec hasSuffix:@"%"] && spec.length > 1) {
                NSString* valueText = [spec substringToIndex:spec.length - 1];
                unsigned long long percentValue = 0;
                NSScanner* scanner = [NSScanner scannerWithString:valueText];
                parsed =
                    [scanner scanUnsignedLongLong:&percentValue] && scanner.isAtEnd;
                if (parsed) {
                    parsedLimit = Calc_From_Val_Percents(ramInfo.RamSizeReduced,
                        (UInt64)percentValue);
                }
            } else {
                NSString* valueText = spec;
                if ([valueText hasSuffix:@"b"] && valueText.length > 1) {
                    valueText = [valueText substringToIndex:valueText.length - 1];
                }

                unsigned shift = 0;
                if (valueText.length > 1) {
                    const unichar suffix =
                        [valueText characterAtIndex:valueText.length - 1];
                    switch (suffix) {
                    case 'k':
                        shift = 10;
                        break;
                    case 'm':
                        shift = 20;
                        break;
                    case 'g':
                        shift = 30;
                        break;
                    case 't':
                        shift = 40;
                        break;
                    default:
                        break;
                    }
                    if (shift != 0) {
                        valueText = [valueText substringToIndex:valueText.length - 1];
                    }
                }

                unsigned long long baseValue = 0;
                NSScanner* scanner = [NSScanner scannerWithString:valueText];
                parsed = [scanner scanUnsignedLongLong:&baseValue] && scanner.isAtEnd;
                if (parsed) {
                    parsedLimit = (UInt64)baseValue;
                    if (shift != 0) {
                        if (parsedLimit >= ((UInt64)1 << (64 - shift))) {
                            parsed = false;
                        } else {
                            parsedLimit <<= shift;
                        }
                    }
                }
            }

            if (parsed) {
                memoryUsageLimit = parsedLimit;
                isDefined = true;
            }
        }
    }

    return isDefined;
}

static void
SZCompressionEstimateGetCpuThreadCounts(UInt32& numCPUs,
    UInt32& numHardwareThreads) {
    numCPUs = 1;
    numHardwareThreads = 1;

    NWindows::NSystem::CProcessAffinity threadsInfo;
    threadsInfo.InitST();

#ifdef _WIN32
#ifndef Z7_ST
    threadsInfo.Get_and_return_NumProcessThreads_and_SysThreads(
        numCPUs, numHardwareThreads);
#endif
#else
    if (threadsInfo.Get()) {
        numCPUs = threadsInfo.GetNumProcessThreads();
        numHardwareThreads = threadsInfo.GetNumSystemThreads();
    } else {
        numCPUs = NWindows::NSystem::GetNumberOfProcessors();
        numHardwareThreads = numCPUs;
    }

    if (numCPUs == 0) {
        numCPUs = 1;
    }
    if (numHardwareThreads < numCPUs) {
        numHardwareThreads = numCPUs;
    }
#endif
}

static UInt64 SZCompressionEstimateAutoDictionary(int methodID, int level) {
    switch (methodID) {
    case kSZCompressionEstimateLZMA:
    case kSZCompressionEstimateLZMA2:
        return level <= 4 ? (UInt64)1 << (level * 2 + 16)
            : level <= sizeof(size_t) / 2 + 4
            ? (UInt64)1 << (level + 20)
            : (UInt64)1 << (sizeof(size_t) / 2 + 24);

    case kSZCompressionEstimatePPMd:
    case kSZCompressionEstimatePPMdZip:
        return (UInt64)1 << (level + 19);

    case kSZCompressionEstimateDeflate:
        return (UInt64)1 << 15;

    case kSZCompressionEstimateDeflate64:
        return (UInt64)1 << 16;

    case kSZCompressionEstimateBZip2:
        if (level >= 5) {
            return (UInt64)900 << 10;
        }
        if (level >= 3) {
            return (UInt64)500 << 10;
        }
        return (UInt64)100 << 10;

    case kSZCompressionEstimateCopy:
        return 0;

#if SHICHIZIP_ZS_VARIANT
    case kSZCompressionEstimateFastLzma2:
        if (level == 0) {
            level = 1;
        }
        if (level > 9) {
            level = 9;
        }
        switch (level) {
        case 1:
            return (UInt64)1 << 20;
        case 2:
        case 3:
            return (UInt64)2 << 20;
        case 4:
            return (UInt64)4 << 20;
        case 5:
            return (UInt64)16 << 20;
        case 6:
            return (UInt64)32 << 20;
        case 7:
        case 8:
            return (UInt64)64 << 20;
        case 9:
        default:
            return (UInt64)128 << 20;
        }

    case kSZCompressionEstimateZstd:
        if (level == (int)kSZCompressionZstdUltimateLevel) {
            return (UInt64)1 << 27;
        }
        if (SZCompressionEstimateIsZstdFastLevel(level)) {
            const UInt32 fastLevel = SZCompressionEstimateZstdFastLevel(level);
            const UInt32 windowLog = fastLevel >= 12 ? 20u
                : fastLevel >= 6                     ? 22u
                                                     : 24u;
            return (UInt64)1 << windowLog;
        }
        if (level <= 3) {
            return (UInt64)1 << 23;
        }
        if (level <= 9) {
            return (UInt64)1 << 24;
        }
        if (level <= 16) {
            return (UInt64)1 << 25;
        }
        return (UInt64)1 << 26;

    case kSZCompressionEstimateBrotli:
        return level >= 9 ? (UInt64)16 << 20
            : level >= 5  ? (UInt64)8 << 20
                          : (UInt64)4 << 20;

    case kSZCompressionEstimateLz4:
        if (level <= 4) {
            return (UInt64)4 << 20;
        }
        if (level <= 8) {
            return (UInt64)8 << 20;
        }
        return (UInt64)16 << 20;

    case kSZCompressionEstimateLz5:
        if (level <= 5) {
            return (UInt64)8 << 20;
        }
        if (level <= 10) {
            return (UInt64)16 << 20;
        }
        return (UInt64)32 << 20;

    case kSZCompressionEstimateLizardFastLz4:
    case kSZCompressionEstimateLizardLizV1:
    case kSZCompressionEstimateLizardFastLz4Huffman:
    case kSZCompressionEstimateLizardLizV1Huffman:
        return level >= 40 ? (UInt64)64 << 20
            : level >= 30  ? (UInt64)32 << 20
                           : (UInt64)16 << 20;
#endif

    default:
        return (UInt64)-1;
    }
}

static UInt64 SZCompressionEstimateDictionary(SZCompressionSettings* settings,
    int methodID, int level) {
    if (settings.dictionarySize > 0) {
        return settings.dictionarySize;
    }
    return SZCompressionEstimateAutoDictionary(methodID, level);
}

static bool SZCompressionEstimateAutoWordSize(int methodID, int level,
    UInt32& wordSize) {
    switch (methodID) {
    case kSZCompressionEstimateLZMA:
    case kSZCompressionEstimateLZMA2:
        wordSize = (level < 7 ? 32u : 64u);
        return true;

    case kSZCompressionEstimateDeflate:
    case kSZCompressionEstimateDeflate64:
        if (level >= 9) {
            wordSize = 128;
        } else if (level >= 7) {
            wordSize = 64;
        } else {
            wordSize = 32;
        }
        return true;

    case kSZCompressionEstimatePPMd:
        if (level >= 9) {
            wordSize = 32;
        } else if (level >= 7) {
            wordSize = 16;
        } else if (level >= 5) {
            wordSize = 6;
        } else {
            wordSize = 4;
        }
        return true;

    case kSZCompressionEstimatePPMdZip:
        wordSize = level + 3;
        return true;

#if SHICHIZIP_ZS_VARIANT
    case kSZCompressionEstimateFastLzma2:
        if (level == 0) {
            level = 1;
        }
        if (level <= 4) {
            wordSize = 32;
        } else if (level == 5) {
            wordSize = 48;
        } else if (level == 6) {
            wordSize = 64;
        } else if (level == 7) {
            wordSize = 96;
        } else {
            wordSize = 273;
        }
        return true;
#endif

    default:
        return false;
    }
}

static bool SZCompressionEstimateWordSize(SZCompressionSettings* settings,
    int methodID, int level,
    UInt32& wordSize) {
    if (settings.wordSize > 0) {
        wordSize = settings.wordSize;
        return true;
    }
    return SZCompressionEstimateAutoWordSize(methodID, level, wordSize);
}

static UInt64 SZCompressionEstimateMemoryUsage_Threads_Dict_DecompMem(
    SZArchiveFormat format, int methodID, int level, UInt32 numThreads,
    UInt64 dict64, UInt64& decompressMemory) {
    decompressMemory = (UInt64)-1;

    if (level == 0) {
        decompressMemory = (UInt64)1 << 20;
        return decompressMemory;
    }

    UInt64 size = 0;
    if (SZCompressionEstimateFormatSupportsFilters(format) && level >= 9) {
        size += (12 << 20) * 2 + (5 << 20);
    }

    UInt32 numMainZipThreads = 1;
    if (SZCompressionEstimateIsZipFormat(format)) {
        UInt32 numSubThreads = 1;
        if (methodID == kSZCompressionEstimateLZMA && numThreads > 1 && level >= 5) {
            numSubThreads = 2;
        }
        numMainZipThreads = numThreads / numSubThreads;
        if (numMainZipThreads > 1) {
            size += (UInt64)numMainZipThreads * ((size_t)sizeof(size_t) << 23);
        } else {
            numMainZipThreads = 1;
        }
    }

    if (dict64 == (UInt64)-1) {
        return (UInt64)-1;
    }

    switch (methodID) {
    case kSZCompressionEstimateLZMA:
    case kSZCompressionEstimateLZMA2: {
        const UInt32 dict = (dict64 >= kSZCompressionEstimateLzmaMaxDictSize
                ? kSZCompressionEstimateLzmaMaxDictSize
                : (UInt32)dict64);

        UInt32 hashSize = dict - 1;
        hashSize |= (hashSize >> 1);
        hashSize |= (hashSize >> 2);
        hashSize |= (hashSize >> 4);
        hashSize |= (hashSize >> 8);
        hashSize >>= 1;
        if (hashSize >= (1 << 24)) {
            hashSize >>= 1;
        }
        hashSize |= (1 << 16) - 1;
        if (level < 5) {
            hashSize |= (256 << 10) - 1;
        }
        hashSize++;

        UInt64 size1 = (UInt64)hashSize * 4;
        size1 += (UInt64)dict * 4;
        if (level >= 5) {
            size1 += (UInt64)dict * 4;
        }
        size1 += (2 << 20);

        UInt32 numThreads1 = 1;
        if (numThreads > 1 && level >= 5) {
            size1 += (2 << 20) + (4 << 20);
            numThreads1 = 2;
        }

        UInt32 numBlockThreads = numThreads / numThreads1;
        UInt64 chunkSize = 0;
        if (methodID == kSZCompressionEstimateLZMA2 && numBlockThreads != 1) {
            chunkSize = (UInt64)dict << 2;
            const UInt32 kMinSize = (UInt32)1 << 20;
            const UInt32 kMaxSize = (UInt32)1 << 28;
            if (chunkSize < kMinSize) {
                chunkSize = kMinSize;
            }
            if (chunkSize > kMaxSize) {
                chunkSize = kMaxSize;
            }
            if (chunkSize < dict) {
                chunkSize = dict;
            }
            chunkSize += (kMinSize - 1);
            chunkSize &= ~(UInt64)(kMinSize - 1);
        }

        if (chunkSize == 0) {
            const UInt32 kBlockSizeMax = (UInt32)0 - (UInt32)(1 << 16);
            UInt64 blockSize = (UInt64)dict + (1 << 16) + (numThreads1 > 1 ? (1 << 20) : 0);
            blockSize += (blockSize >> (blockSize < ((UInt32)1 << 30) ? 1 : 2));
            if (blockSize >= kBlockSizeMax) {
                blockSize = kBlockSizeMax;
            }
            size += numBlockThreads * (size1 + blockSize);
        } else {
            size += numBlockThreads * (size1 + chunkSize);
            const UInt32 numPackChunks = numBlockThreads + (numBlockThreads / 8) + 1;
            if (chunkSize < ((UInt32)1 << 26)) {
                numBlockThreads++;
            }
            if (chunkSize < ((UInt32)1 << 24)) {
                numBlockThreads++;
            }
            if (chunkSize < ((UInt32)1 << 22)) {
                numBlockThreads++;
            }
            size += numPackChunks * chunkSize;
        }

        decompressMemory = dict + (2 << 20);
        return size;
    }

    case kSZCompressionEstimatePPMd:
        decompressMemory = dict64 + (2 << 20);
        return size + decompressMemory;

    case kSZCompressionEstimateDeflate:
    case kSZCompressionEstimateDeflate64: {
        UInt64 size1 = 3 << 20;
        size1 += (1 << 20);
        size += size1 * numMainZipThreads;
        decompressMemory = (2 << 20);
        return size;
    }

    case kSZCompressionEstimateBZip2:
        decompressMemory = (7 << 20);
        return size + ((UInt64)10 << 20) * numThreads;

    case kSZCompressionEstimatePPMdZip:
        decompressMemory = dict64 + (2 << 20);
        return size + (UInt64)decompressMemory * numThreads;

#if SHICHIZIP_ZS_VARIANT
    case kSZCompressionEstimateFastLzma2: {
        const UInt64 dictionary = dict64 == (UInt64)-1 ? (UInt64)16 << 20 : dict64;
        const UInt32 effectiveThreads = numThreads == 0 ? 1u : numThreads;
        decompressMemory = dictionary + (4 << 20);
        return ((UInt64)12 << 20) + dictionary * 3 + ((UInt64)4 << 20) * effectiveThreads;
    }

    case kSZCompressionEstimateZstd: {
        const UInt64 dictionary = dict64 == (UInt64)-1 ? (UInt64)1 << 24 : dict64;
        const UInt32 effectiveThreads = numThreads == 0 ? 1u : numThreads;
        const UInt64 perThread = SZCompressionEstimateIsZstdFastLevel(level)
            ? (UInt64)3 << 20
            : (UInt64)8 << 20;
        decompressMemory = dictionary + (2 << 20);
        return dictionary * 2 + perThread * effectiveThreads;
    }

    case kSZCompressionEstimateBrotli: {
        const UInt64 dictionary = dict64 == (UInt64)-1 ? (UInt64)8 << 20 : dict64;
        const UInt32 effectiveThreads = numThreads == 0 ? 1u : numThreads;
        decompressMemory = dictionary + (1 << 20);
        return dictionary * 2 + ((UInt64)10 << 20) * effectiveThreads;
    }

    case kSZCompressionEstimateLz4: {
        const UInt64 dictionary = dict64 == (UInt64)-1 ? (UInt64)8 << 20 : dict64;
        const UInt32 effectiveThreads = numThreads == 0 ? 1u : numThreads;
        decompressMemory = (4 << 20);
        return dictionary + ((UInt64)6 << 20) * effectiveThreads;
    }

    case kSZCompressionEstimateLz5: {
        const UInt64 dictionary = dict64 == (UInt64)-1 ? (UInt64)16 << 20 : dict64;
        const UInt32 effectiveThreads = numThreads == 0 ? 1u : numThreads;
        decompressMemory = (6 << 20);
        return dictionary + ((UInt64)8 << 20) * effectiveThreads;
    }

    case kSZCompressionEstimateLizardFastLz4:
    case kSZCompressionEstimateLizardLizV1:
    case kSZCompressionEstimateLizardFastLz4Huffman:
    case kSZCompressionEstimateLizardLizV1Huffman: {
        const UInt64 dictionary = dict64 == (UInt64)-1 ? (UInt64)16 << 20 : dict64;
        const UInt32 effectiveThreads = numThreads == 0 ? 1u : numThreads;
        decompressMemory = (8 << 20);
        return dictionary + ((UInt64)10 << 20) * effectiveThreads;
    }
#endif

    default:
        return (UInt64)-1;
    }
}

static UInt32 SZCompressionEstimateAutoThreads(SZCompressionSettings* settings,
    int methodID, int level,
    UInt64 dict64,
    UInt64 memoryUsageLimit,
    bool memoryUsageLimitIsDefined) {
    if (!SZCompressionEstimateFormatSupportsThreads(settings.format)) {
        return 1;
    }

    UInt32 numCPUs = 1;
    UInt32 numHardwareThreads = 1;
    SZCompressionEstimateGetCpuThreadCounts(numCPUs, numHardwareThreads);

    UInt32 numAlgoThreadsMax = numHardwareThreads * 2;
    if (SZCompressionEstimateIsZipFormat(settings.format)) {
        numAlgoThreadsMax = 8 << (sizeof(size_t) / 2);
    } else if (SZCompressionEstimateIsXzFormat(settings.format)) {
        numAlgoThreadsMax = 256 * 2;
    } else {
        switch (methodID) {
        case kSZCompressionEstimateLZMA:
            numAlgoThreadsMax = 2;
            break;
        case kSZCompressionEstimateLZMA2:
            numAlgoThreadsMax = 256 * 2;
            break;
        case kSZCompressionEstimateBZip2:
            numAlgoThreadsMax = 64;
            break;
#if SHICHIZIP_ZS_VARIANT
        case kSZCompressionEstimateFastLzma2:
        case kSZCompressionEstimateZstd:
        case kSZCompressionEstimateBrotli:
        case kSZCompressionEstimateLz4:
        case kSZCompressionEstimateLz5:
        case kSZCompressionEstimateLizardFastLz4:
        case kSZCompressionEstimateLizardLizV1:
        case kSZCompressionEstimateLizardFastLz4Huffman:
        case kSZCompressionEstimateLizardLizV1Huffman:
            numAlgoThreadsMax = 128;
            break;
#endif
        case kSZCompressionEstimateCopy:
        case kSZCompressionEstimatePPMd:
        case kSZCompressionEstimateDeflate:
        case kSZCompressionEstimateDeflate64:
        case kSZCompressionEstimatePPMdZip:
            numAlgoThreadsMax = 1;
            break;
        default:
            break;
        }
    }

    UInt32 autoThreads = numCPUs;
    if (autoThreads > numAlgoThreadsMax) {
        autoThreads = numAlgoThreadsMax;
    }

    if (memoryUsageLimitIsDefined && autoThreads > 1) {
        if (SZCompressionEstimateIsZipFormat(settings.format)) {
            for (; autoThreads > 1; autoThreads--) {
                UInt64 decompressMemory;
                const UInt64 usage = SZCompressionEstimateMemoryUsage_Threads_Dict_DecompMem(
                    settings.format, methodID, level, autoThreads, dict64,
                    decompressMemory);
                if (usage <= memoryUsageLimit) {
                    break;
                }
            }
        } else if (methodID == kSZCompressionEstimateLZMA2) {
            const UInt32 numThreads1 = (level >= 5 ? 2 : 1);
            UInt32 numBlockThreads = autoThreads / numThreads1;
            for (; numBlockThreads > 1; numBlockThreads--) {
                autoThreads = numBlockThreads * numThreads1;
                UInt64 decompressMemory;
                const UInt64 usage = SZCompressionEstimateMemoryUsage_Threads_Dict_DecompMem(
                    settings.format, methodID, level, autoThreads, dict64,
                    decompressMemory);
                if (usage <= memoryUsageLimit) {
                    break;
                }
            }
            autoThreads = numBlockThreads * numThreads1;
        }
    }

    return autoThreads;
}

} // namespace

// ============================================================
// SZArchive — main class
// ============================================================

@interface SZArchive () {
    CArchiveLink* _arcLink;
    BOOL _isOpen;
    NSString* _archivePath;
    NSString* _openType;
    NSString* _cachedPassword;
    BOOL _cachedPasswordIsDefined;
}
@end

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
        const char* message;
    } flagMessages[] = {
        { kpv_ErrorFlags_IsNotArc, "Is not archive" },
        { kpv_ErrorFlags_HeadersError, "Headers Error" },
        { kpv_ErrorFlags_EncryptedHeadersError,
            "Headers Error in encrypted archive. Wrong password?" },
        { kpv_ErrorFlags_UnavailableStart, "Unavailable start of archive" },
        { kpv_ErrorFlags_UnconfirmedStart, "Unconfirmed start of archive" },
        { kpv_ErrorFlags_UnexpectedEnd, "Unexpected end of data" },
        { kpv_ErrorFlags_DataAfterEnd, "Data after end of archive" },
        { kpv_ErrorFlags_UnsupportedMethod, "Unsupported method" },
        { kpv_ErrorFlags_UnsupportedFeature, "Unsupported feature" },
        { kpv_ErrorFlags_DataError, "Data Error" },
        { kpv_ErrorFlags_CrcError, "CRC Error" },
    };

    for (size_t index = 0; index < sizeof(flagMessages) / sizeof(flagMessages[0]);
        index++) {
        const auto& entry = flagMessages[index];
        if ((errorFlags & entry.flag) == 0) {
            continue;
        }
        [messages addObject:[NSString stringWithUTF8String:entry.message]];
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

static NSError* SZOpenArchiveErrorFromPasswordContext(
    HRESULT result, const CArcErrorInfo& errorInfo, BOOL passwordWasAsked) {
    if (result == E_ABORT) {
        return SZMakeError(SZArchiveErrorCodeUserCancelled,
            @"Operation was cancelled");
    }

    if (result != S_FALSE) {
        return SZMakeError(
            result, [NSString stringWithFormat:@"Failed to open archive (0x%08X)", (unsigned)result]);
    }

    const UInt32 errorFlags = errorInfo.GetErrorFlags();
    const BOOL wrongPassword = SZOpenErrorFlagsIndicateWrongPassword(errorFlags)
        || (passwordWasAsked && !errorInfo.ErrorFlags_Defined);
    if (wrongPassword) {
        return SZMakeError(SZArchiveErrorCodeWrongPassword,
            @"Cannot open encrypted archive. Wrong password?");
    }

    if (SZOpenErrorFlagsIndicateUnsupportedArchive(errorFlags)) {
        return SZMakeDetailedError(SZArchiveErrorCodeUnsupportedArchive,
            @"Cannot open archive or unsupported format",
            SZOpenArchiveFailureReason(errorInfo));
    }

    if (!errorInfo.IsArc_After_NonOpen() && errorInfo.ErrorMessage.IsEmpty()) {
        return SZMakeDetailedError(SZArchiveErrorCodeUnsupportedArchive,
            @"Cannot open archive or unsupported format",
            SZOpenArchiveFailureReason(errorInfo));
    }

    return SZMakeDetailedError(SZArchiveErrorCodeInvalidArchive,
        @"Cannot open archive",
        SZOpenArchiveFailureReason(errorInfo));
}

static NSError*
SZOpenArchiveErrorFromResult(HRESULT result, const CArcErrorInfo& errorInfo,
    const SZOpenCallbackUI& callbackUI) {
    return SZOpenArchiveErrorFromPasswordContext(result, errorInfo,
        callbackUI.PasswordWasAsked);
}

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

static HRESULT SZResolveFolderItemIndices(IFolderFolder* folder,
    NSArray<NSString*>* itemPaths,
    NSString* archiveSubdir,
    std::vector<UInt32>& indices) {
    indices.clear();

    NSString* normalizedSubdir = SZNormalizeArchiveRelativePath(archiveSubdir);
    UInt32 numItems = 0;
    RINOK(folder->GetNumberOfItems(&numItems))

    for (NSString* itemPath in itemPaths) {
        NSString* normalizedPath = SZNormalizeArchiveRelativePath(itemPath);
        if (![SZArchiveParentPath(normalizedPath)
                isEqualToString:normalizedSubdir]) {
            return E_INVALIDARG;
        }

        NSString* expectedName = SZArchiveLeafName(normalizedPath);
        if (expectedName.length == 0) {
            return E_INVALIDARG;
        }

        BOOL found = NO;
        for (UInt32 index = 0; index < numItems; index++) {
            NSString* itemName = SZFolderItemName(folder, index);
            if (![itemName isEqualToString:expectedName]) {
                continue;
            }
            indices.push_back(index);
            found = YES;
            break;
        }

        if (!found) {
            return E_INVALIDARG;
        }
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

static NSError* SZArchiveUpdateErrorFromResult(HRESULT result,
    NSString* fallbackDescription,
    const UString& errorMessage) {
    if (result == E_ABORT) {
        return SZMakeError(SZArchiveErrorCodeUserCancelled,
            @"Operation was cancelled");
    }

    if (result == E_NOTIMPL) {
        return SZMakeError(
            SZArchiveErrorCodeUnsupportedFormat,
            @"This archive does not support that in-place update operation.");
    }

    if (result == E_INVALIDARG) {
        return SZMakeError(result, @"Invalid archive item selection.");
    }

    if (result == (HRESULT)ERROR_ALREADY_EXISTS || result == HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)) {
        return SZMakeError(
            result, @"An item with the same name already exists in the archive.");
    }

    NSString* details = ToNS(errorMessage);
    if (details.length > 0) {
        return SZMakeDetailedError(result, fallbackDescription, details);
    }

    return SZMakeError(result, [NSString stringWithFormat:@"%@ (0x%08X)", fallbackDescription, (unsigned)result]);
}

@implementation SZArchive

+ (SZCompressionResourceInfo*)compressionResourceEstimateForSettings:
    (SZCompressionSettings*)settings {
    SZCompressionResourceInfo* info = [SZCompressionResourceInfo new];
    if (!settings) {
        return info;
    }

    const int methodID = SZCompressionEstimateMethodID(settings);
    if (methodID < 0) {
        return info;
    }

    const int level = SZCompressionEstimateLevel(settings);
    const UInt64 dict64 = SZCompressionEstimateDictionary(settings, methodID, level);
    if (dict64 != (UInt64)-1) {
        info.resolvedDictionarySizeIsDefined = YES;
        info.resolvedDictionarySize = dict64;
    }

    UInt32 wordSize = 0;
    if (SZCompressionEstimateWordSize(settings, methodID, level, wordSize)) {
        info.resolvedWordSizeIsDefined = YES;
        info.resolvedWordSize = wordSize;
    }

    const SZCompressionEstimateRamInfo ramInfo = SZCompressionEstimateGetRamInfo();
    UInt64 memoryUsageLimit = ramInfo.UsageAuto;
    const bool memoryUsageLimitIsDefined = SZCompressionEstimateGetMemoryUsageLimit(settings, ramInfo,
        memoryUsageLimit);

    UInt32 numThreads = settings.numThreads;
    if (!SZCompressionEstimateFormatSupportsThreads(settings.format)) {
        numThreads = 1;
    } else if (numThreads == 0) {
        numThreads = SZCompressionEstimateAutoThreads(settings, methodID, level,
            dict64, memoryUsageLimit,
            memoryUsageLimitIsDefined);
    }
    if (SZCompressionEstimateFormatSupportsThreads(settings.format)) {
        info.resolvedNumThreadsIsDefined = YES;
        info.resolvedNumThreads = numThreads;
    }

    if (!SZCompressionEstimateFormatSupportsMemoryUse(settings.format)) {
        return info;
    }

    UInt64 decompressionMemory;
    const UInt64 compressionMemory = SZCompressionEstimateMemoryUsage_Threads_Dict_DecompMem(
        settings.format, methodID, level, numThreads, dict64,
        decompressionMemory);
    if (compressionMemory != (UInt64)-1) {
        info.compressionMemoryIsDefined = YES;
        info.compressionMemory = compressionMemory;
    }
    if (decompressionMemory != (UInt64)-1) {
        info.decompressionMemoryIsDefined = YES;
        info.decompressionMemory = decompressionMemory;
    }
    if (memoryUsageLimitIsDefined) {
        info.memoryUsageLimitIsDefined = YES;
        info.memoryUsageLimit = memoryUsageLimit;
    }
    return info;
}

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

- (BOOL)reopenAfterExternalMutationWithSession:(SZOperationSession*)session
                                         error:(NSError**)error {
    NSString* archivePath = [_archivePath copy];
    NSString* openType = [_openType copy];
    NSString* password = _cachedPasswordIsDefined ? [_cachedPassword copy] : nil;
    if (archivePath.length == 0) {
        if (error) {
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open");
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
        _arcLink = new CArchiveLink;
        _isOpen = NO;
        _cachedPasswordIsDefined = NO;
    }
    return self;
}

- (void)dealloc {
    [self close];
    delete _arcLink;
    _arcLink = nullptr;
}

+ (NSString*)sevenZipVersionString {
    return @MY_VERSION;
}

// MARK: - Open / Close

- (BOOL)openAtPath:(NSString*)path error:(NSError**)error {
    return [self openAtPath:path
                   openType:nil
                   password:nil
                    session:nil
                      error:error];
}

- (BOOL)openAtPath:(NSString*)path
          progress:(id<SZProgressDelegate>)progress
             error:(NSError**)error {
    return [self openAtPath:path password:nil progress:progress error:error];
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
          progress:(id<SZProgressDelegate>)progress
             error:(NSError**)error {
    return [self openAtPath:path
                   password:password
                    session:SZMakeDefaultOperationSession(progress)
                      error:error];
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
    CCodecs* codecs = SZGetCodecs();
    if (!codecs) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeFailedToInitCodecs,
                @"Failed to init codecs");
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
                    stringWithFormat:@"Invalid archive open type: %@", openType]);
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

    SZOperationSession* resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZOpenCallbackUI callbackUI;
    callbackUI.Session = resolvedSession;
    if (password) {
        callbackUI.PasswordIsDefined = true;
        callbackUI.Password = ToU(password);
    }

    HRESULT res = _arcLink->Open3(options, &callbackUI);
    if (res != S_OK) {
        if (error) {
            *error = SZOpenArchiveErrorFromResult(res, _arcLink->NonOpen_ErrorInfo,
                callbackUI);
        }
        return NO;
    }

    if (callbackUI.PasswordIsDefined) {
        [self storeCachedPassword:callbackUI.Password defined:true];
    }
    _openType = [openType copy];
    _isOpen = YES;
    return YES;
}

- (void)close {
    if (_isOpen)
        _arcLink->Close();
    _isOpen = NO;
    _openType = nil;
    [self clearCachedPassword];
}

// MARK: - Properties

- (NSString*)formatName {
    if (!_isOpen)
        return nil;
    const CArc& arc = _arcLink->Arcs.Back();
    CCodecs* c = SZGetCodecs();
    if (!c || arc.FormatIndex < 0)
        return nil;
    return ToNS(c->Formats[arc.FormatIndex].Name);
}

- (uint64_t)archivePhysicalSize {
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
    if (!_isOpen)
        return 0;
    IInArchive* archive = _arcLink->GetArchive();
    if (!archive)
        return 0;
    UInt32 n = 0;
    archive->GetNumberOfItems(&n);
    return n;
}

- (NSArray<SZArchiveEntry*>*)entries {
    if (!_isOpen)
        return @[];
    IInArchive* archive = _arcLink->GetArchive();
    if (!archive)
        return @[];
    const CArc& arc = _arcLink->Arcs.Back();
    UInt32 n = 0;
    archive->GetNumberOfItems(&n);
    NSMutableArray* arr = [NSMutableArray arrayWithCapacity:n];
    for (UInt32 i = 0; i < n; i++) {
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

static BOOL CheckExtractResult(SZFolderExtractCallback* fae, HRESULT r,
    NSError** error) {
    if (r == S_OK && fae->PasswordWasWrong) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeWrongPassword, @"Wrong password");
        return NO;
    }
    if (r == S_OK && fae->NumErrors > 0) {
        NSString* title =
            [NSString stringWithFormat:@"Completed with %u error%@", fae->NumErrors,
                fae->NumErrors == 1 ? @"" : @"s"];
        NSString* failureReason = fae->LastErrorMessage.IsEmpty() ? nil : ToNS(fae->LastErrorMessage);
        if (error)
            *error = SZMakeDetailedError(SZArchiveErrorCodePartialFailure, title,
                failureReason);
        return NO;
    }
    if (r != S_OK) {
        if (error)
            *error = SZMakeError(r == E_ABORT ? SZArchiveErrorCodeUserCancelled
                                              : SZArchiveErrorCodeExtractionFailed,
                r == E_ABORT ? @"Cancelled" : @"Extraction failed");
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
            [NSString stringWithFormat:@"Can't create folder \"%@\"", dest],
            failureReason);
    }

    return NO;
}

// MARK: - Extract

- (BOOL)extractToPath:(NSString*)dest
             settings:(SZExtractionSettings*)s
             progress:(id<SZProgressDelegate>)p
                error:(NSError**)error {
    return [self extractToPath:dest
                      settings:s
                       session:SZMakeDefaultOperationSession(p)
                         error:error];
}

- (BOOL)extractToPath:(NSString*)dest
             settings:(SZExtractionSettings*)s
              session:(SZOperationSession*)session
                error:(NSError**)error {
    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open");
        return NO;
    }
    IInArchive* archive = _arcLink->GetArchive();
    const CArc& arc = _arcLink->Arcs.Back();
    if (!EnsureExtractionDirectoryExists(dest, error)) {
        return NO;
    }

    SZOperationSession* resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZFolderExtractCallback* faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Session = resolvedSession;
    faeSpec->OverwriteMode = s.overwriteMode;
    faeSpec->ArchivePath = ToU(_archivePath);
    faeSpec->TestMode = false;
    NSData* quarantineData = s.sourceArchivePathForQuarantine ? SZQuarantineDataForArchivePath(s.sourceArchivePathForQuarantine) : nil;
    [self configureExtractPasswordForCallback:faeSpec
                             explicitPassword:s.password];

    CArchiveExtractCallback* ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);
    CExtractNtOptions ntOptions;
    if (s.preserveNtSecurityInfo) {
        ntOptions.NtSecurity.Def = true;
        ntOptions.NtSecurity.Val = true;
    }
    UStringVector removePathParts = BuildRemovePathParts(s.pathPrefixToStrip);

    ecs->InitForMulti(false, MapPathMode(s.pathMode),
        MapOverwriteMode(s.overwriteMode),
        NExtract::NZoneIdMode::kNone, false);
    if (quarantineData.length > 0) {
        ecs->ZoneBuf.CopyFrom((const Byte*)quarantineData.bytes, quarantineData.length);
    }
    ecs->Init(ntOptions, NULL, &arc, faeCallback, false, false, us2fs(ToU(dest)),
        removePathParts, false, arc.GetEstmatedPhySize());

    HRESULT r = archive->Extract(nullptr, (UInt32)(Int32)-1, 0, ec);
    [self updateCachedPasswordFromExtractCallback:faeSpec result:r];
    return CheckExtractResult(faeSpec, r, error);
}

- (BOOL)extractEntries:(NSArray<NSNumber*>*)indices
                toPath:(NSString*)dest
              settings:(SZExtractionSettings*)s
              progress:(id<SZProgressDelegate>)p
                 error:(NSError**)error {
    return [self extractEntries:indices
                         toPath:dest
                       settings:s
                        session:SZMakeDefaultOperationSession(p)
                          error:error];
}

- (BOOL)extractEntries:(NSArray<NSNumber*>*)indices
                toPath:(NSString*)dest
              settings:(SZExtractionSettings*)s
               session:(SZOperationSession*)session
                 error:(NSError**)error {
    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open");
        return NO;
    }
    IInArchive* archive = _arcLink->GetArchive();
    const CArc& arc = _arcLink->Arcs.Back();
    if (!EnsureExtractionDirectoryExists(dest, error)) {
        return NO;
    }

    SZOperationSession* resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZFolderExtractCallback* faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Session = resolvedSession;
    faeSpec->OverwriteMode = s.overwriteMode;
    faeSpec->ArchivePath = ToU(_archivePath);
    faeSpec->TestMode = false;
    NSData* quarantineData = s.sourceArchivePathForQuarantine ? SZQuarantineDataForArchivePath(s.sourceArchivePathForQuarantine) : nil;
    [self configureExtractPasswordForCallback:faeSpec
                             explicitPassword:s.password];

    CArchiveExtractCallback* ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);
    CExtractNtOptions ntOptions;
    if (s.preserveNtSecurityInfo) {
        ntOptions.NtSecurity.Def = true;
        ntOptions.NtSecurity.Val = true;
    }
    UStringVector removePathParts = BuildRemovePathParts(s.pathPrefixToStrip);

    ecs->InitForMulti(false, MapPathMode(s.pathMode),
        MapOverwriteMode(s.overwriteMode),
        NExtract::NZoneIdMode::kNone, false);
    if (quarantineData.length > 0) {
        ecs->ZoneBuf.CopyFrom((const Byte*)quarantineData.bytes, quarantineData.length);
    }
    ecs->Init(ntOptions, NULL, &arc, faeCallback, false, false, us2fs(ToU(dest)),
        removePathParts, false, arc.GetEstmatedPhySize());

    std::vector<UInt32> ia;
    ia.reserve(indices.count);
    for (NSNumber* n in indices)
        ia.push_back([n unsignedIntValue]);
    HRESULT r = archive->Extract(ia.data(), (UInt32)ia.size(), 0, ec);
    [self updateCachedPasswordFromExtractCallback:faeSpec result:r];
    return CheckExtractResult(faeSpec, r, error);
}

- (BOOL)testWithProgress:(id<SZProgressDelegate>)p error:(NSError**)error {
    return [self testWithSession:SZMakeDefaultOperationSession(p) error:error];
}

- (BOOL)testWithSession:(SZOperationSession*)session error:(NSError**)error {
    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open");
        return NO;
    }
    IInArchive* archive = _arcLink->GetArchive();
    const CArc& arc = _arcLink->Arcs.Back();

    SZOperationSession* resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZFolderExtractCallback* faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Session = resolvedSession;
    faeSpec->ArchivePath = ToU(_archivePath);
    faeSpec->TestMode = true;
    [self configureExtractPasswordForCallback:faeSpec explicitPassword:nil];

    CArchiveExtractCallback* ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);
    CExtractNtOptions ntOptions;
    UStringVector removePathParts;

    ecs->InitForMulti(false, NExtract::NPathMode::kFullPaths,
        NExtract::NOverwriteMode::kOverwrite,
        NExtract::NZoneIdMode::kNone, false);
    ecs->Init(ntOptions, NULL, &arc, faeCallback, false, true, FString(),
        removePathParts, false, arc.GetEstmatedPhySize());

    HRESULT r = archive->Extract(nullptr, (UInt32)(Int32)-1, 1, ec);
    [self updateCachedPasswordFromExtractCallback:faeSpec result:r];
    return CheckExtractResult(faeSpec, r, error);
}

- (BOOL)createFolderNamed:(NSString*)folderName
          inArchiveSubdir:(NSString*)archiveSubdir
                  session:(SZOperationSession*)session
                    error:(NSError**)error {
    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open");
        return NO;
    }

    SZOperationSession* resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZAgentUpdateCallback* updateSpec = new SZAgentUpdateCallback;
    CMyComPtr<IFolderArchiveUpdateCallback> updateCallback(updateSpec);
    updateSpec->Session = resolvedSession;
    updateSpec->ArchivePath = ToU(_archivePath ?: @"");
    if (_cachedPasswordIsDefined) {
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
                result, errorInfo, updateSpec->PasswordWasAsked);
        }
        return NO;
    }

    CMyComPtr<IFolderOperations> folderOperations;
    folder.QueryInterface(IID_IFolderOperations, &folderOperations);
    if (!folderOperations) {
        if (error) {
            *error = SZMakeError(SZArchiveErrorCodeUnsupportedFormat,
                @"This archive does not support in-place updates.");
        }
        return NO;
    }

    result = folderOperations->CreateFolder(ToU(folderName), updateCallback);

    if (updateSpec->PasswordIsDefined && (result == S_OK || updateSpec->ArchiveWasReplaced)) {
        [self storeCachedPassword:updateSpec->Password defined:true];
    }

    if ((result == S_OK || updateSpec->ArchiveWasReplaced) && ![self reopenAfterExternalMutationWithSession:resolvedSession
                                                                                                      error:error]) {
        return NO;
    }

    if (result != S_OK) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(
                result, @"Cannot create folder in archive",
                updateSpec->LastErrorMessage);
        }
        return NO;
    }

    return YES;
}

- (BOOL)renameItemAtPath:(NSString*)itemPath
         inArchiveSubdir:(NSString*)archiveSubdir
                 newName:(NSString*)newName
                 session:(SZOperationSession*)session
                   error:(NSError**)error {
    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open");
        return NO;
    }

    SZOperationSession* resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZAgentUpdateCallback* updateSpec = new SZAgentUpdateCallback;
    CMyComPtr<IFolderArchiveUpdateCallback> updateCallback(updateSpec);
    updateSpec->Session = resolvedSession;
    updateSpec->ArchivePath = ToU(_archivePath ?: @"");
    if (_cachedPasswordIsDefined) {
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
                result, errorInfo, updateSpec->PasswordWasAsked);
        }
        return NO;
    }

    std::vector<UInt32> indices;
    result = SZResolveFolderItemIndices(folder, @[ itemPath ], archiveSubdir, indices);
    if (result != S_OK || indices.size() != 1) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(
                E_INVALIDARG, @"Cannot rename item in archive", UString());
        }
        return NO;
    }

    CMyComPtr<IFolderOperations> folderOperations;
    folder.QueryInterface(IID_IFolderOperations, &folderOperations);
    if (!folderOperations) {
        if (error) {
            *error = SZMakeError(SZArchiveErrorCodeUnsupportedFormat,
                @"This archive does not support in-place updates.");
        }
        return NO;
    }

    result = folderOperations->Rename(indices[0], ToU(newName), updateCallback);

    if (updateSpec->PasswordIsDefined && (result == S_OK || updateSpec->ArchiveWasReplaced)) {
        [self storeCachedPassword:updateSpec->Password defined:true];
    }

    if ((result == S_OK || updateSpec->ArchiveWasReplaced) && ![self reopenAfterExternalMutationWithSession:resolvedSession
                                                                                                      error:error]) {
        return NO;
    }

    if (result != S_OK) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(result,
                @"Cannot rename item in archive",
                updateSpec->LastErrorMessage);
        }
        return NO;
    }

    return YES;
}

- (BOOL)deleteItemsAtPaths:(NSArray<NSString*>*)itemPaths
           inArchiveSubdir:(NSString*)archiveSubdir
                   session:(SZOperationSession*)session
                     error:(NSError**)error {
    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open");
        return NO;
    }

    SZOperationSession* resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZAgentUpdateCallback* updateSpec = new SZAgentUpdateCallback;
    CMyComPtr<IFolderArchiveUpdateCallback> updateCallback(updateSpec);
    updateSpec->Session = resolvedSession;
    updateSpec->ArchivePath = ToU(_archivePath ?: @"");
    if (_cachedPasswordIsDefined) {
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
                result, errorInfo, updateSpec->PasswordWasAsked);
        }
        return NO;
    }

    std::vector<UInt32> indices;
    result = SZResolveFolderItemIndices(folder, itemPaths, archiveSubdir, indices);
    if (result != S_OK || indices.empty()) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(
                E_INVALIDARG, @"Cannot delete items from archive", UString());
        }
        return NO;
    }

    CMyComPtr<IFolderOperations> folderOperations;
    folder.QueryInterface(IID_IFolderOperations, &folderOperations);
    if (!folderOperations) {
        if (error) {
            *error = SZMakeError(SZArchiveErrorCodeUnsupportedFormat,
                @"This archive does not support in-place updates.");
        }
        return NO;
    }

    result = folderOperations->Delete(indices.data(), (UInt32)indices.size(),
        updateCallback);

    if (updateSpec->PasswordIsDefined && (result == S_OK || updateSpec->ArchiveWasReplaced)) {
        [self storeCachedPassword:updateSpec->Password defined:true];
    }

    if ((result == S_OK || updateSpec->ArchiveWasReplaced) && ![self reopenAfterExternalMutationWithSession:resolvedSession
                                                                                                      error:error]) {
        return NO;
    }

    if (result != S_OK) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(
                result, @"Cannot delete items from archive",
                updateSpec->LastErrorMessage);
        }
        return NO;
    }

    return YES;
}

- (BOOL)addPaths:(NSArray<NSString*>*)sourcePaths
    toArchiveSubdir:(NSString*)archiveSubdir
           moveMode:(BOOL)moveMode
            session:(SZOperationSession*)session
              error:(NSError**)error {
    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open");
        return NO;
    }

    if (sourcePaths.count == 0) {
        return YES;
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
                *error = SZMakeError(E_INVALIDARG, @"Invalid source path.");
            }
            return NO;
        }

        if (!folderPrefix) {
            folderPrefix = parentPath;
        } else if (![folderPrefix isEqualToString:parentPath]) {
            if (error) {
                *error = SZMakeError(E_INVALIDARG, @"All items added to an open archive "
                                                   @"must come from the same folder.");
            }
            return NO;
        }

        [normalizedPaths addObject:standardizedPath];
        pathStorage.push_back(ToU(leafName));
    }

    std::vector<const wchar_t*> pathPointers;
    pathPointers.reserve(pathStorage.size());
    for (const UString& path : pathStorage) {
        pathPointers.push_back(path.Ptr());
    }

    SZOperationSession* resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZAgentUpdateCallback* updateSpec = new SZAgentUpdateCallback;
    CMyComPtr<IFolderArchiveUpdateCallback> updateCallback(updateSpec);
    updateSpec->Session = resolvedSession;
    updateSpec->ArchivePath = ToU(_archivePath ?: @"");
    if (_cachedPasswordIsDefined) {
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
                result, errorInfo, updateSpec->PasswordWasAsked);
        }
        return NO;
    }

    CMyComPtr<IFolderOperations> folderOperations;
    folder.QueryInterface(IID_IFolderOperations, &folderOperations);
    if (!folderOperations) {
        if (error) {
            *error = SZMakeError(SZArchiveErrorCodeUnsupportedFormat,
                @"This archive does not support in-place updates.");
        }
        return NO;
    }

    result = folderOperations->CopyFrom(
        moveMode ? 1 : 0, ToU(folderPrefix ?: @"").Ptr(), pathPointers.data(),
        (UInt32)pathPointers.size(), updateCallback);

    if (updateSpec->PasswordIsDefined && (result == S_OK || updateSpec->ArchiveWasReplaced)) {
        [self storeCachedPassword:updateSpec->Password defined:true];
    }

    if ((result == S_OK || updateSpec->ArchiveWasReplaced) && ![self reopenAfterExternalMutationWithSession:resolvedSession
                                                                                                      error:error]) {
        return NO;
    }

    if (result != S_OK) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(result,
                @"Cannot update archive contents",
                updateSpec->LastErrorMessage);
        }
        return NO;
    }

    return YES;
}

- (BOOL)replaceItemAtPath:(NSString*)itemPath
          inArchiveSubdir:(NSString*)archiveSubdir
           withFileAtPath:(NSString*)sourceFilePath
                  session:(SZOperationSession*)session
                    error:(NSError**)error {
    if (!_isOpen) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open");
        return NO;
    }

    NSString* standardizedSourcePath =
        [NSURL fileURLWithPath:sourceFilePath].standardizedURL.path;
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:standardizedSourcePath]) {
        if (error) {
            *error = SZMakeError(E_INVALIDARG,
                @"The updated nested archive file is missing.");
        }
        return NO;
    }

    SZOperationSession* resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZAgentUpdateCallback* updateSpec = new SZAgentUpdateCallback;
    CMyComPtr<IFolderArchiveUpdateCallback> updateCallback(updateSpec);
    updateSpec->Session = resolvedSession;
    updateSpec->ArchivePath = ToU(_archivePath ?: @"");
    if (_cachedPasswordIsDefined) {
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
                result, errorInfo, updateSpec->PasswordWasAsked);
        }
        return NO;
    }

    std::vector<UInt32> indices;
    result = SZResolveFolderItemIndices(folder, @[ itemPath ], archiveSubdir, indices);
    if (result != S_OK || indices.size() != 1) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(
                E_INVALIDARG, @"Cannot update nested archive in parent archive",
                UString());
        }
        return NO;
    }

    CMyComPtr<IFolderOperations> folderOperations;
    folder.QueryInterface(IID_IFolderOperations, &folderOperations);
    if (!folderOperations) {
        if (error) {
            *error = SZMakeError(SZArchiveErrorCodeUnsupportedFormat,
                @"This archive does not support in-place updates.");
        }
        return NO;
    }

    result = folderOperations->CopyFromFile(
        indices[0], ToU(standardizedSourcePath).Ptr(), updateCallback);

    if (updateSpec->PasswordIsDefined && (result == S_OK || updateSpec->ArchiveWasReplaced)) {
        [self storeCachedPassword:updateSpec->Password defined:true];
    }

    if ((result == S_OK || updateSpec->ArchiveWasReplaced) && ![self reopenAfterExternalMutationWithSession:resolvedSession
                                                                                                      error:error]) {
        return NO;
    }

    if (result != S_OK) {
        if (error) {
            *error = SZArchiveUpdateErrorFromResult(
                result, @"Cannot update nested archive in parent archive",
                updateSpec->LastErrorMessage);
        }
        return NO;
    }

    return YES;
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
    default:
        return UString();
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

    if (settings.format == SZArchiveFormatZip && settings.encryption == SZEncryptionMethodAES256) {
        return UString(L"AES256");
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

// MARK: - Create

+ (BOOL)createAtPath:(NSString*)archivePath
           fromPaths:(NSArray<NSString*>*)src
            settings:(SZCompressionSettings*)s
            progress:(id<SZProgressDelegate>)p
               error:(NSError**)error {
    return [self createAtPath:archivePath
                    fromPaths:src
                     settings:s
                      session:SZMakeDefaultOperationSession(p)
                        error:error];
}

+ (BOOL)createAtPath:(NSString*)archivePath
           fromPaths:(NSArray<NSString*>*)src
            settings:(SZCompressionSettings*)s
             session:(SZOperationSession*)session
               error:(NSError**)error {
    CCodecs* codecs = SZGetCodecs();
    if (!codecs) {
        if (error)
            *error = SZMakeError(-1, @"Failed to init codecs");
        return NO;
    }

    const int methodID = SZCompressionEstimateMethodID(s);

    NSString* formatName = SZArchiveCodecNameForCreateFormat(s.format);
    if (formatName.length == 0) {
        if (error)
            *error = SZMakeError(SZArchiveErrorCodeUnsupportedFormat,
                @"Unsupported format");
        return NO;
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

    if (s.createSFX) {
        const int sfxMethodID = methodID;
        if (s.format != SZArchiveFormat7z || !SZCompressionEstimateMethodSupportsSFX(sfxMethodID)) {
            if (error)
                *error = SZMakeError(-8, @"The selected compression method does not "
                                         @"support Windows SFX archives.");
            return NO;
        }
        if (!SZLocateBundledWindowsSfxModule(options.SfxModule)) {
            if (error)
                *error = SZMakeError(
                    -1,
                    @"The Windows SFX module is missing from the application bundle.");
            return NO;
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
            *error = SZMakeError(-8, @"Unsupported format");
        return NO;
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
                *error = SZMakeError(-1, @"Invalid split volume sizes.");
            return NO;
        }
    } else if (s.splitVolumeSize > 0) {
        options.VolumesSizes.Add(s.splitVolumeSize);
    }

    if (s.createSFX && options.VolumesSizes.Size() > 0) {
        if (error)
            *error = SZMakeError(
                -1, @"Windows SFX archives cannot be split into volumes.");
        return NO;
    }

    NWildcard::CCensor censor;
    for (NSString* srcPath in src) {
        censor.AddPreItem_NoWildcard(ToU(srcPath));
    }
    if (s.excludeMacResourceFiles) {
        SZAddMacResourceFileExcludes(censor);
    }

    SZOperationSession* resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZUpdateCallbackUI callbackUI;
    callbackUI.Session = resolvedSession;
    if (s.password.length > 0) {
        callbackUI.PasswordIsDefined = true;
        callbackUI.Password = ToU(s.password);
    }

    SZOpenCallbackUI openCallbackUI;
    openCallbackUI.Session = resolvedSession;
    CUpdateErrorInfo errorInfo;
    CObjectVector<COpenType> types;

    HRESULT r = UpdateArchive(codecs, types, ToU(archivePath), censor, options,
        errorInfo, &openCallbackUI, &callbackUI, true);

    if (r != S_OK) {
        NSString* desc;
        if (r == E_ABORT)
            desc = @"Compression was cancelled";
        else if (errorInfo.Message.Len() > 0)
            desc = [NSString stringWithUTF8String:errorInfo.Message.Ptr()];
        else
            desc = [NSString
                stringWithFormat:@"Compression failed (0x%08X)", (unsigned)r];
        if (error)
            *error = SZMakeError(r, desc);
        return NO;
    }
    return YES;
}

// MARK: - Formats

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
    CCodecs* codecs = SZGetCodecs();
    if (!codecs) {
        if (error)
            *error = SZMakeError(-1, @"Failed to init codecs");
        return nil;
    }

    CHashOptions options;
    options.Methods.Add(UString(L"CRC32"));
    options.Methods.Add(UString(L"CRC64"));
    options.Methods.Add(UString(L"XXH64"));
    options.Methods.Add(UString(L"MD5"));
    options.Methods.Add(UString(L"SHA1"));
    options.Methods.Add(UString(L"SHA256"));
    options.Methods.Add(UString(L"SHA384"));
    options.Methods.Add(UString(L"SHA512"));
    options.Methods.Add(UString(L"SHA3-256"));
    options.Methods.Add(UString(L"BLAKE2sp"));

    NWildcard::CCensor censor;
    NWildcard::CCensorPathProps props;
    props.Recursive = false;
    censor.AddItem(NWildcard::k_AbsPath, true, ToU(path), props);

    class HashCB : public IHashCallbackUI {
    public:
        __unsafe_unretained SZOperationSession* session;
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

        HRESULT StartScanning() override { return CheckBreak(); }
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
            if (session && name) {
                [session reportCurrentFileName:ToNS(UString(name))];
            }
            return CheckBreak();
        }
        HRESULT OpenFileError(const FString& path, DWORD errorCode) override {
            RecordFailure(L"Unable to open file for hashing.", path, errorCode);
            return S_FALSE;
        }
        HRESULT SetOperationResult(UInt64, const CHashBundle& hb, bool) override {
            for (unsigned i = 0; i < hb.Hashers.Size(); i++) {
                const CHasherState& h = hb.Hashers[i];
                char hex[256];
                HashHexToString(hex, h.Digests[0], h.DigestSize);
                results[[NSString stringWithUTF8String:h.Name.Ptr()]] =
                    [NSString stringWithUTF8String:hex];
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
            RecordFailure(L"Unable to scan file for hashing.", path, errorCode);
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
        void RecordFailure(const wchar_t* description, const FString& path,
            DWORD errorCode) {
            if (HasFailure()) {
                return;
            }

            failureDescription = description;
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
                ? @"Hash calculation failed"
                : ToNS(cb.failureDescription);
            NSString* reason = cb.failureReason.IsEmpty() ? nil : ToNS(cb.failureReason);
            *error = SZMakeDetailedError(cb.failureResult, description, reason);
        }
        return nil;
    }

    if (r != S_OK) {
        NSString* reason = errorInfo.IsEmpty()
            ? nil
            : [NSString stringWithUTF8String:errorInfo.Ptr()];
        if (error)
            *error = SZMakeDetailedError(r, @"Hash calculation failed", reason);
        return nil;
    }

    return cb.results;
}

@end
