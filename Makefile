# ShichiZip - lib7zip.a static library build
# Builds the 7-Zip C/C++ core as a static library for embedding in the macOS app

SEVENZ_VARIANT ?= mainline

ifeq ($(SEVENZ_VARIANT),mainline)
SEVENZ_ROOT ?= vendor/7zip
SEVENZ_LIBRARY_NAME ?= lib7zip.a
SEVENZ_OBJECT_SUBDIR ?= mainline
EXTRA_CODEC_INCLUDE_FLAGS =
FASTLZMA2_CFLAGS =
ZSTD_CFLAGS =
ZS_C_SRCS =
ZS_COMMON_SRCS =
ZS_ARCHIVE_SRCS =
ZS_COMPRESS_SRCS =
else ifeq ($(SEVENZ_VARIANT),zs)
SEVENZ_ROOT ?= vendor/7zip-zstd
SEVENZ_LIBRARY_NAME ?= lib7zip-zs.a
SEVENZ_OBJECT_SUBDIR ?= zs
EXTRA_CODEC_INCLUDE_FLAGS = \
	-I$(C_ROOT)/brotli \
	-I$(C_ROOT)/fast-lzma2 \
	-I$(C_ROOT)/hashes \
	-I$(C_ROOT)/lizard \
	-I$(C_ROOT)/lz4 \
	-I$(C_ROOT)/lz5 \
	-I$(C_ROOT)/zstd
FASTLZMA2_CFLAGS = -DNO_XXHASH -DFL2_7ZIP_BUILD
ZSTD_CFLAGS = -DZSTD_LEGACY_SUPPORT -DZSTD_MULTITHREAD
ZS_C_SRCS = \
	$(wildcard $(C_ROOT)/brotli/*.c) \
	$(wildcard $(C_ROOT)/fast-lzma2/*.c) \
	$(wildcard $(C_ROOT)/hashes/*.c) \
	$(wildcard $(C_ROOT)/lizard/*.c) \
	$(wildcard $(C_ROOT)/lz4/*.c) \
	$(wildcard $(C_ROOT)/lz5/*.c) \
	$(wildcard $(C_ROOT)/zstd/*.c) \
	$(wildcard $(C_ROOT)/zstdmt/*.c)
ZS_COMMON_SRCS = \
	$(CPP_ROOT)/Common/Blake3Reg.cpp \
	$(CPP_ROOT)/Common/Md2Reg.cpp \
	$(CPP_ROOT)/Common/Md4Reg.cpp \
	$(CPP_ROOT)/Common/XXH64Reg.cpp \
	$(CPP_ROOT)/Common/XXH32Reg.cpp \
	$(CPP_ROOT)/Common/XXH3-64Reg.cpp \
	$(CPP_ROOT)/Common/XXH3-128Reg.cpp
ZS_ARCHIVE_SRCS = \
	$(CPP_ROOT)/7zip/Archive/BrotliHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/LzHandler.cpp \
	$(CPP_ROOT)/7zip/Archive/Lz4Handler.cpp \
	$(CPP_ROOT)/7zip/Archive/Lz5Handler.cpp \
	$(CPP_ROOT)/7zip/Archive/LizardHandler.cpp
ZS_COMPRESS_SRCS = \
	$(CPP_ROOT)/7zip/Compress/BrotliDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/BrotliEncoder.cpp \
	$(CPP_ROOT)/7zip/Compress/BrotliRegister.cpp \
	$(CPP_ROOT)/7zip/Compress/FastLzma2Register.cpp \
	$(CPP_ROOT)/7zip/Compress/Lz4Decoder.cpp \
	$(CPP_ROOT)/7zip/Compress/Lz4Encoder.cpp \
	$(CPP_ROOT)/7zip/Compress/Lz4Register.cpp \
	$(CPP_ROOT)/7zip/Compress/LizardDecoder.cpp \
	$(CPP_ROOT)/7zip/Compress/LizardEncoder.cpp \
	$(CPP_ROOT)/7zip/Compress/LizardRegister.cpp \
	$(CPP_ROOT)/7zip/Compress/Lz5Decoder.cpp \
	$(CPP_ROOT)/7zip/Compress/Lz5Encoder.cpp \
	$(CPP_ROOT)/7zip/Compress/Lz5Register.cpp \
	$(CPP_ROOT)/7zip/Compress/ZstdEncoder.cpp \
	$(CPP_ROOT)/7zip/Compress/ZstdRegister.cpp
else
$(error Unsupported SEVENZ_VARIANT '$(SEVENZ_VARIANT)')
endif

C_ROOT = $(SEVENZ_ROOT)/C
CPP_ROOT = $(SEVENZ_ROOT)/CPP
ASM_ROOT = $(SEVENZ_ROOT)/Asm

CC = clang
CXX = clang++
AR = ar

MACOSX_DEPLOYMENT_TARGET ?= 13.0
TARGET_ARCH ?= arm64
ARCH = -arch $(TARGET_ARCH)
CFLAGS_COMMON = $(ARCH) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 \
	-D_LARGEFILE_SOURCE -fPIC -Wall -Wextra -MMD -MP
SEVENZ_INCLUDE_FLAGS = -I$(SEVENZ_ROOT)
CFLAGS = $(CFLAGS_COMMON) -std=c11 $(EXTRA_CODEC_INCLUDE_FLAGS)
CXXFLAGS = $(CFLAGS_COMMON) -std=c++23 -DSHICHIZIP_APPLE_DETECTOR $(SEVENZ_INCLUDE_FLAGS) $(EXTRA_CODEC_INCLUDE_FLAGS)
OBJCXXFLAGS = $(CFLAGS_COMMON) -std=c++23 -fobjc-arc -DSHICHIZIP_APPLE_DETECTOR $(SEVENZ_INCLUDE_FLAGS) $(EXTRA_CODEC_INCLUDE_FLAGS)

define require_existing_files
$(if $(strip $(filter-out $(wildcard $(1)),$(1))),$(error Missing required source file(s): $(filter-out $(wildcard $(1)),$(1))),$(1))
endef

O = build/obj/$(SEVENZ_OBJECT_SUBDIR)
LIB_OUT = build/lib
LIB = $(LIB_OUT)/$(SEVENZ_LIBRARY_NAME)

ifeq ($(TARGET_ARCH),arm64)
LZMA_DEC_CFLAGS = -DZ7_LZMA_DEC_OPT
LZMA_DEC_OPT_OBJS = $(O)/Asm/arm64/LzmaDecOpt.o
ARM64_ASM_CFLAGS = -Wno-unused-macros
else
LZMA_DEC_CFLAGS =
LZMA_DEC_OPT_OBJS =
ARM64_ASM_CFLAGS =
endif

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

C_SRCS += $(ZS_C_SRCS)

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

COMMON_SRCS += $(ZS_COMMON_SRCS)

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

ARCHIVE_SRCS += $(ZS_ARCHIVE_SRCS)

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

COMPRESS_SRCS += $(ZS_COMPRESS_SRCS)

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
	$(CPP_ROOT)/7zip/UI/Common/WorkDir.cpp \
	$(CPP_ROOT)/7zip/UI/Common/Update.cpp \
	$(CPP_ROOT)/7zip/UI/Common/UpdateAction.cpp \
	$(CPP_ROOT)/7zip/UI/Common/UpdateCallback.cpp \
	$(CPP_ROOT)/7zip/UI/Common/UpdatePair.cpp \
	$(CPP_ROOT)/7zip/UI/Common/UpdateProduce.cpp
# === UI/Agent (archive-backed folder operations) ===
AGENT_SRCS = \
	$(CPP_ROOT)/7zip/UI/Agent/Agent.cpp \
	$(CPP_ROOT)/7zip/UI/Agent/AgentOut.cpp \
	$(CPP_ROOT)/7zip/UI/Agent/AgentProxy.cpp \
	$(CPP_ROOT)/7zip/UI/Agent/ArchiveFolder.cpp \
	$(CPP_ROOT)/7zip/UI/Agent/ArchiveFolderOut.cpp \
	$(CPP_ROOT)/7zip/UI/Agent/UpdateCallbackAgent.cpp

ifeq ($(SEVENZ_VARIANT),zs)
# The ZS fork replaces the standalone wrapper with the bundled zstd sources and
# omits the upstream XXH64 registration unit.
C_SRCS := $(filter-out $(C_ROOT)/ZstdDec.c,$(C_SRCS))
COMMON_SRCS := $(filter-out $(CPP_ROOT)/Common/Xxh64Reg.cpp,$(COMMON_SRCS))
endif

C_SRCS := $(call require_existing_files,$(C_SRCS))
COMMON_SRCS := $(call require_existing_files,$(COMMON_SRCS))
WIN_SRCS := $(call require_existing_files,$(WIN_SRCS))
SEVENZIP_COMMON_SRCS := $(call require_existing_files,$(SEVENZIP_COMMON_SRCS))
ARCHIVE_SRCS := $(call require_existing_files,$(ARCHIVE_SRCS))
ARCHIVE_SUB_SRCS := $(call require_existing_files,$(ARCHIVE_SUB_SRCS))
COMPRESS_SRCS := $(call require_existing_files,$(COMPRESS_SRCS))
CRYPTO_SRCS := $(call require_existing_files,$(CRYPTO_SRCS))
UI_COMMON_SRCS := $(call require_existing_files,$(UI_COMMON_SRCS))
AGENT_SRCS := $(call require_existing_files,$(AGENT_SRCS))

# === All sources ===
ALL_CPP_SRCS = $(COMMON_SRCS) $(WIN_SRCS) $(SEVENZIP_COMMON_SRCS) \
	$(ARCHIVE_SRCS) $(ARCHIVE_SUB_SRCS) $(COMPRESS_SRCS) $(CRYPTO_SRCS) \
	$(UI_COMMON_SRCS) $(AGENT_SRCS)
SHICHIZIP_VENDOR_MM_SRCS = \
	vendor/SZEncodingDetector.mm \
	vendor/SZAgentCompat.mm

# Generate object file paths
C_OBJS = $(patsubst $(SEVENZ_ROOT)/%.c,$(O)/%.o,$(C_SRCS))
CPP_OBJS = $(patsubst $(SEVENZ_ROOT)/%.cpp,$(O)/%.o,$(ALL_CPP_SRCS))
MM_OBJS = $(patsubst %.mm,$(O)/%.o,$(SHICHIZIP_VENDOR_MM_SRCS))
ALL_OBJS = $(C_OBJS) $(CPP_OBJS) $(MM_OBJS) $(LZMA_DEC_OPT_OBJS)

.PHONY: all clean lib info prepare-7zip lib-mainline lib-zs

all: lib

lib: $(LIB)

lib-mainline:
	@$(MAKE) SEVENZ_VARIANT=mainline lib
	@$(MAKE) -f Makefile.sfx SFX_VARIANT=mainline -j8

lib-zs:
	@$(MAKE) SEVENZ_VARIANT=zs lib
	@$(MAKE) -f Makefile.sfx SFX_VARIANT=zs -j8

prepare-7zip:
	@sh vendor/apply_7zip_patches.sh $(SEVENZ_ROOT)

$(ALL_OBJS): | prepare-7zip

$(LIB): $(ALL_OBJS)
	@mkdir -p $(LIB_OUT)
	$(AR) rcs $@ $^
	@echo "=== Built $@ ($(words $(ALL_OBJS)) objects) ==="

# -MMD -MP in CFLAGS_COMMON emits a sibling *.d next to each *.o so
# re-running make after a header edit (including post-patch vendor
# headers) recompiles only the dependent translation units instead of
# leaving stale objects behind.
-include $(ALL_OBJS:.o=.d)

# Fast LZMA2 needs extra compatibility defines from the fork build.
$(O)/C/fast-lzma2/%.o: $(SEVENZ_ROOT)/C/fast-lzma2/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(FASTLZMA2_CFLAGS) -c -o $@ $<

# Match upstream arm64 builds by enabling the optimized LZMA decoder path.
$(O)/C/LzmaDec.o: $(SEVENZ_ROOT)/C/LzmaDec.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(LZMA_DEC_CFLAGS) -c -o $@ $<

$(O)/Asm/arm64/LzmaDecOpt.o: $(SEVENZ_ROOT)/Asm/arm64/LzmaDecOpt.S $(SEVENZ_ROOT)/Asm/arm64/7zAsm.S
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(ARM64_ASM_CFLAGS) -c -o $@ $<

# Upstream ZS enables legacy decode support and multithreaded ZSTD parameters.
$(O)/C/zstd/%.o: $(SEVENZ_ROOT)/C/zstd/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(ZSTD_CFLAGS) -c -o $@ $<

# Upstream also disables the optional x86 BMI2 ASM path for this TU.
$(O)/C/zstd/huf_decompress.o: $(SEVENZ_ROOT)/C/zstd/huf_decompress.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(ZSTD_CFLAGS) -DZSTD_DISABLE_ASM -c -o $@ $<

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
	rm -rf build/obj build/sfx-obj build/lib build/sfx

# === Cross-compile SFX modules for Windows using zig ===
.PHONY: sfx sfx-mainline sfx-zs sfx-clean

sfx-mainline:
	@$(MAKE) -f Makefile.sfx SFX_VARIANT=mainline -j8

sfx-zs:
	@$(MAKE) -f Makefile.sfx SFX_VARIANT=zs -j8

sfx: sfx-mainline sfx-zs

sfx-clean:
	@$(MAKE) -f Makefile.sfx clean

# Print object count
info:
	@echo "C objects: $(words $(C_OBJS))"
	@echo "C++ objects: $(words $(CPP_OBJS))"
	@echo "Total: $(words $(ALL_OBJS))"
