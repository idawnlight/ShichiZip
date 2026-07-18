#import <Foundation/Foundation.h>

@protocol SZProgressDelegate;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZOperationPromptStyle) {
    SZOperationPromptStyleInformational = 0,
    SZOperationPromptStyleWarning,
    SZOperationPromptStyleCritical,
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

@property (nonatomic, readonly) double progressFraction;
@property (nonatomic, copy, readonly) NSString* currentFileName;
@property (nonatomic, readonly) uint64_t bytesCompleted;
@property (nonatomic, readonly) uint64_t bytesTotal;
@property (nonatomic, readonly) uint64_t filesCompleted;
@property (nonatomic, readonly) BOOL hasReportedProgress;
@property (nonatomic, readonly, getter=isWaitingForUserInteraction) BOOL waitingForUserInteraction;
@property (nonatomic, readonly, getter=isCancellationRequested) BOOL cancellationRequested;

@end

@interface SZOperationSession : NSObject

@property (nonatomic, weak, nullable) id<SZProgressDelegate> progressDelegate;
@property (nonatomic, copy, nullable) SZOperationPasswordRequestHandler passwordRequestHandler;
@property (nonatomic, copy, nullable) SZOperationChoiceRequestHandler choiceRequestHandler;

@property (nonatomic, readonly) double progressFraction;
@property (nonatomic, copy, readonly) NSString* currentFileName;
@property (nonatomic, readonly) uint64_t bytesCompleted;
@property (nonatomic, readonly) uint64_t bytesTotal;
@property (nonatomic, readonly) uint64_t filesCompleted;
@property (nonatomic, readonly) BOOL hasReportedProgress;
@property (nonatomic, readonly, getter=isWaitingForUserInteraction) BOOL waitingForUserInteraction;
@property (nonatomic, readonly, getter=isCancellationRequested) BOOL cancellationRequested;

- (void)reportProgressFraction:(double)fraction;
- (void)reportCurrentFileName:(NSString*)fileName;
- (void)reportBytesCompleted:(uint64_t)completed total:(uint64_t)total;
- (void)reportFilesCompleted:(uint64_t)count;
- (BOOL)shouldCancel;
- (void)requestCancel;
- (void)clearCancellationRequest;
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