#import "SZOperationSession.h"

#import "SZArchive.h"

static inline void SZDispatchAsyncOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static inline void SZDispatchSyncOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

@interface SZOperationSession () {
    double _progressFraction;
    NSString *_currentFileName;
    uint64_t _bytesCompleted;
    uint64_t _bytesTotal;
    BOOL _hasReportedProgress;
    BOOL _waitingForUserInteraction;
    BOOL _cancellationRequested;
}

@end

@interface SZOperationSnapshot ()

- (instancetype)initWithProgressFraction:(double)progressFraction
                         currentFileName:(NSString *)currentFileName
                          bytesCompleted:(uint64_t)bytesCompleted
                               bytesTotal:(uint64_t)bytesTotal
                        hasReportedProgress:(BOOL)hasReportedProgress
                    waitingForUserInteraction:(BOOL)waitingForUserInteraction
                      cancellationRequested:(BOOL)cancellationRequested;

@end

@implementation SZOperationSnapshot {
    double _progressFraction;
    NSString *_currentFileName;
    uint64_t _bytesCompleted;
    uint64_t _bytesTotal;
    BOOL _hasReportedProgress;
    BOOL _waitingForUserInteraction;
    BOOL _cancellationRequested;
}

- (instancetype)initWithProgressFraction:(double)progressFraction
                         currentFileName:(NSString *)currentFileName
                          bytesCompleted:(uint64_t)bytesCompleted
                               bytesTotal:(uint64_t)bytesTotal
                        hasReportedProgress:(BOOL)hasReportedProgress
                    waitingForUserInteraction:(BOOL)waitingForUserInteraction
                      cancellationRequested:(BOOL)cancellationRequested {
    if ((self = [super init])) {
        _progressFraction = progressFraction;
        _currentFileName = [currentFileName copy] ?: @"";
        _bytesCompleted = bytesCompleted;
        _bytesTotal = bytesTotal;
        _hasReportedProgress = hasReportedProgress;
        _waitingForUserInteraction = waitingForUserInteraction;
        _cancellationRequested = cancellationRequested;
    }
    return self;
}

- (double)progressFraction {
    return _progressFraction;
}

- (NSString *)currentFileName {
    return [_currentFileName copy];
}

- (uint64_t)bytesCompleted {
    return _bytesCompleted;
}

- (uint64_t)bytesTotal {
    return _bytesTotal;
}

- (BOOL)hasReportedProgress {
    return _hasReportedProgress;
}

- (BOOL)isWaitingForUserInteraction {
    return _waitingForUserInteraction;
}

- (BOOL)isCancellationRequested {
    return _cancellationRequested;
}

@end

@implementation SZOperationSession

- (instancetype)init {
    if ((self = [super init])) {
        _currentFileName = @"";
    }
    return self;
}

- (double)progressFraction {
    @synchronized (self) {
        return _progressFraction;
    }
}

- (NSString *)currentFileName {
    @synchronized (self) {
        return [_currentFileName copy];
    }
}

- (uint64_t)bytesCompleted {
    @synchronized (self) {
        return _bytesCompleted;
    }
}

- (uint64_t)bytesTotal {
    @synchronized (self) {
        return _bytesTotal;
    }
}

- (BOOL)hasReportedProgress {
    @synchronized (self) {
        return _hasReportedProgress;
    }
}

- (BOOL)isWaitingForUserInteraction {
    @synchronized (self) {
        return _waitingForUserInteraction;
    }
}

- (BOOL)isCancellationRequested {
    @synchronized (self) {
        return _cancellationRequested;
    }
}

- (void)reportProgressFraction:(double)fraction {
    const double clamped = MIN(MAX(fraction, 0.0), 1.0);
    @synchronized (self) {
        _progressFraction = clamped;
        _hasReportedProgress = YES;
    }

    id<SZProgressDelegate> delegate = self.progressDelegate;
    if (!delegate) {
        return;
    }

    SZDispatchAsyncOnMain(^{
        [delegate progressDidUpdate:clamped];
    });
}

- (void)reportCurrentFileName:(NSString *)fileName {
    NSString *resolvedFileName = [fileName copy] ?: @"";
    @synchronized (self) {
        _currentFileName = resolvedFileName;
    }

    id<SZProgressDelegate> delegate = self.progressDelegate;
    if (!delegate) {
        return;
    }

    SZDispatchAsyncOnMain(^{
        [delegate progressDidUpdateFileName:resolvedFileName];
    });
}

- (void)reportBytesCompleted:(uint64_t)completed total:(uint64_t)total {
    @synchronized (self) {
        _bytesCompleted = completed;
        _bytesTotal = total;
    }

    id<SZProgressDelegate> delegate = self.progressDelegate;
    if (!delegate) {
        return;
    }

    SZDispatchAsyncOnMain(^{
        [delegate progressDidUpdateBytesCompleted:completed total:total];
    });
}

- (BOOL)shouldCancel {
    if (self.cancellationRequested) {
        return YES;
    }

    id<SZProgressDelegate> delegate = self.progressDelegate;
    if (!delegate) {
        return NO;
    }

    __block BOOL shouldCancel = NO;
    SZDispatchSyncOnMain(^{
        shouldCancel = [delegate progressShouldCancel];
    });
    return shouldCancel;
}

- (void)requestCancel {
    @synchronized (self) {
        _cancellationRequested = YES;
    }
}

- (void)prepareForUserInteraction {
    @synchronized (self) {
        _waitingForUserInteraction = YES;
    }

    id<SZProgressDelegate> delegate = self.progressDelegate;
    if (!delegate || ![delegate respondsToSelector:@selector(progressPrepareForUserInteraction)]) {
        return;
    }

    SZDispatchSyncOnMain(^{
        [delegate progressPrepareForUserInteraction];
    });
}

- (SZOperationSnapshot *)snapshot {
    @synchronized (self) {
        return [[SZOperationSnapshot alloc] initWithProgressFraction:_progressFraction
                                                     currentFileName:_currentFileName
                                                      bytesCompleted:_bytesCompleted
                                                           bytesTotal:_bytesTotal
                                                    hasReportedProgress:_hasReportedProgress
                                                waitingForUserInteraction:_waitingForUserInteraction
                                                  cancellationRequested:_cancellationRequested];
    }
}

- (BOOL)requestPasswordWithTitle:(NSString *)title
                         message:(NSString *)message
                    initialValue:(NSString *)initialValue
                        password:(NSString * _Nullable * _Nullable)password {
    [self prepareForUserInteraction];

    SZOperationPasswordRequestHandler handler = self.passwordRequestHandler;
    if (!handler) {
        @synchronized (self) {
            _waitingForUserInteraction = NO;
        }
        return NO;
    }

    __block BOOL confirmed = NO;
    __block NSString *resolvedPassword = nil;
    SZDispatchSyncOnMain(^{
        NSString *promptPassword = nil;
        confirmed = handler(title, message, initialValue, &promptPassword);
        resolvedPassword = [promptPassword copy];
    });

    @synchronized (self) {
        _waitingForUserInteraction = NO;
    }

    if (password) {
        *password = resolvedPassword;
    }
    return confirmed;
}

- (NSInteger)requestChoiceWithStyle:(SZOperationPromptStyle)style
                              title:(NSString *)title
                            message:(NSString *)message
                       buttonTitles:(NSArray<NSString *> *)buttonTitles {
    [self prepareForUserInteraction];

    NSInteger defaultChoice = buttonTitles.count > 0 ? (NSInteger)buttonTitles.count - 1 : 0;
    SZOperationChoiceRequestHandler handler = self.choiceRequestHandler;
    if (!handler) {
        @synchronized (self) {
            _waitingForUserInteraction = NO;
        }
        return defaultChoice;
    }

    __block NSInteger choice = defaultChoice;
    SZDispatchSyncOnMain(^{
        choice = handler(style, title, message, buttonTitles);
    });

    @synchronized (self) {
        _waitingForUserInteraction = NO;
    }
    return choice;
}

@end