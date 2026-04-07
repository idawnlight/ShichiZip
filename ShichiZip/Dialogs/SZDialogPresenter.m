#import "SZDialogPresenter.h"

#import "../Bridge/SZArchive.h"

static NSString * const SZShowPasswordPreferenceKey = @"SZShowPasswordInPrompts";

@interface SZPasswordAccessoryController : NSViewController

- (instancetype)initWithInitialValue:(nullable NSString *)initialValue;

@property (nonatomic, readonly) NSString *password;
@property (nonatomic, readonly) BOOL showsPassword;
@property (nonatomic, readonly) NSView *preferredFirstResponderView;

@end

@implementation SZPasswordAccessoryController {
    NSSecureTextField *_secureField;
    NSTextField *_plainField;
    NSButton *_showPasswordButton;
}

- (instancetype)initWithInitialValue:(NSString *)initialValue {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        NSString *password = initialValue ?: @"";

        _secureField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
        _secureField.translatesAutoresizingMaskIntoConstraints = NO;
        _secureField.placeholderString = @"Password";
        _secureField.stringValue = password;

        _plainField = [[NSTextField alloc] initWithFrame:NSZeroRect];
        _plainField.translatesAutoresizingMaskIntoConstraints = NO;
        _plainField.placeholderString = @"Password";
        _plainField.stringValue = password;
        _plainField.hidden = YES;

        _showPasswordButton = [NSButton checkboxWithTitle:@"Show password" target:self action:@selector(togglePasswordVisibility:)];
        _showPasswordButton.translatesAutoresizingMaskIntoConstraints = NO;
        _showPasswordButton.state = [[NSUserDefaults standardUserDefaults] boolForKey:SZShowPasswordPreferenceKey] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return self;
}

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 56)];

    [container addSubview:_secureField];
    [container addSubview:_plainField];
    [container addSubview:_showPasswordButton];

    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintEqualToConstant:320],

        [_secureField.topAnchor constraintEqualToAnchor:container.topAnchor],
        [_secureField.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [_secureField.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [_plainField.topAnchor constraintEqualToAnchor:container.topAnchor],
        [_plainField.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [_plainField.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [_showPasswordButton.topAnchor constraintEqualToAnchor:_secureField.bottomAnchor constant:8],
        [_showPasswordButton.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [_showPasswordButton.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    self.view = container;
    [self syncVisibility];
}

- (void)togglePasswordVisibility:(__unused NSButton *)sender {
    NSString *currentPassword = self.password;
    _secureField.stringValue = currentPassword;
    _plainField.stringValue = currentPassword;
    [self syncVisibility];

    NSView *firstResponder = self.preferredFirstResponderView;
    if (firstResponder) {
        [self.view.window makeFirstResponder:firstResponder];
    }
}

- (void)syncVisibility {
    BOOL showPassword = _showPasswordButton.state == NSControlStateValueOn;
    _secureField.hidden = showPassword;
    _plainField.hidden = !showPassword;
}

- (NSString *)password {
    return _showPasswordButton.state == NSControlStateValueOn ? _plainField.stringValue : _secureField.stringValue;
}

- (BOOL)showsPassword {
    return _showPasswordButton.state == NSControlStateValueOn;
}

- (NSView *)preferredFirstResponderView {
    return self.showsPassword ? _plainField : _secureField;
}

@end

@implementation SZDialogPresenter

+ (NSString *)errorDetailsForError:(NSError *)error {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    NSString *failureReason = error.localizedFailureReason;
    if (failureReason.length > 0 && ![failureReason isEqualToString:error.localizedDescription]) {
        [parts addObject:failureReason];
    }

    NSString *recoverySuggestion = error.localizedRecoverySuggestion;
    if (recoverySuggestion.length > 0) {
        [parts addObject:recoverySuggestion];
    }

    return [parts componentsJoinedByString:@"\n\n"];
}

+ (void)presentError:(NSError *)error forWindow:(NSWindow *)window {
    NSString *title = error.localizedDescription.length > 0 ? error.localizedDescription : @"Operation Failed";
    NSString *message = [self errorDetailsForError:error];
    SZDialogStyle style = SZDialogStyleCritical;
    BOOL useDedicatedPopup = NO;
    if ([error.domain isEqualToString:SZArchiveErrorDomain] && error.code == SZArchiveErrorCodeWrongPassword) {
        style = SZDialogStyleWarning;
        useDedicatedPopup = YES;
    }

    SZModalDialogController *controller = [[SZModalDialogController alloc] initWithStyle:style
                                                                                    title:title
                                                                                  message:message
                                                                             buttonTitles:@[@"OK"]
                                                                            accessoryView:nil
                                                                   preferredFirstResponder:nil
                                                                        cancelButtonIndex:0];
    if (window && !useDedicatedPopup) {
        [controller beginSheetModalForWindow:window completionHandler:^(__unused NSInteger selectedButtonIndex) {
        }];
    } else {
        [controller runModal];
    }
}

+ (void)presentMessageWithStyle:(SZDialogStyle)style
                          title:(NSString *)title
                        message:(NSString *)message
                    buttonTitle:(NSString *)buttonTitle
                      forWindow:(NSWindow *)window {
    SZModalDialogController *controller = [[SZModalDialogController alloc] initWithStyle:style
                                                                                    title:title
                                                                                  message:message
                                                                             buttonTitles:@[buttonTitle]
                                                                            accessoryView:nil
                                                                   preferredFirstResponder:nil
                                                                        cancelButtonIndex:0];
    if (window) {
        [controller beginSheetModalForWindow:window completionHandler:^(__unused NSInteger selectedButtonIndex) {
        }];
    } else {
        [controller runModal];
    }
}

+ (NSInteger)runMessageWithStyle:(SZDialogStyle)style
                              title:(NSString *)title
                            message:(NSString *)message
                       buttonTitles:(NSArray<NSString *> *)buttonTitles {
    NSInteger cancelButtonIndex = buttonTitles.count > 0 ? (NSInteger)buttonTitles.count - 1 : 0;
    for (NSInteger index = 0; index < (NSInteger)buttonTitles.count; index++) {
        if ([buttonTitles[(NSUInteger)index] caseInsensitiveCompare:@"Cancel"] == NSOrderedSame) {
            cancelButtonIndex = index;
            break;
        }
    }

    SZModalDialogController *controller = [[SZModalDialogController alloc] initWithStyle:style
                                                                                    title:title
                                                                                  message:message
                                                                             buttonTitles:buttonTitles
                                                                            accessoryView:nil
                                                                   preferredFirstResponder:nil
                                                                        cancelButtonIndex:cancelButtonIndex];
    return [controller runModal];
}

+ (BOOL)promptForPasswordWithTitle:(NSString *)title
                           message:(NSString *)message
                      initialValue:(NSString *)initialValue
                           password:(NSString * _Nullable * _Nullable)password {
    SZPasswordAccessoryController *accessoryController = [[SZPasswordAccessoryController alloc] initWithInitialValue:initialValue];
    SZModalDialogController *controller = [[SZModalDialogController alloc] initWithStyle:SZDialogStyleWarning
                                                                                    title:title
                                                                                  message:message
                                                                             buttonTitles:@[@"Cancel", @"OK"]
                                                                            accessoryView:accessoryController.view
                                                                   preferredFirstResponder:accessoryController.preferredFirstResponderView
                                                                        cancelButtonIndex:0];

    NSInteger selectedButtonIndex = [controller runModal];
    if (selectedButtonIndex != 1) {
        return NO;
    }

    [[NSUserDefaults standardUserDefaults] setBool:accessoryController.showsPassword forKey:SZShowPasswordPreferenceKey];
    if (password) {
        *password = accessoryController.password;
    }
    return YES;
}

@end