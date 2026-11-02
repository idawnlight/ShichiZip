#import <XCTest/XCTest.h>

#import "../ShichiZip/Bridge/SZBridgeCommon.h"

@interface BridgePreferencesCacheTests : XCTestCase
@end

@implementation BridgePreferencesCacheTests

- (void)testCachedDefaultsAndLocalizationRefreshAfterVolatileLanguageChanges {
    NSUserDefaults* defaults = SZSharedNSUserDefaults();
    NSBundle* baseBundle = SZLocalizationBundle();
    XCTAssertTrue(defaults == SZSharedNSUserDefaults());
    XCTAssertTrue(baseBundle == SZLocalizationBundle());

    NSDictionary<NSString*, id>* originalArguments = [defaults volatileDomainForName:NSArgumentDomain];
    NSMutableDictionary<NSString*, id>* arguments = [originalArguments mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString* key = @"app.fileManager.statusFiles";
    NSString* baseValue = [baseBundle localizedStringForKey:key value:nil table:@"App"];

    @try {
        for (NSString* language in @[ @"en", @"zh-Hans", @"en" ]) {
            arguments[@"LanguageOverride"] = language;
            [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
            XCTAssertEqualObjects([defaults stringForKey:@"LanguageOverride"], language);
            XCTAssertEqualObjects(SZLocalizedString(key), [language isEqualToString:@"en"] ? @"files" : @"个文件");
        }

        for (NSString* language in @[ @"missing-language", @"" ]) {
            arguments[@"LanguageOverride"] = language;
            [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
            XCTAssertEqualObjects(SZLocalizedString(key), baseValue);
        }
        XCTAssertEqualObjects(SZLocalizedString(@"bridge.cache.missing-key"), @"bridge.cache.missing-key");
    } @finally {
        if (originalArguments) {
            [defaults setVolatileDomain:originalArguments forName:NSArgumentDomain];
        } else {
            [defaults removeVolatileDomainForName:NSArgumentDomain];
        }
        // Restore the cached selection as well as the complete in-memory argument domain.
        SZLocalizedString(key);
    }
}

@end
