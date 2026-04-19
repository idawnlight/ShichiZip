#import "SZObjCLog.h"

#import <os/log.h>

typedef NS_ENUM(NSUInteger, SZObjCLogKind) {
    SZObjCLogKindDebug,
    SZObjCLogKindInfo,
    SZObjCLogKindError,
};

static NSString* SZObjCLogMessage(NSString* format, va_list arguments) {
    NSString* message = [[NSString alloc] initWithFormat:format arguments:arguments];
    return message ?: @"<log formatting failed>";
}

static NSString* SZObjCLogSubsystem(void) {
    return NSBundle.mainBundle.bundleIdentifier ?: @"ShichiZip";
}

static os_log_t SZObjCUnifiedLog(NSString* prefix) {
    return os_log_create(SZObjCLogSubsystem().UTF8String, prefix.UTF8String);
}

static void SZObjCWriteUnifiedLog(NSString* prefix,
    os_log_type_t type,
    NSString* message,
    BOOL includePrivateData) {
    os_log_t log = SZObjCUnifiedLog(prefix);

    if (includePrivateData) {
        os_log_with_type(log, type, "%{private}@", message);
    } else {
        os_log_with_type(log, type, "%{public}@", message);
    }
}

static void SZObjCLogWrite(NSString* prefix,
    SZObjCLogKind kind,
    NSString* format,
    va_list arguments) {
    NSString* message = SZObjCLogMessage(format, arguments);

    switch (kind) {
    case SZObjCLogKindDebug:
#if DEBUG
        SZObjCWriteUnifiedLog(prefix, OS_LOG_TYPE_DEBUG, message, NO);
        NSLog(@"[%@] %@", prefix, message);
#endif
        break;
    case SZObjCLogKindInfo:
#if DEBUG
        SZObjCWriteUnifiedLog(prefix, OS_LOG_TYPE_INFO, message, NO);
        NSLog(@"[%@] %@", prefix, message);
#else
        SZObjCWriteUnifiedLog(prefix, OS_LOG_TYPE_INFO, message, YES);
#endif
        break;
    case SZObjCLogKindError:
#if DEBUG
        SZObjCWriteUnifiedLog(prefix, OS_LOG_TYPE_ERROR, message, NO);
        NSLog(@"[%@] %@", prefix, message);
#else
        SZObjCWriteUnifiedLog(prefix, OS_LOG_TYPE_ERROR, message, YES);
#endif
        break;
    }
}

void SZLogDebug(NSString* prefix, NSString* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    SZObjCLogWrite(prefix, SZObjCLogKindDebug, format, arguments);
    va_end(arguments);
}

void SZLogInfo(NSString* prefix, NSString* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    SZObjCLogWrite(prefix, SZObjCLogKindInfo, format, arguments);
    va_end(arguments);
}

void SZLogError(NSString* prefix, NSString* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    SZObjCLogWrite(prefix, SZObjCLogKindError, format, arguments);
    va_end(arguments);
}