#import "SZArchive.h"

@implementation SZArchiveUpdateIssue

- (instancetype)initWithStage:(SZArchiveUpdateIssueStage)stage
                         path:(NSString*)path
                    errorCode:(int32_t)errorCode
                      message:(NSString*)message {
    if ((self = [super init])) {
        _stage = stage;
        _path = [path copy] ?: @"";
        _errorCode = errorCode;
        _message = [message copy];
    }
    return self;
}

@end

@implementation SZArchiveUpdateOutcome

- (instancetype)initWithCompletion:(SZArchiveUpdateCompletion)completion
                  archiveCommitted:(BOOL)archiveCommitted
                            issues:(NSArray<SZArchiveUpdateIssue*>*)issues
                   totalIssueCount:(uint64_t)totalIssueCount
                   issuesTruncated:(BOOL)issuesTruncated {
    if ((self = [super init])) {
        _completion = completion;
        _archiveCommitted = archiveCommitted;
        _issues = [issues copy] ?: @[];
        _totalIssueCount = totalIssueCount;
        _issuesTruncated = issuesTruncated;
    }
    return self;
}

- (BOOL)hasWarnings {
    return _totalIssueCount > 0;
}

@end
