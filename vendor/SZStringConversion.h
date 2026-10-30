#pragma once

#import <Foundation/Foundation.h>

#define BOOL BOOL_7Z_COMPAT
#if __has_include("CPP/Common/MyString.h")
#include "CPP/Common/MyString.h"
#elif __has_include("7zip/CPP/Common/MyString.h")
#include "7zip/CPP/Common/MyString.h"
#elif __has_include("7zip-zstd/CPP/Common/MyString.h")
#include "7zip-zstd/CPP/Common/MyString.h"
#else
#error "7-Zip MyString.h not found"
#endif
#undef BOOL

#include <vector>

NS_ASSUME_NONNULL_BEGIN

// 7-Zip stores UTF-16 code units even when wchar_t is 32 bits. Preserve those
// units and explicit lengths rather than decoding scalars or using terminators.
static inline UString SZToUString(NSString* _Nullable string) {
    const NSUInteger length = string.length;
    if (length == 0) {
        return UString();
    }

    unichar stackBuffer[256];
    std::vector<unichar> heapBuffer(length > 256 ? length : 0);
    unichar* utf16 = length <= 256 ? stackBuffer : heapBuffer.data();
    [string getCharacters:utf16 range:NSMakeRange(0, length)];

    UString converted;
    wchar_t* buffer = converted.GetBuf_SetEnd((unsigned)length);
    for (NSUInteger index = 0; index < length; index++) {
        buffer[index] = (wchar_t)utf16[index];
    }
    return converted;
}

static inline NSString* SZToNSString(const UString& string) {
    const unsigned length = string.Len();
    if (length == 0) {
        return @"";
    }

    unichar stackBuffer[256];
    std::vector<unichar> heapBuffer(length > 256 ? length : 0);
    unichar* utf16 = length <= 256 ? stackBuffer : heapBuffer.data();
    const wchar_t* buffer = string.Ptr();
    for (unsigned index = 0; index < length; index++) {
        utf16[index] = (unichar)buffer[index];
    }
    return [NSString stringWithCharacters:utf16 length:length];
}

NS_ASSUME_NONNULL_END
