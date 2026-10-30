#import "SZOperationSession.h"

#import <QuartzCore/QuartzCore.h>
#include <os/lock.h>

#import "SZArchive.h"

static inline void SZDispatchSyncOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static inline void SZUnlockUnfairLock(os_unfair_lock_t _Nonnull* _Nonnull lockPtr) {
    os_unfair_lock_unlock(*lockPtr);
}

#define SZ_SCOPED_LOCK_NAME(counter) szScopedLock##counter
#define SZ_SCOPED_LOCK_IMPL(lock, counter)                                                                \
    os_unfair_lock_t SZ_SCOPED_LOCK_NAME(counter) __attribute__((cleanup(SZUnlockUnfairLock))) = &(lock); \
    os_unfair_lock_lock(SZ_SCOPED_LOCK_NAME(counter))
#define SZ_SCOPED_LOCK(lock) SZ_SCOPED_LOCK_IMPL(lock, __COUNTER__)

static const CFTimeInterval SZOperationSnapshotMinimumInterval = 0.05;
static const NSUInteger SZOperationIssueDetailLimit = 256;
static SZOperationSessionFactory SZDefaultSessionFactory;

@implementation SZMemoryLimitPromptResult

- (instancetype)initWithSaveLimit:(BOOL)saveLimit
                      skipArchive:(BOOL)skipArchive
                   rememberChoice:(BOOL)rememberChoice
                          limitGB:(uint32_t)limitGB {
    if ((self = [super init])) {
        _saveLimit = saveLimit;
        _skipArchive = skipArchive;
        _rememberChoice = rememberChoice;
        _limitGB = limitGB;
    }
    return self;
}

@end

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
    os_unfair_lock _stateLock;
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

+ (SZOperationSessionFactory)defaultSessionFactory {
    @synchronized([SZOperationSession class]) {
        return [SZDefaultSessionFactory copy];
    }
}

+ (void)setDefaultSessionFactory:(SZOperationSessionFactory)factory {
    @synchronized([SZOperationSession class]) {
        SZDefaultSessionFactory = [factory copy];
    }
}

+ (SZOperationSession*)makeDefaultSession {
    SZOperationSessionFactory factory = self.defaultSessionFactory;
    return factory ? factory() : [[SZOperationSession alloc] init];
}

- (instancetype)init {
    if ((self = [super init])) {
        _stateLock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
        _phase = SZOperationPhaseWaiting;
        _currentFileName = @"";
        _cancellationAllowed = YES;
        _issues = [NSMutableArray array];
    }
    return self;
}

- (SZOperationSnapshotHandler)snapshotHandler {
    SZ_SCOPED_LOCK(_stateLock);
    return [_snapshotHandler copy];
}

- (void)setSnapshotHandler:(SZOperationSnapshotHandler)snapshotHandler {
    {
        SZ_SCOPED_LOCK(_stateLock);
        _snapshotHandler = [snapshotHandler copy];
    }
    [self scheduleSnapshotDelivery];
}

- (SZOperationPhase)phase {
    SZ_SCOPED_LOCK(_stateLock);
    return _phase;
}

- (double)progressFraction {
    SZ_SCOPED_LOCK(_stateLock);
    return _progressFraction;
}

- (NSString*)currentFileName {
    SZ_SCOPED_LOCK(_stateLock);
    return [_currentFileName copy];
}

- (uint64_t)bytesCompleted {
    SZ_SCOPED_LOCK(_stateLock);
    return _bytesCompleted;
}

- (uint64_t)bytesTotal {
    SZ_SCOPED_LOCK(_stateLock);
    return _bytesTotal;
}

- (uint64_t)filesCompleted {
    SZ_SCOPED_LOCK(_stateLock);
    return _filesCompleted;
}

- (uint64_t)filesTotal {
    SZ_SCOPED_LOCK(_stateLock);
    return _filesTotal;
}

- (BOOL)hasReportedProgress {
    SZ_SCOPED_LOCK(_stateLock);
    return _hasReportedProgress;
}

- (BOOL)isWaitingForUserInteraction {
    SZ_SCOPED_LOCK(_stateLock);
    return _waitingForUserInteraction;
}

- (BOOL)isCancellationRequested {
    SZ_SCOPED_LOCK(_stateLock);
    return _cancellationRequested;
}

- (BOOL)isCancellationAllowed {
    SZ_SCOPED_LOCK(_stateLock);
    return _cancellationAllowed;
}

- (uint64_t)totalIssueCount {
    SZ_SCOPED_LOCK(_stateLock);
    return _totalIssueCount;
}

- (void)reportPhase:(SZOperationPhase)phase {
    {
        SZ_SCOPED_LOCK(_stateLock);
        _phase = phase;
    }
    [self scheduleSnapshotDelivery];
}

- (void)reportProgressFraction:(double)fraction {
    const double clamped = MIN(MAX(fraction, 0.0), 1.0);
    {
        SZ_SCOPED_LOCK(_stateLock);
        _progressFraction = clamped;
        _hasReportedProgress = YES;
    }
    [self scheduleSnapshotDelivery];
}

- (void)reportCurrentFileName:(NSString*)fileName {
    {
        SZ_SCOPED_LOCK(_stateLock);
        _currentFileName = [fileName copy] ?: @"";
    }
    [self scheduleSnapshotDelivery];
}

- (void)reportBytesCompleted:(uint64_t)completed total:(uint64_t)total {
    {
        SZ_SCOPED_LOCK(_stateLock);
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
    {
        SZ_SCOPED_LOCK(_stateLock);
        _filesCompleted = count;
    }
    [self scheduleSnapshotDelivery];
}

- (void)reportFilesTotal:(uint64_t)count {
    {
        SZ_SCOPED_LOCK(_stateLock);
        _filesTotal = count;
    }
    [self scheduleSnapshotDelivery];
}

- (void)reportUpdateIssue:(SZArchiveUpdateIssue*)issue {
    if (!issue) {
        return;
    }

    {
        SZ_SCOPED_LOCK(_stateLock);
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
    {
        SZ_SCOPED_LOCK(_stateLock);
        if (!_cancellationAllowed) {
            return;
        }
        _cancellationRequested = YES;
        _phase = SZOperationPhaseCancelling;
    }
    [self scheduleSnapshotDelivery];
}

- (void)clearCancellationRequest {
    {
        SZ_SCOPED_LOCK(_stateLock);
        _cancellationRequested = NO;
        if (_phase == SZOperationPhaseCancelling) {
            _phase = SZOperationPhaseWaiting;
        }
    }
    [self scheduleSnapshotDelivery];
}

- (void)beginFinalizing {
    {
        SZ_SCOPED_LOCK(_stateLock);
        _cancellationRequested = NO;
        _cancellationAllowed = NO;
        _phase = SZOperationPhaseFinalizing;
    }
    [self scheduleSnapshotDelivery];
}

- (void)prepareForUserInteraction {
    {
        SZ_SCOPED_LOCK(_stateLock);
        _waitingForUserInteraction = YES;
    }
    [self scheduleSnapshotDelivery];
}

- (void)finishUserInteraction {
    {
        SZ_SCOPED_LOCK(_stateLock);
        _waitingForUserInteraction = NO;
    }
    [self scheduleSnapshotDelivery];
}

- (SZOperationSnapshot*)snapshot {
    SZ_SCOPED_LOCK(_stateLock);
    return [self newSnapshotWhileLocked];
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

- (SZArchiveUpdateEncryption*)requestUpdateEncryptionForArchive:(NSString*)archivePath
                                              defaultEncryption:(SZEncryptionMethod)defaultEncryption {
    SZOperationUpdateEncryptionRequestHandler handler = self.updateEncryptionRequestHandler;
    if (!handler || [self shouldCancel]) {
        return nil;
    }

    [self prepareForUserInteraction];
    __block SZArchiveUpdateEncryption* selection = nil;
    @try {
        SZDispatchSyncOnMain(^{
            if (![self shouldCancel]) {
                selection = handler(archivePath, defaultEncryption);
            }
        });
    } @finally {
        [self finishUserInteraction];
    }
    return [self shouldCancel] ? nil : selection;
}

- (SZMemoryLimitPromptResult*)requestMemoryLimitWithRequiredBytes:(uint64_t)requiredBytes
                                                currentLimitBytes:(uint64_t)currentLimitBytes
                                                      archivePath:(NSString*)archivePath
                                                         filePath:(NSString*)filePath
                                                         testMode:(BOOL)testMode
                                                     showRemember:(BOOL)showRemember {
    SZOperationMemoryLimitRequestHandler handler = self.memoryLimitRequestHandler;
    if (!handler || [self shouldCancel]) {
        return nil;
    }

    [self prepareForUserInteraction];
    __block SZMemoryLimitPromptResult* selection = nil;
    @try {
        SZDispatchSyncOnMain(^{
            if (![self shouldCancel]) {
                selection = handler(requiredBytes, currentLimitBytes, archivePath, filePath, testMode, showRemember);
            }
        });
    } @finally {
        [self finishUserInteraction];
    }
    return [self shouldCancel] ? nil : selection;
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

    {
        SZ_SCOPED_LOCK(_stateLock);
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
            {
                SZ_SCOPED_LOCK(self->_stateLock);
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
