#import <Foundation/Foundation.h>

@class SZArchiveEntry;
@class SZArchiveEntryProperty;
@class SZArchiveItemReference;
@class SZBenchDisplayRow;
@class SZBenchSnapshot;
@class SZOperationSession;
@protocol SZPasswordDelegate;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const SZArchiveErrorDomain;
FOUNDATION_EXPORT NSString* const SZArchiveMutationCommittedErrorKey;
FOUNDATION_EXPORT NSString* const SZArchiveMutationReopenFailedErrorKey;

typedef NS_ENUM(NSInteger, SZArchiveUpdateIssueStage) {
    SZArchiveUpdateIssueStageScan = 0,
    SZArchiveUpdateIssueStageOpen,
    SZArchiveUpdateIssueStageRead,
    SZArchiveUpdateIssueStageUpdate,
};

typedef NS_ENUM(NSInteger, SZArchiveUpdateCompletion) {
    SZArchiveUpdateCompletionComplete = 0,
    SZArchiveUpdateCompletionCompletedWithWarnings,
};

@interface SZArchiveUpdateIssue : NSObject

- (instancetype)initWithStage:(SZArchiveUpdateIssueStage)stage
                         path:(NSString*)path
                    errorCode:(int32_t)errorCode
                      message:(nullable NSString*)message NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) SZArchiveUpdateIssueStage stage;
@property (nonatomic, copy, readonly) NSString* path;
@property (nonatomic, readonly) int32_t errorCode;
@property (nonatomic, copy, readonly, nullable) NSString* message;

@end

@interface SZArchiveUpdateOutcome : NSObject

- (instancetype)initWithCompletion:(SZArchiveUpdateCompletion)completion
                  archiveCommitted:(BOOL)archiveCommitted
                            issues:(NSArray<SZArchiveUpdateIssue*>*)issues
                   totalIssueCount:(uint64_t)totalIssueCount
                   issuesTruncated:(BOOL)issuesTruncated NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) SZArchiveUpdateCompletion completion;
@property (nonatomic, readonly, getter=wasArchiveCommitted) BOOL archiveCommitted;
@property (nonatomic, copy, readonly) NSArray<SZArchiveUpdateIssue*>* issues;
@property (nonatomic, readonly) uint64_t totalIssueCount;
@property (nonatomic, readonly, getter=areIssuesTruncated) BOOL issuesTruncated;
@property (nonatomic, readonly) BOOL hasWarnings;

@end

typedef NS_ERROR_ENUM(SZArchiveErrorDomain, SZArchiveErrorCode) {
    SZArchiveErrorCodeFailedToInitCodecs = -1,
    SZArchiveErrorCodeUnsupportedArchive = -2,
    SZArchiveErrorCodeNoOpenArchive = -4,
    SZArchiveErrorCodeUserCancelled = -5,
    SZArchiveErrorCodeExtractionFailed = -6,
    SZArchiveErrorCodeUnsupportedFormat = -8,
    SZArchiveErrorCodeWrongPassword = -12,
    SZArchiveErrorCodePartialFailure = -13,
    SZArchiveErrorCodeInvalidArchive = -14,
};

/// Supported archive formats for creation
typedef NS_ENUM(NSInteger, SZArchiveFormat) {
    SZArchiveFormat7z = 0,
    SZArchiveFormatZip,
    SZArchiveFormatTar,
    SZArchiveFormatGZip,
    SZArchiveFormatBZip2,
    SZArchiveFormatXz,
    SZArchiveFormatWim,
#if SHICHIZIP_ZS_VARIANT
    SZArchiveFormatZstd,
    SZArchiveFormatBrotli,
    SZArchiveFormatLizard,
    SZArchiveFormatLz4,
    SZArchiveFormatLz5
#endif
};

/// Compression method
typedef NS_ENUM(NSInteger, SZCompressionMethod) {
    SZCompressionMethodLZMA = 0,
    SZCompressionMethodLZMA2,
    SZCompressionMethodPPMd,
    SZCompressionMethodBZip2,
    SZCompressionMethodDeflate,
    SZCompressionMethodDeflate64,
    SZCompressionMethodCopy
};

/// Update mode for archive creation
typedef NS_ENUM(NSInteger, SZCompressionUpdateMode) {
    SZCompressionUpdateModeAdd = 0,
    SZCompressionUpdateModeUpdate,
    SZCompressionUpdateModeFresh,
    SZCompressionUpdateModeSync,
};

/// Path mode for archive creation
typedef NS_ENUM(NSInteger, SZCompressionPathMode) {
    SZCompressionPathModeRelativePaths = 0,
    SZCompressionPathModeFullPaths,
    SZCompressionPathModeAbsolutePaths,
};

/// Encryption method
typedef NS_ENUM(NSInteger, SZEncryptionMethod) {
    SZEncryptionMethodNone = 0,
    SZEncryptionMethodAES256,
    SZEncryptionMethodZipCrypto
};

/// Overwrite mode for extraction
typedef NS_ENUM(NSInteger, SZOverwriteMode) {
    SZOverwriteModeAsk = 0,
    SZOverwriteModeSkip,
    SZOverwriteModeRename,
    SZOverwriteModeOverwrite,
    SZOverwriteModeRenameExisting
};

/// Path mode for extraction
typedef NS_ENUM(NSInteger, SZPathMode) {
    SZPathModeFullPaths = 0,
    SZPathModeCurrentPaths,
    SZPathModeNoPaths,
    SZPathModeAbsolutePaths
};

/// Three-state boolean used for archive metadata settings.
typedef NS_ENUM(NSInteger, SZCompressionBoolSetting) {
    SZCompressionBoolSettingNotDefined = -1,
    SZCompressionBoolSettingOff = 0,
    SZCompressionBoolSettingOn = 1,
};

/// Time precision for stored archive timestamps.
typedef NS_ENUM(NSInteger, SZCompressionTimePrecision) {
    SZCompressionTimePrecisionAutomatic = -1,
    SZCompressionTimePrecisionWindows = 0,
    SZCompressionTimePrecisionUnix = 1,
    SZCompressionTimePrecisionDOS = 2,
    SZCompressionTimePrecisionLinux = 3,
};

/// Compression settings for archive creation
@interface SZCompressionSettings : NSObject
@property (nonatomic) SZArchiveFormat format;
@property (nonatomic) NSInteger levelValue;
@property (nonatomic) SZCompressionMethod method;
@property (nonatomic) SZCompressionUpdateMode updateMode;
@property (nonatomic) SZCompressionPathMode pathMode;
@property (nonatomic) SZEncryptionMethod encryption;
@property (nonatomic, copy, nullable) NSString* password;
@property (nonatomic, copy, nullable) NSString* methodName;
@property (nonatomic, copy, nullable) NSString* parameters;
@property (nonatomic, copy, nullable) NSString* memoryUsage;
@property (nonatomic, copy, nullable) NSString* splitVolumes;
@property (nonatomic) BOOL encryptFileNames;
@property (nonatomic) BOOL solidMode;
@property (nonatomic) uint64_t dictionarySize; // in bytes, 0 = auto
@property (nonatomic) uint32_t wordSize; // 0 = auto
@property (nonatomic) uint32_t numThreads; // 0 = auto
@property (nonatomic) uint64_t splitVolumeSize; // 0 = no split
@property (nonatomic) BOOL createSFX;
@property (nonatomic) BOOL openSharedFiles;
@property (nonatomic) BOOL deleteAfterCompression;
@property (nonatomic) BOOL excludeMacResourceFiles;
@property (nonatomic) SZCompressionBoolSetting storeSymbolicLinks;
@property (nonatomic) SZCompressionBoolSetting storeHardLinks;
@property (nonatomic) SZCompressionBoolSetting storeAlternateDataStreams;
@property (nonatomic) SZCompressionBoolSetting storeFileSecurity;
@property (nonatomic) SZCompressionBoolSetting preserveSourceAccessTime;
@property (nonatomic) SZCompressionBoolSetting storeModificationTime;
@property (nonatomic) SZCompressionBoolSetting storeCreationTime;
@property (nonatomic) SZCompressionBoolSetting storeAccessTime;
@property (nonatomic) SZCompressionBoolSetting setArchiveTimeToLatestFile;
@property (nonatomic) SZCompressionTimePrecision timePrecision;
@end

/// Extraction settings
@interface SZExtractionSettings : NSObject
@property (nonatomic) SZPathMode pathMode;
@property (nonatomic) SZOverwriteMode overwriteMode;
@property (nonatomic, copy, nullable) NSString* password;
@property (nonatomic, copy, nullable) NSString* pathPrefixToStrip;
@property (nonatomic) BOOL preserveNtSecurityInfo;
@property (nonatomic, copy, nullable) NSString* sourceArchivePathForQuarantine;
@end

/// Password callback delegate
@protocol SZPasswordDelegate <NSObject>
- (nullable NSString*)passwordRequiredForArchive:(NSString*)archivePath;
@end

/// Represents a single entry in an archive
@interface SZArchiveItemReference : NSObject
@property (nonatomic, readonly) NSUInteger archiveIndex;
@property (nonatomic, readonly, getter=hasArchiveIndex) BOOL archiveIndexAvailable;
@property (nonatomic, copy, readonly) NSString* path;
@property (nonatomic, readonly, getter=isDirectory) BOOL directory;
@property (nonatomic, copy, readonly) NSUUID* snapshotIdentifier;

- (instancetype)initWithArchiveIndex:(NSUInteger)archiveIndex
                                path:(NSString*)path
                         isDirectory:(BOOL)isDirectory
                  snapshotIdentifier:(NSUUID*)snapshotIdentifier
    NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithLogicalDirectoryPath:(NSString*)path
                          snapshotIdentifier:(NSUUID*)snapshotIdentifier;

- (instancetype)init NS_UNAVAILABLE;
@end

@interface SZArchiveEntry : NSObject
@property (nonatomic, copy) NSString* path;
@property (nonatomic, copy) NSArray<NSString*>* pathParts;
@property (nonatomic, copy) NSDictionary<NSString*, NSString*>* propertyValues;
@property (nonatomic) uint64_t size;
@property (nonatomic) uint64_t packedSize;
@property (nonatomic, strong, nullable) NSDate* modifiedDate;
@property (nonatomic, strong, nullable) NSDate* createdDate;
@property (nonatomic, strong, nullable) NSDate* accessedDate;
@property (nonatomic) uint32_t crc;
@property (nonatomic) BOOL isDirectory;
@property (nonatomic) BOOL isEncrypted;
@property (nonatomic) BOOL isAnti;
@property (nonatomic, copy, nullable) NSString* method;
@property (nonatomic) uint32_t attributes;
@property (nonatomic) uint64_t position;
@property (nonatomic) uint64_t block;
@property (nonatomic, copy, nullable) NSString* comment;
@property (nonatomic) NSUInteger index; // internal archive index
@property (nonatomic, strong, readonly) SZArchiveItemReference* reference;
@end

/// Describes one item property exposed by the archive handler.
@interface SZArchiveEntryProperty : NSObject
@property (nonatomic, copy) NSString* key;
@property (nonatomic, copy, nullable) NSString* titleKey;
@property (nonatomic, copy) NSString* title;
@property (nonatomic) NSUInteger propID;
@property (nonatomic) NSUInteger valueType;
@end

/// Format info for detected/available formats
@interface SZFormatInfo : NSObject
@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSArray<NSString*>* extensions;
@property (nonatomic) BOOL canWrite;
@property (nonatomic) BOOL supportsSymbolicLinks;
@property (nonatomic) BOOL supportsHardLinks;
@property (nonatomic) BOOL supportsAlternateDataStreams;
@property (nonatomic) BOOL supportsFileSecurity;
@property (nonatomic) BOOL supportsModificationTime;
@property (nonatomic) BOOL supportsCreationTime;
@property (nonatomic) BOOL supportsAccessTime;
@property (nonatomic) BOOL defaultsModificationTime;
@property (nonatomic) BOOL defaultsCreationTime;
@property (nonatomic) BOOL defaultsAccessTime;
@property (nonatomic) BOOL keepsName;
@property (nonatomic) uint32_t supportedTimePrecisionMask;
@property (nonatomic) SZCompressionTimePrecision defaultTimePrecision;
@end

/// Compression memory estimate for the current add-dialog settings.
@interface SZCompressionResourceInfo : NSObject
@property (nonatomic) BOOL compressionMemoryIsDefined;
@property (nonatomic) uint64_t compressionMemory;
@property (nonatomic) BOOL decompressionMemoryIsDefined;
@property (nonatomic) uint64_t decompressionMemory;
@property (nonatomic) BOOL memoryUsageLimitIsDefined;
@property (nonatomic) uint64_t memoryUsageLimit;
@property (nonatomic) BOOL resolvedDictionarySizeIsDefined;
@property (nonatomic) uint64_t resolvedDictionarySize;
@property (nonatomic) BOOL resolvedWordSizeIsDefined;
@property (nonatomic) uint32_t resolvedWordSize;
@property (nonatomic) BOOL resolvedNumThreadsIsDefined;
@property (nonatomic) uint32_t resolvedNumThreads;
@end

/// Main archive interface — wraps 7-Zip C++ core
@interface SZArchive : NSObject

/// Open an existing archive for reading
- (BOOL)openAtPath:(NSString*)path error:(NSError**)error;

/// Open an existing archive for reading with an explicit operation session
- (BOOL)openAtPath:(NSString*)path
           session:(nullable SZOperationSession*)session
             error:(NSError**)error;

/// Open an existing archive for reading with an explicit 7-Zip open type
- (BOOL)openAtPath:(NSString*)path
          openType:(nullable NSString*)openType
           session:(nullable SZOperationSession*)session
             error:(NSError**)error;

/// Open with password
- (BOOL)openAtPath:(NSString*)path
          password:(nullable NSString*)password
             error:(NSError**)error;

/// Open with password and an explicit operation session
- (BOOL)openAtPath:(NSString*)path
          password:(nullable NSString*)password
           session:(nullable SZOperationSession*)session
             error:(NSError**)error;

/// Close the archive
- (void)close;

/// Reopen the current archive after another handle mutated the backing file.
- (BOOL)reopenAfterExternalMutationWithSession:(nullable SZOperationSession*)session
                                         error:(NSError**)error;

/// Get the detected format name
@property (nonatomic, readonly, nullable) NSString* formatName;

/// Get whether the detected archive format supports in-place updates.
@property (nonatomic, readonly) BOOL canWrite;

/// Entry properties exposed by the archive handler, mapped to ShichiZip column identifiers.
@property (nonatomic, readonly) NSArray<SZArchiveEntryProperty*>* entryProperties;

/// Entry property keys exposed by the archive handler, mapped to ShichiZip column identifiers.
@property (nonatomic, readonly) NSArray<NSString*>* entryPropertyKeys;

/// Get the physical size of the archive file in bytes when available
@property (nonatomic, readonly) uint64_t archivePhysicalSize;

/// Get whether the archive uses solid compression when available
@property (nonatomic, readonly, getter=isSolidArchive) BOOL solidArchive;

/// Get the number of entries
@property (nonatomic, readonly) NSUInteger entryCount;

/// Identifies the currently open entry listing generation.
@property (nonatomic, copy, readonly, nullable) NSUUID* entrySnapshotIdentifier;

/// Get all entries
- (NSArray<SZArchiveEntry*>*)entries;

/// Get all entries with an explicit operation session for cancellation checks
- (nullable NSArray<SZArchiveEntry*>*)entriesWithSession:(nullable SZOperationSession*)session
                                                   error:(NSError**)error;

/// Extract all entries to a destination with an explicit operation session
- (BOOL)extractToPath:(NSString*)destinationPath
             settings:(SZExtractionSettings*)settings
              session:(nullable SZOperationSession*)session
                error:(NSError**)error;

/// Extract specific entries by index with an explicit operation session
- (BOOL)extractEntries:(NSArray<NSNumber*>*)indices
                toPath:(NSString*)destinationPath
              settings:(SZExtractionSettings*)settings
               session:(nullable SZOperationSession*)session
                 error:(NSError**)error;

/// Test archive integrity with an explicit operation session
- (BOOL)testWithSession:(nullable SZOperationSession*)session
                  error:(NSError**)error;

/// Create a folder inside the currently open archive.
- (nullable SZArchiveUpdateOutcome*)createFolderNamed:(NSString*)folderName
                                      inArchiveSubdir:(NSString*)archiveSubdir
                                              session:(nullable SZOperationSession*)session
                                                error:(NSError**)error;

/// Rename one exact item in the currently open archive.
- (nullable SZArchiveUpdateOutcome*)renameItemAtReference:(SZArchiveItemReference*)itemReference
                                          inArchiveSubdir:(NSString*)archiveSubdir
                                                  newName:(NSString*)newName
                                                  session:(nullable SZOperationSession*)session
                                                    error:(NSError**)error;

/// Delete one or more exact items from the currently open archive.
- (nullable SZArchiveUpdateOutcome*)deleteItemsAtReferences:(NSArray<SZArchiveItemReference*>*)itemReferences
                                            inArchiveSubdir:(NSString*)archiveSubdir
                                                    session:(nullable SZOperationSession*)session
                                                      error:(NSError**)error;

/// Add files or folders from disk into the currently open archive.
- (nullable SZArchiveUpdateOutcome*)addPaths:(NSArray<NSString*>*)sourcePaths
                             toArchiveSubdir:(NSString*)archiveSubdir
                                    moveMode:(BOOL)moveMode
                                     session:(nullable SZOperationSession*)session
                                       error:(NSError**)error;

/// Replace one exact existing item in the currently open archive with a file
/// from disk.
- (nullable SZArchiveUpdateOutcome*)replaceItemAtReference:(SZArchiveItemReference*)itemReference
                                           inArchiveSubdir:(NSString*)archiveSubdir
                                            withFileAtPath:(NSString*)sourceFilePath
                                                   session:(nullable SZOperationSession*)session
                                                     error:(NSError**)error;

/// Create or update an archive from files with an explicit operation session.
+ (nullable SZArchiveUpdateOutcome*)createAtPath:(NSString*)archivePath
                                       fromPaths:(NSArray<NSString*>*)sourcePaths
                                        settings:(SZCompressionSettings*)settings
                                         session:(nullable SZOperationSession*)session
                                           error:(NSError**)error;

/// Get list of supported format infos
+ (NSArray<SZFormatInfo*>*)supportedFormats;

/// Get estimated compression and decompression memory usage for archive
/// creation settings.
+ (SZCompressionResourceInfo*)compressionResourceEstimateForSettings:
    (SZCompressionSettings*)settings;

/// Calculate hash of files — returns dict of algorithmName → hexDigest
+ (nullable NSDictionary<NSString*, NSString*>*)
    calculateHashForPath:(NSString*)path
                   error:(NSError**)error;

/// Calculate hash of files with an explicit operation session
+ (nullable NSDictionary<NSString*, NSString*>*)
    calculateHashForPath:(NSString*)path
                 session:(nullable SZOperationSession*)session
                   error:(NSError**)error;

/// Get the underlying 7-Zip core version string.
+ (NSString*)sevenZipVersionString;

/// Correct an archive item path exactly as 7-Zip does before writing it to the
/// file system for non-absolute extraction modes.
+ (NSString*)correctedFileSystemRelativePathForArchivePath:(NSString*)path
                                               isDirectory:(BOOL)isDirectory;

/// Return a hashable key with the same filename-equivalence semantics used by
/// the bundled 7-Zip Agent hierarchy.
+ (NSData*)fileNameComparisonKeyForArchivePathComponent:(NSString*)component;

@end

@interface SZArchive (Benchmark)

/// Get estimated benchmark memory usage in bytes
+ (uint64_t)benchMemoryUsageForThreads:(uint32_t)threads
                            dictionary:(uint64_t)dictSize;

/// Stop running benchmark
+ (void)stopBenchmark;

/// Run the GUI benchmark flow (matches BenchmarkDialog.cpp)
+ (void)runBenchmarkWithDictionary:(uint64_t)dictSize
                           threads:(uint32_t)threads
                            passes:(uint32_t)passes
                          progress:(void (^)(SZBenchSnapshot* snapshot))progress
                        completion:(void (^)(BOOL success,
                                       NSString* _Nullable errorMessage))
                                       completion;

@end

/// One benchmark row formatted for UI display.
@interface SZBenchDisplayRow : NSObject
@property (nonatomic, copy) NSString* sizeText;
@property (nonatomic, copy) NSString* speedText;
@property (nonatomic, copy) NSString* usageText;
@property (nonatomic, copy) NSString* rpuText;
@property (nonatomic, copy) NSString* ratingText;
@end

/// Full benchmark snapshot for the benchmark window.
@interface SZBenchSnapshot : NSObject
@property (nonatomic) uint32_t passesCompleted;
@property (nonatomic) uint32_t passesTotal;
@property (nonatomic, getter=isFinished) BOOL finished;
@property (nonatomic, copy) NSString* logText;
@property (nonatomic, nullable, strong) SZBenchDisplayRow* encodeCurrent;
@property (nonatomic, nullable, strong) SZBenchDisplayRow* encodeResult;
@property (nonatomic, nullable, strong) SZBenchDisplayRow* decodeCurrent;
@property (nonatomic, nullable, strong) SZBenchDisplayRow* decodeResult;
@property (nonatomic, nullable, strong) SZBenchDisplayRow* totalResult;
@end

NS_ASSUME_NONNULL_END
