#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#define BOOL BOOL_7Z_COMPAT
#include "7zip/CPP/Common/MyString.h"
#include "7zip/CPP/Common/UTFConvert.h"
#undef BOOL

bool ShichiZip_DetectLegacyEncodingAndConvertToUnicode(UString &dest, const AString &src)
{
    @autoreleasepool {
        if (src.IsEmpty()) {
            return false;
        }

        NSData *data = [NSData dataWithBytes:src.Ptr() length:(NSUInteger)src.Len()];
        if (data.length == 0) {
            return false;
        }

        NSArray<NSNumber *> *suggestedEncodings = @[
            @(NSUTF8StringEncoding),
            @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)),
            @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGBK_95)),
            @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSChineseSimplif)),
            @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5)),
            @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSChineseTrad)),
            @(NSShiftJISStringEncoding),
            @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_KR)),
            @(NSWindowsCP1251StringEncoding),
            @(NSWindowsCP1252StringEncoding),
        ];

        NSDictionary<NSStringEncodingDetectionOptionsKey, id> *options = @{
            NSStringEncodingDetectionSuggestedEncodingsKey: suggestedEncodings,
            NSStringEncodingDetectionUseOnlySuggestedEncodingsKey: @YES,
            NSStringEncodingDetectionAllowLossyKey: @NO,
        };

        NSString *converted = nil;
        BOOL usedLossyConversion = NO;
        NSStringEncoding encoding = [NSString stringEncodingForData:data
                                                   encodingOptions:options
                                                   convertedString:&converted
                                               usedLossyConversion:&usedLossyConversion];

        if (!converted || usedLossyConversion) {
            return false;
        }

        if (encoding == NSUTF8StringEncoding || encoding == NSASCIIStringEncoding) {
            return false;
        }

        if ([converted rangeOfString:@"\uFFFD"].location != NSNotFound) {
            return false;
        }

        const char *utf8 = [converted UTF8String];
        if (!utf8) {
            return false;
        }

        return ConvertUTF8ToUnicode(AString(utf8), dest);
    }
}