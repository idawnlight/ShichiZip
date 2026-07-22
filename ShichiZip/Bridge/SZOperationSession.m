#import "SZOperationSession.h"

#import <QuartzCore/QuartzCore.h>

#import "SZArchive.h"

static inline void SZDispatchSyncOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static const CFTimeInterval SZOperationSnapshotMinimumInterval = 0.05;
static const NSUInteger SZOperationIssueDetailLimit = 256;

@implementation SZOperationChoiceRequest

- (instancetype)initWithStyle:(SZOperationPromptStyle)style
                        title:(NSString*)title
                      message:(NSString*)message
                 buttonTitles:(NSArray<NSString*>*)buttonTitles
           defaultButtonIndex:(NSInteger)defaultButtonIndex
            cancelButtonIndex:(NSInteger)cancelButtonIndex {
    const NSInteger buttonCount = (NSInteger)buttonTitles.count;
    if (buttonCount == 0
        || defaultButtonIndex < 0
        || defaultButtonIndex >= buttonCount
        || cancelButtonIndex < 0
        || cancelButtonIndex >= buttonCount) {
        [NSException raise:NSInvalidArgumentException
                    format:@"SZOperationChoiceRequest requires nonempty buttons and in-range default and cancel indices"];
    }

    if ((self = [super init])) {
        _style = style;
        _title = [title copy];
        _message = [message copy];
        _buttonTitles = [buttonTitles copy];
        _defaultButtonIndex = defaultButtonIndex;
        _cancelButtonIndex = cancelButtonIndex;
    }
    return self;
}

@end

@interface SZOperationSnapshot ()

- (instancetype)initWithPhase:(SZOperationPhase)phase
             progressFraction:(double)progressFraction
              currentFileName:(NSString*)currentFileName
               bytesCompleted:(uint64_t)bytesCompleted
                   bytesTotal:(uint64_t)bytesTotal
               filesCompleted:(uint64_t)filesCompleted
                   filesTotal:(uint64_t)filesTotal
          hasReportedProgress:(BOOL)hasReportedProgress
    waitingForUserInteraction:(BOOL)waitingForUserInteraction
        cancellationRequested:(BOOL)cancellationRequested
          cancellationAllowed:(BOOL)cancellationAllowed
                       issues:(NSArray<SZArchiveUpdateIssue*>*)issues
              totalIssueCount:(uint64_t)totalIssueCount
              issuesTruncated:(BOOL)issuesTruncated;

@end

@implementation SZOperationSnapshot

- (instancetype)initWithPhase:(SZOperationPhase)phase
             progressFraction:(double)progressFraction
              currentFileName:(NSString*)currentFileName
               bytesCompleted:(uint64_t)bytesCompleted
                   bytesTotal:(uint64_t)bytesTotal
               filesCompleted:(uint64_t)filesCompleted
                   filesTotal:(uint64_t)filesTotal
          hasReportedProgress:(BOOL)hasReportedProgress
    waitingForUserInteraction:(BOOL)waitingForUserInteraction
        cancellationRequested:(BOOL)cancellationRequested
          cancellationAllowed:(BOOL)cancellationAllowed
                       issues:(NSArray<SZArchiveUpdateIssue*>*)issues
              totalIssueCount:(uint64_t)totalIssueCount
              issuesTruncated:(BOOL)issuesTruncated {
    if ((self = [super init])) {
        _phase = phase;
        _progressFraction = progressFraction;
        _currentFileName = [currentFileName copy] ?: @"";
        _bytesCompleted = bytesCompleted;
        _bytesTotal = bytesTotal;
        _filesCompleted = filesCompleted;
        _filesTotal = filesTotal;
        _hasReportedProgress = hasReportedProgress;
        _waitingForUserInteraction = waitingForUserInteraction;
        _cancellationRequested = cancellationRequested;
        _cancellationAllowed = cancellationAllowed;
        _issues = [issues copy] ?: @[];
        _totalIssueCount = totalIssueCount;
        _issuesTruncated = issuesTruncated;
    }
    return self;
}

@end

@interface SZOperationSession () {
    SZOperationPhase _phase;
    double _progressFraction;
    NSString* _currentFileName;
    uint64_t _bytesCompleted;
    uint64_t _bytesTotal;
    uint64_t _filesCompleted;
    uint64_t _filesTotal;
    BOOL _hasReportedProgress;
    BOOL _waitingForUserInteraction;
    BOOL _cancellationRequested;
    BOOL _cancellationAllowed;
    NSMutableArray<SZArchiveUpdateIssue*>* _issues;
    uint64_t _totalIssueCount;
    BOOL _issuesTruncated;
    CFTimeInterval _lastSnapshotDispatchTime;
    BOOL _snapshotDispatchScheduled;
    SZOperationSnapshotHandler _snapshotHandler;
}

@end

@implementation SZOperationSession

- (instancetype)init {
    if ((self = [super init])) {
        _phase = SZOperationPhaseWaiting;
        _currentFileName = @"";
        _cancellationAllowed = YES;
        _issues = [NSMutableArray array];
    }
    return self;
}

- (SZOperationSnapshotHandler)snapshotHandler {
    @synchronized(self) {
        return [_snapshotHandler copy];
    }
}

- (void)setSnapshotHandler:(SZOperationSnapshotHandler)snapshotHandler {
    @synchronized(self) {
        _snapshotHandler = [snapshotHandler copy];
    }
    [self scheduleSnapshotDelivery];
}

- (SZOperationPhase)phase {
    @synchronized(self) {
        return _phase;
    }
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

- (uint64_t)filesTotal {
    @synchronized(self) {
        return _filesTotal;
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

- (BOOL)isCancellationAllowed {
    @synchronized(self) {
        return _cancellationAllowed;
    }
}

- (uint64_t)totalIssueCount {
    @synchronized(self) {
        return _totalIssueCount;
    }
}

- (void)reportPhase:(SZOperationPhase)phase {
    @synchronized(self) {
        _phase = phase;
    }
    [self scheduleSnapshotDelivery];
}

- (void)reportProgressFraction:(double)fraction {
    const double clamped = MIN(MAX(fraction, 0.0), 1.0);
    @synchronized(self) {
        _progressFraction = clamped;
        _hasReportedProgress = YES;
    }
    [self scheduleSnapshotDelivery];
}

- (void)reportCurrentFileName:(NSString*)fileName {
    @synchronized(self) {
        _currentFileName = [fileName copy] ?: @"";
    }
    [self scheduleSnapshotDelivery];
}

- (void)reportBytesCompleted:(uint64_t)completed total:(uint64_t)total {
    @synchronized(self) {
        _bytesCompleted = completed;
        _bytesTotal = total;
        if (total > 0) {
            _progressFraction = MIN((double)completed / (double)total, 1.0);
            _hasReportedProgress = YES;
        }
    }
    [self scheduleSnapshotDelivery];
}

- (void)reportFilesCompleted:(uint64_t)count {
    @synchronized(self) {
        _filesCompleted = count;
    }
    [self scheduleSnapshotDelivery];
}

- (void)reportFilesTotal:(uint64_t)count {
    @synchronized(self) {
        _filesTotal = count;
    }
    [self scheduleSnapshotDelivery];
}

- (void)reportUpdateIssue:(SZArchiveUpdateIssue*)issue {
    if (!issue) {
        return;
    }

    @synchronized(self) {
        _totalIssueCount++;
        if (_issues.count < SZOperationIssueDetailLimit) {
            [_issues addObject:issue];
        } else {
            _issuesTruncated = YES;
        }
    }
    [self scheduleSnapshotDelivery];
}

- (BOOL)shouldCancel {
    return self.cancellationRequested;
}

- (void)requestCancel {
    @synchronized(self) {
        if (!_cancellationAllowed) {
            return;
        }
        _cancellationRequested = YES;
        _phase = SZOperationPhaseCancelling;
    }
    [self scheduleSnapshotDelivery];
}

- (void)clearCancellationRequest {
    @synchronized(self) {
        _cancellationRequested = NO;
        if (_phase == SZOperationPhaseCancelling) {
            _phase = SZOperationPhaseWaiting;
        }
    }
    [self scheduleSnapshotDelivery];
}

- (void)beginFinalizing {
    @synchronized(self) {
        _cancellationRequested = NO;
        _cancellationAllowed = NO;
        _phase = SZOperationPhaseFinalizing;
    }
    [self scheduleSnapshotDelivery];
}

- (void)prepareForUserInteraction {
    @synchronized(self) {
        _waitingForUserInteraction = YES;
    }
    [self scheduleSnapshotDelivery];
}

- (void)finishUserInteraction {
    @synchronized(self) {
        _waitingForUserInteraction = NO;
    }
    [self scheduleSnapshotDelivery];
}

- (SZOperationSnapshot*)snapshot {
    @synchronized(self) {
        return [self newSnapshotWhileLocked];
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

- (NSInteger)requestChoice:(SZOperationChoiceRequest*)request {
    [self prepareForUserInteraction];

    SZOperationChoiceRequestHandler handler = self.choiceRequestHandler;
    if (!handler) {
        [self finishUserInteraction];
        return request.cancelButtonIndex;
    }

    __block NSInteger choice = request.cancelButtonIndex;
    SZDispatchSyncOnMain(^{
        choice = handler(request);
    });

    [self finishUserInteraction];
    if (choice < 0 || choice >= (NSInteger)request.buttonTitles.count) {
        return request.cancelButtonIndex;
    }
    return choice;
}

- (SZOperationSnapshot*)newSnapshotWhileLocked {
    return [[SZOperationSnapshot alloc]
                    initWithPhase:_phase
                 progressFraction:_progressFraction
                  currentFileName:_currentFileName
                   bytesCompleted:_bytesCompleted
                       bytesTotal:_bytesTotal
                   filesCompleted:_filesCompleted
                       filesTotal:_filesTotal
              hasReportedProgress:_hasReportedProgress
        waitingForUserInteraction:_waitingForUserInteraction
            cancellationRequested:_cancellationRequested
              cancellationAllowed:_cancellationAllowed
                           issues:_issues
                  totalIssueCount:_totalIssueCount
                  issuesTruncated:_issuesTruncated];
}

- (void)scheduleSnapshotDelivery {
    __block BOOL shouldSchedule = NO;
    __block CFTimeInterval delay = 0;

    @synchronized(self) {
        if (!_snapshotHandler || _snapshotDispatchScheduled) {
            return;
        }

        const CFTimeInterval now = CACurrentMediaTime();
        if (_lastSnapshotDispatchTime > 0) {
            delay = MAX(SZOperationSnapshotMinimumInterval
                    - (now - _lastSnapshotDispatchTime),
                0);
        }
        _snapshotDispatchScheduled = YES;
        shouldSchedule = YES;
    }

    if (!shouldSchedule) {
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                       (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            SZOperationSnapshotHandler handler;
            SZOperationSnapshot* snapshot;
            @synchronized(self) {
                self->_snapshotDispatchScheduled = NO;
                self->_lastSnapshotDispatchTime = CACurrentMediaTime();
                handler = [self->_snapshotHandler copy];
                snapshot = [self newSnapshotWhileLocked];
            }

            if (handler) {
                handler(snapshot);
            }
        });
}

@end
