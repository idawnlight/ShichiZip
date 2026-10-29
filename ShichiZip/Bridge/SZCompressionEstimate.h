#pragma once

#import "SZArchive.h"
#include "C/7zTypes.h"

int SZCompressionEstimateMethodID(SZCompressionSettings* settings);
bool SZCompressionEstimateMethodSupportsSFX(int methodID);
UInt32 SZCompressionLevelPropertyValue(int methodID, NSInteger levelValue);
