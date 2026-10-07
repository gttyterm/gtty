// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const default_prefix = if (target.result.cpu.arch == .aarch64) "/opt/homebrew" else "/usr/local";
    const sdl: Sdl = .{
        .brew_prefix = b.option([]const u8, "brew-prefix", "Homebrew prefix (macOS)") orelse default_prefix,
        // Self-contained binaries (scripts/build-bin.sh): SDL3, SDL3_ttf and
        // freetype compiled from source and linked in statically.
        .bundled = b.option(bool, "bundled-sdl", "Build SDL3 + SDL3_ttf from source and link them statically") orelse false,
        // Needed with an explicit macOS -Dtarget (e.g. an older minimum
        // version): the SDK from `xcrun --show-sdk-path`.
        .macos_sdk = b.option([]const u8, "macos-sdk", "macOS SDK path, for an explicit macOS -Dtarget"),
    };
    // Release binaries (scripts/build-bin.sh): no debug info.
    const strip = b.option(bool, "strip", "Leave out debug info");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    configure(b, mod, target, optimize, sdl);
    // The version (build.zig.zon) for --version, SDL's app metadata and
    // the packages (scripts/package.sh reads the same line).
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "gtty", .root_module = mod });
    b.installArtifact(exe);

    // zig build run [-- --script test/smoke.gt]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run gtty");
    run_step.dependOn(&run_cmd.step);

    // zig build test — unit tests for the parser, colors and gt commands.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configure(b, test_mod, target, optimize, sdl);
    test_mod.addOptions("build_options", options);
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

const Sdl = struct {
    brew_prefix: []const u8,
    bundled: bool,
    macos_sdk: ?[]const u8,
};

fn configure(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sdl: Sdl) void {
    mod.addIncludePath(b.path("src/sys"));
    mod.addCSourceFile(.{ .file = b.path("src/sys/gtty_pty.c"), .flags = &.{ "-std=gnu11", "-Wall" } });
    mod.addCSourceFile(.{ .file = b.path("src/sys/gtty_beep.c"), .flags = &.{ "-std=gnu11", "-Wall" } });
    // LaunchServices calls used by `show` are deprecated (still supported).
    mod.addCSourceFile(.{ .file = b.path("src/sys/gtty_open.c"), .flags = &.{ "-std=gnu11", "-Wall", "-Wno-deprecated-declarations" } });
    // Files dropped on gtty: copied into a folder in the background.
    mod.addCSourceFile(.{ .file = b.path("src/sys/gtty_copy.c"), .flags = &.{ "-std=gnu11", "-Wall" } });

    if (target.result.os.tag == .macos) {
        // The gtty menu in the system menu bar (Cocoa).
        mod.addCSourceFile(.{ .file = b.path("src/sys/gtty_menu.m"), .flags = &.{"-Wall"} });
        // Dragging a file name out of a job window (NSDraggingSession).
        mod.addCSourceFile(.{ .file = b.path("src/sys/gtty_drag.m"), .flags = &.{"-Wall"} });
    } else {
        mod.addCSourceFile(.{ .file = b.path("src/sys/gtty_menu.c"), .flags = &.{ "-std=gnu11", "-Wall" } });
        // Dragging files out under Wayland (libwayland-client via dlopen).
        mod.addCSourceFile(.{ .file = b.path("src/sys/gtty_drag.c"), .flags = &.{ "-std=gnu11", "-Wall" } });
    }

    if (target.result.os.tag == .macos) {
        addSdk(b, mod, sdl.macos_sdk);
        mod.linkFramework("Cocoa", .{}); // the gtty menu
        mod.linkFramework("AudioToolbox", .{}); // the system alert sound
        mod.linkFramework("CoreServices", .{}); // LaunchServices (`show`)
        mod.linkFramework("CoreFoundation", .{});
    } else {
        mod.linkSystemLibrary("util", .{}); // openpty on older glibc
        mod.linkSystemLibrary("dl", .{}); // dlopen on older glibc (Wayland drag)
    }

    if (sdl.bundled) {
        const libs = bundledSdl(b, target, optimize, sdl.macos_sdk) orelse return; // fetched lazily
        mod.linkLibrary(libs.sdl3);
        mod.linkLibrary(libs.ttf);
        return;
    }
    if (target.result.os.tag == .macos) {
        // Homebrew: /opt/homebrew on Apple Silicon, /usr/local on Intel.
        // Override with -Dbrew-prefix=/some/path if yours is elsewhere.
        mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{sdl.brew_prefix}) });
        mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{sdl.brew_prefix}) });
    }
    // On macOS we point at Homebrew directly (no pkg-config needed);
    // on Linux pkg-config finds SDL3 wherever the distro put it.
    const pc: std.Build.Module.SystemLib.UsePkgConfig = if (target.result.os.tag == .macos) .no else .yes;
    mod.linkSystemLibrary("SDL3", .{ .use_pkg_config = pc });
    mod.linkSystemLibrary("SDL3_ttf", .{ .use_pkg_config = pc });
}

/// Search paths into the macOS SDK (cross builds; no-op without one).
fn addSdk(b: *std.Build, mod: *std.Build.Module, macos_sdk: ?[]const u8) void {
    const sdk = macos_sdk orelse return;
    mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) });
    mod.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
}

const Bundled = struct { sdl3: *std.Build.Step.Compile, ttf: *std.Build.Step.Compile };

/// SDL3 (castholm/SDL, a Zig port), plus SDL3_ttf and freetype built here
/// from their release sources (no harfbuzz / plutosvg: gtty doesn't shape
/// text), freetype with libpng + zlib for the color emoji fonts (Apple
/// Color Emoji, Noto Color Emoji: PNG images). Built once per target; the
/// app and the tests share them.
var bundled_cache: ?Bundled = null;

fn bundledSdl(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, macos_sdk: ?[]const u8) ?Bundled {
    if (bundled_cache) |c| return c;
    const sdl_dep = if (macos_sdk) |sdk| b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
        .system_include_path = std.Build.LazyPath{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) },
        .system_framework_path = std.Build.LazyPath{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) },
        .library_path = std.Build.LazyPath{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) },
    }) else b.lazyDependency("sdl", .{ .target = target, .optimize = optimize, .preferred_linkage = .static });
    const sdl_dep_ = sdl_dep orelse return null;
    const ttf_src = b.lazyDependency("sdl_ttf", .{}) orelse return null;
    const ft_src = b.lazyDependency("freetype", .{}) orelse return null;
    const zlib_src = b.lazyDependency("zlib", .{}) orelse return null;
    const png_src = b.lazyDependency("libpng", .{}) orelse return null;
    const sdl3 = sdl_dep_.artifact("SDL3");

    const zlib = b.addLibrary(.{ .name = "z", .linkage = .static, .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    addSdk(b, zlib.root_module, macos_sdk);
    zlib.root_module.addCMacro("HAVE_UNISTD_H", "1");
    zlib.root_module.addCSourceFiles(.{ .root = zlib_src.path("."), .files = &.{
        "adler32.c", "compress.c", "crc32.c",   "deflate.c", "infback.c", "inffast.c",
        "inflate.c", "inftrees.c", "trees.c", "uncompr.c", "zutil.c",
    } });
    zlib.installHeader(zlib_src.path("zlib.h"), "zlib.h");
    zlib.installHeader(zlib_src.path("zconf.h"), "zconf.h");

    const png = b.addLibrary(.{ .name = "png", .linkage = .static, .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    addSdk(b, png.root_module, macos_sdk);
    const png_conf = b.addWriteFiles();
    _ = png_conf.addCopyFile(png_src.path("scripts/pnglibconf.h.prebuilt"), "pnglibconf.h");
    png.root_module.addIncludePath(png_conf.getDirectory());
    png.root_module.addIncludePath(png_src.path("."));
    png.root_module.linkLibrary(zlib);
    // Plain C everywhere (no NEON / SSE files to add).
    png.root_module.addCMacro("PNG_ARM_NEON_OPT", "0");
    png.root_module.addCMacro("PNG_INTEL_SSE_OPT", "0");
    png.root_module.addCSourceFiles(.{ .root = png_src.path("."), .files = &.{
        "png.c",      "pngerror.c", "pngget.c",  "pngmem.c",   "pngpread.c", "pngread.c", "pngrio.c",   "pngrtran.c",
        "pngrutil.c", "pngset.c",   "pngtrans.c", "pngwio.c",  "pngwrite.c", "pngwtran.c", "pngwutil.c",
    } });
    png.installHeader(png_src.path("png.h"), "png.h");
    png.installHeader(png_src.path("pngconf.h"), "pngconf.h");
    png.installHeader(png_conf.getDirectory().path(b, "pnglibconf.h"), "pnglibconf.h");

    const ft = b.addLibrary(.{ .name = "freetype", .linkage = .static, .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    addSdk(b, ft.root_module, macos_sdk);
    ft.root_module.addIncludePath(ft_src.path("include"));
    ft.root_module.addCMacro("FT2_BUILD_LIBRARY", "1");
    ft.root_module.addCMacro("FT_CONFIG_OPTION_USE_PNG", "1");
    ft.root_module.linkLibrary(png);
    ft.root_module.addCSourceFiles(.{ .root = ft_src.path("."), .files = &freetype_srcs, .flags = &.{"-std=c99"} });
    ft.installHeadersDirectory(ft_src.path("include"), "", .{});

    const ttf = b.addLibrary(.{ .name = "SDL3_ttf", .linkage = .static, .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    addSdk(b, ttf.root_module, macos_sdk);
    // Its color-glyph blending reads 32-bit pixels at unaligned addresses
    // (harmless on arm64 / x86): no C sanitizer, or it traps there.
    ttf.root_module.sanitize_c = .off;
    ttf.root_module.addIncludePath(ttf_src.path("include"));
    ttf.root_module.addIncludePath(ttf_src.path("src"));
    ttf.root_module.linkLibrary(sdl3); // headers
    ttf.root_module.linkLibrary(ft);
    ttf.root_module.addCSourceFiles(.{ .root = ttf_src.path("src"), .files = &.{
        "SDL_ttf.c",
        "SDL_hashtable.c",
        "SDL_hashtable_ttf.c",
        "SDL_renderer_textengine.c",
        "SDL_surface_textengine.c",
        "SDL_gpu_textengine.c",
    }, .flags = &.{"-std=gnu11"} });
    ttf.installHeadersDirectory(ttf_src.path("include/SDL3_ttf"), "SDL3_ttf", .{});

    bundled_cache = .{ .sdl3 = sdl3, .ttf = ttf };
    return bundled_cache;
}

// freetype's CMakeLists.txt BASE_SRCS, with the portable ftsystem / ftdebug.
const freetype_srcs = [_][]const u8{
    "src/autofit/autofit.c",   "src/base/ftbase.c",      "src/base/ftbbox.c",
    "src/base/ftbdf.c",        "src/base/ftbitmap.c",    "src/base/ftcid.c",
    "src/base/ftfstype.c",     "src/base/ftgasp.c",      "src/base/ftglyph.c",
    "src/base/ftgxval.c",      "src/base/ftinit.c",      "src/base/ftmm.c",
    "src/base/ftotval.c",      "src/base/ftpatent.c",    "src/base/ftpfr.c",
    "src/base/ftstroke.c",     "src/base/ftsynth.c",     "src/base/fttype1.c",
    "src/base/ftwinfnt.c",     "src/bdf/bdf.c",          "src/bzip2/ftbzip2.c",
    "src/cache/ftcache.c",     "src/cff/cff.c",          "src/cid/type1cid.c",
    "src/gzip/ftgzip.c",       "src/lzw/ftlzw.c",        "src/pcf/pcf.c",
    "src/pfr/pfr.c",           "src/psaux/psaux.c",      "src/pshinter/pshinter.c",
    "src/psnames/psnames.c",   "src/raster/raster.c",    "src/sdf/sdf.c",
    "src/sfnt/sfnt.c",         "src/smooth/smooth.c",    "src/svg/svg.c",
    "src/truetype/truetype.c", "src/type1/type1.c",      "src/type42/type42.c",
    "src/winfonts/winfnt.c",   "src/base/ftsystem.c",    "src/base/ftdebug.c",
};
