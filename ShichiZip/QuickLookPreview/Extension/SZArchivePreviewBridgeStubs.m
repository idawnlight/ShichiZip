#import <Cocoa/Cocoa.h>

#import "../../Bridge/SZOperationSession.h"

@interface SZMemoryLimitPromptResult : NSObject

@property (nonatomic) BOOL saveLimit;
@property (nonatomic) BOOL skipArchive;
@property (nonatomic) BOOL rememberChoice;
@property (nonatomic) uint32_t limitGB;

@end

@implementation SZMemoryLimitPromptResult
@end

@interface SZDialogPresenter : NSObject

+ (BOOL)promptForMemoryLimitWithRequiredBytes:(uint64_t)requiredBytes
                            currentLimitBytes:(uint64_t)currentLimitBytes
                                  archivePath:(nullable NSString*)archivePath
                                     filePath:(nullable NSString*)filePath
                                     testMode:(BOOL)testMode
                                 showRemember:(BOOL)showRemember
                                       result:(SZMemoryLimitPromptResult* _Nullable* _Nullable)result;

@end

@implementation SZDialogPresenter

+ (BOOL)promptForMemoryLimitWithRequiredBytes:(uint64_t)requiredBytes
                            currentLimitBytes:(uint64_t)currentLimitBytes
                                  archivePath:(nullable NSString*)archivePath
                                     filePath:(nullable NSString*)filePath
                                     testMode:(BOOL)testMode
                                 showRemember:(BOOL)showRemember
                                       result:(SZMemoryLimitPromptResult* _Nullable* _Nullable)result {
    return NO;
}

@end

static void SZArchivePreviewLog(NSString* prefix, NSString* format, va_list arguments) {
    NSString* message = [[NSString alloc] initWithFormat:format arguments:arguments];
    NSLog(@"[%@] %@", prefix, message);
}

void SZLogDebug(NSString* prefix, NSString* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    SZArchivePreviewLog(prefix, format, arguments);
    va_end(arguments);
}

void SZLogInfo(NSString* prefix, NSString* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    SZArchivePreviewLog(prefix, format, arguments);
    va_end(arguments);
}

void SZLogError(NSString* prefix, NSString* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    SZArchivePreviewLog(prefix, format, arguments);
    va_end(arguments);
}

SZOperationSession* SZMakeDefaultOperationSession(void) {
    return [[SZOperationSession alloc] init];
}
