#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZDialogStyle) {
    SZDialogStyleInformational = 0,
    SZDialogStyleWarning,
    SZDialogStyleCritical,
};

typedef NS_OPTIONS(NSUInteger, SZDialogActionRole) {
    SZDialogActionRoleNone = 0,
    SZDialogActionRoleDefault = 1 << 0,
    SZDialogActionRoleCancel = 1 << 1,
};

@interface SZDialogAction : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithTitle:(NSString*)title roles:(SZDialogActionRole)roles NS_DESIGNATED_INITIALIZER;

@property (nonatomic, copy, readonly) NSString* title;
@property (nonatomic, readonly) SZDialogActionRole roles;

@end

typedef void(NS_SWIFT_UI_ACTOR ^ SZModalDialogCompletionHandler)(NSInteger selectedButtonIndex);
typedef BOOL(NS_SWIFT_UI_ACTOR ^ SZModalDialogShouldFinishHandler)(NSInteger selectedButtonIndex);

@interface SZModalDialogController : NSWindowController

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;
- (instancetype)initWithWindow:(nullable NSWindow*)window NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithStyle:(SZDialogStyle)style
                        title:(NSString*)title
                      message:(nullable NSString*)message
                      actions:(NSArray<SZDialogAction*>*)actions
                accessoryView:(nullable NSView*)accessoryView
      preferredFirstResponder:(nullable NSView*)preferredFirstResponder;

// Presents as a sheet and returns immediately; the result is delivered in the completion handler.
- (void)beginSheetModalForWindow:(NSWindow*)window
               completionHandler:(SZModalDialogCompletionHandler)completionHandler;

// Presents as a standalone modal window and blocks until it closes.
- (NSInteger)runModal;

- (void)finishWithButtonIndex:(NSInteger)buttonIndex;

- (void)setButtonEnabled:(BOOL)enabled atIndex:(NSInteger)index;

@property (nonatomic, copy, nullable) SZModalDialogShouldFinishHandler shouldFinishHandler;

@end

NS_ASSUME_NONNULL_END
