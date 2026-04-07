#import "SZModalDialogController.h"

@interface SZModalDialogContentViewController : NSViewController

- (instancetype)initWithStyle:(SZDialogStyle)style
                        title:(NSString *)title
                      message:(nullable NSString *)message
                 buttonTitles:(NSArray<NSString *> *)buttonTitles
                accessoryView:(nullable NSView *)accessoryView
       preferredFirstResponder:(nullable NSView *)preferredFirstResponder
                      target:(id)target
                      action:(SEL)action;

@property (nonatomic, readonly) NSView *preferredFirstResponderView;

@end

@interface SZModalDialogController () <NSWindowDelegate>

@property (nonatomic) NSInteger cancelButtonIndex;
@property (nonatomic) NSInteger selectedButtonIndex;
@property (nonatomic, copy, nullable) SZModalDialogCompletionHandler completionHandler;
@property (nonatomic, strong) SZModalDialogContentViewController *contentController;
@property (nonatomic, strong, nullable) SZModalDialogController *selfRetainer;

@end

@implementation SZModalDialogContentViewController {
    SZDialogStyle _style;
    NSString *_dialogTitle;
    NSString *_dialogMessage;
    NSArray<NSString *> *_buttonTitles;
    NSView *_accessoryView;
    NSView *_preferredFirstResponderView;
    __weak id _target;
    SEL _action;
}

- (instancetype)initWithStyle:(SZDialogStyle)style
                        title:(NSString *)title
                      message:(NSString *)message
                 buttonTitles:(NSArray<NSString *> *)buttonTitles
                accessoryView:(NSView *)accessoryView
       preferredFirstResponder:(NSView *)preferredFirstResponder
                      target:(id)target
                      action:(SEL)action {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _style = style;
        _dialogTitle = [title copy];
        _dialogMessage = [message copy] ?: @"";
        _buttonTitles = [buttonTitles copy];
        _accessoryView = accessoryView;
        _preferredFirstResponderView = preferredFirstResponder;
        _target = target;
        _action = action;
    }
    return self;
}

- (NSImage *)symbolImage {
    NSString *symbolName = @"info.circle.fill";
    NSColor *tintColor = NSColor.systemBlueColor;

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

    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:30 weight:NSFontWeightMedium];
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    image = [image imageWithSymbolConfiguration:config];
    image.template = YES;

    NSImageView *imageView = [[NSImageView alloc] init];
    imageView.image = image;
    imageView.contentTintColor = tintColor;
    return imageView.image;
}

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 200)];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
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

    NSTextField *titleLabel = [NSTextField labelWithString:_dialogTitle];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    titleLabel.maximumNumberOfLines = 0;

    NSTextField *messageLabel = [NSTextField wrappingLabelWithString:_dialogMessage ?: @""];
    messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    messageLabel.font = [NSFont systemFontOfSize:12];
    messageLabel.textColor = NSColor.secondaryLabelColor;
    messageLabel.maximumNumberOfLines = 0;

    NSStackView *textStack = [[NSStackView alloc] init];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    textStack.alignment = NSLayoutAttributeLeading;
    textStack.spacing = 6;
    [textStack addArrangedSubview:titleLabel];
    [textStack addArrangedSubview:messageLabel];
    [container addSubview:textStack];

    NSView *accessoryContainer = [[NSView alloc] initWithFrame:NSZeroRect];
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

    NSStackView *buttonStack = [[NSStackView alloc] init];
    buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
    buttonStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttonStack.spacing = 8;
    buttonStack.alignment = NSLayoutAttributeCenterY;
    [container addSubview:buttonStack];

    for (NSInteger index = 0; index < (NSInteger)_buttonTitles.count; index++) {
        NSString *title = _buttonTitles[(NSUInteger)index];
        NSButton *button = [NSButton buttonWithTitle:title target:_target action:_action];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.tag = index;
        if (index == (NSInteger)_buttonTitles.count - 1) {
            button.keyEquivalent = @"\r";
        }
        if ([title caseInsensitiveCompare:@"Cancel"] == NSOrderedSame) {
            button.keyEquivalent = @"\e";
        }
        [buttonStack addArrangedSubview:button];
    }

    NSLayoutConstraint *accessoryHeight = [accessoryContainer.heightAnchor constraintGreaterThanOrEqualToConstant:_accessoryView ? 1 : 0];
    accessoryHeight.priority = _accessoryView ? NSLayoutPriorityRequired : NSLayoutPriorityDefaultLow;

    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintEqualToConstant:440],

        [iconView.topAnchor constraintEqualToAnchor:container.topAnchor constant:20],
        [iconView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20],
        [iconView.widthAnchor constraintEqualToConstant:32],
        [iconView.heightAnchor constraintEqualToConstant:32],

        [textStack.topAnchor constraintEqualToAnchor:container.topAnchor constant:20],
        [textStack.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [textStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20],

        [accessoryContainer.topAnchor constraintEqualToAnchor:textStack.bottomAnchor constant:_accessoryView ? 16 : 0],
        [accessoryContainer.leadingAnchor constraintEqualToAnchor:textStack.leadingAnchor],
        [accessoryContainer.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20],
        accessoryHeight,

        [buttonStack.topAnchor constraintEqualToAnchor:accessoryContainer.bottomAnchor constant:18],
        [buttonStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20],
        [buttonStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16],
    ]];

    self.view = container;
}

- (NSView *)preferredFirstResponderView {
    return _preferredFirstResponderView;
}

@end

@implementation SZModalDialogController

- (instancetype)initWithStyle:(SZDialogStyle)style
                        title:(NSString *)title
                      message:(NSString *)message
                 buttonTitles:(NSArray<NSString *> *)buttonTitles
                accessoryView:(NSView *)accessoryView
       preferredFirstResponder:(NSView *)preferredFirstResponder
            cancelButtonIndex:(NSInteger)cancelButtonIndex {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 200)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    if ((self = [super initWithWindow:window])) {
        _cancelButtonIndex = cancelButtonIndex;
        _selectedButtonIndex = cancelButtonIndex;

        window.title = @"ShichiZip";
        window.titleVisibility = NSWindowTitleHidden;
        window.titlebarAppearsTransparent = YES;
        window.movableByWindowBackground = YES;
        window.releasedWhenClosed = NO;
        window.delegate = self;

        _contentController = [[SZModalDialogContentViewController alloc] initWithStyle:style
                                                                                  title:title
                                                                                message:message
                                                                           buttonTitles:buttonTitles
                                                                          accessoryView:accessoryView
                                                                 preferredFirstResponder:preferredFirstResponder
                                                                                target:self
                                                                                action:@selector(buttonClicked:)];
        window.contentViewController = _contentController;
        [window.contentView layoutSubtreeIfNeeded];

        NSSize fittingSize = _contentController.view.fittingSize;
        if (fittingSize.width < 440) {
            fittingSize.width = 440;
        }
        [window setContentSize:fittingSize];
    }
    return self;
}

- (void)buttonClicked:(NSButton *)sender {
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

- (void)beginSheetModalForWindow:(NSWindow *)window
               completionHandler:(SZModalDialogCompletionHandler)completionHandler {
    self.selfRetainer = self;
    self.completionHandler = completionHandler;

    [window beginSheet:self.window completionHandler:^(__unused NSModalResponse returnCode) {
        NSInteger buttonIndex = self.selectedButtonIndex;
        if (self.completionHandler) {
            self.completionHandler(buttonIndex);
        }
        self.completionHandler = nil;
        self.selfRetainer = nil;
    }];

    NSView *firstResponder = self.contentController.preferredFirstResponderView;
    if (firstResponder) {
        [self.window makeFirstResponder:firstResponder];
    }
}

- (NSInteger)runModal {
    self.selfRetainer = self;
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];

    NSView *firstResponder = self.contentController.preferredFirstResponderView;
    if (firstResponder) {
        [self.window makeFirstResponder:firstResponder];
    }

    [NSApp runModalForWindow:self.window];
    [self.window orderOut:nil];

    NSInteger buttonIndex = self.selectedButtonIndex;
    self.selfRetainer = nil;
    return buttonIndex;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [self finishWithButtonIndex:self.cancelButtonIndex];
    return NO;
}

@end