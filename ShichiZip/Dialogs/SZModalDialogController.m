#import "SZModalDialogController.h"

#import "SZDialogPresenter.h"

static const CGFloat SZModalDialogMinimumContentWidth = 440.0;
static const CGFloat SZModalDialogMaximumTextColumnWidth = 520.0;

@implementation SZDialogAction

- (instancetype)initWithTitle:(NSString*)title roles:(SZDialogActionRole)roles {
    if ((self = [super init])) {
        _title = [title copy];
        _roles = roles;
    }
    return self;
}

@end

@interface SZModalDialogWindow : NSWindow

@property (nonatomic, weak, nullable) NSButton* cancelButton;

@end

@implementation SZModalDialogWindow

- (BOOL)performKeyEquivalent:(NSEvent*)event {
    const NSEventModifierFlags disallowedModifiers = NSEventModifierFlagCommand
        | NSEventModifierFlagControl
        | NSEventModifierFlagOption
        | NSEventModifierFlagShift;
    if ((event.modifierFlags & disallowedModifiers) == 0
        && [event.charactersIgnoringModifiers isEqualToString:@"\e"]) {
        if (self.cancelButton.enabled) {
            [self.cancelButton performClick:nil];
        } else {
            NSBeep();
        }
        return YES;
    }

    return [super performKeyEquivalent:event];
}

@end

static NSInteger SZModalDialogUniqueActionIndex(NSArray<SZDialogAction*>* actions,
                                                SZDialogActionRole role,
                                                NSString* roleName) {
    NSInteger matchingIndex = NSNotFound;
    for (NSInteger index = 0; index < (NSInteger)actions.count; index++) {
        SZDialogAction* action = actions[(NSUInteger)index];
        if ((action.roles & role) == 0) {
            continue;
        }
        if (matchingIndex != NSNotFound) {
            [NSException raise:NSInvalidArgumentException
                        format:@"SZModalDialogController requires exactly one %@ action", roleName];
        }
        matchingIndex = index;
    }

    if (matchingIndex == NSNotFound) {
        [NSException raise:NSInvalidArgumentException
                    format:@"SZModalDialogController requires exactly one %@ action", roleName];
    }
    return matchingIndex;
}

static NSString* SZModalDialogAppDisplayName(void) {
    NSBundle* bundle = NSBundle.mainBundle;
    NSString* displayName = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    if (displayName.length > 0) {
        return displayName;
    }

    NSString* bundleName = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
    if (bundleName.length > 0) {
        return bundleName;
    }

    return @"ShichiZip";
}

@interface SZModalDialogContentViewController : NSViewController

- (instancetype)initWithStyle:(SZDialogStyle)style
                        title:(NSString*)title
                      message:(nullable NSString*)message
                      actions:(NSArray<SZDialogAction*>*)actions
                accessoryView:(nullable NSView*)accessoryView
      preferredFirstResponder:(nullable NSView*)preferredFirstResponder
                       target:(id)target
                       action:(SEL)action;

@property (nonatomic, readonly) NSView* preferredFirstResponderView;
@property (nonatomic, copy, readonly) NSArray<NSButton*>* dialogButtons;

@end

@interface SZModalDialogController () <NSWindowDelegate>

@property (nonatomic) NSInteger cancelButtonIndex;
@property (nonatomic) NSInteger selectedButtonIndex;
@property (nonatomic, copy, nullable) SZModalDialogCompletionHandler completionHandler;
@property (nonatomic, strong) SZModalDialogContentViewController* contentController;
@property (nonatomic, strong, nullable) SZModalDialogController* selfRetainer;

@end

@implementation SZModalDialogContentViewController {
    SZDialogStyle _style;
    NSString* _dialogTitle;
    NSString* _dialogMessage;
    NSArray<SZDialogAction*>* _actions;
    NSView* _accessoryView;
    NSView* _preferredFirstResponderView;
    NSArray<NSButton*>* _dialogButtons;
    __weak id _target;
    SEL _action;
}

- (CGFloat)minimumContentWidth {
    CGFloat minimumWidth = SZModalDialogMinimumContentWidth;
    if (_accessoryView) {
        const CGFloat accessoryWidth = _accessoryView.fittingSize.width + 86;
        if (accessoryWidth > minimumWidth) {
            minimumWidth = accessoryWidth;
        }
    }
    const CGFloat buttonRowWidth = [self minimumButtonRowWidth];
    if (buttonRowWidth > minimumWidth) {
        minimumWidth = buttonRowWidth;
    }
    return minimumWidth;
}

- (CGFloat)minimumButtonRowWidth {
    if (_actions.count == 0) {
        return 0;
    }

    CGFloat totalWidth = 40;
    totalWidth += (_actions.count - 1) * 8;

    for (SZDialogAction* action in _actions) {
        NSButton* button = [NSButton buttonWithTitle:action.title target:nil action:NULL];
        NSSize fittingSize = button.fittingSize;
        totalWidth += ceil(fittingSize.width);
    }

    return totalWidth;
}

- (instancetype)initWithStyle:(SZDialogStyle)style
                        title:(NSString*)title
                      message:(NSString*)message
                      actions:(NSArray<SZDialogAction*>*)actions
                accessoryView:(NSView*)accessoryView
      preferredFirstResponder:(NSView*)preferredFirstResponder
                       target:(id)target
                       action:(SEL)action {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _style = style;
        _dialogTitle = [title copy];
        _dialogMessage = [message copy] ?: @"";
        _actions = [actions copy];
        _accessoryView = accessoryView;
        _preferredFirstResponderView = preferredFirstResponder;
        _target = target;
        _action = action;
    }
    return self;
}

- (NSImage*)symbolImage {
    NSString* symbolName = @"info.circle.fill";
    NSColor* tintColor = NSColor.systemBlueColor;

    switch (_style) {
    case SZDialogStyleWarning:
        symbolName = @"exclamationmark.triangle.fill";
        tintColor = NSColor.systemOrangeColor;
        break;
    case SZDialogStyleCritical:
        symbolName = @"xmark.octagon.fill";
        tintColor = NSColor.systemRedColor;
        break;
    case SZDialogStyleInformational:
    default:
        break;
    }

    NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration configurationWithPointSize:30 weight:NSFontWeightMedium];
    NSImage* image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    image = [image imageWithSymbolConfiguration:config];
    image.template = YES;

    NSImageView* imageView = [[NSImageView alloc] init];
    imageView.image = image;
    imageView.contentTintColor = tintColor;
    return imageView.image;
}

- (void)loadView {
    NSView* container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, SZModalDialogMinimumContentWidth, 200)];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    const BOOL hasMessage = _dialogMessage.length > 0;

    NSImageView* iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.image = [self symbolImage];
    switch (_style) {
    case SZDialogStyleWarning:
        iconView.contentTintColor = NSColor.systemOrangeColor;
        break;
    case SZDialogStyleCritical:
        iconView.contentTintColor = NSColor.systemRedColor;
        break;
    case SZDialogStyleInformational:
    default:
        iconView.contentTintColor = NSColor.systemBlueColor;
        break;
    }
    [container addSubview:iconView];

    NSTextField* titleLabel = [NSTextField labelWithString:_dialogTitle];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    titleLabel.maximumNumberOfLines = 0;
    titleLabel.preferredMaxLayoutWidth = SZModalDialogMaximumTextColumnWidth;
    [titleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [titleLabel.widthAnchor constraintLessThanOrEqualToConstant:SZModalDialogMaximumTextColumnWidth].active = YES;

    NSStackView* textStack = [[NSStackView alloc] init];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    textStack.alignment = NSLayoutAttributeLeading;
    textStack.spacing = hasMessage ? 6 : 0;
    [textStack addArrangedSubview:titleLabel];
    if (hasMessage) {
        NSTextField* messageLabel = [NSTextField wrappingLabelWithString:_dialogMessage];
        messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
        messageLabel.font = [NSFont systemFontOfSize:12];
        messageLabel.textColor = NSColor.secondaryLabelColor;
        messageLabel.lineBreakMode = NSLineBreakByCharWrapping;
        messageLabel.maximumNumberOfLines = 0;
        messageLabel.preferredMaxLayoutWidth = SZModalDialogMaximumTextColumnWidth;
        messageLabel.accessibilityIdentifier = @"modal.message";
        [messageLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [messageLabel.widthAnchor constraintLessThanOrEqualToConstant:SZModalDialogMaximumTextColumnWidth].active = YES;
        [textStack addArrangedSubview:messageLabel];
    }
    [container addSubview:textStack];

    NSView* accessoryContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    accessoryContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:accessoryContainer];

    if (_accessoryView) {
        _accessoryView.translatesAutoresizingMaskIntoConstraints = NO;
        [accessoryContainer addSubview:_accessoryView];
        [NSLayoutConstraint activateConstraints:@[
            [_accessoryView.topAnchor constraintEqualToAnchor:accessoryContainer.topAnchor],
            [_accessoryView.leadingAnchor constraintEqualToAnchor:accessoryContainer.leadingAnchor],
            [_accessoryView.trailingAnchor constraintEqualToAnchor:accessoryContainer.trailingAnchor],
            [_accessoryView.bottomAnchor constraintEqualToAnchor:accessoryContainer.bottomAnchor],
        ]];
    }

    NSStackView* buttonStack = [[NSStackView alloc] init];
    buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
    buttonStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttonStack.spacing = 8;
    buttonStack.alignment = NSLayoutAttributeCenterY;
    [buttonStack setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [buttonStack setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [container addSubview:buttonStack];

    NSMutableArray<NSButton*>* buttons = [NSMutableArray arrayWithCapacity:_actions.count];

    for (NSInteger index = 0; index < (NSInteger)_actions.count; index++) {
        SZDialogAction* dialogAction = _actions[(NSUInteger)index];
        NSButton* button = [NSButton buttonWithTitle:dialogAction.title target:_target action:_action];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.tag = index;
        button.accessibilityIdentifier = [NSString stringWithFormat:@"modal.button.%ld", (long)index];
        [buttonStack addArrangedSubview:button];
        [buttons addObject:button];
    }

    _dialogButtons = [buttons copy];

    NSLayoutConstraint* accessoryHeight = [accessoryContainer.heightAnchor constraintGreaterThanOrEqualToConstant:_accessoryView ? 1 : 0];
    accessoryHeight.priority = _accessoryView ? NSLayoutPriorityRequired : NSLayoutPriorityDefaultLow;

    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintGreaterThanOrEqualToConstant:[self minimumContentWidth]],

        [iconView.topAnchor constraintEqualToAnchor:container.topAnchor
                                           constant:20],
        [iconView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                               constant:20],
        [iconView.widthAnchor constraintEqualToConstant:32],
        [iconView.heightAnchor constraintEqualToConstant:32],

        [textStack.topAnchor constraintEqualToAnchor:container.topAnchor
                                            constant:20],
        [textStack.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor
                                                constant:14],
        [textStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor
                                                 constant:-20],

        [accessoryContainer.topAnchor constraintEqualToAnchor:textStack.bottomAnchor
                                                     constant:_accessoryView ? (hasMessage ? 16 : 10) : 0],
        [accessoryContainer.leadingAnchor constraintEqualToAnchor:textStack.leadingAnchor],
        [accessoryContainer.trailingAnchor constraintEqualToAnchor:container.trailingAnchor
                                                          constant:-20],
        accessoryHeight,

        [buttonStack.topAnchor constraintEqualToAnchor:accessoryContainer.bottomAnchor
                                              constant:18],
        [buttonStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor
                                                               constant:20],
        [buttonStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor
                                                   constant:-20],
        [buttonStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor
                                                 constant:-16],
    ]];

    self.view = container;
}

- (NSView*)preferredFirstResponderView {
    return _preferredFirstResponderView;
}

@end

@implementation SZModalDialogController

- (instancetype)initWithWindow:(NSWindow*)window {
    self = [super initWithWindow:window];
    if (self) {
        _cancelButtonIndex = NSNotFound;
        _selectedButtonIndex = NSNotFound;
    }
    return self;
}

- (instancetype)initWithStyle:(SZDialogStyle)style
                        title:(NSString*)title
                      message:(NSString*)message
                      actions:(NSArray<SZDialogAction*>*)actions
                accessoryView:(NSView*)accessoryView
      preferredFirstResponder:(NSView*)preferredFirstResponder {
    if (actions.count == 0) {
        [NSException raise:NSInvalidArgumentException
                    format:@"SZModalDialogController requires at least one action"];
    }
    const NSInteger defaultButtonIndex = SZModalDialogUniqueActionIndex(actions,
                                                                        SZDialogActionRoleDefault,
                                                                        @"default");
    const NSInteger cancelButtonIndex = SZModalDialogUniqueActionIndex(actions,
                                                                       SZDialogActionRoleCancel,
                                                                       @"cancel");

    SZModalDialogWindow* window = [[SZModalDialogWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 200)
                                                                         styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView)
                                                                           backing:NSBackingStoreBuffered
                                                                             defer:NO];
    if ((self = [self initWithWindow:window])) {
        _cancelButtonIndex = cancelButtonIndex;
        _selectedButtonIndex = cancelButtonIndex;

        window.title = SZModalDialogAppDisplayName();
        window.titleVisibility = NSWindowTitleHidden;
        window.titlebarAppearsTransparent = YES;
        window.movableByWindowBackground = YES;
        window.releasedWhenClosed = NO;
        window.delegate = self;

        _contentController = [[SZModalDialogContentViewController alloc] initWithStyle:style
                                                                                 title:title
                                                                               message:message
                                                                               actions:actions
                                                                         accessoryView:accessoryView
                                                               preferredFirstResponder:preferredFirstResponder
                                                                                target:self
                                                                                action:@selector(buttonClicked:)];
        window.contentViewController = _contentController;
        [window.contentView layoutSubtreeIfNeeded];

        NSButton* defaultButton = _contentController.dialogButtons[(NSUInteger)defaultButtonIndex];
        window.defaultButtonCell = (NSButtonCell*)defaultButton.cell;
        window.cancelButton = _contentController.dialogButtons[(NSUInteger)cancelButtonIndex];

        NSSize fittingSize = _contentController.view.fittingSize;
        const CGFloat minimumWidth = [_contentController minimumContentWidth];
        if (fittingSize.width < minimumWidth) {
            fittingSize.width = minimumWidth;
        }
        [window setContentSize:fittingSize];
    }
    return self;
}

- (void)buttonClicked:(NSButton*)sender {
    if (self.shouldFinishHandler && !self.shouldFinishHandler(sender.tag)) {
        return;
    }

    [self finishWithButtonIndex:sender.tag];
}

- (void)finishWithButtonIndex:(NSInteger)buttonIndex {
    self.selectedButtonIndex = buttonIndex;

    if (self.window.sheetParent) {
        [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseOK + buttonIndex];
    } else if (NSApp.modalWindow == self.window) {
        [NSApp stopModalWithCode:NSModalResponseOK + buttonIndex];
        [self.window orderOut:nil];
        self.selfRetainer = nil;
    } else {
        [self.window close];
        self.selfRetainer = nil;
    }
}

- (void)setButtonEnabled:(BOOL)enabled atIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.contentController.dialogButtons.count) {
        return;
    }

    self.contentController.dialogButtons[(NSUInteger)index].enabled = enabled;
}

- (void)activatePreferredFirstResponder {
    NSView* firstResponder = self.contentController.preferredFirstResponderView;
    if (firstResponder) {
        [self.window makeFirstResponder:firstResponder];
    }
}

- (void)beginSheetModalForWindow:(NSWindow*)window
               completionHandler:(SZModalDialogCompletionHandler)completionHandler {
    NSWindow* sheetParent = [SZDialogPresenter sheetParentWindowForWindow:window];
    if (!sheetParent) {
        NSInteger buttonIndex = [self runModal];
        completionHandler(buttonIndex);
        return;
    }

    self.selfRetainer = self;
    self.completionHandler = completionHandler;

    [sheetParent beginSheet:self.window
          completionHandler:^(__unused NSModalResponse returnCode) {
              NSInteger buttonIndex = self.selectedButtonIndex;
              if (self.completionHandler) {
                  self.completionHandler(buttonIndex);
              }
              self.completionHandler = nil;
              self.selfRetainer = nil;
          }];

    [self activatePreferredFirstResponder];
}

- (NSInteger)runModal {
    self.selfRetainer = self;
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];

    [self activatePreferredFirstResponder];

    [NSApp runModalForWindow:self.window];
    [self.window orderOut:nil];

    NSInteger buttonIndex = self.selectedButtonIndex;
    self.selfRetainer = nil;
    return buttonIndex;
}

- (BOOL)windowShouldClose:(NSWindow*)sender {
    [self finishWithButtonIndex:self.cancelButtonIndex];
    return NO;
}

@end
