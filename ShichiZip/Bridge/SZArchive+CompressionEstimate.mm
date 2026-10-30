// SZArchive+CompressionEstimate.mm — Compression resource estimation

#include "SZBridgeCommon.h"
#include "SZCompressionEstimate.h"

#include "CPP/7zip/Common/MethodProps.h"
#include "CPP/Windows/System.h"

namespace {

enum SZCompressionEstimateMethod {
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

} // namespace

bool SZCompressionEstimateMethodSupportsSFX(int methodID) {
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

namespace {

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

} // namespace

UInt32 SZCompressionLevelPropertyValue(int methodID,
    NSInteger levelValue) {
#if SHICHIZIP_ZS_VARIANT
    if (methodID == kSZCompressionEstimateZstd && levelValue < 0) {
        return (UInt32)(kSZCompressionZstdFastLevelIncrement - levelValue);
    }
#endif
    return (UInt32)levelValue;
}

int SZCompressionEstimateMethodID(SZCompressionSettings* settings) {
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

namespace {

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

@implementation SZArchive (CompressionEstimate)

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

@end
