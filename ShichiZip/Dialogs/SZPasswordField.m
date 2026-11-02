#import "SZPasswordField.h"

@implementation SZPasswordField {
    NSSecureTextField* _secureField;
    NSTextField* _plainField;
}

- (instancetype)initWithValue:(NSString*)value
                  placeholder:(NSString*)placeholder
      accessibilityIdentifier:(NSString*)identifier {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 220, 24)])) {
        _enabled = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _secureField = [[NSSecureTextField alloc] initWithFrame:self.bounds];
        _plainField = [[NSTextField alloc] initWithFrame:self.bounds];
        for (NSTextField* field in @[ _secureField, _plainField ]) {
            field.translatesAutoresizingMaskIntoConstraints = NO;
            field.placeholderString = placeholder;
            field.stringValue = value;
            field.delegate = self;
            [self addSubview:field];
            [NSLayoutConstraint activateConstraints:@[
                [field.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
                [field.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
                [field.topAnchor constraintEqualToAnchor:self.topAnchor],
                [field.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            ]];
        }
        _secureField.accessibilityIdentifier = identifier;
        _plainField.accessibilityIdentifier = [identifier stringByAppendingString:@"Plain"];
        [self updateVisibility];
    }
    return self;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, 24);
}

- (NSTextField*)visibleField {
    return _showsPassword ? _plainField : _secureField;
}

- (NSString*)stringValue {
    return self.visibleField.stringValue;
}

- (void)setStringValue:(NSString*)value {
    for (NSTextField* field in @[ _secureField, _plainField ]) {
        if (![field.stringValue isEqualToString:value]) {
            field.stringValue = value;
        }
    }
}

- (void)setShowsPassword:(BOOL)showsPassword {
    [self setShowsPassword:showsPassword moveFocus:NO];
}

- (void)setShowsPassword:(BOOL)showsPassword moveFocus:(BOOL)moveFocus {
    NSTextField* previousField = self.visibleField;
    NSText* editor = previousField.currentEditor;
    BOOL hasFocus = editor && self.window.firstResponder == editor;
    NSRange selection = hasFocus ? editor.selectedRange : NSMakeRange(NSNotFound, 0);
    BOOL changed = _showsPassword != showsPassword;
    if (changed) {
        NSString* value = previousField.stringValue;
        _secureField.stringValue = value;
        _plainField.stringValue = value;
        _showsPassword = showsPassword;
        [self updateVisibility];
    }
    if (_enabled && ((changed && hasFocus) || (moveFocus && !hasFocus))
        && [self.window makeFirstResponder:self.visibleField]) {
        if (hasFocus) {
            self.visibleField.currentEditor.selectedRange = selection;
        }
    }
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [self updateVisibility];
}

- (void)updateVisibility {
    _secureField.hidden = _showsPassword;
    _secureField.enabled = _enabled && !_showsPassword;
    _plainField.hidden = !_showsPassword;
    _plainField.enabled = _enabled && _showsPassword;
}

- (void)setAccessibilityLabel:(NSString*)accessibilityLabel {
    [super setAccessibilityLabel:accessibilityLabel];
    _secureField.accessibilityLabel = accessibilityLabel;
    _plainField.accessibilityLabel = accessibilityLabel;
}

- (void)controlTextDidChange:(NSNotification*)notification {
    NSTextField* field = notification.object;
    NSTextField* otherField = field == _secureField ? _plainField : _secureField;
    otherField.stringValue = field.stringValue;
    if (self.textDidChangeHandler) {
        self.textDidChangeHandler(field.stringValue);
    }
}

@end
