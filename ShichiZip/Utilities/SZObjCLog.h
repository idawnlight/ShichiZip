#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void SZLogDebug(NSString* prefix, NSString* format, ...) NS_FORMAT_FUNCTION(2, 3);
FOUNDATION_EXPORT void SZLogInfo(NSString* prefix, NSString* format, ...) NS_FORMAT_FUNCTION(2, 3);
FOUNDATION_EXPORT void SZLogError(NSString* prefix, NSString* format, ...) NS_FORMAT_FUNCTION(2, 3);

NS_ASSUME_NONNULL_END