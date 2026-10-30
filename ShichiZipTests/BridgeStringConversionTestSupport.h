#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* SZTestBridgeRoundTripString(NSString* _Nullable input);
FOUNDATION_EXPORT NSArray<NSNumber*>* SZTestBridgeUStringCodeUnits(NSString* input);
FOUNDATION_EXPORT NSString* SZTestBridgeStringFromUStringCodeUnits(NSArray<NSNumber*>* input);
FOUNDATION_EXPORT NSString* SZTestBridgeDecodeCStringData(NSData* bytes);

NS_ASSUME_NONNULL_END
