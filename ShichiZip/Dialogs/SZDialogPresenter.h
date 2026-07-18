#import <Cocoa/Cocoa.h>

#import "../Bridge/SZOperationSession.h"
#import "SZModalDialogController.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZMemoryLimitPromptResult : NSObject

@property (nonatomic) BOOL saveLimit;
@property (nonatomic) BOOL skipArchive;
@property (nonatomic) BOOL rememberChoice;
@property (nonatomic) uint32_t limitGB;

@end

@interface SZDialogPresenter : NSObject

+ (nullable NSWindow*)sheetParentWindowForWindow:(nullable NSWindow*)window;

+ (SZDialogStyle)dialogStyleForPromptStyle:(SZOperationPromptStyle)promptStyle;

+ (void)presentError:(NSError*)error forWindow:(nullable NSWindow*)window;

+ (void)presentMessageWithStyle:(SZDialogStyle)style
                          title:(NSString*)title
                        message:(nullable NSString*)message
                    buttonTitle:(NSString*)buttonTitle
                      forWindow:(nullable NSWindow*)window;

+ (NSInteger)runChoiceRequest:(SZOperationChoiceRequest*)request;

+ (BOOL)promptForPasswordWithTitle:(NSString*)title
                           message:(nullable NSString*)message
                      initialValue:(nullable NSString*)initialValue
                          password:(NSString* _Nullable* _Nullable)password;

+ (BOOL)promptForMemoryLimitWithRequiredBytes:(uint64_t)requiredBytes
                            currentLimitBytes:(uint64_t)currentLimitBytes
                                  archivePath:(nullable NSString*)archivePath
                                     filePath:(nullable NSString*)filePath
                                     testMode:(BOOL)testMode
                                 showRemember:(BOOL)showRemember
                                       result:(SZMemoryLimitPromptResult* _Nullable* _Nullable)result;

@end

NS_ASSUME_NONNULL_END