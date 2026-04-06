#import <Foundation/Foundation.h>

@class SZArchiveEntry;
@protocol SZProgressDelegate;
@protocol SZPasswordDelegate;

NS_ASSUME_NONNULL_BEGIN

/// Supported archive formats for creation
typedef NS_ENUM(NSInteger, SZArchiveFormat) {
    SZArchiveFormat7z = 0,
    SZArchiveFormatZip,
    SZArchiveFormatTar,
    SZArchiveFormatGZip,
    SZArchiveFormatBZip2,
    SZArchiveFormatXz,
    SZArchiveFormatWim,
    SZArchiveFormatZstd
};

/// Compression level
typedef NS_ENUM(NSInteger, SZCompressionLevel) {
    SZCompressionLevelStore = 0,
    SZCompressionLevelFastest = 1,
    SZCompressionLevelFast = 3,
    SZCompressionLevelNormal = 5,
    SZCompressionLevelMaximum = 7,
    SZCompressionLevelUltra = 9
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
    SZOverwriteModeOverwrite
};

/// Path mode for extraction
typedef NS_ENUM(NSInteger, SZPathMode) {
    SZPathModeFullPaths = 0,
    SZPathModeNoPaths,
    SZPathModeAbsolutePaths
};

/// Compression settings for archive creation
@interface SZCompressionSettings : NSObject
@property (nonatomic) SZArchiveFormat format;
@property (nonatomic) SZCompressionLevel level;
@property (nonatomic) SZCompressionMethod method;
@property (nonatomic) SZEncryptionMethod encryption;
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic) BOOL encryptFileNames;
@property (nonatomic) BOOL solidMode;
@property (nonatomic) uint32_t dictionarySize;   // in bytes, 0 = auto
@property (nonatomic) uint32_t wordSize;          // 0 = auto
@property (nonatomic) uint32_t numThreads;        // 0 = auto
@property (nonatomic) uint64_t splitVolumeSize;   // 0 = no split
@property (nonatomic) BOOL createSFX;
@end

/// Extraction settings
@interface SZExtractionSettings : NSObject
@property (nonatomic) SZPathMode pathMode;
@property (nonatomic) SZOverwriteMode overwriteMode;
@property (nonatomic, copy, nullable) NSString *password;
@end

/// Progress callback delegate
@protocol SZProgressDelegate <NSObject>
- (void)progressDidUpdate:(double)fraction;
- (void)progressDidUpdateFileName:(NSString *)fileName;
- (void)progressDidUpdateBytesCompleted:(uint64_t)completed total:(uint64_t)total;
- (BOOL)progressShouldCancel;
@optional
- (void)progressDidUpdateSpeed:(double)bytesPerSecond;
- (void)progressDidUpdateCompressionRatio:(double)ratio;
@end

/// Password callback delegate
@protocol SZPasswordDelegate <NSObject>
- (nullable NSString *)passwordRequiredForArchive:(NSString *)archivePath;
@end

/// Represents a single entry in an archive
@interface SZArchiveEntry : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic) uint64_t size;
@property (nonatomic) uint64_t packedSize;
@property (nonatomic, strong, nullable) NSDate *modifiedDate;
@property (nonatomic, strong, nullable) NSDate *createdDate;
@property (nonatomic) uint32_t crc;
@property (nonatomic) BOOL isDirectory;
@property (nonatomic) BOOL isEncrypted;
@property (nonatomic, copy, nullable) NSString *method;
@property (nonatomic) uint32_t attributes;
@property (nonatomic, copy, nullable) NSString *comment;
@property (nonatomic) NSUInteger index; // internal archive index
@end

/// Format info for detected/available formats
@interface SZFormatInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray<NSString *> *extensions;
@property (nonatomic) BOOL canWrite;
@end

/// Main archive interface — wraps 7-Zip C++ core
@interface SZArchive : NSObject

/// Open an existing archive for reading
- (BOOL)openAtPath:(NSString *)path
             error:(NSError **)error;

/// Open with password
- (BOOL)openAtPath:(NSString *)path
          password:(nullable NSString *)password
             error:(NSError **)error;

/// Close the archive
- (void)close;

/// Get the detected format name
@property (nonatomic, readonly, nullable) NSString *formatName;

/// Get the number of entries
@property (nonatomic, readonly) NSUInteger entryCount;

/// Get all entries
- (NSArray<SZArchiveEntry *> *)entries;

/// Extract all entries to a destination
- (BOOL)extractToPath:(NSString *)destinationPath
             settings:(SZExtractionSettings *)settings
             progress:(nullable id<SZProgressDelegate>)progress
                error:(NSError **)error;

/// Extract specific entries by index
- (BOOL)extractEntries:(NSArray<NSNumber *> *)indices
                toPath:(NSString *)destinationPath
              settings:(SZExtractionSettings *)settings
              progress:(nullable id<SZProgressDelegate>)progress
                 error:(NSError **)error;

/// Test archive integrity
- (BOOL)testWithProgress:(nullable id<SZProgressDelegate>)progress
                   error:(NSError **)error;

/// Create a new archive from files
+ (BOOL)createAtPath:(NSString *)archivePath
           fromPaths:(NSArray<NSString *> *)sourcePaths
            settings:(SZCompressionSettings *)settings
            progress:(nullable id<SZProgressDelegate>)progress
               error:(NSError **)error;

/// Get list of supported format infos
+ (NSArray<SZFormatInfo *> *)supportedFormats;

/// Calculate hash of files
+ (nullable NSDictionary<NSString *, NSString *> *)calculateHashForPath:(NSString *)path
                                                            algorithm:(NSString *)algorithm
                                                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
