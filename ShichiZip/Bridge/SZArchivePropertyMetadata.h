#pragma once

#include "SZBridgeCommon.h"

NS_ASSUME_NONNULL_BEGIN

NSArray<SZArchiveEntryProperty*>* SZCopyEntryProperties(IInArchive* archive);
NSString* _Nullable SZPropertyDisplayString(IInArchive* archive, UInt32 itemIndex, PROPID propID);

NS_ASSUME_NONNULL_END
