# ShichiZip - lib7zip.a static library build
# Builds the 7-Zip C/C++ core as a static library for embedding in the macOS app

SEVENZ_ROOT = vendor/7zip
C_ROOT = $(SEVENZ_ROOT)/C
CPP_ROOT = $(SEVENZ_ROOT)/CPP
ASM_ROOT = $(SEVENZ_ROOT)/Asm

CC = clang
CXX = clang++
AR = ar

MACOSX_DEPLOYMENT_TARGET ?= 13.0

ARCH = -arch arm64
CFLAGS_COMMON = $(ARCH) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 \
	-D_LARGEFILE_SOURCE -fPIC -Wall -Wextra
CFLAGS = $(CFLAGS_COMMON) -std=c11
CXXFLAGS = $(CFLAGS_COMMON) -std=c++11 -DSHICHIZIP_APPLE_DETECTOR
OBJCXXFLAGS = $(CFLAGS_COMMON) -std=c++11 -fobjc-arc -DSHICHIZIP_APPLE_DETECTOR

O = build/obj
LIB_OUT = build/lib
LIB = $(LIB_OUT)/lib7zip.a

# === C sources (core compression engine) ===
C_SRCS = \
	$(C_ROOT)/7zBuf2.c \
	$(C_ROOT)/7zCrc.c \
	$(C_ROOT)/7zCrcOpt.c \
	$(C_ROOT)/7zStream.c \
	$(C_ROOT)/Aes.c \
	$(C_ROOT)/AesOpt.c \
	$(C_ROOT)/Alloc.c \
	$(C_ROOT)/Bcj2.c \
	$(C_ROOT)/Bcj2Enc.c \
	$(C_ROOT)/Blake2s.c \
	$(C_ROOT)/Bra.c \
	$(C_ROOT)/Bra86.c \
	$(C_ROOT)/BraIA64.c \
	$(C_ROOT)/BwtSort.c \
	$(C_ROOT)/CpuArch.c \
	$(C_ROOT)/Delta.c \
	$(C_ROOT)/HuffEnc.c \
	$(C_ROOT)/LzFind.c \
	$(C_ROOT)/LzFindMt.c \
	$(C_ROOT)/LzFindOpt.c \
	$(C_ROOT)/Lzma2Dec.c \
	$(C_ROOT)/Lzma2DecMt.c \
	$(C_ROOT)/Lzma2Enc.c \
	$(C_ROOT)/LzmaDec.c \
	$(C_ROOT)/LzmaEnc.c \
	$(C_ROOT)/Md5.c \
	$(C_ROOT)/MtCoder.c \
	$(C_ROOT)/MtDec.c \
	$(C_ROOT)/Ppmd7.c \
	$(C_ROOT)/Ppmd7Dec.c \
	$(C_ROOT)/Ppmd7aDec.c \
	$(C_ROOT)/Ppmd7Enc.c \
	$(C_ROOT)/Ppmd8.c \
	$(C_ROOT)/Ppmd8Dec.c \
	$(C_ROOT)/Ppmd8Enc.c \
	$(C_ROOT)/Sha1.c \
	$(C_ROOT)/Sha1Opt.c \
	$(C_ROOT)/Sha256.c \
	$(C_ROOT)/Sha256Opt.c \
	$(C_ROOT)/Sha3.c \
	$(C_ROOT)/Sha512.c \
	$(C_ROOT)/Sha512Opt.c \
	$(C_ROOT)/Sort.c \
	$(C_ROOT)/SwapBytes.c \
	$(C_ROOT)/Threads.c \
	$(C_ROOT)/Xxh64.c \
	$(C_ROOT)/Xz.c \
	$(C_ROOT)/XzDec.c \
	$(C_ROOT)/XzEnc.c \
	$(C_ROOT)/XzIn.c \
	$(C_ROOT)/XzCrc64.c \
	$(C_ROOT)/XzCrc64Opt.c \
	$(C_ROOT)/ZstdDec.c

# === CPP/Common (cross-platform utilities) ===
COMMON_SRCS = \
	$(CPP_ROOT)/Common/CRC.cpp \
	$(CPP_ROOT)/Common/CrcReg.cpp \
	$(CPP_ROOT)/Common/CommandLineParser.cpp \
	$(CPP_ROOT)/Common/DynLimBuf.cpp \
	$(CPP_ROOT)/Common/IntToString.cpp \
	$(CPP_ROOT)/Common/ListFileUtils.cpp \
	$(CPP_ROOT)/Common/LzFindPrepare.cpp \
	$(CPP_ROOT)/Common/Md5Reg.cpp \
	$(CPP_ROOT)/Common/MyMap.cpp \
	$(CPP_ROOT)/Common/MyString.cpp \
	$(CPP_ROOT)/Common/MyVector.cpp \
	$(CPP_ROOT)/Common/MyWindows.cpp \
	$(CPP_ROOT)/Common/MyXml.cpp \
	$(CPP_ROOT)/Common/NewHandler.cpp \
	$(CPP_ROOT)/Common/Sha1Prepare.cpp \
	$(CPP_ROOT)/Common/Sha1Reg.cpp \
	$(CPP_ROOT)/Common/Sha256Prepare.cpp \
	$(CPP_ROOT)/Common/Sha256Reg.cpp \
	$(CPP_ROOT)/Common/Sha3Reg.cpp \
	$(CPP_ROOT)/Common/Sha512Prepare.cpp \
	$(CPP_ROOT)/Common/Sha512Reg.cpp \
	$(CPP_ROOT)/Common/StdInStream.cpp \
	$(CPP_ROOT)/Common/StdOutStream.cpp \
	$(CPP_ROOT)/Common/StringConvert.cpp \
	$(CPP_ROOT)/Common/StringToInt.cpp \
	$(CPP_ROOT)/Common/UTFConvert.cpp \
	$(CPP_ROOT)/Common/Wildcard.cpp \
	$(CPP_ROOT)/Common/Xxh64Reg.cpp \
	$(CPP_ROOT)/Common/XzCrc64Init.cpp \
	$(CPP_ROOT)/Common/XzCrc64Reg.cpp

# === CPP/Windows (POSIX abstraction layer) ===
WIN_SRCS = \
	$(CPP_ROOT)/Windows/ErrorMsg.cpp \
	$(CPP_ROOT)/Windows/FileDir.cpp \
	$(CPP_ROOT)/Windows/FileFind.cpp \
	$(CPP_ROOT)/Windows/FileIO.cpp \
	$(CPP_ROOT)/Windows/FileLink.cpp \
	$(CPP_ROOT)/Windows/FileName.cpp \
	$(CPP_ROOT)/Windows/PropVariant.cpp \
	$(CPP_ROOT)/Windows/PropVariantConv.cpp \
	$(CPP_ROOT)/Windows/PropVariantUtils.cpp \
	$(CPP_ROOT)/Windows/Synchronization.cpp \
	$(CPP_ROOT)/Windows/System.cpp \
	$(CPP_ROOT)/Windows/SystemInfo.cpp \
	$(CPP_ROOT)/Windows/TimeUtils.cpp

# === CPP/7zip/Common (7-Zip shared utilities) ===
SEVENZIP_COMMON_SRCS = \
	$(CPP_ROOT)/7zip/Common/CreateCoder.cpp \
	$(CPP_ROOT)/7zip/Common/CWrappers.cpp \
	$(CPP_ROOT)/7zip/Common/FilePathAutoRename.cpp \
	$(CPP_ROOT)/7zip/Common/FileStreams.cpp \
	$(CPP_ROOT)/7zip/Common/FilterCoder.cpp \
	$(CPP_ROOT)/7zip/Common/InBuffer.cpp \
	$(CPP_ROOT)/7zip/Common/InOutTempBuffer.cpp \
	$(CPP_ROOT)/7zip/Common/LimitedStreams.cpp \
	$(CPP_ROOT)/7zip/Common/LockedStream.cpp \
	$(CPP_ROOT)/7zip/Common/MemBlocks.cpp \
	$(CPP_ROOT)/7zip/Common/MethodId.cpp \
	$(CPP_ROOT)/7zip/Common/MethodProps.cpp \
	$(CPP_ROOT)/7zip/Common/MultiOutStream.cpp \
	$(CPP_ROOT)/7zip/Common/OffsetStream.cpp \
	$(CPP_ROOT)/7zip/Common/OutBuffer.cpp \
	$(CPP_ROOT)/7zip/Common/OutMemStream.cpp \
	$(CPP_ROOT)/7zip/Common/ProgressMt.cpp \
	$(CPP_ROOT)/7zip/Common/ProgressUtils.cpp \
	$(CPP_ROOT)/7zip/Common/PropId.cpp \
	$(CPP_ROOT)/7zip/Common/StreamBinder.cpp \
	$(CPP_ROOT)/7zip/Common/StreamObjects.cpp \
	$(CPP_ROOT)/7zip/Common/StreamUtils.cpp \
	$(CPP_ROOT)/7zip/Common/UniqBlocks.cpp \
	$(CPP_ROOT)/7zip/Common/VirtThread.cpp

# === Archive format handlers ===
ARCHIVE_SRCS = \
	$(CPP_ROOT)/7zip/Archive/ApfsHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/ApmHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/ArHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/ArjHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/Base64Handler.cpp \
	$(CPP_ROOT)/7zip/Archive/Bz2Handler.cpp \
	$(CPP_ROOT)/7zip/Archive/ComHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/CpioHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/CramfsHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/DeflateProps.cpp \
	$(CPP_ROOT)/7zip/Archive/DmgHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/ElfHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/ExtHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/FatHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/FlvHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/GzHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/GptHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/HandlerCont.cpp \
	$(CPP_ROOT)/7zip/Archive/HfsHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/IhexHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/LpHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/LzhHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/LzmaHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/MachoHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/MbrHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/MslzHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/MubHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/NtfsHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/PeHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/PpmdHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/QcowHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/RpmHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/SparseHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/SplitHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/SquashfsHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/SwfHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/UefiHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/VdiHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/VhdHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/VhdxHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/VmdkHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/XarHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/XzHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/ZHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/ZstdHandler.cpp

# Archive sub-format handlers
ARCHIVE_SUB_SRCS = \
	$(CPP_ROOT)/7zip/Archive/7z/7zCompressionMode.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zDecode.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zEncode.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zExtract.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zFolderInStream.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zHandlerOut.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zHeader.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zIn.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zOut.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zProperties.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zSpecStream.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zUpdate.cpp \
	$(CPP_ROOT)/7zip/Archive/7z/7zRegister.cpp \
	$(CPP_ROOT)/7zip/Archive/Cab/CabBlockInStream.cpp \
	$(CPP_ROOT)/7zip/Archive/Cab/CabHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/Cab/CabHeader.cpp \
	$(CPP_ROOT)/7zip/Archive/Cab/CabIn.cpp \
	$(CPP_ROOT)/7zip/Archive/Cab/CabRegister.cpp \
	$(CPP_ROOT)/7zip/Archive/Chm/ChmHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/Chm/ChmIn.cpp \
	$(CPP_ROOT)/7zip/Archive/Iso/IsoHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/Iso/IsoHeader.cpp \
	$(CPP_ROOT)/7zip/Archive/Iso/IsoIn.cpp \
	$(CPP_ROOT)/7zip/Archive/Iso/IsoRegister.cpp \
	$(CPP_ROOT)/7zip/Archive/Nsis/NsisDecode.cpp \
	$(CPP_ROOT)/7zip/Archive/Nsis/NsisHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/Nsis/NsisIn.cpp \
	$(CPP_ROOT)/7zip/Archive/Nsis/NsisRegister.cpp \
	$(CPP_ROOT)/7zip/Archive/Rar/RarHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/Rar/Rar5Handler.cpp \
	$(CPP_ROOT)/7zip/Archive/Tar/TarHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/Tar/TarHandlerOut.cpp \
	$(CPP_ROOT)/7zip/Archive/Tar/TarHeader.cpp \
	$(CPP_ROOT)/7zip/Archive/Tar/TarIn.cpp \
	$(CPP_ROOT)/7zip/Archive/Tar/TarOut.cpp \
	$(CPP_ROOT)/7zip/Archive/Tar/TarUpdate.cpp \
	$(CPP_ROOT)/7zip/Archive/Tar/TarRegister.cpp \
	$(CPP_ROOT)/7zip/Archive/Udf/UdfHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/Udf/UdfIn.cpp \
	$(CPP_ROOT)/7zip/Archive/Wim/WimHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/Wim/WimHandlerOut.cpp \
	$(CPP_ROOT)/7zip/Archive/Wim/WimIn.cpp \
	$(CPP_ROOT)/7zip/Archive/Wim/WimRegister.cpp \
	$(CPP_ROOT)/7zip/Archive/Zip/ZipAddCommon.cpp \
	$(CPP_ROOT)/7zip/Archive/Zip/ZipHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/Zip/ZipHandlerOut.cpp \
	$(CPP_ROOT)/7zip/Archive/Zip/ZipIn.cpp \
	$(CPP_ROOT)/7zip/Archive/Zip/ZipItem.cpp \
	$(CPP_ROOT)/7zip/Archive/Zip/ZipOut.cpp \
	$(CPP_ROOT)/7zip/Archive/Zip/ZipUpdate.cpp \
	$(CPP_ROOT)/7zip/Archive/Zip/ZipRegister.cpp \
	$(CPP_ROOT)/7zip/Archive/Common/CoderMixer2.cpp \
	$(CPP_ROOT)/7zip/Archive/Common/DummyOutStream.cpp \
	$(CPP_ROOT)/7zip/Archive/Common/FindSignature.cpp \
	$(CPP_ROOT)/7zip/Archive/Common/InStreamWithCRC.cpp \
	$(CPP_ROOT)/7zip/Archive/Common/ItemNameUtils.cpp \
	$(CPP_ROOT)/7zip/Archive/Common/MultiStream.cpp \
	$(CPP_ROOT)/7zip/Archive/Common/OutStreamWithCRC.cpp \
	$(CPP_ROOT)/7zip/Archive/Common/OutStreamWithSha1.cpp \
	$(CPP_ROOT)/7zip/Archive/Common/HandlerOut.cpp \
	$(CPP_ROOT)/7zip/Archive/Common/ParseProperties.cpp

# === Compression codecs ===
COMPRESS_SRCS = \
	$(CPP_ROOT)/7zip/Compress/Bcj2Coder.cpp \
	$(CPP_ROOT)/7zip/Compress/Bcj2Register.cpp \
	$(CPP_ROOT)/7zip/Compress/BcjCoder.cpp \
	$(CPP_ROOT)/7zip/Compress/BcjRegister.cpp \
	$(CPP_ROOT)/7zip/Compress/BitlDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/BranchMisc.cpp \
	$(CPP_ROOT)/7zip/Compress/BranchRegister.cpp \
	$(CPP_ROOT)/7zip/Compress/ByteSwap.cpp \
	$(CPP_ROOT)/7zip/Compress/BZip2Crc.cpp \
	$(CPP_ROOT)/7zip/Compress/BZip2Decoder.cpp \
	$(CPP_ROOT)/7zip/Compress/BZip2Encoder.cpp \
	$(CPP_ROOT)/7zip/Compress/BZip2Register.cpp \
	$(CPP_ROOT)/7zip/Compress/CopyCoder.cpp \
	$(CPP_ROOT)/7zip/Compress/CopyRegister.cpp \
	$(CPP_ROOT)/7zip/Compress/Deflate64Register.cpp \
	$(CPP_ROOT)/7zip/Compress/DeflateDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/DeflateEncoder.cpp \
	$(CPP_ROOT)/7zip/Compress/DeflateRegister.cpp \
	$(CPP_ROOT)/7zip/Compress/DeltaFilter.cpp \
	$(CPP_ROOT)/7zip/Compress/ImplodeDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/LzfseDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/LzhDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/Lzma2Decoder.cpp \
	$(CPP_ROOT)/7zip/Compress/Lzma2Encoder.cpp \
	$(CPP_ROOT)/7zip/Compress/Lzma2Register.cpp \
	$(CPP_ROOT)/7zip/Compress/LzmaDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/LzmaEncoder.cpp \
	$(CPP_ROOT)/7zip/Compress/LzmaRegister.cpp \
	$(CPP_ROOT)/7zip/Compress/LzmsDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/LzOutWindow.cpp \
	$(CPP_ROOT)/7zip/Compress/LzxDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/PpmdDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/PpmdEncoder.cpp \
	$(CPP_ROOT)/7zip/Compress/PpmdRegister.cpp \
	$(CPP_ROOT)/7zip/Compress/PpmdZip.cpp \
	$(CPP_ROOT)/7zip/Compress/QuantumDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/ShrinkDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/XpressDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/XzDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/XzEncoder.cpp \
	$(CPP_ROOT)/7zip/Compress/ZlibDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/ZlibEncoder.cpp \
	$(CPP_ROOT)/7zip/Compress/ZDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/ZstdDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/Rar1Decoder.cpp \
	$(CPP_ROOT)/7zip/Compress/Rar2Decoder.cpp \
	$(CPP_ROOT)/7zip/Compress/Rar3Decoder.cpp \
	$(CPP_ROOT)/7zip/Compress/Rar3Vm.cpp \
	$(CPP_ROOT)/7zip/Compress/Rar5Decoder.cpp \
	$(CPP_ROOT)/7zip/Compress/RarCodecsRegister.cpp

# === Crypto ===
CRYPTO_SRCS = \
	$(CPP_ROOT)/7zip/Crypto/7zAes.cpp \
	$(CPP_ROOT)/7zip/Crypto/7zAesRegister.cpp \
	$(CPP_ROOT)/7zip/Crypto/HmacSha1.cpp \
	$(CPP_ROOT)/7zip/Crypto/HmacSha256.cpp \
	$(CPP_ROOT)/7zip/Crypto/MyAes.cpp \
	$(CPP_ROOT)/7zip/Crypto/MyAesReg.cpp \
	$(CPP_ROOT)/7zip/Crypto/Pbkdf2HmacSha1.cpp \
	$(CPP_ROOT)/7zip/Crypto/RandGen.cpp \
	$(CPP_ROOT)/7zip/Crypto/Rar20Crypto.cpp \
	$(CPP_ROOT)/7zip/Crypto/Rar5Aes.cpp \
	$(CPP_ROOT)/7zip/Crypto/RarAes.cpp \
	$(CPP_ROOT)/7zip/Crypto/WzAes.cpp \
	$(CPP_ROOT)/7zip/Crypto/ZipCrypto.cpp \
	$(CPP_ROOT)/7zip/Crypto/ZipStrong.cpp

# === UI/Common (archive operations - NOT Console UI) ===
UI_COMMON_SRCS = \
	$(CPP_ROOT)/7zip/UI/Common/ArchiveCommandLine.cpp \
	$(CPP_ROOT)/7zip/UI/Common/ArchiveExtractCallback.cpp \
	$(CPP_ROOT)/7zip/UI/Common/ArchiveOpenCallback.cpp \
	$(CPP_ROOT)/7zip/UI/Common/Bench.cpp \
	$(CPP_ROOT)/7zip/UI/Common/DefaultName.cpp \
	$(CPP_ROOT)/7zip/UI/Common/EnumDirItems.cpp \
	$(CPP_ROOT)/7zip/UI/Common/Extract.cpp \
	$(CPP_ROOT)/7zip/UI/Common/ExtractingFilePath.cpp \
	$(CPP_ROOT)/7zip/UI/Common/HashCalc.cpp \
	$(CPP_ROOT)/7zip/UI/Common/LoadCodecs.cpp \
	$(CPP_ROOT)/7zip/UI/Common/OpenArchive.cpp \
	$(CPP_ROOT)/7zip/UI/Common/PropIDUtils.cpp \
	$(CPP_ROOT)/7zip/UI/Common/SetProperties.cpp \
	$(CPP_ROOT)/7zip/UI/Common/SortUtils.cpp \
	$(CPP_ROOT)/7zip/UI/Common/TempFiles.cpp \
	$(CPP_ROOT)/7zip/UI/Common/Update.cpp \
	$(CPP_ROOT)/7zip/UI/Common/UpdateAction.cpp \
	$(CPP_ROOT)/7zip/UI/Common/UpdateCallback.cpp \
	$(CPP_ROOT)/7zip/UI/Common/UpdatePair.cpp \
	$(CPP_ROOT)/7zip/UI/Common/UpdateProduce.cpp

# === All sources ===
ALL_CPP_SRCS = $(COMMON_SRCS) $(WIN_SRCS) $(SEVENZIP_COMMON_SRCS) \
	$(ARCHIVE_SRCS) $(ARCHIVE_SUB_SRCS) $(COMPRESS_SRCS) $(CRYPTO_SRCS) \
	$(UI_COMMON_SRCS)
SHICHIZIP_VENDOR_MM_SRCS = vendor/SZEncodingDetector.mm

# Generate object file paths
C_OBJS = $(patsubst $(SEVENZ_ROOT)/%.c,$(O)/%.o,$(C_SRCS))
CPP_OBJS = $(patsubst $(SEVENZ_ROOT)/%.cpp,$(O)/%.o,$(ALL_CPP_SRCS))
MM_OBJS = $(patsubst %.mm,$(O)/%.o,$(SHICHIZIP_VENDOR_MM_SRCS))
ALL_OBJS = $(C_OBJS) $(CPP_OBJS) $(MM_OBJS)

.PHONY: all clean lib info prepare-7zip

all: lib

lib: $(LIB)

prepare-7zip:
	@sh vendor/apply_7zip_patches.sh

$(ALL_OBJS): | prepare-7zip

$(LIB): $(ALL_OBJS)
	@mkdir -p $(LIB_OUT)
	$(AR) rcs $@ $^
	@echo "=== Built $@ ($(words $(ALL_OBJS)) objects) ==="

# C compilation
$(O)/%.o: $(SEVENZ_ROOT)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c -o $@ $<

# C++ compilation
$(O)/%.o: $(SEVENZ_ROOT)/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(O)/%.o: %.mm
	@mkdir -p $(dir $@)
	$(CXX) $(OBJCXXFLAGS) -c -o $@ $<

clean:
	rm -rf build

# Print object count
info:
	@echo "C objects: $(words $(C_OBJS))"
	@echo "C++ objects: $(words $(CPP_OBJS))"
	@echo "Total: $(words $(ALL_OBJS))"
