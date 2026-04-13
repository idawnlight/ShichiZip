#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZDialogStyle) {
    SZDialogStyleInformational = 0,
    SZDialogStyleWarning,
    SZDialogStyleCritical,
};

typedef void (NS_SWIFT_UI_ACTOR ^SZModalDialogCompletionHandler)(NSInteger selectedButtonIndex);

@interface SZModalDialogController : NSWindowController

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;
- (instancetype)initWithWindow:(nullable NSWindow*)window NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithStyle:(SZDialogStyle)style
                        title:(NSString*)title
                      message:(nullable NSString*)message
                 buttonTitles:(NSArray<NSString*>*)buttonTitles
                accessoryView:(nullable NSView*)accessoryView
      preferredFirstResponder:(nullable NSView*)preferredFirstResponder
            cancelButtonIndex:(NSInteger)cancelButtonIndex;

- (void)beginSheetModalForWindow:(NSWindow*)window
               completionHandler:(SZModalDialogCompletionHandler)completionHandler;

- (void)finishWithButtonIndex:(NSInteger)buttonIndex;

- (void)setButtonEnabled:(BOOL)enabled atIndex:(NSInteger)index;

- (NSInteger)runModal;

@end

NS_ASSUME_NONNULL_END
