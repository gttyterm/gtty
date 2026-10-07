// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Parsing of gtty's own commands.
//!
//! A line typed at the prompt is resolved in this order (App does the OS
//! part, see oscmd.zig):
//!   1. `/name args` — explicitly a gtty command (`/s`, `/close 3`).
//!   2. Something the OS knows (a program, a path, a shell builtin, or an
//!      alias/function from the user's shell config) — run it as a job. The OS goes first, so a gtty name never hides an OS
//!      command; the `/` is how to reach gtty's version.
//!   3. A gtty command name without the slash (`quit`) — `parseGtty`.
//!      Script hooks (/wait, /type, …) need the slash.
//!   4. Nothing — rejected (beep, the text flashes red).

const std = @import("std");

pub const Target = union(enum) {
    all,
    focused,
    id: u32,
};

pub const Zoom = union(enum) {
    in,
    out,
    reset,
    set: f32,
};

pub const MenuPick = enum { run, settings, copy, paste, select_all, new_shell, new_window, sync_typing, about };

pub const Command = union(enum) {
    /// No leading `/`: the OS gets the first chance (see above).
    line: []const u8,
    empty,
    help,
    /// s / sh / shell [program] — a job window with the user's shell;
    /// `--cwd <folder>` starts it there (the AI uses it).
    shell: struct { program: ?[]const u8 = null, cwd: ?[]const u8 = null },
    /// /run <command line> — always a new job window.
    run: []const u8,
    close: Target,
    focus: u32,
    zoom: Zoom,
    /// colors [on | off] — the current window's colors; no argument toggles.
    colors: ?bool,
    /// show [-a] <file> — open a file with its default app (no default
    /// app, or -a: pick the app). No job window.
    show: struct { path: []const u8, pick: bool = false },
    clear: Target,
    list,
    /// settings — open the settings window (also in the gtty menu).
    settings,
    quit,
    /// /shot <file.bmp> — save a screenshot of the gtty window.
    shot: []const u8,
    /// /wait <ms> — pause a --script run.
    wait: u32,
    /// /type <text> — type text + Enter as if from the keyboard (for scripts).
    type: []const u8,
    /// /text <text> — type text without Enter (for scripts).
    text: []const u8,
    /// /key <keys> — press a key through the real keyboard path, e.g.
    /// `ctrl+shift+left`, `cmd+right`, `backspace` (for scripts).
    key: []const u8,
    /// /click <x> <y> — left click at window coordinates (for scripts).
    click: struct { x: f32, y: f32 },
    /// /rclick <x> <y> — right click at window coordinates (for scripts).
    rclick: struct { x: f32, y: f32 },
    /// /move <x> <y> — move the mouse there, no button (for scripts).
    move: struct { x: f32, y: f32 },
    /// /dclick <x> <y> — left double-click (for scripts).
    dclick: struct { x: f32, y: f32 },
    /// /down <x> <y>, /up <x> <y> — left button down / up there, e.g. to
    /// hold on a file name, /move, then /up (for scripts).
    down: struct { x: f32, y: f32 },
    up: struct { x: f32, y: f32 },
    /// /drag <x1> <y1> <x2> <y2> — press at the first point, move to the
    /// second and release, e.g. to select text (for scripts).
    drag: [4]f32,
    /// /resize <w> <h> — resize gtty's OS window (window coordinates).
    resize: [2]f32,
    /// /menu run | settings | copy | paste | select-all | new-shell | new-window | sync-typing | about — pick a
    /// menu entry, as the
    /// menu bar would (for scripts: macOS menus can't be clicked).
    menu: MenuPick,
    /// /mods cmd+shift | none — the modifier keys held from now on, as if
    /// pressed (for scripts: hover / click with ⌘ etc.).
    mods: []const u8,
    /// /target main | settings — which OS window the next /click, /move,
    /// /drag, /text, /key, /type and /shot go to (for scripts).
    target: enum { main, settings },
    /// /record start <dir> [fps] | stop — save every frame (window size,
    /// PPM) into dir with their times in `frames.txt`; the script's mouse
    /// pointer is drawn in them (for the README animations, docs/demo).
    record: union(enum) { start: struct { dir: []const u8, fps: u32 }, stop },
    /// /slow <text> — type text one character at a time, no Enter (demos).
    slow: []const u8,
    /// /glide <x> <y> [ms] — move the mouse there smoothly (default 400
    /// ms), with the button state of the last /down or /up (demos).
    glide: struct { x: f32, y: f32, ms: u32 },
    /// /pace <ms> — the gap between script lines from now on (default 400).
    pace: u32,
    /// /dropover <x> <y> — files from another app dragged over gtty, here
    /// (SDL drop position events). /drop <x> <y> <path> — dropped there.
    dropover: struct { x: f32, y: f32 },
    drop: struct { x: f32, y: f32, path: []const u8 },
    /// A gtty command used wrongly: the message to show.
    bad: []const u8,
    /// Not a gtty command name.
    unknown: []const u8,
};

pub const help_text =
    \\s                     open your shell in a job window
    \\list                  list job windows
    \\focus N               bring window #N up  (also: click, Ctrl+Tab)
    \\close [N | all]       close job windows
    \\zoom in | out | 150%  zoom the current window  (also: Cmd/Ctrl +/-)
    \\colors [on | off]     show or hide the current window's colors
    \\show [-a] FILE        open a file in its default app (-a: choose the app)
    \\settings              open the settings window  (also in the gtty menu)
    \\/clear                clear the current window  (plain clear is the OS's)
    \\quit                  exit gtty
    \\anything else the OS knows runs in a job window: bash, ls -l, make
    \\/name: gtty's command even if the OS has the same name (/clear)
;

/// A prompt line: `/…` is a gtty command; anything else is `.line`.
pub fn parse(line_in: []const u8) Command {
    const line = std.mem.trim(u8, line_in, " \t");
    if (line.len == 0) return .empty;
    if (line[0] == '/') {
        const rest = std.mem.trim(u8, line[1..], " \t");
        // "/" alone, or a path like /bin/ls: not a gtty command name.
        if (rest.len == 0) return .help;
        if (std.mem.indexOfScalar(u8, firstWord(rest), '/') != null) return .{ .line = line };
        return parseGtty(rest, true);
    }
    return .{ .line = line };
}

fn firstWord(s: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    return s[0..end];
}

/// A gtty command without its slash: "close 3". `.unknown` if the name
/// isn't one of gtty's commands. `explicit`: typed with the `/`; the
/// script hooks (wait, shot, type, text, key, click, rclick, drag, resize) only count then, so they never
/// hide the shell's `wait` and `type`.
pub fn parseGtty(text: []const u8, explicit: bool) Command {
    var it = std.mem.tokenizeAny(u8, text, " \t");
    const sub = it.next() orelse return .help;
    const rest = std.mem.trim(u8, it.rest(), " \t");

    if (eq(sub, "help")) return .help;
    if (eq(sub, "s") or eq(sub, "sh") or eq(sub, "shell")) {
        if (std.mem.startsWith(u8, rest, "--cwd")) {
            var dir = std.mem.trim(u8, rest[5..], " \t");
            if (dir.len >= 2 and (dir[0] == '"' or dir[0] == '\'') and dir[dir.len - 1] == dir[0]) dir = dir[1 .. dir.len - 1];
            if (dir.len == 0) return .{ .bad = "s --cwd <folder>" };
            return .{ .shell = .{ .cwd = dir } };
        }
        var args = std.mem.tokenizeAny(u8, rest, " \t");
        return .{ .shell = .{ .program = args.next() } };
    }
    if (eq(sub, "run")) {
        if (rest.len == 0) return .{ .bad = "/run needs a command" };
        return .{ .run = rest };
    }
    if (eq(sub, "close")) return .{ .close = target(rest, .all) };
    if (eq(sub, "clear")) return .{ .clear = target(rest, .focused) };
    if (eq(sub, "focus")) {
        const n = std.fmt.parseInt(u32, std.mem.trimStart(u8, rest, "#"), 10) catch return .{ .bad = "/focus needs a window number" };
        return .{ .focus = n };
    }
    if (eq(sub, "zoom")) {
        if (rest.len == 0 or eq(rest, "in") or eq(rest, "+")) return .{ .zoom = .in };
        if (eq(rest, "out") or eq(rest, "-")) return .{ .zoom = .out };
        if (eq(rest, "reset") or eq(rest, "0") or eq(rest, "100%")) return .{ .zoom = .reset };
        const num = std.mem.trimEnd(u8, rest, "%");
        const v = std.fmt.parseFloat(f32, num) catch return .{ .bad = "/zoom in | out | reset | 150%" };
        return .{ .zoom = .{ .set = if (v > 5) v / 100 else v } };
    }
    if (eq(sub, "colors") or eq(sub, "colours")) {
        if (rest.len == 0) return .{ .colors = null };
        if (eq(rest, "on")) return .{ .colors = true };
        if (eq(rest, "off")) return .{ .colors = false };
        return .{ .bad = "/colors on | off" };
    }
    if (eq(sub, "show")) {
        const usage = "show <file>  (show -a <file>: choose the app)";
        var path = rest;
        var pick = false;
        if (std.mem.startsWith(u8, path, "-a ") or std.mem.startsWith(u8, path, "-a\t") or eq(path, "-a")) {
            pick = true;
            path = std.mem.trim(u8, path[2..], " \t");
        }
        // One file; the rest of the line is its name (spaces and all), or
        // the name in quotes.
        if (path.len >= 2 and (path[0] == '"' or path[0] == '\'') and path[path.len - 1] == path[0]) path = path[1 .. path.len - 1];
        if (path.len == 0) return .{ .bad = usage };
        return .{ .show = .{ .path = path, .pick = pick } };
    }
    if (eq(sub, "list")) return .list;
    if (eq(sub, "settings")) return .settings;
    if (eq(sub, "quit")) return .quit;
    if (!explicit) return .{ .unknown = sub };
    // Script hooks: only with the slash.
    if (eq(sub, "shot")) return .{ .shot = if (rest.len > 0) rest else "gtty-shot.bmp" };
    if (eq(sub, "click") or eq(sub, "rclick") or eq(sub, "move") or eq(sub, "dclick") or eq(sub, "down") or eq(sub, "up")) {
        const usage = if (eq(sub, "move")) "/move <x> <y>" else if (eq(sub, "rclick")) "/rclick <x> <y>" else if (eq(sub, "dclick")) "/dclick <x> <y>" else if (eq(sub, "down")) "/down <x> <y>" else if (eq(sub, "up")) "/up <x> <y>" else "/click <x> <y>";
        var nums = std.mem.tokenizeAny(u8, rest, " \t,");
        const x = std.fmt.parseFloat(f32, nums.next() orelse "") catch return .{ .bad = usage };
        const y = std.fmt.parseFloat(f32, nums.next() orelse "") catch return .{ .bad = usage };
        if (eq(sub, "move")) return .{ .move = .{ .x = x, .y = y } };
        if (eq(sub, "rclick")) return .{ .rclick = .{ .x = x, .y = y } };
        if (eq(sub, "dclick")) return .{ .dclick = .{ .x = x, .y = y } };
        if (eq(sub, "down")) return .{ .down = .{ .x = x, .y = y } };
        if (eq(sub, "up")) return .{ .up = .{ .x = x, .y = y } };
        return .{ .click = .{ .x = x, .y = y } };
    }
    if (eq(sub, "glide") or eq(sub, "dropover") or eq(sub, "drop")) {
        const usage = if (eq(sub, "glide")) "/glide <x> <y> [ms]" else if (eq(sub, "drop")) "/drop <x> <y> <path>" else "/dropover <x> <y>";
        var nums = std.mem.tokenizeAny(u8, rest, " \t,");
        const x = std.fmt.parseFloat(f32, nums.next() orelse "") catch return .{ .bad = usage };
        const y = std.fmt.parseFloat(f32, nums.next() orelse "") catch return .{ .bad = usage };
        const tail = std.mem.trim(u8, nums.rest(), " \t");
        if (eq(sub, "dropover")) return .{ .dropover = .{ .x = x, .y = y } };
        if (eq(sub, "drop")) return if (tail.len > 0) .{ .drop = .{ .x = x, .y = y, .path = tail } } else .{ .bad = usage };
        const ms = if (tail.len > 0) std.fmt.parseInt(u32, tail, 10) catch return .{ .bad = usage } else 400;
        return .{ .glide = .{ .x = x, .y = y, .ms = ms } };
    }
    if (eq(sub, "record")) {
        const usage = "/record start <dir> [fps] | stop";
        var words = std.mem.tokenizeAny(u8, rest, " \t");
        const what = words.next() orelse return .{ .bad = usage };
        if (eq(what, "stop")) return .{ .record = .stop };
        if (!eq(what, "start")) return .{ .bad = usage };
        const dir = words.next() orelse return .{ .bad = usage };
        const fps = if (words.next()) |n| std.fmt.parseInt(u32, n, 10) catch return .{ .bad = usage } else 15;
        if (fps == 0 or fps > 60) return .{ .bad = usage };
        return .{ .record = .{ .start = .{ .dir = dir, .fps = fps } } };
    }
    if (eq(sub, "slow")) return .{ .slow = rest };
    if (eq(sub, "pace")) return .{ .pace = std.fmt.parseInt(u32, rest, 10) catch return .{ .bad = "/pace <ms>" } };
    if (eq(sub, "drag")) {
        var nums = std.mem.tokenizeAny(u8, rest, " \t,");
        var v: [4]f32 = undefined;
        for (&v) |*n| n.* = std.fmt.parseFloat(f32, nums.next() orelse "") catch return .{ .bad = "/drag <x1> <y1> <x2> <y2>" };
        return .{ .drag = v };
    }
    if (eq(sub, "resize")) {
        var nums = std.mem.tokenizeAny(u8, rest, " \t,x");
        var v: [2]f32 = undefined;
        for (&v) |*n| n.* = std.fmt.parseFloat(f32, nums.next() orelse "") catch return .{ .bad = "/resize <w> <h>" };
        return .{ .resize = v };
    }
    if (eq(sub, "type")) return .{ .type = rest };
    if (eq(sub, "text")) return .{ .text = rest };
    if (eq(sub, "key")) return if (rest.len > 0) .{ .key = rest } else .{ .bad = "/key ctrl+shift+left" };
    if (eq(sub, "wait")) return .{ .wait = std.fmt.parseInt(u32, rest, 10) catch 500 };
    if (eq(sub, "menu")) {
        const usage = "/menu run | settings | copy | paste | select-all | new-shell | new-window | sync-typing | about";
        if (eq(rest, "run")) return .{ .menu = .run };
        if (eq(rest, "settings")) return .{ .menu = .settings };
        if (eq(rest, "copy")) return .{ .menu = .copy };
        if (eq(rest, "paste")) return .{ .menu = .paste };
        if (eq(rest, "select-all")) return .{ .menu = .select_all };
        if (eq(rest, "new-shell")) return .{ .menu = .new_shell };
        if (eq(rest, "new-window")) return .{ .menu = .new_window };
        if (eq(rest, "sync-typing")) return .{ .menu = .sync_typing };
        if (eq(rest, "about")) return .{ .menu = .about };
        return .{ .bad = usage };
    }
    if (eq(sub, "mods")) return if (rest.len > 0) .{ .mods = rest } else .{ .bad = "/mods cmd+shift | none" };
    if (eq(sub, "target")) {
        if (eq(rest, "main")) return .{ .target = .main };
        if (eq(rest, "settings")) return .{ .target = .settings };
        return .{ .bad = "/target main | settings" };
    }
    return .{ .unknown = sub };
}

/// With the AI on, a line that is exactly one of gtty's commands (no
/// slash) runs at once; anything looser goes to the AI, which knows the
/// shell's commands too. Exact: a known name with the arguments it takes
/// (`close 3`, `focus 2`, `s`, `list`), not "close the finished windows"
/// or "show me the big files". Script hooks always need the slash.
pub fn parseExact(text_in: []const u8) ?Command {
    const text = std.mem.trim(u8, text_in, " \t");
    const cmd = parseGtty(text, false);
    var it = std.mem.tokenizeAny(u8, text, " \t");
    _ = it.next();
    const rest = std.mem.trim(u8, it.rest(), " \t");
    var words = std.mem.tokenizeAny(u8, rest, " \t");
    var n_words: usize = 0;
    while (words.next()) |_| n_words += 1;
    return switch (cmd) {
        .unknown, .bad, .line, .empty => null,
        .help, .list, .settings, .quit => if (rest.len == 0) cmd else null,
        .shell => |sh| if (sh.cwd != null or n_words <= 1) cmd else null,
        .close, .clear => if (rest.len == 0 or exactTarget(rest)) cmd else null,
        // show: App checks that the file exists.
        .focus, .zoom, .colors, .show, .run => cmd,
        else => null,
    };
}

fn exactTarget(s: []const u8) bool {
    if (eq(s, "all") or eq(s, "*") or eq(s, ".") or eq(s, "this")) return true;
    _ = std.fmt.parseInt(u32, std.mem.trimStart(u8, s, "#"), 10) catch return false;
    return true;
}

fn target(s: []const u8, default: Target) Target {
    if (s.len == 0) return default;
    if (eq(s, "all") or eq(s, "*")) return .all;
    if (eq(s, ".") or eq(s, "this")) return .focused;
    const n = std.fmt.parseInt(u32, std.mem.trimStart(u8, s, "#"), 10) catch return default;
    return .{ .id = n };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "exact gtty commands (AI on)" {
    const t = std.testing;
    try t.expect(parseExact("s") != null);
    try t.expectEqualStrings("~/src", parseExact("s --cwd '~/src'").?.shell.cwd.?);
    try t.expect(parseExact("close 3") != null);
    try t.expect(parseExact("close #3") != null);
    try t.expect(parseExact("close the finished windows") == null);
    try t.expect(parseExact("focus 2") != null);
    try t.expect(parseExact("focus the editor") == null);
    try t.expect(parseExact("list") != null);
    try t.expect(parseExact("list all pdf files here") == null);
    try t.expect(parseExact("shell out to bash please") == null);
    try t.expect(parseExact("copy my docs") == null);
    try t.expect(parseExact("wait 300") == null);
}

test "parse prompt lines and gtty commands" {
    const t = std.testing;
    try t.expect(parse("ls -la") == .line);
    try t.expect(parse("gt sh") == .line); // the old prefix is just a word now
    try t.expect(parse("/") == .help);
    try t.expect(parse("/sh") == .shell);
    try t.expect(parse("/bin/ls -l") == .line); // a path, not a gtty command
    try t.expectEqualStrings("bash", parse("/shell bash").shell.program.?);
    try t.expect(parse("/close").close == .all);
    try t.expectEqual(@as(u32, 3), parse("/close 3").close.id);
    try t.expectEqualStrings("make -j8", parse("/run make -j8").run);
    try t.expectEqual(@as(f32, 1.5), parse("/zoom 150%").zoom.set);
    try t.expectEqualStrings("echo hi", parse("/type echo hi").type);
    try t.expectEqual(@as(f32, 40), parse("/click 40 600").click.x);
    try t.expect(parse("/click 40") == .bad);
    try t.expectEqual(@as(f32, 600), parse("/rclick 40 600").rclick.y);
    try t.expectEqual(@as(f32, 300), parse("/drag 10 20 300 40").drag[2]);
    try t.expect(parse("/drag 10 20") == .bad);
    try t.expectEqual(@as(f32, 7), parse("/move 5 7").move.y);
    try t.expectEqual(@as(f32, 9), parse("/dclick 8 9").dclick.y);
    try t.expectEqual(@as(f32, 3), parse("/down 3 4").down.x);
    try t.expectEqual(@as(f32, 6), parse("/up 5 6").up.y);
    try t.expectEqual(@as(f32, 600), parse("/resize 800 600").resize[1]);
    try t.expect(parseGtty("resize 800 600", false) == .unknown);
    try t.expectEqualStrings("ctrl+shift+left", parse("/key ctrl+shift+left").key);
    try t.expectEqualStrings("echo hi", parse("/text echo hi").text);
    try t.expect(parse("/nosuch") == .unknown);
    try t.expect(parseGtty("s", false) == .shell);
    try t.expect(parse("  ") == .empty);
    // Without the slash (after the OS said no):
    try t.expect(parseGtty("quit", false) == .quit);
    try t.expect(parseGtty("frobnicate now", false) == .unknown);
    // Script hooks need the slash:
    try t.expect(parseGtty("ls -l", false) == .unknown);
    try t.expect(parseGtty("wait", false) == .unknown);
    try t.expect(parseGtty("type ls", false) == .unknown);
    try t.expect(parse("/wait 100").wait == 100);
    try t.expect(parse("/colors").colors == null);
    try t.expect(parse("/colors off").colors.? == false);
    try t.expect(parseGtty("colors on", false).colors.? == true);
    try t.expect(parse("/colors red") == .bad);
    // show: the rest of the line is the file; -a picks the app.
    try t.expectEqualStrings("my notes.txt", parseGtty("show my notes.txt", false).show.path);
    try t.expect(!parseGtty("show a.txt", false).show.pick);
    try t.expectEqualStrings("/tmp/a b.pdf", parse("/show -a \"/tmp/a b.pdf\"").show.path);
    try t.expect(parse("/show -a x").show.pick);
    try t.expect(parseGtty("show", false) == .bad);
    try t.expect(parseGtty("show -a", false) == .bad);
    try t.expect(parseGtty("settings", false) == .settings);
    try t.expect(parse("/menu run").menu == .run);
    try t.expect(parse("/menu sub 0") == .bad);
    try t.expect(parse("/menu x") == .bad);
    try t.expect(parseGtty("menu run", false) == .unknown);
    try t.expect(parse("/target settings").target == .settings);
    try t.expect(parse("/target files") == .bad);
    try t.expectEqualStrings("cmd+shift", parse("/mods cmd+shift").mods);
    // Demo hooks.
    try t.expectEqualStrings("/tmp/f", parse("/record start /tmp/f 20").record.start.dir);
    try t.expectEqual(@as(u32, 15), parse("/record start /tmp/f").record.start.fps);
    try t.expect(parse("/record stop").record == .stop);
    try t.expect(parse("/record") == .bad);
    try t.expectEqual(@as(u32, 400), parse("/glide 10 20").glide.ms);
    try t.expectEqual(@as(u32, 900), parse("/glide 10 20 900").glide.ms);
    try t.expectEqualStrings("/tmp/a b.txt", parse("/drop 10 20 /tmp/a b.txt").drop.path);
    try t.expect(parse("/drop 10 20") == .bad);
    try t.expectEqualStrings("ls -l", parse("/slow ls -l").slow);
    try t.expect(parseGtty("slow ls", false) == .unknown);
    try t.expect(parse("/pace 150").pace == 150);
}
