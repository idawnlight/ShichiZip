#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A password editor whose secure and plain fields share one value.
@interface SZPasswordField : NSView <NSTextFieldDelegate>

- (instancetype)initWithValue:(NSString*)value
                  placeholder:(NSString*)placeholder
      accessibilityIdentifier:(NSString*)identifier;

@property (nonatomic, copy) NSString* stringValue;
@property (nonatomic) BOOL showsPassword;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) NSTextField* visibleField;
@property (nonatomic, copy, nullable) void (^textDidChangeHandler)(NSString* value);

- (void)setShowsPassword:(BOOL)showsPassword moveFocus:(BOOL)moveFocus;

@end

NS_ASSUME_NONNULL_END
