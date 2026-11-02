#include "SZArchiveInternal.h"

@implementation SZArchiveUpdateEncryption

- (instancetype)initWithEncryption:(SZEncryptionMethod)encryption
                          password:(NSString*)password {
    if ((self = [super init])) {
        _encryption = encryption;
        _password = encryption == SZEncryptionMethodNone ? nil : [password copy];
    }
    return self;
}

- (BOOL)validateWithError:(NSError**)error {
    if (_encryption == SZEncryptionMethodNone) {
        return YES;
    }

    NSString* errorKey = nil;
    if (_encryption != SZEncryptionMethodAES256
        && _encryption != SZEncryptionMethodZipCrypto) {
        errorKey = @"app.archive.error.invalidUpdateEncryptionMethod";
    } else if (_password.length == 0) {
        errorKey = @"password.enterPassword";
    } else {
        // Match the ZIP handler's password character range before any writes.
        for (NSUInteger i = 0; i < _password.length; i++) {
            const unichar character = [_password characterAtIndex:i];
            if (character < 0x20 || character > 0x7F) {
                errorKey = @"password.useAscii";
                break;
            }
        }
        if (!errorKey && _encryption == SZEncryptionMethodAES256
            && _password.length > 99) {
            errorKey = @"password.tooLong";
        }
    }

    if (errorKey) {
        if (error) {
            *error = SZMakeError(E_INVALIDARG, SZLocalizedString(errorKey));
        }
        return NO;
    }
    return YES;
}

@end

@implementation SZCompressionSettings
- (instancetype)init {
    if ((self = [super init])) {
        _format = SZArchiveFormat7z;
        _levelValue = 5; // Normal
        _method = SZCompressionMethodLZMA2;
        _encryption = SZEncryptionMethodNone;
        _updateMode = SZCompressionUpdateModeAdd;
        _pathMode = SZCompressionPathModeRelativePaths;
        _methodName = @"LZMA2";
        _solidMode = YES;
        _openSharedFiles = NO;
        _deleteAfterCompression = NO;
        _storeSymbolicLinks = SZCompressionBoolSettingNotDefined;
        _storeHardLinks = SZCompressionBoolSettingNotDefined;
        _storeAlternateDataStreams = SZCompressionBoolSettingNotDefined;
        _storeFileSecurity = SZCompressionBoolSettingNotDefined;
        _preserveSourceAccessTime = SZCompressionBoolSettingNotDefined;
        _storeModificationTime = SZCompressionBoolSettingNotDefined;
        _storeCreationTime = SZCompressionBoolSettingNotDefined;
        _storeAccessTime = SZCompressionBoolSettingNotDefined;
        _setArchiveTimeToLatestFile = SZCompressionBoolSettingNotDefined;
        _timePrecision = SZCompressionTimePrecisionAutomatic;
    }
    return self;
}
@end

@implementation SZExtractionSettings
- (instancetype)init {
    if ((self = [super init])) {
        _pathMode = SZPathModeFullPaths;
        _overwriteMode = SZOverwriteModeAsk;
        _preserveNtSecurityInfo = NO;
    }
    return self;
}
@end

@implementation SZArchiveItemReference

- (instancetype)initWithArchiveIndex:(NSUInteger)archiveIndex
                                path:(NSString*)path
                         isDirectory:(BOOL)isDirectory
                  snapshotIdentifier:(NSUUID*)snapshotIdentifier {
    if ((self = [super init])) {
        _archiveIndex = archiveIndex;
        _path = [path copy];
        _directory = isDirectory;
        _snapshotIdentifier = [snapshotIdentifier copy];
    }
    return self;
}

- (instancetype)initWithLogicalDirectoryPath:(NSString*)path
                          snapshotIdentifier:(NSUUID*)snapshotIdentifier {
    return [self initWithArchiveIndex:NSNotFound
                                 path:path
                          isDirectory:YES
                   snapshotIdentifier:snapshotIdentifier];
}

- (BOOL)hasArchiveIndex {
    return _archiveIndex != NSNotFound;
}

@end

@implementation SZArchiveEntry
- (instancetype)init {
    if ((self = [super init])) {
        _path = @"";
        _pathParts = @[];
        _propertyValues = @{ };
    }
    return self;
}
@end
@implementation SZArchiveEntryProperty
@end
@implementation SZFormatInfo
@end
@implementation SZCompressionResourceInfo
@end
