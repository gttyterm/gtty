// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! gtty — True Graphic Virtual Terminal: a multi-window terminal.

const std = @import("std");
const c = @import("c.zig").c;
const App = @import("App.zig");
const JobWindow = @import("ui/JobWindow.zig");
const Config = @import("core/Config.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.c_allocator;

    // Settings file first; then GTTY_* variables and options win for this
    // run. A test script reads (and writes) one only with GTTY_CONFIG, so
    // the user's settings never change a test's picture.
    var script_mode = false;
    var pre = init.args.iterate();
    while (pre.next()) |a| {
        if (std.mem.eql(u8, a, "--script")) script_mode = true;
    }
    const use_config = !script_mode or c.getenv("GTTY_CONFIG") != null;
    const cfg: Config = if (use_config) Config.load() else .{};
    var opts: App.Options = .{
        .cfg = cfg,
        .save_config = use_config,
        .font_pt = cfg.font_pt,
        .scrollback = cfg.scrollback,
        .command = cfg.command(),
    };
    JobWindow.anim_len_ms = cfg.anim_ms;
    if (c.getenv("GTTY_FONT_SIZE")) |s| {
        opts.font_pt = std.fmt.parseFloat(f32, std.mem.span(s)) catch opts.font_pt;
    }
    if (c.getenv("GTTY_ANIM_MS")) |s| {
        JobWindow.anim_len_ms = std.fmt.parseInt(u64, std.mem.span(s), 10) catch JobWindow.anim_len_ms;
    }
    if (c.getenv("GTTY_SCROLLBACK")) |s| {
        opts.scrollback = std.fmt.parseInt(usize, std.mem.span(s), 10) catch opts.scrollback;
    }

    var args = init.args.iterate();
    _ = args.next(); // program name
    var command_given = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--script")) {
            opts.script = args.next();
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--command")) {
            opts.command = args.next() orelse {
                std.debug.print("{s} needs a command, e.g. gtty -c 'htop' (\"\" for none)\n", .{a});
                return;
            };
            command_given = true;
        } else if (std.mem.eql(u8, a, "--scrollback")) {
            const n = args.next() orelse "";
            opts.scrollback = std.fmt.parseInt(usize, n, 10) catch {
                std.debug.print("--scrollback needs a number of lines\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, a, "--version")) {
            std.debug.print("gtty " ++ @import("build_options").version ++ "\n" ++ App.copyright ++ "\n" ++ App.license_line ++ "\n", .{});
            return;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print(
                \\usage: gtty [-c command] [--script file] [--scrollback lines]
                \\  -c, --command cmd   run cmd at start as if typed at the prompt
                \\                      (default: s, your shell; "" for none)
                \\
            , .{});
            return;
        }
    }
    // A test script opens its own windows: no start-up shell unless asked.
    if (opts.script != null and !command_given) opts.command = null;

    // Launched from Finder/Dock the working directory is "/": start in $HOME.
    var cwd_buf: [4096]u8 = undefined;
    if (c.getcwd(&cwd_buf, cwd_buf.len)) |cwd| {
        if (std.mem.eql(u8, std.mem.span(cwd), "/")) {
            if (c.getenv("HOME")) |home| _ = c.chdir(home);
        }
    }

    @import("core/trace.zig").init();
    const app = try App.create(gpa, opts);
    defer app.destroy();
    app.run();
}

test {
    _ = @import("core/color.zig");
    _ = @import("core/Screen.zig");
    _ = @import("core/wcwidth.zig");
    _ = @import("core/Tee.zig");
    _ = @import("ui/commands.zig");
    _ = @import("core/git.zig");
    _ = @import("ui/Peek.zig");
    _ = @import("ui/Menu.zig");
    _ = @import("ui/ids.zig");
    _ = @import("ui/tiling.zig");
    _ = @import("ui/file_path.zig");
    _ = @import("ui/FileOpener.zig");
    _ = @import("ui/LineEdit.zig");
    _ = @import("ui/PastePreview.zig");
    _ = @import("core/remote.zig");
    _ = @import("core/RemoteLink.zig");
    _ = @import("core/Config.zig");
    _ = @import("core/oscmd.zig");
    _ = @import("core/ShellNames.zig");
    _ = @import("ai/Ai.zig");
    _ = @import("ai/Memory.zig");
}
