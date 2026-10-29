#include "SZArchivePropertyMetadata.h"

#include "CPP/7zip/UI/Common/PropIDUtils.h"

struct SZEntryPropertyMetadata {
    const char* key;
    const char* titleKey;
    const char* title;
};

static SZEntryPropertyMetadata SZEntryPropertyMetadataForPropID(PROPID propID) {
    switch (propID) {
    case kpidPath:
    case kpidName:
        return { "name", "column.name", "Name" };
    case kpidExtension:
        return { "extension", "column.extension", "Extension" };
    case kpidIsDir:
        return { "folder", "column.folder", "Folder" };
    case kpidSize:
        return { "size", "column.size", "Size" };
    case kpidPackSize:
        return { "packedSize", "column.packedSize", "Packed Size" };
    case kpidMTime:
        return { "modified", "column.modified", "Modified" };
    case kpidCTime:
        return { "created", "column.created", "Created" };
    case kpidATime:
        return { "accessed", "column.accessed", "Accessed" };
    case kpidAttrib:
        return { "attributes", "column.attributes", "Attributes" };
    case kpidSolid:
        return { "solid", "column.solid", "Solid" };
    case kpidCommented:
        return { "commented", "column.commented", "Commented" };
    case kpidEncrypted:
        return { "encrypted", "column.encrypted", "Encrypted" };
    case kpidSplitBefore:
        return { "splitBefore", "column.splitBefore", "Split Before" };
    case kpidSplitAfter:
        return { "splitAfter", "column.splitAfter", "Split After" };
    case kpidDictionarySize:
        return { "dictionary", "column.dictionary", "Dictionary" };
    case kpidCRC:
        return { "crc", "column.crc", "CRC" };
    case kpidType:
        return { "type", "column.type", "Type" };
    case kpidIsAnti:
        return { "anti", "column.anti", "Anti" };
    case kpidMethod:
        return { "method", "column.method", "Method" };
    case kpidHostOS:
        return { "hostOS", "column.hostOS", "Host OS" };
    case kpidFileSystem:
        return { "fileSystem", "column.fileSystem", "File System" };
    case kpidUser:
        return { "user", "column.user", "User" };
    case kpidGroup:
        return { "group", "column.group", "Group" };
    case kpidBlock:
        return { "block", "column.block", "Block" };
    case kpidComment:
        return { "comment", "column.comment", "Comment" };
    case kpidPosition:
        return { "position", "column.position", "Position" };
    case kpidPrefix:
        return { "pathPrefix", "column.pathPrefix", "Path Prefix" };
    case kpidNumSubDirs:
        return { "folders", "column.folders", "Folders" };
    case kpidNumSubFiles:
        return { "files", "column.files", "Files" };
    case kpidUnpackVer:
        return { "version", "column.version", "Version" };
    case kpidVolume:
        return { "volume", "column.volume", "Volume" };
    case kpidIsVolume:
        return { "multivolume", "column.multivolume", "Multivolume" };
    case kpidOffset:
        return { "offset", "column.offset", "Offset" };
    case kpidLinks:
        return { "links", "column.links", "Links" };
    case kpidNumBlocks:
        return { "blocks", "column.blocks", "Blocks" };
    case kpidNumVolumes:
        return { "volumes", "column.volumes", "Volumes" };
    case kpidTimeType:
        return { "timeType", "column.timeType", "Time Type" };
    case kpidBit64:
        return { "bit64", "column.bit64", "64-bit" };
    case kpidBigEndian:
        return { "bigEndian", "column.bigEndian", "Big-endian" };
    case kpidCpu:
        return { "cpu", "column.cpu", "CPU" };
    case kpidPhySize:
        return { "physicalSize", "column.physicalSize", "Physical Size" };
    case kpidHeadersSize:
        return { "headersSize", "column.headersSize", "Headers Size" };
    case kpidChecksum:
        return { "checksum", "column.checksum", "Checksum" };
    case kpidCharacts:
        return { "characteristics", "column.characteristics", "Characteristics" };
    case kpidVa:
        return { "virtualAddress", "column.virtualAddress", "Virtual Address" };
    case kpidId:
        return { "id", "column.id", "ID" };
    case kpidShortName:
        return { "shortName", "column.shortName", "Short Name" };
    case kpidCreatorApp:
        return { "creatorApplication", "column.creatorApplication", "Creator Application" };
    case kpidSectorSize:
        return { "sectorSize", "column.sectorSize", "Sector Size" };
    case kpidPosixAttrib:
        return { "posixAttributes", "column.posixAttributes", "Mode" };
    case kpidSymLink:
        return { "symbolicLink", "column.symbolicLink", "Symbolic Link" };
    case kpidError:
        return { "error", "column.error", "Error" };
    case kpidTotalSize:
        return { "totalSize", "column.totalSize", "Total Size" };
    case kpidFreeSpace:
        return { "freeSpace", "column.freeSpace", "Free Space" };
    case kpidClusterSize:
        return { "clusterSize", "column.clusterSize", "Cluster Size" };
    case kpidVolumeName:
        return { "volumeName", "column.volumeName", "Label" };
    case kpidLocalName:
        return { "localName", "column.localName", "Local Name" };
    case kpidProvider:
        return { "provider", "column.provider", "Provider" };
    case kpidNtSecure:
        return { "ntSecurity", "column.ntSecurity", "NT Security" };
    case kpidIsAltStream:
        return { "alternateStream", "column.alternateStream", "Alternate Stream" };
    case kpidIsAux:
        return { "aux", "column.aux", "Aux" };
    case kpidIsDeleted:
        return { "deleted", "column.deleted", "Deleted" };
    case kpidIsTree:
        return { "tree", "column.tree", "Is Tree" };
    case kpidSha1:
        return { "sha1", "column.sha1", "SHA-1" };
    case kpidSha256:
        return { "sha256", "column.sha256", "SHA-256" };
    case kpidErrorType:
        return { "errorType", "column.errorType", "Error Type" };
    case kpidNumErrors:
        return { "errors", "column.errors", "Errors" };
    case kpidErrorFlags:
        return { "errorFlags", "column.errorFlags", "Errors" };
    case kpidWarningFlags:
        return { "warningFlags", "column.warningFlags", "Warnings" };
    case kpidWarning:
        return { "warning", "column.warning", "Warning" };
    case kpidNumStreams:
        return { "streams", "column.streams", "Streams" };
    case kpidNumAltStreams:
        return { "alternateStreams", "column.alternateStreams", "Alternate Streams" };
    case kpidAltStreamsSize:
        return { "alternateStreamsSize", "column.alternateStreamsSize", "Alternate Streams Size" };
    case kpidVirtualSize:
        return { "virtualSize", "column.virtualSize", "Virtual Size" };
    case kpidUnpackSize:
        return { "unpackSize", "column.unpackSize", "Unpack Size" };
    case kpidTotalPhySize:
        return { "totalPhysicalSize", "column.totalPhysicalSize", "Total Physical Size" };
    case kpidVolumeIndex:
        return { "volumeIndex", "column.volumeIndex", "Volume Index" };
    case kpidSubType:
        return { "subtype", "column.subtype", "SubType" };
    case kpidShortComment:
        return { "shortComment", "column.shortComment", "Short Comment" };
    case kpidCodePage:
        return { "codePage", "column.codePage", "Code Page" };
    case kpidIsNotArcType:
        return { "notArchiveType", "column.notArchiveType", "Is not archive type" };
    case kpidPhySizeCantBeDetected:
        return { "physicalSizeCannotBeDetected", "column.physicalSizeCannotBeDetected", "Physical Size can't be detected" };
    case kpidZerosTailIsAllowed:
        return { "zerosTailIsAllowed", "column.zerosTailIsAllowed", "Zeros Tail Is Allowed" };
    case kpidTailSize:
        return { "tailSize", "column.tailSize", "Tail Size" };
    case kpidEmbeddedStubSize:
        return { "embeddedStubSize", "column.embeddedStubSize", "Embedded Stub Size" };
    case kpidNtReparse:
        return { "link", "column.link", "Link" };
    case kpidHardLink:
        return { "hardLink", "column.hardLink", "Hard Link" };
    case kpidINode:
        return { "inode", "column.inode", "iNode" };
    case kpidStreamId:
        return { "streamID", "column.streamID", "Stream ID" };
    case kpidReadOnly:
        return { "readOnly", "column.readOnly", "Read-only" };
    case kpidOutName:
        return { "outName", "column.outName", "Out Name" };
    case kpidCopyLink:
        return { "copyLink", "column.copyLink", "Copy Link" };
    case kpidArcFileName:
        return { "archiveFileName", "column.archiveFileName", "ArcFileName" };
    case kpidIsHash:
        return { "hash", "column.hash", "IsHash" };
    case kpidChangeTime:
        return { "changed", "column.changed", "Metadata Changed" };
    case kpidUserId:
        return { "userID", "column.userID", "User ID" };
    case kpidGroupId:
        return { "groupID", "column.groupID", "Group ID" };
    case kpidDeviceMajor:
        return { "deviceMajor", "column.deviceMajor", "Device Major" };
    case kpidDeviceMinor:
        return { "deviceMinor", "column.deviceMinor", "Device Minor" };
    case kpidDevMajor:
        return { "devMajor", "column.devMajor", "Dev Major" };
    case kpidDevMinor:
        return { "devMinor", "column.devMinor", "Dev Minor" };
    default:
        return { nullptr, nullptr, nullptr };
    }
}

static SZArchiveEntryProperty* SZMakeEntryProperty(PROPID propID, VARTYPE valueType, NSString* propertyName) {
    const SZEntryPropertyMetadata metadata = SZEntryPropertyMetadataForPropID(propID);
    SZArchiveEntryProperty* property = [SZArchiveEntryProperty new];
    property.key = metadata.key ? @(metadata.key) : [NSString stringWithFormat:@"property.%u", (unsigned)propID];
    property.titleKey = metadata.titleKey ? @(metadata.titleKey) : nil;
    if (metadata.title) {
        property.title = @(metadata.title);
    } else if (propertyName.length > 0) {
        property.title = propertyName;
    } else {
        property.title = [NSString stringWithFormat:@"Property %u", (unsigned)propID];
    }
    property.propID = (NSUInteger)propID;
    property.valueType = (NSUInteger)valueType;
    return property;
}

NSArray<SZArchiveEntryProperty*>* SZCopyEntryProperties(IInArchive* archive) {
    NSMutableArray<SZArchiveEntryProperty*>* properties = [NSMutableArray array];
    NSMutableSet<NSString*>* seen = [NSMutableSet set];

    void (^addProperty)(SZArchiveEntryProperty*) = ^(SZArchiveEntryProperty* property) {
        if (property.key.length == 0 || [seen containsObject:property.key])
            return;
        [seen addObject:property.key];
        [properties addObject:property];
    };

    addProperty(SZMakeEntryProperty(kpidPath, VT_BSTR, nil));

    UInt32 propertyCount = 0;
    if (archive->GetNumberOfProperties(&propertyCount) != S_OK)
        return properties;

    for (UInt32 propertyIndex = 0; propertyIndex < propertyCount; propertyIndex++) {
        BSTR propertyNameBSTR = NULL;
        PROPID propID = kpidNoProperty;
        VARTYPE valueType = VT_EMPTY;
        const HRESULT result = archive->GetPropertyInfo(propertyIndex, &propertyNameBSTR, &propID, &valueType);
        NSString* propertyName = propertyNameBSTR ? ToNS(UString(propertyNameBSTR)) : @"";
        if (propertyNameBSTR)
            ::SysFreeString(propertyNameBSTR);
        if (result != S_OK || propID == kpidIsDir)
            continue;
        addProperty(SZMakeEntryProperty(propID, valueType, propertyName));
    }

    return properties;
}

NSString* SZPropertyDisplayString(IInArchive* archive, UInt32 itemIndex, PROPID propID) {
    NWindows::NCOM::CPropVariant value;
    if (archive->GetProperty(itemIndex, propID, &value) != S_OK || value.vt == VT_EMPTY)
        return nil;

    UString displayString;
    ConvertPropertyToString2(displayString, value, propID);
    if (displayString.IsEmpty())
        return @"";
    return ToNS(displayString);
}
