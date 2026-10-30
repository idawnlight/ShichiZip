#pragma once

#include "C/7zTypes.h"
#import "SZArchive.h"

int SZCompressionEstimateMethodID(SZCompressionSettings* settings);
bool SZCompressionEstimateMethodSupportsSFX(int methodID);
UInt32 SZCompressionLevelPropertyValue(int methodID, NSInteger levelValue);
