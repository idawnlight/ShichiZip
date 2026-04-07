#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZDialogStyle) {
    SZDialogStyleInformational = 0,
    SZDialogStyleWarning,
    SZDialogStyleCritical,
};

typedef void (^SZModalDialogCompletionHandler)(NSInteger selectedButtonIndex);

@interface SZModalDialogController : NSWindowController

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (instancetype)initWithStyle:(SZDialogStyle)style
                        title:(NSString *)title
                      message:(nullable NSString *)message
                 buttonTitles:(NSArray<NSString *> *)buttonTitles
                accessoryView:(nullable NSView *)accessoryView
       preferredFirstResponder:(nullable NSView *)preferredFirstResponder
            cancelButtonIndex:(NSInteger)cancelButtonIndex NS_DESIGNATED_INITIALIZER;

- (void)beginSheetModalForWindow:(NSWindow *)window
               completionHandler:(SZModalDialogCompletionHandler)completionHandler;

- (NSInteger)runModal;

@end

NS_ASSUME_NONNULL_END