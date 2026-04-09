#import <Foundation/Foundation.h>

@protocol SZProgressDelegate;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZOperationPromptStyle) {
    SZOperationPromptStyleInformational = 0,
    SZOperationPromptStyleWarning,
    SZOperationPromptStyleCritical,
};

typedef BOOL (^SZOperationPasswordRequestHandler)(NSString *title,
                                                 NSString * _Nullable message,
                                                 NSString * _Nullable initialValue,
                                                 NSString * _Nullable * _Nullable password);

typedef NSInteger (^SZOperationChoiceRequestHandler)(SZOperationPromptStyle style,
                                                     NSString *title,
                                                     NSString * _Nullable message,
                                                     NSArray<NSString *> *buttonTitles);

@interface SZOperationSnapshot : NSObject

@property (nonatomic, readonly) double progressFraction;
@property (nonatomic, copy, readonly) NSString *currentFileName;
@property (nonatomic, readonly) uint64_t bytesCompleted;
@property (nonatomic, readonly) uint64_t bytesTotal;
@property (nonatomic, readonly) BOOL hasReportedProgress;
@property (nonatomic, readonly, getter=isWaitingForUserInteraction) BOOL waitingForUserInteraction;
@property (nonatomic, readonly, getter=isCancellationRequested) BOOL cancellationRequested;

@end

@interface SZOperationSession : NSObject

@property (nonatomic, weak, nullable) id<SZProgressDelegate> progressDelegate;
@property (nonatomic, copy, nullable) SZOperationPasswordRequestHandler passwordRequestHandler;
@property (nonatomic, copy, nullable) SZOperationChoiceRequestHandler choiceRequestHandler;

@property (nonatomic, readonly) double progressFraction;
@property (nonatomic, copy, readonly) NSString *currentFileName;
@property (nonatomic, readonly) uint64_t bytesCompleted;
@property (nonatomic, readonly) uint64_t bytesTotal;
@property (nonatomic, readonly) BOOL hasReportedProgress;
@property (nonatomic, readonly, getter=isWaitingForUserInteraction) BOOL waitingForUserInteraction;
@property (nonatomic, readonly, getter=isCancellationRequested) BOOL cancellationRequested;

- (void)reportProgressFraction:(double)fraction;
- (void)reportCurrentFileName:(NSString *)fileName;
- (void)reportBytesCompleted:(uint64_t)completed total:(uint64_t)total;
- (BOOL)shouldCancel;
- (void)requestCancel;
- (void)prepareForUserInteraction;
- (void)finishUserInteraction;
- (SZOperationSnapshot *)snapshot;
- (BOOL)requestPasswordWithTitle:(NSString *)title
                         message:(nullable NSString *)message
                    initialValue:(nullable NSString *)initialValue
                        password:(NSString * _Nullable * _Nullable)password;
- (NSInteger)requestChoiceWithStyle:(SZOperationPromptStyle)style
                              title:(NSString *)title
                            message:(nullable NSString *)message
                       buttonTitles:(NSArray<NSString *> *)buttonTitles;

@end

NS_ASSUME_NONNULL_END