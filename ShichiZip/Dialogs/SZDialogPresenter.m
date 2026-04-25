#import "SZDialogPresenter.h"

#import "../Bridge/SZArchive.h"
#import "../Bridge/SZBridgeCommon.h"

static NSString* const SZShowPasswordPreferenceKey = @"SZShowPasswordInPrompts";

static uint32_t SZDialogRoundUpByteCountToGB(uint64_t byteCount) {
    if (byteCount == 0) {
        return 1;
    }

    const uint64_t rounded = (byteCount + (((uint64_t)1 << 30) - 1)) >> 30;
    return rounded > UINT32_MAX ? UINT32_MAX : (uint32_t)rounded;
}

@interface SZPasswordAccessoryController : NSViewController

- (instancetype)initWithInitialValue:(nullable NSString*)initialValue;

@property (nonatomic, readonly) NSString* password;
@property (nonatomic, readonly) BOOL showsPassword;
@property (nonatomic, readonly) NSView* preferredFirstResponderView;

@end

@interface SZMemoryLimitAccessoryController : NSViewController

- (instancetype)initWithRequiredBytes:(uint64_t)requiredBytes
                    currentLimitBytes:(uint64_t)currentLimitBytes
                          archivePath:(nullable NSString*)archivePath
                             filePath:(nullable NSString*)filePath
                         showRemember:(BOOL)showRemember;

@property (nonatomic, readonly) BOOL saveLimit;
@property (nonatomic, readonly) BOOL skipArchive;
@property (nonatomic, readonly) BOOL rememberChoice;
@property (nonatomic, readonly) uint32_t limitGB;
@property (nonatomic, readonly) BOOL installedRAMIsInsufficient;
@property (nonatomic, readonly) NSView* preferredFirstResponderView;

@end

@implementation SZPasswordAccessoryController {
    NSSecureTextField* _secureField;
    NSTextField* _plainField;
    NSButton* _showPasswordButton;
}

- (instancetype)initWithInitialValue:(NSString*)initialValue {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        NSString* password = initialValue ?: @"";

        _secureField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
        _secureField.translatesAutoresizingMaskIntoConstraints = NO;
        _secureField.placeholderString = SZLocalizedString(@"password.password");
        _secureField.stringValue = password;
        _secureField.accessibilityIdentifier = @"passwordPrompt.password";

        _plainField = [[NSTextField alloc] initWithFrame:NSZeroRect];
        _plainField.translatesAutoresizingMaskIntoConstraints = NO;
        _plainField.placeholderString = SZLocalizedString(@"password.password");
        _plainField.stringValue = password;
        _plainField.hidden = YES;
        _plainField.accessibilityIdentifier = @"passwordPrompt.passwordPlain";

        _showPasswordButton = [NSButton checkboxWithTitle:SZLocalizedString(@"password.showPassword") target:self action:@selector(togglePasswordVisibility:)];
        _showPasswordButton.translatesAutoresizingMaskIntoConstraints = NO;
        _showPasswordButton.state = [[NSUserDefaults standardUserDefaults] boolForKey:SZShowPasswordPreferenceKey] ? NSControlStateValueOn : NSControlStateValueOff;
        _showPasswordButton.accessibilityIdentifier = @"passwordPrompt.showPassword";
    }
    return self;
}

- (void)loadView {
    NSView* container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 56)];

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

        [_showPasswordButton.topAnchor constraintEqualToAnchor:_secureField.bottomAnchor
                                                      constant:8],
        [_showPasswordButton.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [_showPasswordButton.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    self.view = container;
    [self syncVisibility];
}

- (void)togglePasswordVisibility:(__unused NSButton*)sender {
    NSString* currentPassword = self.password;
    _secureField.stringValue = currentPassword;
    _plainField.stringValue = currentPassword;
    [self syncVisibility];

    NSView* firstResponder = self.preferredFirstResponderView;
    if (firstResponder) {
        [self.view.window makeFirstResponder:firstResponder];
    }
}

- (void)syncVisibility {
    BOOL showPassword = _showPasswordButton.state == NSControlStateValueOn;
    _secureField.hidden = showPassword;
    _plainField.hidden = !showPassword;
}

- (NSString*)password {
    return _showPasswordButton.state == NSControlStateValueOn ? _plainField.stringValue : _secureField.stringValue;
}

- (BOOL)showsPassword {
    return _showPasswordButton.state == NSControlStateValueOn;
}

- (NSView*)preferredFirstResponderView {
    return self.showsPassword ? _plainField : _secureField;
}

@end

@implementation SZMemoryLimitPromptResult
@end

@implementation SZMemoryLimitAccessoryController {
    uint32_t _requiredGB;
    uint32_t _currentLimitGB;
    uint32_t _installedRAMGB;
    BOOL _showRemember;
    NSButton* _saveLimitButton;
    NSTextField* _limitField;
    NSTextField* _limitUnitLabel;
    NSButton* _allowButton;
    NSButton* _skipButton;
    NSButton* _rememberButton;
    NSString* _archivePath;
    NSString* _filePath;
}

- (instancetype)initWithRequiredBytes:(uint64_t)requiredBytes
                    currentLimitBytes:(uint64_t)currentLimitBytes
                          archivePath:(NSString*)archivePath
                             filePath:(NSString*)filePath
                         showRemember:(BOOL)showRemember {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _requiredGB = SZDialogRoundUpByteCountToGB(requiredBytes);
        _currentLimitGB = SZDialogRoundUpByteCountToGB(currentLimitBytes);
        _installedRAMGB = SZDialogRoundUpByteCountToGB([NSProcessInfo processInfo].physicalMemory);
        _showRemember = showRemember;
        _archivePath = [archivePath copy] ?: @"";
        _filePath = [filePath copy] ?: @"";
    }
    return self;
}

- (BOOL)installedRAMIsInsufficient {
    return _installedRAMGB > 0 && _requiredGB > _installedRAMGB;
}

- (NSTextField*)detailLabelWithString:(NSString*)stringValue {
    NSTextField* label = [NSTextField wrappingLabelWithString:stringValue];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:12];
    label.textColor = NSColor.secondaryLabelColor;
    label.maximumNumberOfLines = 0;
    [label setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    return label;
}

- (NSButton*)radioButtonWithTitle:(NSString*)title action:(SEL)action {
    NSButton* button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.buttonType = NSButtonTypeRadio;
    button.title = title;
    button.target = self;
    button.action = action;
    return button;
}

- (void)loadView {
    NSView* container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 220)];

    NSStackView* stack = [[NSStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    [container addSubview:stack];

    NSStackView* detailsStack = [[NSStackView alloc] init];
    detailsStack.translatesAutoresizingMaskIntoConstraints = NO;
    detailsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    detailsStack.alignment = NSLayoutAttributeLeading;
    detailsStack.spacing = 4;
    [detailsStack addArrangedSubview:[self detailLabelWithString:[NSString stringWithFormat:@"%@: %u GB", SZLocalizedString(@"memory.requiredSize"), _requiredGB]]];
    [detailsStack addArrangedSubview:[self detailLabelWithString:[NSString stringWithFormat:@"%@: %u GB", SZLocalizedString(@"memory.allowedLimit"), _currentLimitGB]]];
    [detailsStack addArrangedSubview:[self detailLabelWithString:[NSString stringWithFormat:@"%@: %u GB", SZLocalizedString(@"memory.ramSize"), _installedRAMGB]]];
    if (_archivePath.length > 0) {
        [detailsStack addArrangedSubview:[self detailLabelWithString:[NSString stringWithFormat:SZLocalizedString(@"app.fileManager.archiveTransfer.archive"), _archivePath]]];
    }
    if (_filePath.length > 0) {
        [detailsStack addArrangedSubview:[self detailLabelWithString:[NSString stringWithFormat:@"%@: %@", SZLocalizedString(@"menu.file"), _filePath]]];
    }
    [stack addArrangedSubview:detailsStack];

    _saveLimitButton = [NSButton checkboxWithTitle:SZLocalizedString(@"memory.changeAllowedLimit") target:self action:@selector(toggleSaveLimit:)];
    _saveLimitButton.translatesAutoresizingMaskIntoConstraints = NO;
    _saveLimitButton.accessibilityIdentifier = @"memoryLimit.saveLimit";

    NSNumberFormatter* formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.minimum = @1;
    formatter.maximum = @16384;
    formatter.allowsFloats = NO;
    formatter.generatesDecimalNumbers = NO;

    _limitField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _limitField.translatesAutoresizingMaskIntoConstraints = NO;
    _limitField.formatter = formatter;
    _limitField.alignment = NSTextAlignmentRight;
    _limitField.stringValue = [NSString stringWithFormat:@"%u", MAX(_requiredGB, 1u)];
    _limitField.enabled = NO;
    _limitField.accessibilityIdentifier = @"memoryLimit.limitField";

    _limitUnitLabel = [NSTextField labelWithString:@"GB"];
    _limitUnitLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _limitUnitLabel.textColor = NSColor.secondaryLabelColor;
    _limitUnitLabel.enabled = NO;

    NSStackView* limitStack = [[NSStackView alloc] init];
    limitStack.translatesAutoresizingMaskIntoConstraints = NO;
    limitStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    limitStack.alignment = NSLayoutAttributeCenterY;
    limitStack.spacing = 8;
    [limitStack addArrangedSubview:_saveLimitButton];
    [limitStack addArrangedSubview:_limitField];
    [limitStack addArrangedSubview:_limitUnitLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_limitField.widthAnchor constraintEqualToConstant:72],
    ]];
    [stack addArrangedSubview:limitStack];

    NSTextField* actionLabel = [NSTextField labelWithString:SZLocalizedString(@"memory.action")];
    actionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    actionLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [stack addArrangedSubview:actionLabel];

    _allowButton = [self radioButtonWithTitle:SZLocalizedString(@"memory.allowUnpacking") action:@selector(selectActionButton:)];
    _skipButton = [self radioButtonWithTitle:SZLocalizedString(@"memory.skipUnpacking") action:@selector(selectActionButton:)];
    _allowButton.state = self.installedRAMIsInsufficient ? NSControlStateValueOff : NSControlStateValueOn;
    _skipButton.state = self.installedRAMIsInsufficient ? NSControlStateValueOn : NSControlStateValueOff;
    _allowButton.accessibilityIdentifier = @"memoryLimit.allowButton";
    _skipButton.accessibilityIdentifier = @"memoryLimit.skipButton";

    NSStackView* actionStack = [[NSStackView alloc] init];
    actionStack.translatesAutoresizingMaskIntoConstraints = NO;
    actionStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    actionStack.alignment = NSLayoutAttributeLeading;
    actionStack.spacing = 6;
    [actionStack addArrangedSubview:_allowButton];
    [actionStack addArrangedSubview:_skipButton];
    [stack addArrangedSubview:actionStack];

    _rememberButton = [NSButton checkboxWithTitle:SZLocalizedString(@"memory.repeatAction") target:nil action:NULL];
    _rememberButton.translatesAutoresizingMaskIntoConstraints = NO;
    _rememberButton.hidden = !_showRemember;
    _rememberButton.accessibilityIdentifier = @"memoryLimit.rememberButton";
    if (_showRemember) {
        [stack addArrangedSubview:_rememberButton];
    }

    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintEqualToConstant:380],
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    self.view = container;
}

- (void)toggleSaveLimit:(NSButton*)sender {
    const BOOL enabled = sender.state == NSControlStateValueOn;
    _limitField.enabled = enabled;
    _limitUnitLabel.enabled = enabled;
    if (enabled && _limitField.integerValue <= 0) {
        _limitField.stringValue = [NSString stringWithFormat:@"%u", MAX(_requiredGB, 1u)];
    }
}

- (void)selectActionButton:(NSButton*)sender {
    const BOOL shouldSkip = sender == _skipButton;
    _allowButton.state = shouldSkip ? NSControlStateValueOff : NSControlStateValueOn;
    _skipButton.state = shouldSkip ? NSControlStateValueOn : NSControlStateValueOff;
}

- (BOOL)saveLimit {
    return _saveLimitButton.state == NSControlStateValueOn;
}

- (BOOL)skipArchive {
    return _skipButton.state == NSControlStateValueOn;
}

- (BOOL)rememberChoice {
    return _showRemember && _rememberButton.state == NSControlStateValueOn;
}

- (uint32_t)limitGB {
    if (!self.saveLimit) {
        return _currentLimitGB;
    }

    const NSInteger value = _limitField.integerValue;
    return value > 0 ? (uint32_t)value : MAX(_requiredGB, 1u);
}

- (NSView*)preferredFirstResponderView {
    return _allowButton;
}

@end

@implementation SZDialogPresenter

+ (SZDialogStyle)dialogStyleForPromptStyle:(SZOperationPromptStyle)promptStyle {
    switch (promptStyle) {
    case SZOperationPromptStyleWarning:
        return SZDialogStyleWarning;
    case SZOperationPromptStyleCritical:
        return SZDialogStyleCritical;
    case SZOperationPromptStyleInformational:
    default:
        return SZDialogStyleInformational;
    }
}

+ (NSString*)errorDetailsForError:(NSError*)error {
    NSMutableArray<NSString*>* parts = [NSMutableArray array];

    NSString* failureReason = error.localizedFailureReason;
    if (failureReason.length > 0 && ![failureReason isEqualToString:error.localizedDescription]) {
        [parts addObject:failureReason];
    }

    NSString* recoverySuggestion = error.localizedRecoverySuggestion;
    if (recoverySuggestion.length > 0) {
        [parts addObject:recoverySuggestion];
    }

    return [parts componentsJoinedByString:@"\n\n"];
}

+ (void)presentError:(NSError*)error forWindow:(NSWindow*)window {
    NSString* title = error.localizedDescription.length > 0 ? error.localizedDescription : SZLocalizedString(@"common.ok");
    NSString* message = [self errorDetailsForError:error];
    SZDialogStyle style = SZDialogStyleCritical;
    BOOL useDedicatedPopup = NO;
    if ([error.domain isEqualToString:SZArchiveErrorDomain] && error.code == SZArchiveErrorCodeWrongPassword) {
        style = SZDialogStyleWarning;
        useDedicatedPopup = YES;
    }

    SZModalDialogController* controller = [[SZModalDialogController alloc] initWithStyle:style
                                                                                   title:title
                                                                                 message:message
                                                                            buttonTitles:@[ SZLocalizedString(@"common.ok") ]
                                                                           accessoryView:nil
                                                                 preferredFirstResponder:nil
                                                                       cancelButtonIndex:0];
    if (window && !useDedicatedPopup) {
        [controller beginSheetModalForWindow:window completionHandler:^(__unused NSInteger selectedButtonIndex) { }];
    } else {
        [controller runModal];
    }
}

+ (void)presentMessageWithStyle:(SZDialogStyle)style
                          title:(NSString*)title
                        message:(NSString*)message
                    buttonTitle:(NSString*)buttonTitle
                      forWindow:(NSWindow*)window {
    SZModalDialogController* controller = [[SZModalDialogController alloc] initWithStyle:style
                                                                                   title:title
                                                                                 message:message
                                                                            buttonTitles:@[ buttonTitle ]
                                                                           accessoryView:nil
                                                                 preferredFirstResponder:nil
                                                                       cancelButtonIndex:0];
    if (window) {
        [controller beginSheetModalForWindow:window completionHandler:^(__unused NSInteger selectedButtonIndex) { }];
    } else {
        [controller runModal];
    }
}

+ (NSInteger)runMessageWithStyle:(SZDialogStyle)style
                           title:(NSString*)title
                         message:(NSString*)message
                    buttonTitles:(NSArray<NSString*>*)buttonTitles {
    NSInteger cancelButtonIndex = buttonTitles.count > 0 ? (NSInteger)buttonTitles.count - 1 : 0;
    NSString* localizedCancelTitle = SZLocalizedString(@"common.cancel");
    for (NSInteger index = 0; index < (NSInteger)buttonTitles.count; index++) {
        NSString* buttonTitle = buttonTitles[(NSUInteger)index];
        if ([buttonTitle caseInsensitiveCompare:@"Cancel"] == NSOrderedSame
            || [buttonTitle caseInsensitiveCompare:localizedCancelTitle] == NSOrderedSame) {
            cancelButtonIndex = index;
            break;
        }
    }

    SZModalDialogController* controller = [[SZModalDialogController alloc] initWithStyle:style
                                                                                   title:title
                                                                                 message:message
                                                                            buttonTitles:buttonTitles
                                                                           accessoryView:nil
                                                                 preferredFirstResponder:nil
                                                                       cancelButtonIndex:cancelButtonIndex];
    return [controller runModal];
}

+ (BOOL)promptForPasswordWithTitle:(NSString*)title
                           message:(NSString*)message
                      initialValue:(NSString*)initialValue
                          password:(NSString* _Nullable* _Nullable)password {
    SZPasswordAccessoryController* accessoryController = [[SZPasswordAccessoryController alloc] initWithInitialValue:initialValue];
    SZModalDialogController* controller = [[SZModalDialogController alloc] initWithStyle:SZDialogStyleWarning
                                                                                   title:title
                                                                                 message:message
                                                                            buttonTitles:@[ SZLocalizedString(@"common.cancel"), SZLocalizedString(@"common.ok") ]
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

+ (BOOL)promptForMemoryLimitWithRequiredBytes:(uint64_t)requiredBytes
                            currentLimitBytes:(uint64_t)currentLimitBytes
                                  archivePath:(NSString*)archivePath
                                     filePath:(NSString*)filePath
                                     testMode:(BOOL)testMode
                                 showRemember:(BOOL)showRemember
                                       result:(SZMemoryLimitPromptResult* _Nullable* _Nullable)result {
    SZMemoryLimitAccessoryController* accessoryController = [[SZMemoryLimitAccessoryController alloc] initWithRequiredBytes:requiredBytes
                                                                                                          currentLimitBytes:currentLimitBytes
                                                                                                                archivePath:archivePath
                                                                                                                   filePath:filePath
                                                                                                               showRemember:showRemember];

    NSString* message = SZLocalizedString(@"memory.requiresBigRAM");
    if (accessoryController.installedRAMIsInsufficient) {
        message = [message stringByAppendingFormat:@" %@",
            SZLocalizedString(@"memory.blocked")];
    }

    SZModalDialogController* controller = [[SZModalDialogController alloc] initWithStyle:(accessoryController.installedRAMIsInsufficient ? SZDialogStyleCritical : SZDialogStyleWarning)
                                                                                   title:SZLocalizedString(@"memory.usageRequest")
                                                                                 message:message
                                                                            buttonTitles:@[ SZLocalizedString(@"common.cancel"), SZLocalizedString(@"common.continue") ]
                                                                           accessoryView:accessoryController.view
                                                                 preferredFirstResponder:accessoryController.preferredFirstResponderView
                                                                       cancelButtonIndex:0];

    NSInteger selectedButtonIndex = [controller runModal];
    if (selectedButtonIndex != 1) {
        return NO;
    }

    if (result) {
        SZMemoryLimitPromptResult* promptResult = [SZMemoryLimitPromptResult new];
        promptResult.saveLimit = accessoryController.saveLimit;
        promptResult.skipArchive = accessoryController.skipArchive;
        promptResult.rememberChoice = accessoryController.rememberChoice;
        promptResult.limitGB = accessoryController.limitGB;
        *result = promptResult;
    }
    return YES;
}

@end