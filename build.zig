const std = @import("std");
const Io = std.Io;

const Variant = enum {
    mainline,
    zs,
    all,

    fn vendorRoot(self: Variant) []const u8 {
        return switch (self) {
            .mainline => "vendor/7zip",
            .zs => "vendor/7zip-zstd",
            .all => unreachable,
        };
    }

    fn libName(self: Variant) []const u8 {
        return switch (self) {
            .mainline => "lib7zip",
            .zs => "lib7zip-zs",
            .all => unreachable,
        };
    }

    fn stepLabel(self: Variant) []const u8 {
        return @tagName(self);
    }
};

const SfxArch = enum { x86, x86_64, all };

pub fn build(b: *std.Build) void {
    const variant = b.option(Variant, "variant", "Variant to build for lib and sfx steps; use all to fan out both variants") orelse .mainline;
    var target_query = b.standardTargetOptionsQueryOnly(.{});
    if ((target_query.os_tag == null or target_query.os_tag == .macos) and target_query.os_version_min == null) {
        target_query.os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } };
    }
    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});
    const sfx_arch = b.option(SfxArch, "sfx-arch", "Windows SFX architecture selection") orelse .x86;

    const prepare_mainline = prepareVendor(b, .mainline);
    const prepare_zs = prepareVendor(b, .zs);

    const lib_mainline = buildLib(b, .mainline, target, optimize, prepare_mainline);
    const lib_zs = buildLib(b, .zs, target, optimize, prepare_zs);

    const lib_step = b.step("lib", "Build the selected macOS static library");
    switch (variant) {
        .mainline => lib_step.dependOn(&lib_mainline.step),
        .zs => lib_step.dependOn(&lib_zs.step),
        .all => {
            lib_step.dependOn(&lib_mainline.step);
            lib_step.dependOn(&lib_zs.step);
        },
    }
    b.getInstallStep().dependOn(lib_step);

    const sfx_step = b.step("sfx", "Build the selected Windows SFX modules for the selected architecture(s)");
    switch (variant) {
        .mainline => addSfxTargets(b, sfx_step, .mainline, sfx_arch, optimize),
        .zs => addSfxTargets(b, sfx_step, .zs, sfx_arch, optimize),
        .all => {
            addSfxTargets(b, sfx_step, .mainline, sfx_arch, optimize);
            addSfxTargets(b, sfx_step, .zs, sfx_arch, optimize);
        },
    }

    const all_step = b.step("all", "Build lib and sfx for the selected variant(s)");
    all_step.dependOn(lib_step);
    all_step.dependOn(sfx_step);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn concatFlags(b: *std.Build, base: []const []const u8, extra: []const []const u8) []const []const u8 {
    var flags = std.ArrayList([]const u8).empty;
    flags.appendSlice(b.allocator, base) catch @panic("OOM");
    flags.appendSlice(b.allocator, extra) catch @panic("OOM");
    return flags.items;
}

fn prepareVendor(b: *std.Build, variant: Variant) *std.Build.Step {
    const sevenz_root = variant.vendorRoot();
    const patch_cmd = b.addSystemCommand(&.{ "sh", "vendor/apply_7zip_patches.sh", sevenz_root });
    return &patch_cmd.step;
}

fn addSfxTargets(
    b: *std.Build,
    step: *std.Build.Step,
    comptime variant: Variant,
    sfx_arch: SfxArch,
    optimize: std.builtin.OptimizeMode,
) void {
    switch (sfx_arch) {
        .x86 => step.dependOn(&buildSfx(b, variant, .x86, optimize).step),
        .x86_64 => step.dependOn(&buildSfx(b, variant, .x86_64, optimize).step),
        .all => {
            step.dependOn(&buildSfx(b, variant, .x86, optimize).step);
            step.dependOn(&buildSfx(b, variant, .x86_64, optimize).step);
        },
    }
}

/// Walk a directory at build-script time and collect all `.c` files.
/// Returns paths relative to root (e.g. "C/zstd/decompress.c").
fn collectCFilesRelative(b: *std.Build, root_path: []const u8, sub_dir: []const u8) []const []const u8 {
    const io = b.graph.io;
    const full_path = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ root_path, sub_dir }) catch @panic("OOM");
    const cwd = Io.Dir.cwd();
    const dir = cwd.openDir(io, full_path, .{ .iterate = true }) catch return &.{};
    var walker = dir.walk(b.allocator) catch return &.{};
    defer walker.deinit();

    var files = std.ArrayList([]const u8).empty;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".c")) {
            const rel = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ sub_dir, entry.path }) catch @panic("OOM");
            files.append(b.allocator, rel) catch @panic("OOM");
        }
    }
    return files.items;
}

fn archString(a: std.Target.Cpu.Arch) []const u8 {
    return switch (a) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        .x86 => "x86",
        else => "unknown",
    };
}

const DarwinArchiveRepackStep = struct {
    step: std.Build.Step,
    input_archive: std.Build.LazyPath,
    output_file: std.Build.GeneratedFile,
    output_key: []const u8,
    output_basename: []const u8,

    fn create(
        b: *std.Build,
        input_archive: std.Build.LazyPath,
        output_key: []const u8,
        output_basename: []const u8,
    ) *DarwinArchiveRepackStep {
        const repack = b.allocator.create(DarwinArchiveRepackStep) catch @panic("OOM");
        repack.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("darwin archive repack {s}", .{output_basename}),
                .owner = b,
                .makeFn = make,
            }),
            .input_archive = input_archive.dupe(b),
            .output_file = .{ .step = &repack.step },
            .output_key = b.allocator.dupe(u8, output_key) catch @panic("OOM"),
            .output_basename = b.allocator.dupe(u8, output_basename) catch @panic("OOM"),
        };
        input_archive.addStepDependencies(&repack.step);
        return repack;
    }

    fn getOutput(repack: *const DarwinArchiveRepackStep) std.Build.LazyPath {
        return .{ .generated = .{ .file = &repack.output_file } };
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;

        const repack: *DarwinArchiveRepackStep = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;

        const archive_path = repack.input_archive.getPath2(b, step);
        const archive_full_path = if (std.fs.path.isAbsolute(archive_path))
            archive_path
        else
            b.pathResolve(&.{ b.graph.cache.cwd, archive_path });
        const base_dir = b.cache_root.join(b.allocator, &.{ "tmp", "darwin-archive-repack", repack.output_key }) catch @panic("OOM");
        const base_dir_full = if (std.fs.path.isAbsolute(base_dir))
            base_dir
        else
            b.pathResolve(&.{ b.graph.cache.cwd, base_dir });
        const work_dir_path = b.pathJoin(&.{ base_dir_full, "work" });
        const output_path = b.pathJoin(&.{ base_dir_full, repack.output_basename });

        try Io.Dir.deleteTree(Io.Dir.cwd(), io, base_dir_full);
        try Io.Dir.createDirPath(Io.Dir.cwd(), io, work_dir_path);

        const zig_exe = b.graph.zig_exe;

        // Extract objects from the SysV archive produced by the Zig compiler.
        try repack.runCommand(step, io, work_dir_path, &.{ zig_exe, "ar", "x", archive_full_path });

        // Repack into a Darwin-format archive with proper 8-byte member alignment.
        var work_dir = try Io.Dir.openDirAbsolute(io, work_dir_path, .{ .iterate = true });
        defer work_dir.close(io);

        var argv = std.ArrayList([]const u8).empty;
        argv.appendSlice(b.allocator, &.{ zig_exe, "ar", "--format=darwin", "rcs", output_path }) catch @panic("OOM");

        var has_objects = false;
        var iter = work_dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".o")) continue;
            // Zig's deterministic archiver stores mode 0 in headers;
            // restore a usable mode so zig ar can read objects back.
            try work_dir.setFilePermissions(io, entry.name, Io.File.Permissions.fromMode(0o644), .{});
            has_objects = true;
            argv.append(b.allocator, b.allocator.dupe(u8, entry.name) catch @panic("OOM")) catch @panic("OOM");
        }

        if (!has_objects) {
            return fail(step, "archive extraction produced no object files");
        }

        try repack.runCommand(step, io, work_dir_path, argv.items);

        repack.output_file.path = output_path;
    }

    fn runCommand(
        repack: *const DarwinArchiveRepackStep,
        step: *std.Build.Step,
        io: Io,
        cwd: []const u8,
        argv: []const []const u8,
    ) !void {
        _ = repack;

        const b = step.owner;
        const result = std.process.run(b.allocator, io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
        }) catch |err| {
            return fail(step, b.fmt("failed to start {s}: {s}", .{ argv[0], @errorName(err) }));
        };
        defer b.allocator.free(result.stdout);
        defer b.allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }

        const command_line = std.mem.join(b.allocator, " ", argv) catch @panic("OOM");
        step.result_error_msgs.append(b.allocator, b.fmt("command failed in {s}: {s}", .{ cwd, command_line })) catch @panic("OOM");

        const stderr_output = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr_output.len > 0) {
            step.result_error_msgs.append(b.allocator, b.fmt("{s}", .{stderr_output})) catch @panic("OOM");
        } else {
            const stdout_output = std.mem.trim(u8, result.stdout, " \t\r\n");
            if (stdout_output.len > 0) {
                step.result_error_msgs.append(b.allocator, b.fmt("{s}", .{stdout_output})) catch @panic("OOM");
            }
        }
        return error.MakeFailed;
    }

    fn fail(step: *std.Build.Step, message: []const u8) error{MakeFailed} {
        step.result_error_msgs.append(step.owner.allocator, step.owner.fmt("{s}", .{message})) catch @panic("OOM");
        return error.MakeFailed;
    }
};

// ---------------------------------------------------------------------------
// macOS static library
// ---------------------------------------------------------------------------

fn buildLib(
    b: *std.Build,
    variant: Variant,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    prepare_step: *std.Build.Step,
) *std.Build.Step.InstallFile {
    const sevenz_root = variant.vendorRoot();
    const lib_name = variant.libName();
    const arch_str = archString(target.result.cpu.arch);

    const root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    const lib = b.addLibrary(.{
        .name = lib_name,
        .root_module = root_module,
        .linkage = .static,
    });

    lib.step.dependOn(prepare_step);

    // --- Flags ---
    const sevenz_include = std.fmt.allocPrint(b.allocator, "-I{s}", .{sevenz_root}) catch @panic("OOM");

    const c_flags_base: []const []const u8 = &.{
        "-DNDEBUG",               "-D_REENTRANT",
        "-D_FILE_OFFSET_BITS=64", "-D_LARGEFILE_SOURCE",
        "-fPIC",                  "-Wall",
        "-Wextra",
    };
    const c_flags = concatFlags(b, c_flags_base, &.{"-std=c11"});

    const cpp_flags = concatFlags(b, c_flags_base, &.{
        "-std=c++23", "-DSHICHIZIP_APPLE_DETECTOR", sevenz_include,
    });

    const objcxx_flags = concatFlags(b, c_flags_base, &.{
        "-std=c++23", "-fobjc-arc", "-DSHICHIZIP_APPLE_DETECTOR", sevenz_include,
    });

    // ZS extra include flags
    const zs_extra_includes: []const []const u8 = if (variant == .zs) blk: {
        const alloc = b.allocator;
        break :blk &[_][]const u8{
            std.fmt.allocPrint(alloc, "-I{s}/C/brotli", .{sevenz_root}) catch @panic("OOM"),
            std.fmt.allocPrint(alloc, "-I{s}/C/fast-lzma2", .{sevenz_root}) catch @panic("OOM"),
            std.fmt.allocPrint(alloc, "-I{s}/C/hashes", .{sevenz_root}) catch @panic("OOM"),
            std.fmt.allocPrint(alloc, "-I{s}/C/lizard", .{sevenz_root}) catch @panic("OOM"),
            std.fmt.allocPrint(alloc, "-I{s}/C/lz4", .{sevenz_root}) catch @panic("OOM"),
            std.fmt.allocPrint(alloc, "-I{s}/C/lz5", .{sevenz_root}) catch @panic("OOM"),
            std.fmt.allocPrint(alloc, "-I{s}/C/zstd", .{sevenz_root}) catch @panic("OOM"),
        };
    } else &.{};

    const c_flags_zs = concatFlags(b, c_flags, zs_extra_includes);
    const cpp_flags_zs = concatFlags(b, cpp_flags, zs_extra_includes);
    const cur_c_flags = if (variant == .zs) c_flags_zs else c_flags;
    const cur_cpp_flags = if (variant == .zs) cpp_flags_zs else cpp_flags;

    // =====================================================================
    // C sources
    // =====================================================================

    const c_srcs_common: []const []const u8 = &.{
        "C/7zBuf2.c",     "C/7zCrc.c",     "C/7zCrcOpt.c",
        "C/7zStream.c",   "C/Aes.c",       "C/AesOpt.c",
        "C/Alloc.c",      "C/Bcj2.c",      "C/Bcj2Enc.c",
        "C/Blake2s.c",    "C/Bra.c",       "C/Bra86.c",
        "C/BraIA64.c",    "C/BwtSort.c",   "C/CpuArch.c",
        "C/Delta.c",      "C/HuffEnc.c",   "C/LzFind.c",
        "C/LzFindMt.c",   "C/LzFindOpt.c", "C/Lzma2Dec.c",
        "C/Lzma2DecMt.c", "C/Lzma2Enc.c",
        // LzmaDec.c added separately (arm64 gets -DZ7_LZMA_DEC_OPT)
         "C/LzmaEnc.c",
        "C/Md5.c",        "C/MtCoder.c",   "C/MtDec.c",
        "C/Ppmd7.c",      "C/Ppmd7Dec.c",  "C/Ppmd7aDec.c",
        "C/Ppmd7Enc.c",   "C/Ppmd8.c",     "C/Ppmd8Dec.c",
        "C/Ppmd8Enc.c",   "C/Sha1.c",      "C/Sha1Opt.c",
        "C/Sha256.c",     "C/Sha256Opt.c", "C/Sha3.c",
        "C/Sha512.c",     "C/Sha512Opt.c", "C/Sort.c",
        "C/SwapBytes.c",  "C/Threads.c",   "C/Xxh64.c",
        "C/Xz.c",         "C/XzDec.c",     "C/XzEnc.c",
        "C/XzIn.c",       "C/XzCrc64.c",   "C/XzCrc64Opt.c",
    };

    root_module.addCSourceFiles(.{
        .root = b.path(sevenz_root),
        .files = c_srcs_common,
        .flags = cur_c_flags,
        .language = .c,
    });

    // C/ZstdDec.c — mainline only
    if (variant == .mainline) {
        root_module.addCSourceFiles(.{
            .root = b.path(sevenz_root),
            .files = &.{"C/ZstdDec.c"},
            .flags = c_flags,
            .language = .c,
        });
    }

    // C/LzmaDec.c — arm64 gets extra -DZ7_LZMA_DEC_OPT
    {
        const lzma_flags = if (target.result.cpu.arch == .aarch64)
            concatFlags(b, cur_c_flags, &.{"-DZ7_LZMA_DEC_OPT"})
        else
            cur_c_flags;
        root_module.addCSourceFiles(.{
            .root = b.path(sevenz_root),
            .files = &.{"C/LzmaDec.c"},
            .flags = lzma_flags,
            .language = .c,
        });
    }

    // ARM64 optimized LZMA decoder assembly
    if (target.result.cpu.arch == .aarch64) {
        root_module.addCSourceFiles(.{
            .root = b.path(sevenz_root),
            .files = &.{"Asm/arm64/LzmaDecOpt.S"},
            .flags = concatFlags(b, c_flags, &.{"-Wno-unused-macros"}),
            .language = .assembly_with_preprocessor,
        });
    }

    // ZS variant: wildcard C source directories
    if (variant == .zs) {
        const zs_common_dirs = [_][]const u8{ "C/brotli", "C/lizard", "C/lz4", "C/lz5", "C/zstdmt" };
        for (zs_common_dirs) |sub| {
            const files = collectCFilesRelative(b, sevenz_root, sub);
            if (files.len > 0) {
                root_module.addCSourceFiles(.{
                    .root = b.path(sevenz_root),
                    .files = files,
                    .flags = c_flags_zs,
                    .language = .c,
                });
            }
        }

        {
            const hash_files = collectCFilesRelative(b, sevenz_root, "C/hashes");
            var common_hash_files = std.ArrayList([]const u8).empty;
            for (hash_files) |file| {
                if (std.mem.eql(u8, file, "C/hashes/xxh_x86dispatch.c")) continue;
                common_hash_files.append(b.allocator, file) catch @panic("OOM");
            }
            if (common_hash_files.items.len > 0) {
                root_module.addCSourceFiles(.{
                    .root = b.path(sevenz_root),
                    .files = common_hash_files.items,
                    .flags = c_flags_zs,
                    .language = .c,
                });
            }

            // Zig's bundled Clang 21 keeps `evex512` disabled on its generic x86
            // baseline, but xxHash's AVX512 dispatcher only needs that register-state
            // feature on the one translation unit that already runtime-gates AVX512.
            // LLVM 22 removed the separate gate, so keep the compatibility shim local.
            const x86_dispatch_flags = if (target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .x86)
                concatFlags(b, c_flags_zs, &.{ "-Xclang", "-target-feature", "-Xclang", "+evex512" })
            else
                c_flags_zs;
            root_module.addCSourceFiles(.{
                .root = b.path(sevenz_root),
                .files = &.{"C/hashes/xxh_x86dispatch.c"},
                .flags = x86_dispatch_flags,
                .language = .c,
            });
        }

        // fast-lzma2: extra -DNO_XXHASH -DFL2_7ZIP_BUILD
        {
            const fl2_files = collectCFilesRelative(b, sevenz_root, "C/fast-lzma2");
            if (fl2_files.len > 0) {
                root_module.addCSourceFiles(.{
                    .root = b.path(sevenz_root),
                    .files = fl2_files,
                    .flags = concatFlags(b, c_flags_zs, &.{ "-DNO_XXHASH", "-DFL2_7ZIP_BUILD" }),
                    .language = .c,
                });
            }
        }

        // zstd: extra -DZSTD_LEGACY_SUPPORT -DZSTD_MULTITHREAD; huf_decompress.c also -DZSTD_DISABLE_ASM
        {
            const zstd_files = collectCFilesRelative(b, sevenz_root, "C/zstd");
            for (zstd_files) |f| {
                const extra: []const []const u8 = if (std.mem.endsWith(u8, f, "huf_decompress.c"))
                    &.{ "-DZSTD_LEGACY_SUPPORT", "-DZSTD_MULTITHREAD", "-DZSTD_DISABLE_ASM" }
                else
                    &.{ "-DZSTD_LEGACY_SUPPORT", "-DZSTD_MULTITHREAD" };
                root_module.addCSourceFile(.{
                    .file = b.path(std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ sevenz_root, f }) catch @panic("OOM")),
                    .flags = concatFlags(b, c_flags_zs, extra),
                    .language = .c,
                });
            }
        }
    }

    // =====================================================================
    // C++ sources
    // =====================================================================

    const common_srcs: []const []const u8 = &.{
        "CPP/Common/CRC.cpp",               "CPP/Common/CrcReg.cpp",
        "CPP/Common/CommandLineParser.cpp", "CPP/Common/DynLimBuf.cpp",
        "CPP/Common/IntToString.cpp",       "CPP/Common/ListFileUtils.cpp",
        "CPP/Common/LzFindPrepare.cpp",     "CPP/Common/Md5Reg.cpp",
        "CPP/Common/MyMap.cpp",             "CPP/Common/MyString.cpp",
        "CPP/Common/MyVector.cpp",          "CPP/Common/MyWindows.cpp",
        "CPP/Common/MyXml.cpp",             "CPP/Common/NewHandler.cpp",
        "CPP/Common/Sha1Prepare.cpp",       "CPP/Common/Sha1Reg.cpp",
        "CPP/Common/Sha256Prepare.cpp",     "CPP/Common/Sha256Reg.cpp",
        "CPP/Common/Sha3Reg.cpp",           "CPP/Common/Sha512Prepare.cpp",
        "CPP/Common/Sha512Reg.cpp",         "CPP/Common/StdInStream.cpp",
        "CPP/Common/StdOutStream.cpp",      "CPP/Common/StringConvert.cpp",
        "CPP/Common/StringToInt.cpp",       "CPP/Common/UTFConvert.cpp",
        "CPP/Common/Wildcard.cpp",          "CPP/Common/XzCrc64Init.cpp",
        "CPP/Common/XzCrc64Reg.cpp",
    };

    const win_srcs: []const []const u8 = &.{
        "CPP/Windows/ErrorMsg.cpp",         "CPP/Windows/FileDir.cpp",
        "CPP/Windows/FileFind.cpp",         "CPP/Windows/FileIO.cpp",
        "CPP/Windows/FileLink.cpp",         "CPP/Windows/FileName.cpp",
        "CPP/Windows/PropVariant.cpp",      "CPP/Windows/PropVariantConv.cpp",
        "CPP/Windows/PropVariantUtils.cpp", "CPP/Windows/Synchronization.cpp",
        "CPP/Windows/System.cpp",           "CPP/Windows/SystemInfo.cpp",
        "CPP/Windows/TimeUtils.cpp",
    };

    const sevenzip_common_srcs: []const []const u8 = &.{
        "CPP/7zip/Common/CreateCoder.cpp",        "CPP/7zip/Common/CWrappers.cpp",
        "CPP/7zip/Common/FilePathAutoRename.cpp", "CPP/7zip/Common/FileStreams.cpp",
        "CPP/7zip/Common/FilterCoder.cpp",        "CPP/7zip/Common/InBuffer.cpp",
        "CPP/7zip/Common/InOutTempBuffer.cpp",    "CPP/7zip/Common/LimitedStreams.cpp",
        "CPP/7zip/Common/LockedStream.cpp",       "CPP/7zip/Common/MemBlocks.cpp",
        "CPP/7zip/Common/MethodId.cpp",           "CPP/7zip/Common/MethodProps.cpp",
        "CPP/7zip/Common/MultiOutStream.cpp",     "CPP/7zip/Common/OffsetStream.cpp",
        "CPP/7zip/Common/OutBuffer.cpp",          "CPP/7zip/Common/OutMemStream.cpp",
        "CPP/7zip/Common/ProgressMt.cpp",         "CPP/7zip/Common/ProgressUtils.cpp",
        "CPP/7zip/Common/PropId.cpp",             "CPP/7zip/Common/StreamBinder.cpp",
        "CPP/7zip/Common/StreamObjects.cpp",      "CPP/7zip/Common/StreamUtils.cpp",
        "CPP/7zip/Common/UniqBlocks.cpp",         "CPP/7zip/Common/VirtThread.cpp",
    };

    const archive_srcs: []const []const u8 = &.{
        "CPP/7zip/Archive/ApfsHandler.cpp",     "CPP/7zip/Archive/ApmHandler.cpp",
        "CPP/7zip/Archive/ArHandler.cpp",       "CPP/7zip/Archive/ArjHandler.cpp",
        "CPP/7zip/Archive/Base64Handler.cpp",   "CPP/7zip/Archive/Bz2Handler.cpp",
        "CPP/7zip/Archive/ComHandler.cpp",      "CPP/7zip/Archive/CpioHandler.cpp",
        "CPP/7zip/Archive/CramfsHandler.cpp",   "CPP/7zip/Archive/DeflateProps.cpp",
        "CPP/7zip/Archive/DmgHandler.cpp",      "CPP/7zip/Archive/ElfHandler.cpp",
        "CPP/7zip/Archive/ExtHandler.cpp",      "CPP/7zip/Archive/FatHandler.cpp",
        "CPP/7zip/Archive/FlvHandler.cpp",      "CPP/7zip/Archive/GzHandler.cpp",
        "CPP/7zip/Archive/GptHandler.cpp",      "CPP/7zip/Archive/HandlerCont.cpp",
        "CPP/7zip/Archive/HfsHandler.cpp",      "CPP/7zip/Archive/IhexHandler.cpp",
        "CPP/7zip/Archive/LpHandler.cpp",       "CPP/7zip/Archive/LzhHandler.cpp",
        "CPP/7zip/Archive/LzmaHandler.cpp",     "CPP/7zip/Archive/MachoHandler.cpp",
        "CPP/7zip/Archive/MbrHandler.cpp",      "CPP/7zip/Archive/MslzHandler.cpp",
        "CPP/7zip/Archive/MubHandler.cpp",      "CPP/7zip/Archive/NtfsHandler.cpp",
        "CPP/7zip/Archive/PeHandler.cpp",       "CPP/7zip/Archive/PpmdHandler.cpp",
        "CPP/7zip/Archive/QcowHandler.cpp",     "CPP/7zip/Archive/RpmHandler.cpp",
        "CPP/7zip/Archive/SparseHandler.cpp",   "CPP/7zip/Archive/SplitHandler.cpp",
        "CPP/7zip/Archive/SquashfsHandler.cpp", "CPP/7zip/Archive/SwfHandler.cpp",
        "CPP/7zip/Archive/UefiHandler.cpp",     "CPP/7zip/Archive/VdiHandler.cpp",
        "CPP/7zip/Archive/VhdHandler.cpp",      "CPP/7zip/Archive/VhdxHandler.cpp",
        "CPP/7zip/Archive/VmdkHandler.cpp",     "CPP/7zip/Archive/XarHandler.cpp",
        "CPP/7zip/Archive/XzHandler.cpp",       "CPP/7zip/Archive/ZHandler.cpp",
        "CPP/7zip/Archive/ZstdHandler.cpp",
    };

    const archive_sub_srcs: []const []const u8 = &.{
        "CPP/7zip/Archive/7z/7zCompressionMode.cpp",    "CPP/7zip/Archive/7z/7zDecode.cpp",
        "CPP/7zip/Archive/7z/7zEncode.cpp",             "CPP/7zip/Archive/7z/7zExtract.cpp",
        "CPP/7zip/Archive/7z/7zFolderInStream.cpp",     "CPP/7zip/Archive/7z/7zHandler.cpp",
        "CPP/7zip/Archive/7z/7zHandlerOut.cpp",         "CPP/7zip/Archive/7z/7zHeader.cpp",
        "CPP/7zip/Archive/7z/7zIn.cpp",                 "CPP/7zip/Archive/7z/7zOut.cpp",
        "CPP/7zip/Archive/7z/7zProperties.cpp",         "CPP/7zip/Archive/7z/7zSpecStream.cpp",
        "CPP/7zip/Archive/7z/7zUpdate.cpp",             "CPP/7zip/Archive/7z/7zRegister.cpp",
        "CPP/7zip/Archive/Cab/CabBlockInStream.cpp",    "CPP/7zip/Archive/Cab/CabHandler.cpp",
        "CPP/7zip/Archive/Cab/CabHeader.cpp",           "CPP/7zip/Archive/Cab/CabIn.cpp",
        "CPP/7zip/Archive/Cab/CabRegister.cpp",         "CPP/7zip/Archive/Chm/ChmHandler.cpp",
        "CPP/7zip/Archive/Chm/ChmIn.cpp",               "CPP/7zip/Archive/Iso/IsoHandler.cpp",
        "CPP/7zip/Archive/Iso/IsoHeader.cpp",           "CPP/7zip/Archive/Iso/IsoIn.cpp",
        "CPP/7zip/Archive/Iso/IsoRegister.cpp",         "CPP/7zip/Archive/Nsis/NsisDecode.cpp",
        "CPP/7zip/Archive/Nsis/NsisHandler.cpp",        "CPP/7zip/Archive/Nsis/NsisIn.cpp",
        "CPP/7zip/Archive/Nsis/NsisRegister.cpp",       "CPP/7zip/Archive/Rar/RarHandler.cpp",
        "CPP/7zip/Archive/Rar/Rar5Handler.cpp",         "CPP/7zip/Archive/Tar/TarHandler.cpp",
        "CPP/7zip/Archive/Tar/TarHandlerOut.cpp",       "CPP/7zip/Archive/Tar/TarHeader.cpp",
        "CPP/7zip/Archive/Tar/TarIn.cpp",               "CPP/7zip/Archive/Tar/TarOut.cpp",
        "CPP/7zip/Archive/Tar/TarUpdate.cpp",           "CPP/7zip/Archive/Tar/TarRegister.cpp",
        "CPP/7zip/Archive/Udf/UdfHandler.cpp",          "CPP/7zip/Archive/Udf/UdfIn.cpp",
        "CPP/7zip/Archive/Wim/WimHandler.cpp",          "CPP/7zip/Archive/Wim/WimHandlerOut.cpp",
        "CPP/7zip/Archive/Wim/WimIn.cpp",               "CPP/7zip/Archive/Wim/WimRegister.cpp",
        "CPP/7zip/Archive/Zip/ZipAddCommon.cpp",        "CPP/7zip/Archive/Zip/ZipHandler.cpp",
        "CPP/7zip/Archive/Zip/ZipHandlerOut.cpp",       "CPP/7zip/Archive/Zip/ZipIn.cpp",
        "CPP/7zip/Archive/Zip/ZipItem.cpp",             "CPP/7zip/Archive/Zip/ZipOut.cpp",
        "CPP/7zip/Archive/Zip/ZipUpdate.cpp",           "CPP/7zip/Archive/Zip/ZipRegister.cpp",
        "CPP/7zip/Archive/Common/CoderMixer2.cpp",      "CPP/7zip/Archive/Common/DummyOutStream.cpp",
        "CPP/7zip/Archive/Common/FindSignature.cpp",    "CPP/7zip/Archive/Common/InStreamWithCRC.cpp",
        "CPP/7zip/Archive/Common/ItemNameUtils.cpp",    "CPP/7zip/Archive/Common/MultiStream.cpp",
        "CPP/7zip/Archive/Common/OutStreamWithCRC.cpp", "CPP/7zip/Archive/Common/OutStreamWithSha1.cpp",
        "CPP/7zip/Archive/Common/HandlerOut.cpp",       "CPP/7zip/Archive/Common/ParseProperties.cpp",
    };

    const compress_srcs: []const []const u8 = &.{
        "CPP/7zip/Compress/Bcj2Coder.cpp",         "CPP/7zip/Compress/Bcj2Register.cpp",
        "CPP/7zip/Compress/BcjCoder.cpp",          "CPP/7zip/Compress/BcjRegister.cpp",
        "CPP/7zip/Compress/BitlDecoder.cpp",       "CPP/7zip/Compress/BranchMisc.cpp",
        "CPP/7zip/Compress/BranchRegister.cpp",    "CPP/7zip/Compress/ByteSwap.cpp",
        "CPP/7zip/Compress/BZip2Crc.cpp",          "CPP/7zip/Compress/BZip2Decoder.cpp",
        "CPP/7zip/Compress/BZip2Encoder.cpp",      "CPP/7zip/Compress/BZip2Register.cpp",
        "CPP/7zip/Compress/CopyCoder.cpp",         "CPP/7zip/Compress/CopyRegister.cpp",
        "CPP/7zip/Compress/Deflate64Register.cpp", "CPP/7zip/Compress/DeflateDecoder.cpp",
        "CPP/7zip/Compress/DeflateEncoder.cpp",    "CPP/7zip/Compress/DeflateRegister.cpp",
        "CPP/7zip/Compress/DeltaFilter.cpp",       "CPP/7zip/Compress/ImplodeDecoder.cpp",
        "CPP/7zip/Compress/LzfseDecoder.cpp",      "CPP/7zip/Compress/LzhDecoder.cpp",
        "CPP/7zip/Compress/Lzma2Decoder.cpp",      "CPP/7zip/Compress/Lzma2Encoder.cpp",
        "CPP/7zip/Compress/Lzma2Register.cpp",     "CPP/7zip/Compress/LzmaDecoder.cpp",
        "CPP/7zip/Compress/LzmaEncoder.cpp",       "CPP/7zip/Compress/LzmaRegister.cpp",
        "CPP/7zip/Compress/LzmsDecoder.cpp",       "CPP/7zip/Compress/LzOutWindow.cpp",
        "CPP/7zip/Compress/LzxDecoder.cpp",        "CPP/7zip/Compress/PpmdDecoder.cpp",
        "CPP/7zip/Compress/PpmdEncoder.cpp",       "CPP/7zip/Compress/PpmdRegister.cpp",
        "CPP/7zip/Compress/PpmdZip.cpp",           "CPP/7zip/Compress/QuantumDecoder.cpp",
        "CPP/7zip/Compress/ShrinkDecoder.cpp",     "CPP/7zip/Compress/XpressDecoder.cpp",
        "CPP/7zip/Compress/XzDecoder.cpp",         "CPP/7zip/Compress/XzEncoder.cpp",
        "CPP/7zip/Compress/ZlibDecoder.cpp",       "CPP/7zip/Compress/ZlibEncoder.cpp",
        "CPP/7zip/Compress/ZDecoder.cpp",          "CPP/7zip/Compress/ZstdDecoder.cpp",
        "CPP/7zip/Compress/Rar1Decoder.cpp",       "CPP/7zip/Compress/Rar2Decoder.cpp",
        "CPP/7zip/Compress/Rar3Decoder.cpp",       "CPP/7zip/Compress/Rar3Vm.cpp",
        "CPP/7zip/Compress/Rar5Decoder.cpp",       "CPP/7zip/Compress/RarCodecsRegister.cpp",
    };

    const crypto_srcs: []const []const u8 = &.{
        "CPP/7zip/Crypto/7zAes.cpp",          "CPP/7zip/Crypto/7zAesRegister.cpp",
        "CPP/7zip/Crypto/HmacSha1.cpp",       "CPP/7zip/Crypto/HmacSha256.cpp",
        "CPP/7zip/Crypto/MyAes.cpp",          "CPP/7zip/Crypto/MyAesReg.cpp",
        "CPP/7zip/Crypto/Pbkdf2HmacSha1.cpp", "CPP/7zip/Crypto/RandGen.cpp",
        "CPP/7zip/Crypto/Rar20Crypto.cpp",    "CPP/7zip/Crypto/Rar5Aes.cpp",
        "CPP/7zip/Crypto/RarAes.cpp",         "CPP/7zip/Crypto/WzAes.cpp",
        "CPP/7zip/Crypto/ZipCrypto.cpp",      "CPP/7zip/Crypto/ZipStrong.cpp",
    };

    const ui_common_srcs: []const []const u8 = &.{
        "CPP/7zip/UI/Common/ArchiveCommandLine.cpp",
        "CPP/7zip/UI/Common/ArchiveExtractCallback.cpp",
        "CPP/7zip/UI/Common/ArchiveOpenCallback.cpp",
        "CPP/7zip/UI/Common/Bench.cpp",
        "CPP/7zip/UI/Common/DefaultName.cpp",
        "CPP/7zip/UI/Common/EnumDirItems.cpp",
        "CPP/7zip/UI/Common/Extract.cpp",
        "CPP/7zip/UI/Common/ExtractingFilePath.cpp",
        "CPP/7zip/UI/Common/HashCalc.cpp",
        "CPP/7zip/UI/Common/LoadCodecs.cpp",
        "CPP/7zip/UI/Common/OpenArchive.cpp",
        "CPP/7zip/UI/Common/PropIDUtils.cpp",
        "CPP/7zip/UI/Common/SetProperties.cpp",
        "CPP/7zip/UI/Common/SortUtils.cpp",
        "CPP/7zip/UI/Common/TempFiles.cpp",
        "CPP/7zip/UI/Common/WorkDir.cpp",
        "CPP/7zip/UI/Common/Update.cpp",
        "CPP/7zip/UI/Common/UpdateAction.cpp",
        "CPP/7zip/UI/Common/UpdateCallback.cpp",
        "CPP/7zip/UI/Common/UpdatePair.cpp",
        "CPP/7zip/UI/Common/UpdateProduce.cpp",
    };

    const agent_srcs: []const []const u8 = &.{
        "CPP/7zip/UI/Agent/Agent.cpp",            "CPP/7zip/UI/Agent/AgentOut.cpp",
        "CPP/7zip/UI/Agent/AgentProxy.cpp",       "CPP/7zip/UI/Agent/ArchiveFolder.cpp",
        "CPP/7zip/UI/Agent/ArchiveFolderOut.cpp", "CPP/7zip/UI/Agent/UpdateCallbackAgent.cpp",
    };

    // Add all shared C++ groups
    const all_cpp_groups = [_][]const []const u8{
        common_srcs,  win_srcs,         sevenzip_common_srcs,
        archive_srcs, archive_sub_srcs, compress_srcs,
        crypto_srcs,  ui_common_srcs,   agent_srcs,
    };
    for (all_cpp_groups) |group| {
        root_module.addCSourceFiles(.{
            .root = b.path(sevenz_root),
            .files = group,
            .flags = cur_cpp_flags,
            .language = .cpp,
        });
    }

    // Variant-specific C++ sources
    if (variant == .mainline) {
        root_module.addCSourceFiles(.{
            .root = b.path(sevenz_root),
            .files = &.{"CPP/Common/Xxh64Reg.cpp"},
            .flags = cpp_flags,
            .language = .cpp,
        });
    } else {
        root_module.addCSourceFiles(.{
            .root = b.path(sevenz_root),
            .files = &.{
                "CPP/Common/Blake3Reg.cpp",   "CPP/Common/Md2Reg.cpp",
                "CPP/Common/Md4Reg.cpp",      "CPP/Common/XXH64Reg.cpp",
                "CPP/Common/XXH32Reg.cpp",    "CPP/Common/XXH3-64Reg.cpp",
                "CPP/Common/XXH3-128Reg.cpp",
            },
            .flags = cpp_flags_zs,
            .language = .cpp,
        });
        root_module.addCSourceFiles(.{
            .root = b.path(sevenz_root),
            .files = &.{
                "CPP/7zip/Archive/BrotliHandler.cpp", "CPP/7zip/Archive/LzHandler.cpp",
                "CPP/7zip/Archive/Lz4Handler.cpp",    "CPP/7zip/Archive/Lz5Handler.cpp",
                "CPP/7zip/Archive/LizardHandler.cpp",
            },
            .flags = cpp_flags_zs,
            .language = .cpp,
        });
        root_module.addCSourceFiles(.{
            .root = b.path(sevenz_root),
            .files = &.{
                "CPP/7zip/Compress/BrotliDecoder.cpp",  "CPP/7zip/Compress/BrotliEncoder.cpp",
                "CPP/7zip/Compress/BrotliRegister.cpp", "CPP/7zip/Compress/FastLzma2Register.cpp",
                "CPP/7zip/Compress/Lz4Decoder.cpp",     "CPP/7zip/Compress/Lz4Encoder.cpp",
                "CPP/7zip/Compress/Lz4Register.cpp",    "CPP/7zip/Compress/LizardDecoder.cpp",
                "CPP/7zip/Compress/LizardEncoder.cpp",  "CPP/7zip/Compress/LizardRegister.cpp",
                "CPP/7zip/Compress/Lz5Decoder.cpp",     "CPP/7zip/Compress/Lz5Encoder.cpp",
                "CPP/7zip/Compress/Lz5Register.cpp",    "CPP/7zip/Compress/ZstdEncoder.cpp",
                "CPP/7zip/Compress/ZstdRegister.cpp",
            },
            .flags = cpp_flags_zs,
            .language = .cpp,
        });
    }

    // =====================================================================
    // Objective-C++ sources
    // =====================================================================

    root_module.addCSourceFiles(.{
        .files = &.{ "vendor/SZEncodingDetector.mm", "vendor/SZAgentCompat.mm" },
        .flags = objcxx_flags,
        .language = .objective_cpp,
    });

    // =====================================================================
    // Install to zig-out/lib/{arch}/
    // =====================================================================

    const dest_dir = std.fmt.allocPrint(b.allocator, "lib/{s}", .{arch_str}) catch @panic("OOM");
    const dest_name = std.fmt.allocPrint(b.allocator, "{s}.a", .{lib_name}) catch @panic("OOM");

    // Zig emits a SysV archive here, but Darwin's linker requires 64-bit Mach-O
    // members to start on 8-byte boundaries. Repack the finished archive with
    // Apple's libtool before installation so Xcode and clang can link it.
    const archive_for_install: std.Build.LazyPath = blk: {
        if (@import("builtin").os.tag != .macos or target.result.os.tag != .macos) {
            break :blk lib.getEmittedBin();
        }

        const repack = DarwinArchiveRepackStep.create(
            b,
            lib.getEmittedBin(),
            b.fmt("{s}-{s}", .{ arch_str, lib_name }),
            dest_name,
        );
        break :blk repack.getOutput();
    };

    const install = b.addInstallFileWithDir(archive_for_install, .{ .custom = dest_dir }, dest_name);
    archive_for_install.addStepDependencies(&install.step);
    install.step.dependOn(&lib.step);
    return install;
}

// ---------------------------------------------------------------------------
// Windows SFX cross-compilation
// ---------------------------------------------------------------------------

fn buildSfx(
    b: *std.Build,
    comptime variant: Variant,
    comptime arch: std.Target.Cpu.Arch,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.InstallFile {
    const sevenz_root = variant.vendorRoot();
    const variant_str = variant.stepLabel();
    const arch_str = archString(arch);

    const sfx_target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .windows,
        .abi = .gnu,
    });

    const root_module = b.createModule(.{
        .target = sfx_target,
        .optimize = optimize,
        .link_libcpp = true,
    });

    const sfx_name = std.fmt.allocPrint(b.allocator, "7z-{s}-{s}", .{ variant_str, arch_str }) catch @panic("OOM");
    const sfx = b.addExecutable(.{
        .name = sfx_name,
        .root_module = root_module,
    });

    // Windows GUI subsystem (not console)
    sfx.subsystem = .windows;

    // --- Flags ---
    const sevenz_include = std.fmt.allocPrint(b.allocator, "-I{s}", .{sevenz_root}) catch @panic("OOM");

    const c_flags: []const []const u8 = &.{
        "-DNDEBUG",                "-D_REENTRANT",
        "-DUNICODE",               "-D_UNICODE",
        "-DZ7_NO_REGISTRY",        "-DZ7_EXTRACT_ONLY",
        "-DZ7_NO_READ_FROM_CODER", "-DZ7_SFX",
        "-DZ7_NO_LONG_PATH",       "-DZ7_NO_LARGE_PAGES",
        "-Wno-unused-parameter",   "-Wno-missing-field-initializers",
        "-Wno-sign-compare",       "-fno-rtti",
        "-ffunction-sections",     "-fdata-sections",
        "-std=c11",
    };

    const cpp_flags = concatFlags(b, &.{
        "-DNDEBUG",                "-D_REENTRANT",
        "-DUNICODE",               "-D_UNICODE",
        "-DZ7_NO_REGISTRY",        "-DZ7_EXTRACT_ONLY",
        "-DZ7_NO_READ_FROM_CODER", "-DZ7_SFX",
        "-DZ7_NO_LONG_PATH",       "-DZ7_NO_LARGE_PAGES",
        "-Wno-unused-parameter",   "-Wno-missing-field-initializers",
        "-Wno-sign-compare",       "-fno-rtti",
        "-ffunction-sections",     "-fdata-sections",
        "-std=c++11",
    }, &.{sevenz_include});

    // SFX C sources
    root_module.addCSourceFiles(.{
        .root = b.path(sevenz_root),
        .files = &.{
            "C/7zStream.c",  "C/Alloc.c",      "C/Bcj2.c",
            "C/Bra.c",       "C/Bra86.c",      "C/BraIA64.c",
            "C/CpuArch.c",   "C/Delta.c",      "C/DllSecur.c",
            "C/Lzma2Dec.c",  "C/Lzma2DecMt.c", "C/LzmaDec.c",
            "C/MtDec.c",     "C/Ppmd7.c",      "C/Ppmd7Dec.c",
            "C/Threads.c",   "C/Aes.c",        "C/AesOpt.c",
            "C/7zCrc.c",     "C/7zCrcOpt.c",   "C/Sha256.c",
            "C/Sha256Opt.c",
        },
        .flags = c_flags,
        .language = .c,
    });

    // SFX C++ sources
    root_module.addCSourceFiles(.{
        .root = b.path(sevenz_root),
        .files = &.{
            "CPP/7zip/Bundles/SFXWin/SfxWin.cpp",
            "CPP/7zip/UI/GUI/ExtractDialog.cpp",
            "CPP/7zip/UI/GUI/ExtractGUI.cpp",
            "CPP/Common/CRC.cpp",
            "CPP/Common/CommandLineParser.cpp",
            "CPP/Common/IntToString.cpp",
            "CPP/Common/NewHandler.cpp",
            "CPP/Common/MyString.cpp",
            "CPP/Common/StringConvert.cpp",
            "CPP/Common/MyVector.cpp",
            "CPP/Common/Wildcard.cpp",
            "CPP/Common/Sha256Prepare.cpp",
            "CPP/Windows/Clipboard.cpp",
            "CPP/Windows/CommonDialog.cpp",
            "CPP/Windows/DLL.cpp",
            "CPP/Windows/ErrorMsg.cpp",
            "CPP/Windows/FileDir.cpp",
            "CPP/Windows/FileFind.cpp",
            "CPP/Windows/FileIO.cpp",
            "CPP/Windows/FileName.cpp",
            "CPP/Windows/MemoryGlobal.cpp",
            "CPP/Windows/PropVariant.cpp",
            "CPP/Windows/PropVariantConv.cpp",
            "CPP/Windows/ResourceString.cpp",
            "CPP/Windows/Shell.cpp",
            "CPP/Windows/Synchronization.cpp",
            "CPP/Windows/System.cpp",
            "CPP/Windows/TimeUtils.cpp",
            "CPP/Windows/Window.cpp",
            "CPP/Windows/Control/ComboBox.cpp",
            "CPP/Windows/Control/Dialog.cpp",
            "CPP/Windows/Control/ListView.cpp",
            "CPP/7zip/Common/CreateCoder.cpp",
            "CPP/7zip/Common/CWrappers.cpp",
            "CPP/7zip/Common/FilePathAutoRename.cpp",
            "CPP/7zip/Common/FileStreams.cpp",
            "CPP/7zip/Common/InBuffer.cpp",
            "CPP/7zip/Common/FilterCoder.cpp",
            "CPP/7zip/Common/LimitedStreams.cpp",
            "CPP/7zip/Common/OutBuffer.cpp",
            "CPP/7zip/Common/ProgressUtils.cpp",
            "CPP/7zip/Common/PropId.cpp",
            "CPP/7zip/Common/StreamBinder.cpp",
            "CPP/7zip/Common/StreamObjects.cpp",
            "CPP/7zip/Common/StreamUtils.cpp",
            "CPP/7zip/Common/VirtThread.cpp",
            "CPP/7zip/UI/Common/ArchiveExtractCallback.cpp",
            "CPP/7zip/UI/Common/ArchiveOpenCallback.cpp",
            "CPP/7zip/UI/Common/DefaultName.cpp",
            "CPP/7zip/UI/Common/Extract.cpp",
            "CPP/7zip/UI/Common/ExtractingFilePath.cpp",
            "CPP/7zip/UI/Common/LoadCodecs.cpp",
            "CPP/7zip/UI/Common/OpenArchive.cpp",
            "CPP/7zip/UI/Explorer/MyMessages.cpp",
            "CPP/7zip/UI/FileManager/BrowseDialog.cpp",
            "CPP/7zip/UI/FileManager/ComboDialog.cpp",
            "CPP/7zip/UI/FileManager/ExtractCallback.cpp",
            "CPP/7zip/UI/FileManager/FormatUtils.cpp",
            "CPP/7zip/UI/FileManager/OverwriteDialog.cpp",
            "CPP/7zip/UI/FileManager/PasswordDialog.cpp",
            "CPP/7zip/UI/FileManager/ProgressDialog2.cpp",
            "CPP/7zip/UI/FileManager/PropertyName.cpp",
            "CPP/7zip/UI/FileManager/SysIconUtils.cpp",
            "CPP/7zip/Archive/SplitHandler.cpp",
            "CPP/7zip/Archive/Common/CoderMixer2.cpp",
            "CPP/7zip/Archive/Common/ItemNameUtils.cpp",
            "CPP/7zip/Archive/Common/MultiStream.cpp",
            "CPP/7zip/Archive/Common/OutStreamWithCRC.cpp",
            "CPP/7zip/Archive/7z/7zDecode.cpp",
            "CPP/7zip/Archive/7z/7zExtract.cpp",
            "CPP/7zip/Archive/7z/7zHandler.cpp",
            "CPP/7zip/Archive/7z/7zIn.cpp",
            "CPP/7zip/Archive/7z/7zRegister.cpp",
            "CPP/7zip/Compress/Bcj2Coder.cpp",
            "CPP/7zip/Compress/Bcj2Register.cpp",
            "CPP/7zip/Compress/BcjCoder.cpp",
            "CPP/7zip/Compress/BcjRegister.cpp",
            "CPP/7zip/Compress/BranchMisc.cpp",
            "CPP/7zip/Compress/BranchRegister.cpp",
            "CPP/7zip/Compress/CopyCoder.cpp",
            "CPP/7zip/Compress/CopyRegister.cpp",
            "CPP/7zip/Compress/DeltaFilter.cpp",
            "CPP/7zip/Compress/Lzma2Decoder.cpp",
            "CPP/7zip/Compress/Lzma2Register.cpp",
            "CPP/7zip/Compress/LzmaDecoder.cpp",
            "CPP/7zip/Compress/LzmaRegister.cpp",
            "CPP/7zip/Compress/PpmdDecoder.cpp",
            "CPP/7zip/Compress/PpmdRegister.cpp",
            "CPP/7zip/Crypto/7zAes.cpp",
            "CPP/7zip/Crypto/7zAesRegister.cpp",
            "CPP/7zip/Crypto/MyAes.cpp",
        },
        .flags = cpp_flags,
        .language = .cpp,
    });

    // ZS SFX extras
    if (variant == .zs) {
        root_module.addCSourceFiles(.{
            .root = b.path(sevenz_root),
            .files = &.{
                "CPP/Common/MyWindows.cpp",
                "CPP/7zip/Compress/ZstdDecoder.cpp",
                "CPP/7zip/Compress/ZstdRegister.cpp",
            },
            .flags = cpp_flags,
            .language = .cpp,
        });

        const zstd_inc = std.fmt.allocPrint(b.allocator, "-I{s}/C/zstd", .{sevenz_root}) catch @panic("OOM");
        const hashes_inc = std.fmt.allocPrint(b.allocator, "-I{s}/C/hashes", .{sevenz_root}) catch @panic("OOM");
        const sfx_zstd_flags = concatFlags(b, c_flags, &.{ "-DZSTD_DISABLE_ASM", zstd_inc, hashes_inc });

        root_module.addCSourceFiles(.{
            .root = b.path(sevenz_root),
            .files = &.{
                "C/zstd/debug.c",           "C/zstd/entropy_common.c",
                "C/zstd/error_private.c",   "C/zstd/fse_decompress.c",
                "C/zstd/huf_decompress.c",  "C/zstd/pool.c",
                "C/zstd/threading.c",       "C/zstd/zstd_common.c",
                "C/zstd/zstd_ddict.c",      "C/zstd/zstd_decompress_block.c",
                "C/zstd/zstd_decompress.c",
            },
            .flags = sfx_zstd_flags,
            .language = .c,
        });
        root_module.addCSourceFiles(.{
            .root = b.path(sevenz_root),
            .files = &.{"C/hashes/xxhash.c"},
            .flags = sfx_zstd_flags,
            .language = .c,
        });
    }

    // Windows resource file
    root_module.addWin32ResourceFile(.{
        .file = b.path(std.fmt.allocPrint(b.allocator, "{s}/CPP/7zip/Bundles/SFXWin/resource.rc", .{sevenz_root}) catch @panic("OOM")),
        .include_paths = &.{
            b.path(std.fmt.allocPrint(b.allocator, "{s}/CPP/7zip", .{sevenz_root}) catch @panic("OOM")),
            b.path(std.fmt.allocPrint(b.allocator, "{s}/CPP/7zip/Bundles/SFXWin", .{sevenz_root}) catch @panic("OOM")),
            b.path(std.fmt.allocPrint(b.allocator, "{s}/CPP/7zip/UI/GUI", .{sevenz_root}) catch @panic("OOM")),
            b.path(std.fmt.allocPrint(b.allocator, "{s}/CPP/7zip/UI/FileManager", .{sevenz_root}) catch @panic("OOM")),
            b.path(std.fmt.allocPrint(b.allocator, "{s}/CPP", .{sevenz_root}) catch @panic("OOM")),
            b.path(std.fmt.allocPrint(b.allocator, "{s}/C", .{sevenz_root}) catch @panic("OOM")),
            b.path(sevenz_root),
        },
    });

    // Link Windows system libraries
    const win_libs = [_][]const u8{
        "kernel32", "user32",   "advapi32", "shell32",
        "ole32",    "oleaut32", "uuid",     "gdi32",
        "comctl32", "comdlg32", "shlwapi",
    };
    for (win_libs) |wl| {
        root_module.linkSystemLibrary(wl, .{});
    }

    // Install to zig-out/sfx/ with .sfx extension
    const sfx_filename = std.fmt.allocPrint(b.allocator, "7z-{s}-{s}.sfx", .{ variant_str, arch_str }) catch @panic("OOM");
    const install = b.addInstallFileWithDir(sfx.getEmittedBin(), .{ .custom = "sfx" }, sfx_filename);
    install.step.dependOn(&sfx.step);
    return install;
}
