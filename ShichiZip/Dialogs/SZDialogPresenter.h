#import <Cocoa/Cocoa.h>

#import "SZModalDialogController.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZDialogPresenter : NSObject

+ (void)presentError:(NSError *)error forWindow:(nullable NSWindow *)window;

+ (void)presentMessageWithStyle:(SZDialogStyle)style
                          title:(NSString *)title
                        message:(nullable NSString *)message
                    buttonTitle:(NSString *)buttonTitle
                      forWindow:(nullable NSWindow *)window;

+ (NSInteger)runMessageWithStyle:(SZDialogStyle)style
                              title:(NSString *)title
                            message:(nullable NSString *)message
                       buttonTitles:(NSArray<NSString *> *)buttonTitles;

+ (BOOL)promptForPasswordWithTitle:(NSString *)title
                           message:(nullable NSString *)message
                      initialValue:(nullable NSString *)initialValue
                           password:(NSString * _Nullable * _Nullable)password;

@end

NS_ASSUME_NONNULL_END