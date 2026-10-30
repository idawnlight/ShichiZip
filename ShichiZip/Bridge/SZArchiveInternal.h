#pragma once

#include "SZBridgeCommon.h"
#include "SZCallbacks.h"
#include "SZZipExtraction.h"

#include <memory>
#include <objc/objc-sync.h>

NS_ASSUME_NONNULL_BEGIN

class SZArchiveOperationGuard {
public:
    explicit SZArchiveOperationGuard(id object)
        : _object(object) { objc_sync_enter(_object); }
    ~SZArchiveOperationGuard() { objc_sync_exit(_object); }

private:
    __unsafe_unretained id _object;
};

@interface SZArchive () {
    std::unique_ptr<CArchiveLink> _arcLink;
    BOOL _isOpen;
    NSString* _archivePath;
    NSString* _openType;
    NSString* _cachedPassword;
    BOOL _cachedPasswordIsDefined;
    SZZipPasswordCache _zipPasswords;
    NSUUID* _entrySnapshotIdentifier;
}

@end

@interface SZArchiveEntry ()
@property (nonatomic, strong, readwrite) SZArchiveItemReference* reference;
@end

@interface SZArchive (Internal)
- (void)clearCachedPassword;
- (void)storeCachedPassword:(const UString&)password defined:(bool)isDefined;
@end

NSError* SZOpenArchiveErrorFromPasswordContext(
    HRESULT result, const CArcErrorInfo& errorInfo, BOOL passwordWasAsked,
    NSString* _Nullable archivePath);

NS_ASSUME_NONNULL_END
