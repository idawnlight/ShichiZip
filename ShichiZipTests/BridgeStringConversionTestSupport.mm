#import "BridgeStringConversionTestSupport.h"

#import "../ShichiZip/Bridge/SZBridgeCommon.h"

#include <vector>

NSString* SZTestBridgeRoundTripString(NSString* input) {
    return ToNS(ToU(input));
}

NSArray<NSNumber*>* SZTestBridgeUStringCodeUnits(NSString* input) {
    const UString converted = ToU(input);
    NSMutableArray<NSNumber*>* units = [NSMutableArray arrayWithCapacity:converted.Len()];
    for (unsigned index = 0; index < converted.Len(); index++) {
        [units addObject:@((uint32_t)converted[index])];
    }
    return units;
}

NSString* SZTestBridgeStringFromUStringCodeUnits(NSArray<NSNumber*>* input) {
    UString string;
    wchar_t* buffer = string.GetBuf_SetEnd((unsigned)input.count);
    for (NSUInteger index = 0; index < input.count; index++) {
        buffer[index] = (wchar_t)input[index].unsignedShortValue;
    }
    return ToNS(string);
}

NSString* SZTestBridgeDecodeCStringData(NSData* bytes) {
    std::vector<char> buffer(bytes.length + 1, '\0');
    if (bytes.length > 0) {
        memcpy(buffer.data(), bytes.bytes, bytes.length);
    }
    return NSFromCString(buffer.data());
}
