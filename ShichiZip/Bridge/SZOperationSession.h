#import <Foundation/Foundation.h>

@class SZArchiveUpdateIssue;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZOperationPromptStyle) {
    SZOperationPromptStyleInformational = 0,
    SZOperationPromptStyleWarning,
    SZOperationPromptStyleCritical,
};

typedef NS_ENUM(NSInteger, SZOperationPhase) {
    SZOperationPhaseWaiting = 0,
    SZOperationPhaseScanning,
    SZOperationPhaseOpening,
    SZOperationPhaseReading,
    SZOperationPhaseCompressing,
    SZOperationPhaseExtracting,
    SZOperationPhaseUpdating,
    SZOperationPhaseDeleting,
    SZOperationPhaseMovingArchive,
    SZOperationPhaseCancelling,
    SZOperationPhaseFinalizing,
};

typedef BOOL (^SZOperationPasswordRequestHandler)(NSString* title,
    NSString* _Nullable message,
    NSString* _Nullable initialValue,
    NSString* _Nullable* _Nullable password);

@interface SZOperationChoiceRequest : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithStyle:(SZOperationPromptStyle)style
                        title:(NSString*)title
                      message:(nullable NSString*)message
                 buttonTitles:(NSArray<NSString*>*)buttonTitles
           defaultButtonIndex:(NSInteger)defaultButtonIndex
            cancelButtonIndex:(NSInteger)cancelButtonIndex NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) SZOperationPromptStyle style;
@property (nonatomic, copy, readonly) NSString* title;
@property (nonatomic, copy, readonly, nullable) NSString* message;
@property (nonatomic, copy, readonly) NSArray<NSString*>* buttonTitles;
@property (nonatomic, readonly) NSInteger defaultButtonIndex;
@property (nonatomic, readonly) NSInteger cancelButtonIndex;

@end

typedef NSInteger (^SZOperationChoiceRequestHandler)(SZOperationChoiceRequest* request);

@interface SZOperationSnapshot : NSObject

@property (nonatomic, readonly) SZOperationPhase phase;
@property (nonatomic, readonly) double progressFraction;
@property (nonatomic, copy, readonly) NSString* currentFileName;
@property (nonatomic, readonly) uint64_t bytesCompleted;
@property (nonatomic, readonly) uint64_t bytesTotal;
@property (nonatomic, readonly) uint64_t filesCompleted;
@property (nonatomic, readonly) uint64_t filesTotal;
@property (nonatomic, readonly) BOOL hasReportedProgress;
@property (nonatomic, readonly, getter=isWaitingForUserInteraction) BOOL waitingForUserInteraction;
@property (nonatomic, readonly, getter=isCancellationRequested) BOOL cancellationRequested;
@property (nonatomic, readonly, getter=isCancellationAllowed) BOOL cancellationAllowed;
@property (nonatomic, copy, readonly) NSArray<SZArchiveUpdateIssue*>* issues;
@property (nonatomic, readonly) uint64_t totalIssueCount;
@property (nonatomic, readonly, getter=areIssuesTruncated) BOOL issuesTruncated;

@end

typedef void (^SZOperationSnapshotHandler)(SZOperationSnapshot* snapshot);

@interface SZOperationSession : NSObject

@property (nonatomic, copy, nullable) SZOperationSnapshotHandler snapshotHandler;
@property (nonatomic, copy, nullable) SZOperationPasswordRequestHandler passwordRequestHandler;
@property (nonatomic, copy, nullable) SZOperationChoiceRequestHandler choiceRequestHandler;

@property (nonatomic, readonly) SZOperationPhase phase;
@property (nonatomic, readonly) double progressFraction;
@property (nonatomic, copy, readonly) NSString* currentFileName;
@property (nonatomic, readonly) uint64_t bytesCompleted;
@property (nonatomic, readonly) uint64_t bytesTotal;
@property (nonatomic, readonly) uint64_t filesCompleted;
@property (nonatomic, readonly) uint64_t filesTotal;
@property (nonatomic, readonly) BOOL hasReportedProgress;
@property (nonatomic, readonly, getter=isWaitingForUserInteraction) BOOL waitingForUserInteraction;
@property (nonatomic, readonly, getter=isCancellationRequested) BOOL cancellationRequested;
@property (nonatomic, readonly, getter=isCancellationAllowed) BOOL cancellationAllowed;
@property (nonatomic, readonly) uint64_t totalIssueCount;

- (void)reportPhase:(SZOperationPhase)phase;
- (void)reportProgressFraction:(double)fraction;
- (void)reportCurrentFileName:(NSString*)fileName;
- (void)reportBytesCompleted:(uint64_t)completed total:(uint64_t)total;
- (void)reportFilesCompleted:(uint64_t)count;
- (void)reportFilesTotal:(uint64_t)count;
- (void)reportUpdateIssue:(SZArchiveUpdateIssue*)issue;
- (BOOL)shouldCancel;
- (void)requestCancel;
- (void)clearCancellationRequest;
- (void)beginFinalizing;
- (void)prepareForUserInteraction;
- (void)finishUserInteraction;
- (SZOperationSnapshot*)snapshot;
- (BOOL)requestPasswordWithTitle:(NSString*)title
                         message:(nullable NSString*)message
                    initialValue:(nullable NSString*)initialValue
                        password:(NSString* _Nullable* _Nullable)password;
- (NSInteger)requestChoice:(SZOperationChoiceRequest*)request;

@end

NS_ASSUME_NONNULL_END
