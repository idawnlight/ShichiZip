#import "SZOperationSession.h"

#import <QuartzCore/QuartzCore.h>

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
    NSString* _currentFileName;
    uint64_t _bytesCompleted;
    uint64_t _bytesTotal;
    uint64_t _filesCompleted;
    BOOL _hasReportedProgress;
    BOOL _waitingForUserInteraction;
    BOOL _cancellationRequested;
    // Throttling state for progress dispatch to main. See
    // -reportProgressFraction: / -reportBytesCompleted:total: for rules.
    CFAbsoluteTime _lastProgressDispatchTime;
    CFAbsoluteTime _lastBytesDispatchTime;
}

@end

@interface SZOperationSnapshot ()

- (instancetype)initWithProgressFraction:(double)progressFraction
                         currentFileName:(NSString*)currentFileName
                          bytesCompleted:(uint64_t)bytesCompleted
                              bytesTotal:(uint64_t)bytesTotal
                          filesCompleted:(uint64_t)filesCompleted
                     hasReportedProgress:(BOOL)hasReportedProgress
               waitingForUserInteraction:(BOOL)waitingForUserInteraction
                   cancellationRequested:(BOOL)cancellationRequested;

@end

@implementation SZOperationSnapshot {
    double _progressFraction;
    NSString* _currentFileName;
    uint64_t _bytesCompleted;
    uint64_t _bytesTotal;
    uint64_t _filesCompleted;
    BOOL _hasReportedProgress;
    BOOL _waitingForUserInteraction;
    BOOL _cancellationRequested;
}

- (instancetype)initWithProgressFraction:(double)progressFraction
                         currentFileName:(NSString*)currentFileName
                          bytesCompleted:(uint64_t)bytesCompleted
                              bytesTotal:(uint64_t)bytesTotal
                          filesCompleted:(uint64_t)filesCompleted
                     hasReportedProgress:(BOOL)hasReportedProgress
               waitingForUserInteraction:(BOOL)waitingForUserInteraction
                   cancellationRequested:(BOOL)cancellationRequested {
    if ((self = [super init])) {
        _progressFraction = progressFraction;
        _currentFileName = [currentFileName copy] ?: @"";
        _bytesCompleted = bytesCompleted;
        _bytesTotal = bytesTotal;
        _filesCompleted = filesCompleted;
        _hasReportedProgress = hasReportedProgress;
        _waitingForUserInteraction = waitingForUserInteraction;
        _cancellationRequested = cancellationRequested;
    }
    return self;
}

- (double)progressFraction {
    return _progressFraction;
}

- (NSString*)currentFileName {
    return [_currentFileName copy];
}

- (uint64_t)bytesCompleted {
    return _bytesCompleted;
}

- (uint64_t)bytesTotal {
    return _bytesTotal;
}

- (uint64_t)filesCompleted {
    return _filesCompleted;
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
    @synchronized(self) {
        return _progressFraction;
    }
}

- (NSString*)currentFileName {
    @synchronized(self) {
        return [_currentFileName copy];
    }
}

- (uint64_t)bytesCompleted {
    @synchronized(self) {
        return _bytesCompleted;
    }
}

- (uint64_t)bytesTotal {
    @synchronized(self) {
        return _bytesTotal;
    }
}

- (uint64_t)filesCompleted {
    @synchronized(self) {
        return _filesCompleted;
    }
}

- (BOOL)hasReportedProgress {
    @synchronized(self) {
        return _hasReportedProgress;
    }
}

- (BOOL)isWaitingForUserInteraction {
    @synchronized(self) {
        return _waitingForUserInteraction;
    }
}

- (BOOL)isCancellationRequested {
    @synchronized(self) {
        return _cancellationRequested;
    }
}

- (void)reportProgressFraction:(double)fraction {
    const double clamped = MIN(MAX(fraction, 0.0), 1.0);
    BOOL shouldDispatch;
    @synchronized(self) {
        _progressFraction = clamped;
        _hasReportedProgress = YES;
        // Coalesce live updates so 7-Zip's per-frame SetCompleted does
        // not swamp the main queue. Always deliver the terminal value
        // (>=1.0) and the first report; otherwise gate to ~50 ms.
        // Use CACurrentMediaTime (monotonic) rather than
        // CFAbsoluteTimeGetCurrent: wall-clock time can jump backwards
        // on NTP correction or manual clock change, which would make
        // (now - _last) negative and throttle every subsequent report
        // until real time caught up.
        const CFTimeInterval now = CACurrentMediaTime();
        const CFTimeInterval kMinInterval = 0.05;
        shouldDispatch = (clamped >= 1.0)
            || (_lastProgressDispatchTime == 0)
            || (now - _lastProgressDispatchTime >= kMinInterval);
        if (shouldDispatch) {
            _lastProgressDispatchTime = now;
        }
    }

    id<SZProgressDelegate> delegate = self.progressDelegate;
    if (!delegate || !shouldDispatch) {
        return;
    }

    SZDispatchAsyncOnMain(^{
        [delegate progressDidUpdate:clamped];
    });
}

- (void)reportCurrentFileName:(NSString*)fileName {
    NSString* resolvedFileName = [fileName copy] ?: @"";
    @synchronized(self) {
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
    BOOL shouldDispatch;
    @synchronized(self) {
        _bytesCompleted = completed;
        _bytesTotal = total;
        const CFTimeInterval now = CACurrentMediaTime();
        const CFTimeInterval kMinInterval = 0.05;
        shouldDispatch = (total > 0 && completed >= total)
            || (_lastBytesDispatchTime == 0)
            || (now - _lastBytesDispatchTime >= kMinInterval);
        if (shouldDispatch) {
            _lastBytesDispatchTime = now;
        }
    }

    id<SZProgressDelegate> delegate = self.progressDelegate;
    if (!delegate || !shouldDispatch) {
        return;
    }

    SZDispatchAsyncOnMain(^{
        [delegate progressDidUpdateBytesCompleted:completed total:total];
    });
}

- (void)reportFilesCompleted:(uint64_t)count {
    @synchronized(self) {
        _filesCompleted = count;
    }
}

- (BOOL)shouldCancel {
    // Worker threads poll this method on every decoder/encoder tick, so
    // it must never hop to the main thread. Callers that originate
    // cancellation on the main thread are expected to mirror their
    // intent through -requestCancel (see ArchiveOperationCoordinator's
    // periodic snapshot loop, which pushes the ProgressDialog's
    // cancelled state into the session). Reading the atomic flag here
    // avoids a dispatch_sync deadlock whenever the main thread is busy
    // running a modal alert or another synchronous UI request.
    return self.cancellationRequested;
}

- (void)requestCancel {
    @synchronized(self) {
        _cancellationRequested = YES;
    }
}

- (void)clearCancellationRequest {
    @synchronized(self) {
        _cancellationRequested = NO;
    }

    id<SZProgressDelegate> delegate = self.progressDelegate;
    if (!delegate || ![delegate respondsToSelector:@selector(progressResetCancellationRequest)]) {
        return;
    }

    SZDispatchSyncOnMain(^{
        [delegate progressResetCancellationRequest];
    });
}

- (void)prepareForUserInteraction {
    @synchronized(self) {
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

- (void)finishUserInteraction {
    @synchronized(self) {
        _waitingForUserInteraction = NO;
    }
}

- (SZOperationSnapshot*)snapshot {
    @synchronized(self) {
        return [[SZOperationSnapshot alloc]
             initWithProgressFraction:_progressFraction
                      currentFileName:_currentFileName
                       bytesCompleted:_bytesCompleted
                           bytesTotal:_bytesTotal
                       filesCompleted:_filesCompleted
                  hasReportedProgress:_hasReportedProgress
            waitingForUserInteraction:_waitingForUserInteraction
                cancellationRequested:_cancellationRequested];
    }
}

- (BOOL)requestPasswordWithTitle:(NSString*)title
                         message:(NSString*)message
                    initialValue:(NSString*)initialValue
                        password:(NSString* _Nullable* _Nullable)password {
    [self prepareForUserInteraction];

    SZOperationPasswordRequestHandler handler = self.passwordRequestHandler;
    if (!handler) {
        [self finishUserInteraction];
        return NO;
    }

    __block BOOL confirmed = NO;
    __block NSString* resolvedPassword = nil;
    SZDispatchSyncOnMain(^{
        NSString* promptPassword = nil;
        confirmed = handler(title, message, initialValue, &promptPassword);
        resolvedPassword = [promptPassword copy];
    });

    [self finishUserInteraction];

    if (password) {
        *password = resolvedPassword;
    }
    return confirmed;
}

- (NSInteger)requestChoiceWithStyle:(SZOperationPromptStyle)style
                              title:(NSString*)title
                            message:(NSString*)message
                       buttonTitles:(NSArray<NSString*>*)buttonTitles {
    [self prepareForUserInteraction];

    NSInteger defaultChoice = buttonTitles.count > 0 ? (NSInteger)buttonTitles.count - 1 : 0;
    SZOperationChoiceRequestHandler handler = self.choiceRequestHandler;
    if (!handler) {
        [self finishUserInteraction];
        return defaultChoice;
    }

    __block NSInteger choice = defaultChoice;
    SZDispatchSyncOnMain(^{
        choice = handler(style, title, message, buttonTitles);
    });

    [self finishUserInteraction];
    return choice;
}

@end