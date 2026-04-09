// SZArchive+Benchmark.mm — Benchmark implementation (mirrors UI/GUI/BenchmarkDialog.cpp)

#include "SZBridgeCommon.h"

#include "CPP/7zip/UI/Common/Bench.h"

#include <atomic>
#include <mutex>

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

@implementation SZArchive (Benchmark)

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
