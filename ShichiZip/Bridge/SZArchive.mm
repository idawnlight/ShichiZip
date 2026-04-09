// SZArchive.mm — Main archive interface implementation

#include "SZBridgeCommon.h"
#include "SZCallbacks.h"

#import "../Utilities/SZOperationSessionDefaults.h"

#include "CPP/7zip/UI/Common/ArchiveExtractCallback.h"
#include "CPP/7zip/UI/Common/Extract.h"
#include "CPP/7zip/UI/Common/Update.h"
#include "CPP/7zip/UI/Common/UpdateCallback.h"
#include "CPP/7zip/UI/Common/EnumDirItems.h"
#include "CPP/7zip/UI/Common/SetProperties.h"
#include "CPP/7zip/UI/Common/Bench.h"
#include "CPP/7zip/UI/Common/HashCalc.h"
#include "CPP/7zip/UI/Common/OpenArchive.h"
#include "CPP/7zip/Common/MethodProps.h"
#include "CPP/Common/MyString.h"
#include "CPP/Common/StringToInt.h"
#include "CPP/Common/Wildcard.h"
#include "CPP/Windows/ErrorMsg.h"
#include "CPP/Windows/System.h"
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
        _pathMode = SZPathModeFullPaths; _overwriteMode = SZOverwriteModeAsk;
        _preserveNtSecurityInfo = NO;
    }
    return self;
}
@end

@implementation SZArchiveEntry @end
@implementation SZFormatInfo @end
@implementation SZCompressionResourceInfo @end
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
    kSZCompressionEstimateGnu,
    kSZCompressionEstimatePosix,
};

static const UInt32 kSZCompressionEstimateLzmaMaxDictSize = (UInt32)15 << 28;

struct SZCompressionEstimateRamInfo {
    bool IsDefined;
    UInt64 UsageAuto;
};

static bool SZCompressionEstimateFormatSupportsFilters(SZArchiveFormat format) {
    return format == SZArchiveFormat7z;
}

static bool SZCompressionEstimateFormatSupportsThreads(SZArchiveFormat format) {
    switch (format) {
        case SZArchiveFormat7z:
        case SZArchiveFormatZip:
        case SZArchiveFormatBZip2:
        case SZArchiveFormatXz:
            return true;
        default:
            return false;
    }
}

static bool SZCompressionEstimateFormatSupportsMemoryUse(SZArchiveFormat format) {
    switch (format) {
        case SZArchiveFormat7z:
        case SZArchiveFormatZip:
        case SZArchiveFormatGZip:
        case SZArchiveFormatBZip2:
        case SZArchiveFormatXz:
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

static UInt32 SZCompressionEstimateLevel(SZCompressionSettings *settings) {
    const NSInteger level = settings.level;
    return level < 0 ? 5u : (UInt32)level;
}

static int SZCompressionEstimateMethodID(SZCompressionSettings *settings) {
    NSString *methodName = settings.methodName ? settings.methodName.lowercaseString : @"";
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
            return settings.format == SZArchiveFormatZip ? kSZCompressionEstimatePPMdZip : kSZCompressionEstimatePPMd;
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
        default:
            break;
    }

    switch (settings.method) {
        case SZCompressionMethodLZMA:
            return kSZCompressionEstimateLZMA;
        case SZCompressionMethodLZMA2:
            return kSZCompressionEstimateLZMA2;
        case SZCompressionMethodPPMd:
            return settings.format == SZArchiveFormatZip ? kSZCompressionEstimatePPMdZip : kSZCompressionEstimatePPMd;
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
    info.UsageAuto = Calc_From_Val_Percents(size, 80);
    return info;
}

static void SZCompressionEstimateGetCpuThreadCounts(UInt32 &numCPUs,
                                                    UInt32 &numHardwareThreads) {
    numCPUs = 1;
    numHardwareThreads = 1;

    NWindows::NSystem::CProcessAffinity threadsInfo;
    threadsInfo.InitST();

#ifdef _WIN32
#ifndef Z7_ST
    threadsInfo.Get_and_return_NumProcessThreads_and_SysThreads(numCPUs, numHardwareThreads);
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

static UInt64 SZCompressionEstimateAutoDictionary(int methodID, UInt32 level) {
    switch (methodID) {
        case kSZCompressionEstimateLZMA:
        case kSZCompressionEstimateLZMA2:
            return level <= 4
                ? (UInt64)1 << (level * 2 + 16)
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

        default:
            return (UInt64)-1;
    }
}

static UInt64 SZCompressionEstimateDictionary(SZCompressionSettings *settings,
                                              int methodID,
                                              UInt32 level) {
    if (settings.dictionarySize > 0) {
        return settings.dictionarySize;
    }
    return SZCompressionEstimateAutoDictionary(methodID, level);
}

static UInt64 SZCompressionEstimateMemoryUsage_Threads_Dict_DecompMem(SZArchiveFormat format,
                                                                      int methodID,
                                                                      UInt32 level,
                                                                      UInt32 numThreads,
                                                                      UInt64 dict64,
                                                                      UInt64 &decompressMemory) {
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
                UInt64 blockSize = (UInt64)dict + (1 << 16)
                    + (numThreads1 > 1 ? (1 << 20) : 0);
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

        default:
            return (UInt64)-1;
    }
}

static UInt32 SZCompressionEstimateAutoThreads(SZCompressionSettings *settings,
                                               int methodID,
                                               UInt32 level,
                                               UInt64 dict64,
                                               const SZCompressionEstimateRamInfo &ramInfo) {
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

    if (ramInfo.IsDefined && autoThreads > 1) {
        if (SZCompressionEstimateIsZipFormat(settings.format)) {
            for (; autoThreads > 1; autoThreads--) {
                UInt64 decompressMemory;
                const UInt64 usage = SZCompressionEstimateMemoryUsage_Threads_Dict_DecompMem(settings.format,
                                                                                            methodID,
                                                                                            level,
                                                                                            autoThreads,
                                                                                            dict64,
                                                                                            decompressMemory);
                if (usage <= ramInfo.UsageAuto) {
                    break;
                }
            }
        } else if (methodID == kSZCompressionEstimateLZMA2) {
            const UInt32 numThreads1 = (level >= 5 ? 2 : 1);
            UInt32 numBlockThreads = autoThreads / numThreads1;
            for (; numBlockThreads > 1; numBlockThreads--) {
                autoThreads = numBlockThreads * numThreads1;
                UInt64 decompressMemory;
                const UInt64 usage = SZCompressionEstimateMemoryUsage_Threads_Dict_DecompMem(settings.format,
                                                                                            methodID,
                                                                                            level,
                                                                                            autoThreads,
                                                                                            dict64,
                                                                                            decompressMemory);
                if (usage <= ramInfo.UsageAuto) {
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
    CArchiveLink *_arcLink;
    BOOL _isOpen;
    NSString *_archivePath;
    NSString *_cachedPassword;
    BOOL _cachedPasswordIsDefined;
}
@end

static BOOL SZOpenErrorFlagsIndicateWrongPassword(UInt32 errorFlags) {
    return (errorFlags & (kpv_ErrorFlags_EncryptedHeadersError |
                          kpv_ErrorFlags_DataError |
                          kpv_ErrorFlags_CrcError)) != 0;
}

static NSString *SZOpenArchiveFlagDetails(UInt32 errorFlags) {
    NSMutableArray<NSString *> *messages = [NSMutableArray array];

    const struct {
        UInt32 flag;
        const char *message;
    } flagMessages[] = {
        { kpv_ErrorFlags_IsNotArc, "Is not archive" },
        { kpv_ErrorFlags_HeadersError, "Headers Error" },
        { kpv_ErrorFlags_EncryptedHeadersError, "Headers Error in encrypted archive. Wrong password?" },
        { kpv_ErrorFlags_UnavailableStart, "Unavailable start of archive" },
        { kpv_ErrorFlags_UnconfirmedStart, "Unconfirmed start of archive" },
        { kpv_ErrorFlags_UnexpectedEnd, "Unexpected end of data" },
        { kpv_ErrorFlags_DataAfterEnd, "Data after end of archive" },
        { kpv_ErrorFlags_UnsupportedMethod, "Unsupported method" },
        { kpv_ErrorFlags_UnsupportedFeature, "Unsupported feature" },
        { kpv_ErrorFlags_DataError, "Data Error" },
        { kpv_ErrorFlags_CrcError, "CRC Error" },
    };

    for (size_t index = 0; index < sizeof(flagMessages) / sizeof(flagMessages[0]); index++) {
        const auto &entry = flagMessages[index];
        if ((errorFlags & entry.flag) == 0) {
            continue;
        }
        [messages addObject:[NSString stringWithUTF8String:entry.message]];
    }

    return messages.count > 0 ? [messages componentsJoinedByString:@"\n"] : nil;
}

static NSString *SZOpenArchiveFailureReason(const CArcErrorInfo &errorInfo) {
    NSMutableArray<NSString *> *messages = [NSMutableArray array];

    NSString *flagDetails = SZOpenArchiveFlagDetails(errorInfo.GetErrorFlags());
    if (flagDetails.length > 0) {
        [messages addObject:flagDetails];
    }

    NSString *errorMessage = ToNS(errorInfo.ErrorMessage);
    if (errorMessage.length > 0 && ![messages containsObject:errorMessage]) {
        [messages addObject:errorMessage];
    }

    return messages.count > 0 ? [messages componentsJoinedByString:@"\n"] : nil;
}

static NSError *SZOpenArchiveErrorFromResult(HRESULT result,
                                             const CArcErrorInfo &errorInfo,
                                             const SZOpenCallbackUI &callbackUI) {
    if (result == E_ABORT) {
        return SZMakeError(SZArchiveErrorCodeUserCancelled, @"Operation was cancelled");
    }

    if (result != S_FALSE) {
        return SZMakeError(result,
                           [NSString stringWithFormat:@"Failed to open archive (0x%08X)", (unsigned)result]);
    }

    const UInt32 errorFlags = errorInfo.GetErrorFlags();
    const BOOL hadPasswordContext = callbackUI.PasswordWasAsked || callbackUI.PasswordIsDefined;
    const BOOL wrongPassword = (hadPasswordContext &&
                                (errorFlags & (kpv_ErrorFlags_HeadersError |
                                               kpv_ErrorFlags_EncryptedHeadersError |
                                               kpv_ErrorFlags_DataError |
                                               kpv_ErrorFlags_CrcError)) != 0)
        || (callbackUI.PasswordWasAsked && !errorInfo.ErrorFlags_Defined)
        || SZOpenErrorFlagsIndicateWrongPassword(errorFlags);
    if (wrongPassword) {
        return SZMakeError(SZArchiveErrorCodeWrongPassword,
                           @"Cannot open encrypted archive. Wrong password?");
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

@implementation SZArchive

+ (SZCompressionResourceInfo *)compressionResourceEstimateForSettings:(SZCompressionSettings *)settings {
    SZCompressionResourceInfo *info = [SZCompressionResourceInfo new];
    if (!settings || !SZCompressionEstimateFormatSupportsMemoryUse(settings.format)) {
        return info;
    }

    const int methodID = SZCompressionEstimateMethodID(settings);
    if (methodID < 0) {
        return info;
    }

    const UInt32 level = SZCompressionEstimateLevel(settings);
    const UInt64 dict64 = SZCompressionEstimateDictionary(settings, methodID, level);
    const SZCompressionEstimateRamInfo ramInfo = SZCompressionEstimateGetRamInfo();

    UInt32 numThreads = settings.numThreads;
    if (!SZCompressionEstimateFormatSupportsThreads(settings.format)) {
        numThreads = 1;
    } else if (numThreads == 0) {
        numThreads = SZCompressionEstimateAutoThreads(settings, methodID, level, dict64, ramInfo);
    }

    UInt64 decompressionMemory;
    const UInt64 compressionMemory = SZCompressionEstimateMemoryUsage_Threads_Dict_DecompMem(settings.format,
                                                                                              methodID,
                                                                                              level,
                                                                                              numThreads,
                                                                                              dict64,
                                                                                              decompressionMemory);
    if (compressionMemory != (UInt64)-1) {
        info.compressionMemoryIsDefined = YES;
        info.compressionMemory = compressionMemory;
    }
    if (decompressionMemory != (UInt64)-1) {
        info.decompressionMemoryIsDefined = YES;
        info.decompressionMemory = decompressionMemory;
    }
    return info;
}

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
    return [self openAtPath:path openType:nil password:nil session:nil error:error];
}

- (BOOL)openAtPath:(NSString *)path progress:(id<SZProgressDelegate>)progress error:(NSError **)error {
    return [self openAtPath:path password:nil progress:progress error:error];
}

- (BOOL)openAtPath:(NSString *)path session:(SZOperationSession *)session error:(NSError **)error {
    return [self openAtPath:path openType:nil session:session error:error];
}

- (BOOL)openAtPath:(NSString *)path openType:(NSString *)openType session:(SZOperationSession *)session error:(NSError **)error {
    return [self openAtPath:path openType:openType password:nil session:session error:error];
}

- (BOOL)openAtPath:(NSString *)path password:(NSString *)password error:(NSError **)error {
    return [self openAtPath:path password:password session:nil error:error];
}

- (BOOL)openAtPath:(NSString *)path password:(NSString *)password progress:(id<SZProgressDelegate>)progress error:(NSError **)error {
    return [self openAtPath:path password:password session:SZMakeDefaultOperationSession(progress) error:error];
}

- (BOOL)openAtPath:(NSString *)path password:(NSString *)password session:(SZOperationSession *)session error:(NSError **)error {
    return [self openAtPath:path openType:nil password:password session:session error:error];
}

- (BOOL)openAtPath:(NSString *)path openType:(NSString *)openType password:(NSString *)password session:(SZOperationSession *)session error:(NSError **)error {
    CCodecs *codecs = SZGetCodecs();
    if (!codecs) { if (error) *error = SZMakeError(SZArchiveErrorCodeFailedToInitCodecs, @"Failed to init codecs"); return NO; }
    [self close];
    [self clearCachedPassword];
    _archivePath = [path copy];

    CObjectVector<COpenType> types;
    if (openType.length > 0 && !ParseOpenTypes(*codecs, ToU(openType), types)) {
        if (error) {
            *error = SZMakeError(SZArchiveErrorCodeUnsupportedFormat,
                                 [NSString stringWithFormat:@"Invalid archive open type: %@", openType]);
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

    SZOperationSession *resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZOpenCallbackUI callbackUI;
    callbackUI.Session = resolvedSession;
    if (password) {
        callbackUI.PasswordIsDefined = true;
        callbackUI.Password = ToU(password);
    }

    HRESULT res = _arcLink->Open3(options, &callbackUI);
    if (res != S_OK) {
        if (error) {
            *error = SZOpenArchiveErrorFromResult(res, _arcLink->NonOpen_ErrorInfo, callbackUI);
        }
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
        case SZOverwriteModeRenameExisting: return NExtract::NOverwriteMode::kRenameExisting;
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
    return [self extractToPath:dest settings:s session:SZMakeDefaultOperationSession(p) error:error];
}

- (BOOL)extractToPath:(NSString *)dest settings:(SZExtractionSettings *)s session:(SZOperationSession *)session error:(NSError **)error {
    if (!_isOpen) { if (error) *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open"); return NO; }
    IInArchive *archive = _arcLink->GetArchive();
    const CArc &arc = _arcLink->Arcs.Back();
    NWindows::NFile::NDir::CreateComplexDir(us2fs(ToU(dest)));

    SZOperationSession *resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZFolderExtractCallback *faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Session = resolvedSession;
    faeSpec->OverwriteMode = s.overwriteMode;
    [self configureExtractPasswordForCallback:faeSpec explicitPassword:s.password];

    CArchiveExtractCallback *ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);
    CExtractNtOptions ntOptions;
    if (s.preserveNtSecurityInfo) {
        ntOptions.NtSecurity.Def = true;
        ntOptions.NtSecurity.Val = true;
    }
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
    return [self extractEntries:indices toPath:dest settings:s session:SZMakeDefaultOperationSession(p) error:error];
}

- (BOOL)extractEntries:(NSArray<NSNumber *> *)indices toPath:(NSString *)dest settings:(SZExtractionSettings *)s session:(SZOperationSession *)session error:(NSError **)error {
    if (!_isOpen) { if (error) *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open"); return NO; }
    IInArchive *archive = _arcLink->GetArchive();
    const CArc &arc = _arcLink->Arcs.Back();
    NWindows::NFile::NDir::CreateComplexDir(us2fs(ToU(dest)));

    SZOperationSession *resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZFolderExtractCallback *faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Session = resolvedSession;
    faeSpec->OverwriteMode = s.overwriteMode;
    [self configureExtractPasswordForCallback:faeSpec explicitPassword:s.password];

    CArchiveExtractCallback *ecs = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec(ecs);
    CExtractNtOptions ntOptions;
    if (s.preserveNtSecurityInfo) {
        ntOptions.NtSecurity.Def = true;
        ntOptions.NtSecurity.Val = true;
    }
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
    return [self testWithSession:SZMakeDefaultOperationSession(p) error:error];
}

- (BOOL)testWithSession:(SZOperationSession *)session error:(NSError **)error {
    if (!_isOpen) { if (error) *error = SZMakeError(SZArchiveErrorCodeNoOpenArchive, @"No archive open"); return NO; }
    IInArchive *archive = _arcLink->GetArchive();
    const CArc &arc = _arcLink->Arcs.Back();

    SZOperationSession *resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
    SZFolderExtractCallback *faeSpec = new SZFolderExtractCallback;
    CMyComPtr<IFolderArchiveExtractCallback> faeCallback(faeSpec);
    faeSpec->Session = resolvedSession;
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

static UString SZCompressionMethodSpec(SZCompressionSettings *settings) {
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

static bool SZCompressionMethodUsesOrderMode(const UString &methodSpec) {
    return methodSpec.IsEqualTo_Ascii_NoCase("PPMd");
}

static UString SZCompressionEncryptionProperty(SZCompressionSettings *settings) {
    if (settings.password.length == 0) {
        return UString();
    }

    if (settings.format == SZArchiveFormatZip && settings.encryption == SZEncryptionMethodAES256) {
        return UString(L"AES256");
    }

    return UString();
}

static const NUpdateArchive::CActionSet &SZCompressionActionSetForMode(SZCompressionUpdateMode mode) {
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

static NWildcard::ECensorPathMode SZMapCompressionPathMode(SZCompressionPathMode mode) {
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

static void SZAddCompressionProperty(CObjectVector<CProperty> &properties,
                                     const wchar_t *name,
                                     const UString &value) {
    CProperty property;
    property.Name = name;
    property.Value = value;
    properties.Add(property);
}

static void SZAddCompressionPropertyUInt32(CObjectVector<CProperty> &properties,
                                           const wchar_t *name,
                                           UInt32 value) {
    UString text;
    text.Add_UInt32(value);
    SZAddCompressionProperty(properties, name, text);
}

static void SZAddCompressionPropertySize(CObjectVector<CProperty> &properties,
                                         const wchar_t *name,
                                         UInt64 value) {
    UString text;
    text.Add_UInt64(value);
    text.Add_Char('b');
    SZAddCompressionProperty(properties, name, text);
}

static void SZAddCompressionPropertyBool(CObjectVector<CProperty> &properties,
                                         const wchar_t *name,
                                         bool value) {
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

static void SZSplitOptionsToStrings(const UString &src, UStringVector &strings) {
    SplitString(src, strings);
    FOR_VECTOR (i, strings)
    {
        UString &option = strings[i];
        if (option.Len() > 2
            && option[0] == '-'
            && MyCharLower_Ascii(option[1]) == 'm') {
            option.DeleteFrontal(2);
        }
    }
}

static bool SZHasMethodOverride(bool is7z, const UStringVector &strings) {
    FOR_VECTOR (i, strings)
    {
        const UString &option = strings[i];
        if (is7z) {
            const wchar_t *end = NULL;
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

static void SZParseAndAddCompressionProperties(CObjectVector<CProperty> &properties,
                                               const UStringVector &strings) {
    FOR_VECTOR (i, strings)
    {
        const UString &option = strings[i];
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

static bool SZParseVolumeSizes(const UString &text, CRecordVector<UInt64> &values) {
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
                UInt64 &value = values.Back();
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
        const wchar_t *start = text.Ptr(index);
        const wchar_t *end = NULL;
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

+ (BOOL)createAtPath:(NSString *)archivePath fromPaths:(NSArray<NSString *> *)src settings:(SZCompressionSettings *)s progress:(id<SZProgressDelegate>)p error:(NSError **)error {
        return [self createAtPath:archivePath
                                        fromPaths:src
                                         settings:s
                                            session:SZMakeDefaultOperationSession(p)
                                                error:error];
}

+ (BOOL)createAtPath:(NSString *)archivePath fromPaths:(NSArray<NSString *> *)src settings:(SZCompressionSettings *)s session:(SZOperationSession *)session error:(NSError **)error {
    CCodecs *codecs = SZGetCodecs();
    if (!codecs) { if (error) *error = SZMakeError(-1, @"Failed to init codecs"); return NO; }

    static const char *fmts[] = {"7z","zip","tar","gzip","bzip2","xz","wim","zstd"};
    int fi = (int)s.format; if (fi < 0 || fi >= 8) fi = 0;

    CUpdateOptions options;
    options.Commands.Clear();
    CUpdateArchiveCommand command;
    command.ActionSet = SZCompressionActionSetForMode(s.updateMode);
    options.Commands.Add(command);
    options.PathMode = SZMapCompressionPathMode(s.pathMode);
    options.OpenShareForWrite = s.openSharedFiles;
    options.DeleteAfterCompressing = s.deleteAfterCompression;
    options.SfxMode = s.createSFX;
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

    UString fmtName;
    for (const char *c = fmts[fi]; *c; c++) fmtName += (wchar_t)(unsigned char)*c;
    int formatIndex = codecs->FindFormatForArchiveType(fmtName);
    if (formatIndex < 0) {
        NSString *ext = [[archivePath pathExtension] lowercaseString];
        formatIndex = codecs->FindFormatForExtension(ToU(ext));
    }
    if (formatIndex < 0) { if (error) *error = SZMakeError(-8, @"Unsupported format"); return NO; }
    options.MethodMode.Type.FormatIndex = formatIndex;
    options.MethodMode.Type_Defined = true;

    const CArcInfoEx &formatInfo = codecs->Formats[(unsigned)formatIndex];
    const bool is7z = formatInfo.Is_7z();
    const UString methodSpec = SZCompressionMethodSpec(s);
    const bool usesOrderMode = SZCompressionMethodUsesOrderMode(methodSpec);

    UStringVector optionStrings;
    if (s.parameters.length > 0) {
        SZSplitOptionsToStrings(ToU(s.parameters), optionStrings);
    }
    const bool methodOverride = SZHasMethodOverride(is7z, optionStrings);

    // Set compression properties
    CProperty propLevel;
    propLevel.Name = L"x";
    wchar_t levelBuf[16];
    swprintf(levelBuf, 16, L"%d", (int)s.level);
    propLevel.Value = levelBuf;
    options.MethodMode.Properties.Add(propLevel);

    if (!methodSpec.IsEmpty() && !methodOverride) {
        SZAddCompressionProperty(options.MethodMode.Properties,
                                 is7z ? L"0" : L"m",
                                 methodSpec);
    }

    if (s.dictionarySize > 0) {
        const wchar_t *propertyName = usesOrderMode
            ? (is7z ? L"0mem" : L"mem")
            : (is7z ? L"0d" : L"d");
        SZAddCompressionPropertySize(options.MethodMode.Properties,
                                     propertyName,
                                     (UInt64)s.dictionarySize);
    }

    if (s.wordSize > 0) {
        const wchar_t *propertyName = usesOrderMode
            ? (is7z ? L"0o" : L"o")
            : (is7z ? L"0fb" : L"fb");
        SZAddCompressionPropertyUInt32(options.MethodMode.Properties,
                                       propertyName,
                                       s.wordSize);
    }

    const UString encryptionProperty = SZCompressionEncryptionProperty(s);
    if (!encryptionProperty.IsEmpty()) {
        SZAddCompressionProperty(options.MethodMode.Properties,
                                 L"em",
                                 encryptionProperty);
    }

    if (s.numThreads > 0) {
        CProperty p2; p2.Name = L"mt";
        wchar_t buf[16]; swprintf(buf, 16, L"%u", (unsigned)s.numThreads);
        p2.Value = buf;
        options.MethodMode.Properties.Add(p2);
    }
    if ((s.format == SZArchiveFormat7z || s.format == SZArchiveFormatXz) && s.solidMode) {
        CProperty p2; p2.Name = L"s"; p2.Value = L"on";
        options.MethodMode.Properties.Add(p2);
    }
    if (s.encryptFileNames && s.format == SZArchiveFormat7z && s.password.length > 0) {
        CProperty p2; p2.Name = L"he"; p2.Value = L"on";
        options.MethodMode.Properties.Add(p2);
    }

    if (s.storeModificationTime != SZCompressionBoolSettingNotDefined) {
        SZAddCompressionPropertyBool(options.MethodMode.Properties,
                                     L"tm",
                                     s.storeModificationTime == SZCompressionBoolSettingOn);
    }
    if (s.storeCreationTime != SZCompressionBoolSettingNotDefined) {
        SZAddCompressionPropertyBool(options.MethodMode.Properties,
                                     L"tc",
                                     s.storeCreationTime == SZCompressionBoolSettingOn);
    }
    if (s.storeAccessTime != SZCompressionBoolSettingNotDefined) {
        SZAddCompressionPropertyBool(options.MethodMode.Properties,
                                     L"ta",
                                     s.storeAccessTime == SZCompressionBoolSettingOn);
    }
    if (s.timePrecision != SZCompressionTimePrecisionAutomatic) {
        SZAddCompressionPropertyUInt32(options.MethodMode.Properties,
                                       L"tp",
                                       (UInt32)s.timePrecision);
    }

    if (optionStrings.Size() > 0) {
        SZParseAndAddCompressionProperties(options.MethodMode.Properties, optionStrings);
    }

    if (s.splitVolumes.length > 0) {
        if (!SZParseVolumeSizes(ToU(s.splitVolumes), options.VolumesSizes)) {
            if (error) *error = SZMakeError(-1, @"Invalid split volume sizes.");
            return NO;
        }
    } else if (s.splitVolumeSize > 0) {
        options.VolumesSizes.Add(s.splitVolumeSize);
    }

    NWildcard::CCensor censor;
    for (NSString *srcPath in src) {
        censor.AddPreItem_NoWildcard(ToU(srcPath));
    }

    SZOperationSession *resolvedSession = session ?: SZMakeDefaultOperationSession(nil);
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

+ (NSDictionary<NSString*,NSString*> *)calculateHashForPath:(NSString *)path error:(NSError **)error {
    return [self calculateHashForPath:path session:nil error:error];
}

+ (NSDictionary<NSString*,NSString*> *)calculateHashForPath:(NSString *)path session:(SZOperationSession *)session error:(NSError **)error {
    CCodecs *codecs = SZGetCodecs();
    if (!codecs) { if (error) *error = SZMakeError(-1, @"Failed to init codecs"); return nil; }

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
        __unsafe_unretained SZOperationSession *session;
        NSMutableDictionary *results;
        UString failureDescription;
        UString failureReason;
        HRESULT failureResult;
        UInt64 totalSize;

        HashCB(SZOperationSession *resolvedSession):
            session(resolvedSession),
            results([NSMutableDictionary dictionary]),
            failureResult(S_OK),
            totalSize(0) {}

        bool HasFailure() const { return failureResult != S_OK; }

        HRESULT StartScanning() override { return CheckBreak(); }
        HRESULT FinishScanning(const CDirItemsStat &) override { return CheckBreak(); }
        HRESULT SetNumFiles(UInt64) override { return CheckBreak(); }
        HRESULT SetTotal(UInt64 size) override {
            totalSize = size;
            if (session && size > 0) {
                [session reportProgressFraction:0.0];
                [session reportBytesCompleted:0 total:size];
            }
            return CheckBreak();
        }
        HRESULT SetCompleted(const UInt64 *completed) override {
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
        HRESULT BeforeFirstFile(const CHashBundle &) override { return CheckBreak(); }
        HRESULT GetStream(const wchar_t *name, bool) override {
            if (session && name) {
                [session reportCurrentFileName:ToNS(UString(name))];
            }
            return CheckBreak();
        }
        HRESULT OpenFileError(const FString &path, DWORD errorCode) override {
            RecordFailure(L"Unable to open file for hashing.", path, errorCode);
            return S_FALSE;
        }
        HRESULT SetOperationResult(UInt64, const CHashBundle &hb, bool) override {
            for (unsigned i = 0; i < hb.Hashers.Size(); i++) {
                const CHasherState &h = hb.Hashers[i];
                char hex[256];
                HashHexToString(hex, h.Digests[0], h.DigestSize);
                results[[NSString stringWithUTF8String:h.Name.Ptr()]] = [NSString stringWithUTF8String:hex];
            }
            return S_OK;
        }
        HRESULT AfterLastFile(CHashBundle &) override {
            if (session && totalSize > 0) {
                [session reportProgressFraction:1.0];
                [session reportBytesCompleted:totalSize total:totalSize];
            }
            return CheckBreak();
        }
        HRESULT ScanError(const FString &path, DWORD errorCode) override {
            RecordFailure(L"Unable to scan file for hashing.", path, errorCode);
            return S_FALSE;
        }
        HRESULT ScanProgress(const CDirItemsStat &, const FString &path, bool) override {
            if (session && !path.IsEmpty()) {
                [session reportCurrentFileName:ToNS(fs2us(path))];
            }
            return CheckBreak();
        }

    private:
        void RecordFailure(const wchar_t *description, const FString &path, DWORD errorCode) {
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
            NSString *description = cb.failureDescription.IsEmpty() ? @"Hash calculation failed" : ToNS(cb.failureDescription);
            NSString *reason = cb.failureReason.IsEmpty() ? nil : ToNS(cb.failureReason);
            *error = SZMakeDetailedError(cb.failureResult, description, reason);
        }
        return nil;
    }

    if (r != S_OK) {
        NSString *reason = errorInfo.IsEmpty() ? nil : [NSString stringWithUTF8String:errorInfo.Ptr()];
        if (error) *error = SZMakeDetailedError(r, @"Hash calculation failed", reason);
        return nil;
    }

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
