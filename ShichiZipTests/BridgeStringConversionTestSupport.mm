#import "BridgeStringConversionTestSupport.h"

#import "../ShichiZip/Bridge/SZBridgeCommon.h"

#include <vector>

NSString* SZTestBridgeRoundTripString(NSString* input) {
    return ToNS(ToU(input));
}

NSString* SZTestBridgeDecodeCStringData(NSData* bytes) {
    std::vector<char> buffer(bytes.length + 1, '\0');
    if (bytes.length > 0) {
        memcpy(buffer.data(), bytes.bytes, bytes.length);
    }
    return NSFromCString(buffer.data());
}
