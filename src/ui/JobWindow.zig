// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! A job window: one on-screen object per running command.
//!
//! The window owns everything about its job:
//!   * the child process and its PTY (stdin, stdout and stderr all on one
//!     terminal, shown as one combined output — no split views),
//!   * the Screen buffer with its output (a memory window of the last N
//!     rows) and the tee file with all of it (core/Tee.zig),
//!   * its own geometry and zoom. When it is moved, resized, zoomed or
//!     moved to a HiDPI display it recomputes its character grid and tells
//!     the child the new size (TIOCSWINSZ → SIGWINCH),
//!   * drawing itself (frame, title bar, buttons, panes, cursor),
//!   * mouse selection of its text, the hover mark in its left gutter and
//!     the scroller mark on its right edge,
//!   * its footer strip with the chips (the git chip: the branch of the
//!     folder its process is in; the peek that opens from it is App's),
//!   * its file opener (`opener`, FileOpener.zig): the mouse on a file or
//!     folder name outlines it; double-click opens it or cd's there, hold
//!     and drag drags the file out.
//!
//! The App only decides *where* windows go and routes input to them.

const std = @import("std");
const trace = @import("../core/trace.zig");
const c = @import("../c.zig").c;
const Process = @import("../core/Process.zig");
const Screen = @import("../core/Screen.zig");
const color = @import("../core/color.zig");
const Theme = color.Theme;
const Rgb = color.Rgb;
const Gfx = @import("../render/Gfx.zig");
const ids = @import("ids.zig");
const Tee = @import("../core/Tee.zig");
const git = @import("../core/git.zig");
const remote = @import("../core/remote.zig");
const RemoteLink = @import("../core/RemoteLink.zig");
const FileOpener = @import("FileOpener.zig");
const FileFx = @import("FileFx.zig");
const Rect = Gfx.Rect;

const JobWindow = @This();

pub const Kind = enum { command, shell };

/// `close` is the red × : close once finished; while running it opens the
/// kill menu, and only `kill` (the skull in that menu) kills the job.
pub const Hit = enum { none, title, close, kill, check, copy, zoom_in, zoom_out, colors, sync, files, minimize, maximize, scroller, git_chip, folder_chip, footer, out };

/// The selection checkbox at the far left of the title (several windows
/// in the windows area): hidden (one window shown), off (in the job grid),
/// on (shown next to the active window), locked (the active window: always
/// selected, drawn checked and dimmed).
pub const Check = enum { hidden, off, on, locked };

pub const Spec = struct {
    kind: Kind,
    title: []const u8,
    argv: []const []const u8,
    cwd: ?[:0]const u8 = null,
    /// Rows kept in memory (the rest is only in the tee file).
    max_lines: usize = Screen.default_max_lines,
    /// Folder for the tee file; null: no tee.
    log_dir: ?[]const u8 = null,
    /// Extra environment for the child, "NAME=value" (shell hooks).
    env: []const [:0]const u8 = &.{},
};

/// Scale shared by all windows: base font size in pixels and the UI scale
/// (1.0 on normal screens, 2.0 on Retina).
pub const Scale = struct {
    base_px: u16 = 14,
    ui: f32 = 1.0,
};

gpa: std.mem.Allocator,
/// Unique window id (see ids.zig).
uid: ids.Id,
/// Serial number of the job window: the #N label the user sees.
serial: u32,
kind: Kind,
title: []u8,
proc: Process,
out: Screen,
/// All of the job's output (the Screen keeps only the last rows).
log: ?Tee.Log = null,
focused: bool = false,
/// Shown over the entire gtty screen (set by App for the main job).
maximized: bool = false,
/// The kill menu (a drop-down under the × with a skull) is open.
kill_menu: bool = false,
/// Draw the colors the program sent (SGR). Off: every cell in the plain
/// text color on the window body; the escape codes stay hidden either
/// way, and the colors come back when turned on again (they are kept).
colors: bool = true,
/// The selection checkbox (set by App before placing the window).
check: Check = .hidden,
/// Selecting it failed (no room in the windows area): the check shows red
/// until this time.
check_err_until: u64 = 0,
/// When the job was asked to stop (SIGHUP); SIGKILL follows if it is
/// still alive after `hard_kill_ms`.
kill_ms: u64 = 0,
/// The user closed this shell window while it ran (× or `close`): it is
/// ended like `exit 0`, so it shows as a success whatever the hangup gives.
closed_by_user: bool = false,
/// Folders the shell left, newest first (`folder_history_max`; the
/// right-click menu's History ▸). From the shell's folder reports (OSC 7,
/// gtty's hooks), else the process's folder (`refreshChips`).
folders_left: std.ArrayList([]u8) = .empty,
/// The folder it is in now, as last seen.
folder_now: std.ArrayList(u8) = .empty,
/// The shell reports its folder (OSC 7): the process folder isn't used.
folder_reports: bool = false,
/// Bumped on every move to another folder; App's AI memory notes the
/// folder when it differs from `mem_seq` (and the ssh destination when
/// its hash differs from `mem_host`).
folder_seq: u32 = 0,
mem_seq: u32 = 0,
mem_host: u64 = 0,
folder_gen: u32 = 0,
/// `out.done_seq` when names were last looked for (`colorNames`).
folders_done: u32 = 0,
/// The last listing command the user ran in this shell (`ls -l`, `ll`,
/// …; `isListing`), run again after a file action (`refreshListing`),
/// and `out.cmd_seq` when commands were last looked at.
ls_cmd_buf: [256]u8 = undefined,
ls_cmd_len: usize = 0,
cmd_seen: u32 = 0,
/// gtty typed a cd (`cdTo`): once it ended well, list the new folder
/// (`refresh_ls`).
list_after_cd: bool = false,
/// Symbolic links `colorNames` found in the output: where, and what they
/// point at (the hover box, `linkAt`). The newest `links_max`.
links: std.ArrayList(Link) = .empty,

rect: Rect = .{},
zoom: f32 = 1.0,
scale: Scale = .{},
cols: u16 = 80,
rows: u16 = 24,
/// Content cell size in pixels (from relayout), for mouse → cell.
cell_w: f32 = 1,
cell_h: f32 = 1,

/// What the held left mouse button is doing: selecting text, or dragging
/// the scroller thumb (`grab` = where on the thumb it was taken).
drag: enum { none, select, scroller } = .none,
grab: f32 = 0,
/// The mouse is over the scroller (its thumb is drawn wider).
over_scroller: bool = false,
/// When the user last scrolled; the "↑ N" label shows for a while after.
scroll_ms: u64 = 0,
scroll_seen: u32 = 0,
/// The text version last seen by `textChanged`.
seen_version: u64 = 0,
/// ⌘-click on file and folder names (outline, help line, remote checks).
opener: FileOpener = .{},
/// The title-bar copy just took rows [first, end): a white flash over
/// them, then a "Copied" bubble in their middle (`drawCopyFlash`).
copy_flash: ?struct { first: usize, end: usize, ms: u64 } = null,
/// What a mouse action just did to this window's folder's files (a drop
/// copied in, …): the same flash and bubble as the copy (`drawFileFx`).
file_fx: ?FileFx = null,
/// File names put on gtty's file clipboard (copy / cut): a white flash
/// over just those names (`flashNames`, `drawNameFlash`).
/// When the folder chip's name / path was copied (its menu): the chip
/// flashes white; 0 = not flashing.
chip_flash_ms: u64 = 0,
name_flash: ?struct { ranges: [16]Screen.TextRange = undefined, n: usize = 0, ms: u64 } = null,
/// When the user last typed into a program without shell marks (its echo
/// counts as input for a short while: `Screen.echo`).
echo_ms: u64 = 0,
/// When the user last sent the job anything (keys, paste, a typed cd).
key_ms: u64 = 0,
/// When output last came that the user's typing didn't ask for (a build's
/// progress lines being redrawn, …): the cursor stays hidden until the
/// output rests `cursor_rest_ms`, so it doesn't jump around after the
/// redraws (0: resting).
busy_ms: u64 = 0,
/// The selection was made with Shift + arrows in a shell's input line: its
/// head follows the shell's cursor (see `editMove`).
key_sel: bool = false,
/// Sync typing (App.updateSync): the window whose typing goes to the
/// others (`source`), a read-only window that gets it (`follower`), or
/// not in it.
sync: Sync = .off,
/// Something was about to be typed into this read-only window (a paste,
/// a cd, a drop) and was dropped: App says so once.
sync_refused: bool = false,

// Layout cache (pixels), recomputed by relayout().
title_r: Rect = .{},
out_r: Rect = .{},
/// The marks strip left of the text (input / output / AI rows); empty when
/// the marks are off.
marks_r: Rect = .{},
/// Thin strip right of the text with the scroller mark.
scroller_r: Rect = .{},
close_r: Rect = .{},
check_r: Rect = .{}, // empty while hidden
copy_r: Rect = .{}, // empty while a command runs (a shell always has it)
zoom_out_r: Rect = .{}, // text size: A− (down to 100%) and A+
zoom_in_r: Rect = .{},
colors_r: Rect = .{}, // colors on / off (windows area only)
sync_r: Rect = .{}, // sync typing on / off (windows area only)
files_r: Rect = .{}, // the folder in the file manager (windows area only)
/// Where the content actions end (the serial badge follows).
actions_end: f32 = 0,
min_r: Rect = .{},
max_r: Rect = .{},
skull_r: Rect = .{}, // the kill menu, under the ×

started_ms: u64 = 0,
ended_ms: u64 = 0,
/// Last window activity, a timestamp in ms (SDL_GetTicks: since gtty
/// started; monotonic, so a clock change can't reorder the grid): opened,
/// gained focus, moved into or out of the windows area (minimized,
/// swapped), maximized / restored, asked to close / kill, finished. The
/// job grid lists newest first.
last_activity_ms: u64 = 0,

/// Set while the window sits in the job grid: the on-screen cell
/// it is shown in, scaled down. `rect` keeps the full (main-area) size, so
/// the program's terminal size doesn't change when it moves in or out.
/// (Grid windows keep `rect` at x = y = 0, which is where the offscreen
/// render draws them.)
grid_r: ?Rect = null,
/// Window transition: where the window was on screen when it started
/// moving (grid ↔ windows area, maximize, reorder), and when. While set,
/// App draws it moving from there to its place (`animRect`).
anim_from: ?Rect = null,
anim_ms: u64 = 0,
/// Offscreen render of the full-size window, used for the scaled-down view.
thumb: ?*c.SDL_Texture = null,

/// Chips (footer strip): the folder the job's process is in (a shell's
/// `cd` is followed) and the git branch there (empty: not in a repo, no
/// git chip). Re-read once a second while the window is in the windows
/// area and its job runs.
cwd_buf: [4096]u8 = undefined,
cwd_len: usize = 0,
/// In a remote session (ssh / mosh in front): its destination, as typed
/// (empty: local). Checked with the chips, once a second.
remote_buf: [256]u8 = undefined,
remote_len: usize = 0,
/// gtty's own connection to that machine (RemoteLink), made for the
/// user's ssh process `link_pid` (a new ssh: a new link); its command line,
/// environment and folder, copied for the link and for copying files.
link: ?*RemoteLink = null,
link_pid: c_int = 0,
link_args: []u8 = &.{},
link_env: []u8 = &.{},
link_cwd: []u8 = &.{},
/// The user's local port of that ssh (finds their shell over there).
link_port: u16 = 0,
/// gtty couldn't connect (or the connection broke): the remote helpers
/// (file opener, git chip) are off until this ssh session ends; no retry.
link_off: bool = false,
/// App said so (once per session).
link_off_said: bool = false,
/// Over there: the folder of the program in front on the user's
/// terminal ("" unknown), and whether that program is a shell waiting.
rcwd_buf: [4096]u8 = undefined,
rcwd_len: usize = 0,
remote_idle: bool = false,
/// Over there, the user went on elsewhere (another ssh, a container
/// shell, another user): the folder is unknown, helpers are off until
/// they're back.
remote_away: bool = false,
info_next_ms: u64 = 0,
info_id: ?u32 = null,
/// Remote files copied so far (numbered folders for the copies).
copies: u32 = 0,
branch_buf: [256]u8 = undefined,
branch_len: usize = 0,
chips_next_ms: u64 = 0,
/// Footer strip under the text, and the git and folder chips in it (empty
/// when hidden).
foot_r: Rect = .{},
git_chip_r: Rect = .{},
folder_chip_r: Rect = .{},
/// The mouse is over a chip / its peek is open (drawn lighter).
over_git_chip: bool = false,
git_peek_open: bool = false,
over_folder_chip: bool = false,
folder_peek_open: bool = false,

pub fn create(gpa: std.mem.Allocator, gfx: *Gfx, uid: ids.Id, serial: u32, spec: Spec, rect: Rect, scale: Scale) !*JobWindow {
    const w = try gpa.create(JobWindow);
    errdefer gpa.destroy(w);
    w.* = .{
        .gpa = gpa,
        .uid = uid,
        .serial = serial,
        .kind = spec.kind,
        .title = try gpa.dupe(u8, spec.title),
        .proc = .{},
        .out = Screen.init(gpa),
        .log = if (spec.log_dir) |d| Tee.Log.open(gpa, d, serial) catch null else null,
        .rect = rect,
        .scale = scale,
        .started_ms = c.SDL_GetTicks(),
        .last_activity_ms = c.SDL_GetTicks(),
    };
    errdefer gpa.free(w.title);
    errdefer if (w.log) |*l| l.close(gpa);
    w.out.max_lines = spec.max_lines;
    // The folder it starts in, until the process can be asked.
    if (spec.cwd) |d| {
        w.cwd_len = @min(d.len, w.cwd_buf.len);
        @memcpy(w.cwd_buf[0..w.cwd_len], d[0..w.cwd_len]);
    } else if (c.getcwd(&w.cwd_buf, w.cwd_buf.len)) |p| w.cwd_len = std.mem.len(p);
    w.branch_len = git.branch(w.cwd_buf[0..w.cwd_len], &w.branch_buf).len;
    // Work out the grid first so the child starts with the right size.
    try w.relayout(gfx);
    w.proc = try Process.spawn(gpa, .{
        .argv = spec.argv,
        .split_stderr = false,
        .cols = w.cols,
        .rows = w.rows,
        .cwd = spec.cwd,
        .env = spec.env,
    });
    return w;
}

pub fn destroy(w: *JobWindow, reaper: *Process.Reaper) void {
    if (w.thumb) |t| c.SDL_DestroyTexture(t);
    w.endRemote();
    w.proc.terminate(reaper);
    if (w.log) |*l| l.close(w.gpa);
    for (w.folders_left.items) |d| w.gpa.free(d);
    w.folders_left.deinit(w.gpa);
    for (w.links.items) |l| w.gpa.free(l.target);
    w.links.deinit(w.gpa);
    w.folder_now.deinit(w.gpa);
    w.out.deinit();
    w.gpa.free(w.title);
    w.gpa.destroy(w);
}

// ------------------------------------------------------------ process I/O

/// Drain pending output from the child into the screen. Returns true if
/// anything changed (new output or exit).
pub fn pump(w: *JobWindow, gfx: *Gfx) bool {
    var changed = false;
    var buf: [16 * 1024]u8 = undefined;
    // Keep the UI responsive under floods (cat /dev/random): stop after a
    // byte budget or a time budget, whichever comes first; the rest waits
    // in the PTY (the child blocks on write) until the next frame.
    var budget: usize = 512 * 1024;
    const deadline = c.SDL_GetTicksNS() + pump_ns;
    if (w.out.echo and c.SDL_GetTicks() -| w.echo_ms > echo_ms_max) w.out.echo = false;
    // A program redrawing its screen (docker's progress, …) writes a frame
    // in many small writes: while they keep coming (`settle_ms` apart at
    // most), read on, so a half-drawn frame isn't shown (the text would
    // seem to jump).
    while (budget > 0 and c.SDL_GetTicksNS() < deadline) {
        const chunk = w.proc.read(.out, &buf) orelse {
            if (!changed or !w.proc.waitOutput(settle_ms)) break;
            continue;
        };
        if (w.log) |*l| l.write(chunk);
        w.out.feed(chunk);
        // Answers to the program's queries (cursor position, …) go straight
        // to it: not typing, so neither mirrored nor refused (sync typing).
        const replies = w.out.takeReplies();
        if (replies.len > 0) {
            trace.bytes("to", w.serial, replies);
            w.proc.write(replies);
        }
        // A keyboard selection ends where the shell put its cursor.
        if (w.key_sel) if (w.out.sel) |*sel| {
            sel.head = w.cursorPos();
        };
        budget -|= chunk.len;
        changed = true;
    }
    if (changed) if (w.log) |*l| l.flush(); // readable from outside as it comes
    if (changed) {
        const now = c.SDL_GetTicks();
        if (now -| w.key_ms > echo_wait_ms) w.busy_ms = now;
    }
    // A command started: a listing one is remembered (`refreshListing`).
    if (w.out.cmd_seq != w.cmd_seen) {
        w.cmd_seen = w.out.cmd_seq;
        const cmd = w.out.lastCommand();
        if (isListing(cmd) and cmd.len <= w.ls_cmd_buf.len) {
            @memcpy(w.ls_cmd_buf[0..cmd.len], cmd);
            w.ls_cmd_len = cmd.len;
        }
    }
    // A command in the shell ended: its output, if plain, gets its folder
    // names colored.
    if (w.out.done_seq != w.folders_done) {
        w.folders_done = w.out.done_seq;
        if (w.list_after_cd) {
            w.list_after_cd = false;
            if ((w.out.done_status orelse 0) == 0) _ = w.listFolder(true);
        }
        if (!w.out.done_colored) if (w.out.out_rows) |r| if (r.end) |e| w.colorNames(r.start, e);
    }
    if (w.out.osc_cwd_gen != w.folder_gen) {
        w.folder_gen = w.out.osc_cwd_gen;
        w.folder_reports = true;
        w.noteFolder(w.out.reportedFolder());
    }
    if (w.kill_ms != 0 and w.proc.running() and c.SDL_GetTicks() - w.kill_ms > hard_kill_ms) {
        w.proc.killHard();
    }
    if (w.proc.pollExit()) {
        if (w.closed_by_user) w.proc.exit_code = 0;
        w.ended_ms = c.SDL_GetTicks();
        if (w.kill_ms == 0) w.last_activity_ms = w.ended_ms; // a close / kill request already counted
        w.kill_menu = false;
        // A job without shell marks (run from the prompt): all its output.
        if (!w.out.has_marks and !w.out.colored) w.colorNames(0, w.out.lines.items.len);
        w.relayout(gfx) catch {}; // title-bar buttons change (copy appears)
        changed = true;
    }
    return changed;
}

/// A command line that only lists files, safe to run again: its first
/// word is a listing program, and it has no pipes, redirections, lists
/// or substitutions (`ls > x` must not run twice).
fn isListing(cmd: []const u8) bool {
    if (cmd.len == 0 or std.mem.indexOfAny(u8, cmd, ";|&<>`$()\n") != null) return false;
    const end = std.mem.indexOfScalar(u8, cmd, ' ') orelse cmd.len;
    const first = cmd[0..end];
    for ([_][]const u8{ "ls", "ll", "la", "l", "lsd", "exa", "eza", "tree", "dir", "vdir", "gls" }) |name| {
        if (std.mem.eql(u8, first, name)) return true;
    }
    return false;
}

test "listing commands" {
    try std.testing.expect(isListing("ls"));
    try std.testing.expect(isListing("ls -la sub"));
    try std.testing.expect(isListing("ll"));
    try std.testing.expect(!isListing("ls > x"));
    try std.testing.expect(!isListing("ls | wc"));
    try std.testing.expect(!isListing("lsof"));
    try std.testing.expect(!isListing("cat x"));
    try std.testing.expect(optionsOnly("ls -la"));
    try std.testing.expect(!optionsOnly("ls -la sub"));
}

/// Only options after the program name (`ls -la`, not `ls -la sub`):
/// the same listing works in another folder.
fn optionsOnly(cmd: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    _ = it.next();
    while (it.next()) |a| if (a[0] != '-') return false;
    return true;
}

/// After a file action: run the last listing command again (else `ls`)
/// so the output shows the folder as it is now.
pub fn refreshListing(w: *JobWindow) bool {
    return w.listFolder(false);
}

/// Run the last listing command (`new_folder`: after a cd, only one with
/// no names in it; else `ls`). Only in a shell waiting at its prompt
/// with nothing typed yet (that would be wiped), not a read-only window,
/// not remote; `refresh_ls` on. True when it was sent.
fn listFolder(w: *JobWindow, new_folder: bool) bool {
    if (!refresh_ls or w.sync == .follower or !w.atPrompt() or w.out.inputPending()) return false;
    var rbuf: [4096]u8 = undefined;
    if (w.remoteNow(&rbuf) != null) return false;
    const last = w.ls_cmd_buf[0..w.ls_cmd_len];
    const cmd = if (last.len > 0 and (!new_folder or optionsOnly(last))) last else "ls";
    var buf: [300]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\x15{s}\r", .{cmd}) catch return false;
    w.typeBytes(line);
    return true;
}

/// A symbolic link in the output (`links`).
pub const Link = struct {
    range: Screen.TextRange,
    /// Where it points: the real path (absolute; a broken link: its
    /// target as written, made absolute).
    target: [:0]u8,
    folder: bool,
    /// The target is gone.
    broken: bool,
};
const links_max = 256;

/// Folder and link names in plain output rows [start, end) (the program
/// printed no colors): folders in the focus blue, symbolic links with a
/// dash of pink (`Screen.markNames`); links are kept in `links`. Names
/// are taken relative to the window's folder; nothing in a remote
/// session.
fn colorNames(w: *JobWindow, start: usize, end: usize) void {
    if (!color_folders) return;
    var rbuf: [4096]u8 = undefined;
    if (w.remoteNow(&rbuf) != null) return;
    var dbuf: [4096]u8 = undefined;
    var ctx: NameCtx = .{ .w = w, .dir = w.folder(&dbuf) };
    _ = w.out.markNames(start, end, &ctx);
}

const NameCtx = struct {
    w: *JobWindow,
    dir: []const u8,

    pub fn kind(n: *NameCtx, name: []const u8) Screen.NameKind {
        if (std.mem.eql(u8, name, "/")) return .none; // "a / b"
        var pbuf: [4096]u8 = undefined;
        const p = FileOpener.resolve(&pbuf, n.dir, std.mem.trimEnd(u8, name, "/")) orelse return .none;
        var st: c.struct_stat = undefined;
        if (c.lstat(p.ptr, &st) != 0) return .none;
        const dir = FileOpener.kindOf(p) == .folder;
        if (st.st_mode & 0o170000 == 0o120000) return if (dir) .link_folder else .link_file; // S_ISLNK
        return if (dir) .folder else .none;
    }

    pub fn found(n: *NameCtx, k: Screen.NameKind, range: Screen.TextRange, name: []const u8) void {
        if (k != .link_file and k != .link_folder) return;
        const gpa = n.w.gpa;
        var pbuf: [4096]u8 = undefined;
        const p = FileOpener.resolve(&pbuf, n.dir, std.mem.trimEnd(u8, name, "/")) orelse return;
        var tbuf: [4096]u8 = undefined;
        var broken = false;
        const target: []const u8 = if (c.realpath(p.ptr, &tbuf)) |r| std.mem.span(r) else blk: {
            broken = true;
            var lbuf: [4096]u8 = undefined;
            const len = c.readlink(p.ptr, &lbuf, lbuf.len);
            if (len <= 0) return;
            const raw = lbuf[0..@intCast(len)];
            const parent = std.fs.path.dirname(p) orelse "/";
            break :blk FileOpener.resolve(&tbuf, parent, raw) orelse return;
        };
        const owned = gpa.dupeZ(u8, target) catch return;
        const links = &n.w.links;
        if (links.items.len >= links_max) gpa.free(links.orderedRemove(0).target);
        links.append(gpa, .{ .range = range, .target = owned, .folder = k == .link_folder, .broken = broken }) catch gpa.free(owned);
    }
};

/// The symbolic link name (colored, in the windows area) at (x, y).
pub fn linkAt(w: *const JobWindow, x: f32, y: f32) ?*const Link {
    const p = w.textPosAt(x, y) orelse return null;
    var i = w.links.items.len;
    while (i > 0) {
        i -= 1;
        if (w.links.items[i].range.contains(p)) return &w.links.items[i];
    }
    return null;
}

pub const Sync = enum { off, source, follower };

/// Sync typing: what the source window gets typed is also typed into the
/// read-only windows (App sets it; `src` is the source window).
pub const SyncHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, src: *JobWindow, bytes: []const u8) void,
};
pub var sync_hook: ?SyncHook = null;

/// Send keyboard input / a command line to the child's stdin.
pub fn send(w: *JobWindow, bytes: []const u8) void {
    if (w.sync == .follower) {
        w.sync_refused = true;
        return;
    }
    w.key_ms = c.SDL_GetTicks();
    w.proc.write(bytes);
    w.mirror(bytes);
}

/// Keyboard input from the user: jump back to the live output, then send.
/// A read-only window (sync typing) takes nothing but the source window's
/// typing (`syncBytes`); what the source gets typed goes to them too.
pub fn typeBytes(w: *JobWindow, bytes: []const u8) void {
    if (w.sync == .follower) {
        w.sync_refused = true;
        return;
    }
    w.input(bytes);
    w.mirror(bytes);
}

/// The source window's typing, into a read-only window.
pub fn syncBytes(w: *JobWindow, bytes: []const u8) void {
    if (w.sync == .follower) w.input(bytes);
}

fn mirror(w: *JobWindow, bytes: []const u8) void {
    if (w.sync != .source) return;
    if (sync_hook) |h| h.f(h.ctx, w, bytes);
}

fn input(w: *JobWindow, bytes: []const u8) void {
    trace.bytes("to", w.serial, bytes);
    // A program without shell marks (or one running in a shell): what it
    // echoes back is the user's.
    if (!w.out.has_marks or w.out.zone == .output) {
        w.out.echo = true;
        w.echo_ms = c.SDL_GetTicks();
    }
    w.out.scroll = 0;
    w.key_ms = c.SDL_GetTicks();
    w.proc.write(bytes);
}

/// Paste text into the job, as a terminal does: it replaces a selection
/// in the shell's input line (`deleteSel`), line ends go as CR (Enter), and when the program asked for
/// bracketed paste (zsh, bash, vim) the text is wrapped in ESC[200~ …
/// ESC[201~ so a multi-line paste lands in the input line instead of
/// running line by line. ESC bytes in the text are dropped so it can't end
/// the bracket early or send control sequences.
pub fn paste(w: *JobWindow, gpa: std.mem.Allocator, text: []const u8) void {
    _ = w.deleteSel();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const bracket = w.out.bracketed_paste;
    buf.ensureTotalCapacity(gpa, text.len + 12) catch return;
    if (bracket) buf.appendSliceAssumeCapacity("\x1b[200~");
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const b = text[i];
        switch (b) {
            0x1b => {},
            '\r' => {
                buf.append(gpa, '\r') catch return;
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
            },
            '\n' => buf.append(gpa, '\r') catch return,
            else => buf.append(gpa, b) catch return,
        }
    }
    if (bracket) buf.appendSlice(gpa, "\x1b[201~") catch return;
    w.typeBytes(buf.items);
}

pub fn running(w: *const JobWindow) bool {
    return w.proc.running();
}

// ------------------------------------------------------------ input line

/// A shell (with gtty's hooks) waiting at its prompt: the user is editing
/// its input line, so gtty can offer word jumps and selecting with Shift.
pub fn atPrompt(w: *const JobWindow) bool {
    return w.kind == .shell and w.proc.running() and w.out.at_prompt;
}

pub const Move = enum { left, right, word_left, word_right, home, end };

fn cursorPos(w: *const JobWindow) Screen.Pos {
    return .{ .row = w.out.cur_row, .col = w.out.cur_col };
}

/// Move the shell's cursor in its input line (the shell does the moving:
/// words are its words). With `select`, the selection grows from where the
/// cursor was to where the shell puts it; without, it goes away.
pub fn editMove(w: *JobWindow, m: Move, select: bool) void {
    if (select) {
        if (!w.key_sel or w.out.sel == null) {
            w.out.sel = .{ .anchor = w.cursorPos(), .head = w.cursorPos() };
            w.key_sel = true;
        }
    } else w.dropKeySel();
    // Words, Home and End: the keys gtty's hooks bind (shell_hooks.zig).
    w.typeBytes(switch (m) {
        .left => "\x1b[D",
        .right => "\x1b[C",
        .word_left => "\x1b[1;5D",
        .word_right => "\x1b[1;5C",
        .home => "\x1b[H",
        .end => "\x1b[F",
    });
}

/// Forget a keyboard selection (a mouse selection stays).
pub fn dropKeySel(w: *JobWindow) void {
    if (!w.key_sel) return;
    w.key_sel = false;
    w.out.sel = null;
}

/// Delete the selection from the shell's input line (Backspace, Delete,
/// typing or pasting over it), as a text editor does: a keyboard selection
/// (Shift + arrows), or one made with the mouse that lies in the line being
/// typed (`inputSel`). The shell does the erasing: its cursor goes to the
/// selection's right end, then DEL back to its left end. False when there
/// is no such selection (the key then does what it always does).
pub fn deleteSel(w: *JobWindow) bool {
    if (w.key_sel) {
        const sel = w.out.sel orelse return false;
        w.dropKeySel();
        const a, const b = sel.ordered();
        const n = cellsBetween(w.out.cols, a, b);
        if (n <= 0 or n > 100_000) return false;
        if (sel.head.before(sel.anchor)) w.repeat("\x1b[C", @intCast(n));
        w.repeat("\x7f", @intCast(n));
        return true;
    }
    const a, const b = w.inputSel() orelse return false;
    w.out.sel = null;
    const n = cellsBetween(w.out.cols, a, b);
    if (n <= 0 or n > 100_000) return false;
    // From wherever the cursor is to the selection's right end.
    const d = cellsBetween(w.out.cols, w.cursorPos(), b);
    if (d > 0) w.repeat("\x1b[C", @intCast(d)) else if (d < 0) w.repeat("\x1b[D", @intCast(-d));
    w.repeat("\x7f", @intCast(n));
    return true;
}

/// Cells from `a` to `b` (negative when `b` comes first); the input line
/// may wrap over rows.
fn cellsBetween(cols: u16, a: Screen.Pos, b: Screen.Pos) isize {
    const rows = @as(isize, @intCast(b.row)) - @as(isize, @intCast(a.row));
    return rows * @as(isize, cols) + @as(isize, b.col) - @as(isize, a.col);
}

/// A mouse selection inside the line the user is typing at a shell's
/// prompt: its ends, cut at the end of the typed text. Null when there is
/// none, or the selection reaches into the prompt or earlier output. The
/// typed text is the cells marked as input (after the hooks' prompt-end
/// mark) on the cursor's row and the rows it wraps over.
pub fn inputSel(w: *const JobWindow) ?[2]Screen.Pos {
    if (!w.atPrompt()) return null;
    const sel = w.out.sel orelse return null;
    if (sel.empty()) return null;
    const lines = w.out.lines.items;
    const wrapped = w.out.wrapped.items;
    const cur = w.cursorPos();
    if (cur.row >= lines.len or wrapped.len != lines.len) return null;
    var first = cur.row;
    while (first > 0 and wrapped[first - 1]) first -= 1;
    var last = cur.row;
    while (last + 1 < lines.len and wrapped[last]) last += 1;
    var start: ?Screen.Pos = null;
    var end: Screen.Pos = undefined;
    for (first..last + 1) |r| for (lines[r].items, 0..) |cell, i| if (cell.attrs.zone == .input) {
        const p: Screen.Pos = .{ .row = r, .col = @intCast(i) };
        if (start == null) start = p;
        end = .{ .row = r, .col = @intCast(i + 1) };
    };
    const s = start orelse return null;
    var a, var b = sel.ordered();
    if (a.before(s)) return null;
    if (end.before(b)) b = end;
    if (end.before(a)) a = end;
    if (!a.before(b)) return null;
    return .{ a, b };
}

fn repeat(w: *JobWindow, bytes: []const u8, n: usize) void {
    var buf: [1024]u8 = undefined;
    const per = buf.len / bytes.len;
    var left = n;
    while (left > 0) {
        const k = @min(left, per);
        for (0..k) |i| @memcpy(buf[i * bytes.len ..][0..bytes.len], bytes);
        w.typeBytes(buf[0 .. k * bytes.len]);
        left -= k;
    }
}

/// A setting (the settings window's "Kill: force after").
pub var hard_kill_ms: u64 = 2000;
/// Longest one pump() may spend parsing output per frame.
const pump_ns = 10 * std.time.ns_per_ms;
/// How long `pump` waits for more of a burst of output before drawing.
const settle_ms = 2;

/// Kill the job: hang up first (lets programs clean up); if it is still
/// running `hard_kill_ms` later, pump() kills it hard.
pub fn kill(w: *JobWindow) void {
    w.kill_menu = false;
    if (!w.proc.running() or w.kill_ms != 0) return;
    w.kill_ms = c.SDL_GetTicks();
    w.last_activity_ms = w.kill_ms;
    w.proc.hangup();
}

/// Record an action on the window now (see `last_activity_ms`).
pub fn touch(w: *JobWindow) void {
    w.last_activity_ms = c.SDL_GetTicks();
}

/// Close a running shell window: end the shell like `exit 0` (hang up,
/// hard kill after `hard_kill_ms`; recorded as exit 0).
pub fn endShell(w: *JobWindow) void {
    w.closed_by_user = true;
    w.kill();
}

/// Being stopped (kill or `endShell`) but not gone yet.
pub fn ending(w: *const JobWindow) bool {
    return w.kill_ms != 0 and w.proc.running();
}

// ------------------------------------------------------------ geometry

/// Place the window in the windows area (`grid = null`), or in a grid
/// cell: then `r` is its full size (what the program sees) and `grid` the
/// cell on screen: a normal-size title bar over the scaled-down content.
pub fn place(w: *JobWindow, gfx: *Gfx, r: Rect, grid: ?Rect) void {
    w.grid_r = grid;
    if (grid != null) {
        w.over_scroller = false;
        w.drag = .none;
    }
    w.setRect(gfx, if (grid != null) .{ .x = 0, .y = 0, .w = r.w, .h = r.h } else r);
}

/// Where the window is on screen: its grid cell, or its full rect.
pub fn screenBox(w: *const JobWindow) Rect {
    return w.grid_r orelse w.rect;
}

/// How long a window transition takes (GTTY_ANIM_MS; 0 = no animation).
pub var anim_len_ms: u64 = 220;
/// The left-edge marks (settings / GTTY_MARKS, GTTY_MARK_WIDTH): shown, and
/// their width in points.
pub var marks_on: bool = true;
/// Folder names in output without colors: drawn blue (config
/// `color-folders`, Settings → General; `colorFolders`).
pub var color_folders: bool = true;
/// After a file action done in gtty (paste, delete, trash, rename, a
/// drop): run the shell's last listing command again (config
/// `refresh-ls`, Settings → General; `refreshListing`).
pub var refresh_ls: bool = true;
pub var mark_pt: f32 = 4;
/// Space between the window's frame and the marks strip, in points.
const mark_gap: f32 = 3;
/// Typed into a program without marks: its echo is input this long.
const echo_ms_max = 400;

/// Start a transition from `from` (an on-screen rect) to where it is now.
pub fn animateFrom(w: *JobWindow, from: Rect) void {
    if (anim_len_ms == 0) return;
    w.anim_from = from;
    w.anim_ms = c.SDL_GetTicks();
}

/// The on-screen rect at `now` while moving (eased out), else null.
pub fn animRect(w: *const JobWindow, now: u64) ?Rect {
    const from = w.anim_from orelse return null;
    const t = @as(f32, @floatFromInt(now -| w.anim_ms)) / @as(f32, @floatFromInt(@max(anim_len_ms, 1)));
    if (t >= 1) return null;
    const e = 1 - (1 - t) * (1 - t) * (1 - t);
    const to = w.screenBox();
    return .{
        .x = from.x + (to.x - from.x) * e,
        .y = from.y + (to.y - from.y) * e,
        .w = from.w + (to.w - from.w) * e,
        .h = from.h + (to.h - from.h) * e,
    };
}

/// For a transition out of the windows area: draw this grid window as the
/// full-size window it was, its top left at (x, y). Same size as `rect`,
/// so the terminal size doesn't change. Returns the rect drawn.
pub fn drawFullAt(w: *JobWindow, gfx: *Gfx, theme: *const Theme, x: f32, y: f32) Rect {
    const g = w.grid_r orelse {
        w.draw(gfx, theme);
        return w.rect;
    };
    const saved = w.rect;
    const at: Rect = .{ .x = x, .y = y, .w = saved.w, .h = saved.h };
    w.grid_r = null;
    w.setRect(gfx, at);
    w.draw(gfx, theme);
    w.grid_r = g;
    w.setRect(gfx, saved);
    return at;
}

pub fn setRect(w: *JobWindow, gfx: *Gfx, r: Rect) void {
    w.rect = r;
    w.relayout(gfx) catch {};
}

pub fn setScale(w: *JobWindow, gfx: *Gfx, s: Scale) void {
    w.scale = s;
    w.relayout(gfx) catch {};
}

pub fn setZoom(w: *JobWindow, gfx: *Gfx, z: f32) void {
    // Never below 100%: zoom is for enlarging the text.
    w.zoom = std.math.clamp(z, min_zoom, max_zoom);
    if (w.zoom < min_zoom + 0.01) w.zoom = min_zoom;
    w.relayout(gfx) catch {};
}

pub const min_zoom: f32 = 1.0;
pub const max_zoom: f32 = 3.0;

fn textPx(w: *const JobWindow) u16 {
    const px = @as(f32, @floatFromInt(w.scale.base_px)) * w.zoom;
    return @intFromFloat(@max(@round(px), 6));
}

pub fn textFace(w: *const JobWindow, gfx: *Gfx) !*Gfx.Face {
    return gfx.face(w.textPx());
}

fn chromeFace(w: *const JobWindow, gfx: *Gfx) !*Gfx.Face {
    return gfx.face(chromePx(w.scale));
}

/// Title-bar text size: a bit under the content text, never zoomed.
fn chromePx(scale: Scale) u16 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(scale.base_px)) * 1.03));
}

/// Recompute pane rectangles and the character grid; resize the PTYs if
/// the grid changed.
pub fn relayout(w: *JobWindow, gfx: *Gfx) !void {
    const ui = w.scale.ui;
    const chrome = try w.chromeFace(gfx);
    const f = try w.textFace(gfx);
    const border = borderPx(ui);
    const pad = @round(6 * ui);
    const title_h = titleHeight(chrome, ui);
    const foot_h = footHeight(gfx, w.scale);

    // Content at full size. In the windows area that is on screen; in a
    // grid, `rect` is a virtual full-size window at (0, 0) and the content is
    // drawn scaled down into the cell, so the terminal size stays the same.
    // Left of the text: `mark_gap` px of space inside the frame (measured from its
    // thickest, focused / finished width, `frameWidth`), then the marks
    // strip; right: the scroller strip.
    const inner = w.rect.inset(border);
    const strip = @round(6 * ui);
    const space = frameWidth(ui, true) - border + @max(@round(mark_gap * ui), 1);
    const mark_w: f32 = if (marks_on) @max(@round(mark_pt * ui), 1) else 0;
    const left = space + mark_w + pad;
    const right = border + strip + pad;
    w.out_r = .{
        .x = inner.x + left,
        .y = inner.y + title_h + pad * 0.5,
        .w = @max(inner.w - left - right, 0),
        .h = @max(inner.h - title_h - foot_h - pad * 1.5, 0),
    };
    // Footer strip with the chips, under the text (windows area only; a
    // grid copy shows just the text, but the size stays the same).
    w.foot_r = .{ .x = inner.x, .y = inner.y + inner.h - foot_h, .w = inner.w, .h = foot_h };
    w.marks_r = .{ .x = inner.x + space, .y = w.out_r.y, .w = mark_w, .h = w.out_r.h };
    w.scroller_r = .{ .x = inner.x + inner.w - border - strip, .y = w.out_r.y, .w = strip, .h = w.out_r.h };
    w.cell_w = f.cell_w;
    w.cell_h = f.cell_h;
    const cols: u16 = @intFromFloat(@max(@floor(w.out_r.w / f.cell_w), 2));
    const rows: u16 = @intFromFloat(@max(@floor(w.out_r.h / f.cell_h), 1));
    w.out.resize(cols, rows);
    if (cols != w.cols or rows != w.rows) {
        w.cols = cols;
        w.rows = rows;
        trace.line("resize #{d} {d}x{d}", .{ w.serial, cols, rows });
        if (w.proc.pid > 0) w.proc.resize(cols, rows);
    }

    // The title bar is always normal size, with all its actions: across the
    // top of the window, or across the top of its grid cell.
    w.layoutTitle(chrome, if (w.grid_r) |g| g.inset(border) else inner, title_h);
    w.layoutChips(gfx);
}

/// Text size of the chips: the status bar's small text.
fn chipPx(scale: Scale) u16 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(scale.base_px)) * 0.85));
}

pub fn chipFace(gfx: *Gfx, scale: Scale) !*Gfx.Face {
    return gfx.face(chipPx(scale));
}

/// Height of the footer strip (chips) at this scale.
pub fn footHeight(gfx: *Gfx, scale: Scale) f32 {
    const f = chipFace(gfx, scale) catch return 0;
    return @round(f.cell_h + 8 * scale.ui);
}

/// The git chip's text outside a git repo (dimmed, no peek).
const no_git_label = "git";

/// Longest branch name shown on the chip; the peek shows all of it.
const chip_max_chars = 32;

/// The chips, left in the footer, shown in the windows area while the job
/// runs: the folder chip first (the folder's name; not in a remote
/// session, where the local folder means nothing), then the git chip,
/// always there: the branch inside a git repo, else dimmed (`no_git_label`,
/// no peek).
fn layoutChips(w: *JobWindow, gfx: *Gfx) void {
    w.git_chip_r = .{};
    w.folder_chip_r = .{};
    if (w.grid_r != null or !w.proc.running()) return;
    const f = chipFace(gfx, w.scale) catch return;
    const ui = w.scale.ui;
    const r = w.foot_r;
    const h = r.h - @round(3 * ui);
    const y = r.y + @round(r.h - h - @round(1 * ui));
    var x = r.x + @round(6 * ui);
    if (w.remote_len == 0) if (w.folderName()) |name| {
        w.folder_chip_r = .{ .x = x, .y = y, .w = chipWidth(f, ui, name), .h = h };
        x += w.folder_chip_r.w + @round(6 * ui);
    };
    w.git_chip_r = .{ .x = x, .y = y, .w = chipWidth(f, ui, w.branch() orelse no_git_label), .h = h };
}

fn chipWidth(f: *const Gfx.Face, ui: f32, label: []const u8) f32 {
    const label_w = Gfx.textWidth(f, label[0..chipCut(label)]) + (if (chipCut(label) < label.len) f.cell_w else 0);
    return @round(7 * ui) * 2 + chipIconW(f, ui) + label_w;
}

/// The name of the folder the job is in (the folder chip), or null when
/// not known yet.
pub fn folderName(w: *const JobWindow) ?[]const u8 {
    const d = w.cwd();
    if (d.len == 0) return null;
    const base = std.fs.path.basename(d);
    return if (base.len == 0) "/" else base;
}

/// Bytes of `s` shown on the chip (whole code points, at most
/// `chip_max_chars`).
fn chipCut(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (n == chip_max_chars) return i;
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    }
    return s.len;
}

fn chipIconW(f: *const Gfx.Face, ui: f32) f32 {
    return @round(f.cell_h * 0.8) + @round(5 * ui);
}

/// The folder the job's process is in (where the git chip acts).
pub fn cwd(w: *const JobWindow) []const u8 {
    return w.cwd_buf[0..w.cwd_len];
}

/// The git branch there, or null outside a repo.
pub fn branch(w: *const JobWindow) ?[]const u8 {
    return if (w.branch_len > 0) w.branch_buf[0..w.branch_len] else null;
}

/// Re-read the folder and branch now, at the next tick (e.g. after the
/// git chip switched branches).
pub fn refreshChipsSoon(w: *JobWindow) void {
    w.chips_next_ms = 0;
}

pub const folder_history_max = 10;

/// The shell is in folder `dir` now: the one it left goes on top of the
/// folder history (moved up if already there; the oldest drops off), and
/// `dir` leaves it.
fn noteFolder(w: *JobWindow, dir: []const u8) void {
    if (dir.len == 0 or std.mem.eql(u8, dir, w.folder_now.items)) return;
    if (w.folder_now.items.len > 0) left: {
        const prev = w.folder_now.items;
        for (w.folders_left.items, 0..) |d, i| if (std.mem.eql(u8, d, prev)) {
            w.gpa.free(w.folders_left.orderedRemove(i));
            break;
        };
        const copy = w.gpa.dupe(u8, prev) catch break :left;
        w.folders_left.insert(w.gpa, 0, copy) catch {
            w.gpa.free(copy);
            break :left;
        };
        if (w.folders_left.items.len > folder_history_max) w.gpa.free(w.folders_left.pop().?);
    }
    // The folder it is in now isn't one it left.
    for (w.folders_left.items, 0..) |d, i| if (std.mem.eql(u8, d, dir)) {
        w.gpa.free(w.folders_left.orderedRemove(i));
        break;
    };
    w.folder_now.clearRetainingCapacity();
    w.folder_now.appendSlice(w.gpa, dir) catch {};
    w.folder_seq +%= 1;
}

/// Type `cd -- '<dir>'` + Enter into the shell (Ctrl+U first: whatever
/// was typed on its line goes, so the line is just the cd). For a shell at
/// its prompt (`atPrompt`). When it ended well, the new folder is listed
/// (`refresh_ls`, `listFolder`).
pub fn cdTo(w: *JobWindow, dir: []const u8) void {
    w.cdOnly(dir);
    w.list_after_cd = refresh_ls;
}

/// `cdTo` without the listing after it (the AI: its plan's next step
/// waits for the prompt).
pub fn cdOnly(w: *JobWindow, dir: []const u8) void {
    var buf: [8300]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    out.writeAll("\x15cd -- '") catch return;
    for (dir) |ch| {
        if (ch == '\'') out.writeAll("'\\''") catch return else out.writeByte(ch) catch return;
    }
    out.writeAll("'\r") catch return;
    w.typeBytes(out.buffered());
    w.refreshChipsSoon(); // the git chip follows the new folder
}

/// Type `<cmd> -i -- '<file>' '<dir>'` into the shell, not run (Ctrl+U
/// first, as cdTo): a file dropped from another job window. `dir` null:
/// `.`, the folder the shell is in. `-i`: asks before overwriting.
pub fn typeFileCommand(w: *JobWindow, cmd: []const u8, file: []const u8, dir: ?[]const u8) void {
    var buf: [8400]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    out.print("\x15{s} -i -- ", .{cmd}) catch return;
    quoted(&out, file) catch return;
    out.writeByte(' ') catch return;
    if (dir) |d| quoted(&out, d) catch return else out.writeByte('.') catch return;
    w.typeBytes(out.buffered());
}

/// `s` in single quotes for the shell.
fn quoted(out: *std.Io.Writer, s: []const u8) !void {
    try out.writeByte('\'');
    for (s) |ch| {
        if (ch == '\'') try out.writeAll("'\\''") else try out.writeByte(ch);
    }
    try out.writeByte('\'');
}

/// Run the AI's script `n` (`ai-<n>.sh`, see shell_hooks.zig): types
/// `gtty-ai <n> '<request>'` + Enter into the shell at its prompt (Ctrl+U
/// first, a leading space keeps it out of most histories). Its line and
/// its output get the AI mark.
pub fn runAi(w: *JobWindow, n: u32, request: []const u8) void {
    var buf: [1200]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    out.print("\x15 gtty-ai {d} '", .{n}) catch return;
    var shown: usize = 0;
    for (request) |ch| {
        if (shown >= 900) break;
        shown += 1;
        switch (ch) {
            '\'' => out.writeAll("'\\''") catch return,
            0...0x1f, 0x7f => out.writeByte(' ') catch return,
            else => out.writeByte(ch) catch return,
        }
    }
    out.writeAll("'\r") catch return;
    w.out.ai = .armed;
    w.out.scroll = 0;
    trace.bytes("to", w.serial, out.buffered());
    w.proc.write(out.buffered());
}

/// The remote session the window is in now (ssh / mosh is the program
/// in front on its terminal, or the window's own command), or null.
pub fn remoteNow(w: *const JobWindow, buf: []u8) ?remote.Session {
    if (w.proc.running()) {
        const n = c.gtty_fg_args(w.proc.out_fd, buf.ptr, buf.len);
        if (n > 0) return remote.sessionOfNul(buf[0..@intCast(n)]);
    }
    return remote.sessionOfLine(w.title);
}

/// The remote destination seen at the last check ("" when local).
pub fn remoteDest(w: *const JobWindow) []const u8 {
    return w.remote_buf[0..w.remote_len];
}

/// The remote folder (where the user's shell over there is), or "".
pub fn remoteCwd(w: *const JobWindow) []const u8 {
    return w.rcwd_buf[0..w.rcwd_len];
}

/// The link, once it is logged in.
pub fn linkReady(w: *const JobWindow) ?*RemoteLink {
    const l = w.link orelse return null;
    return if (l.state == .ready) l else null;
}

/// gtty couldn't connect to the remote machine (e.g. it wants a
/// password), or the connection broke: off until the session ends.
pub fn linkFailed(w: *const JobWindow) bool {
    return w.link_off;
}

/// The user's ssh as the link copies it (`argv` holds the arguments).
pub fn linkSpec(w: *const JobWindow, argv: *[64][]const u8) RemoteLink.Spec {
    return .{ .argv = remote.splitNul(w.link_args, argv), .env = w.link_env, .cwd = w.link_cwd };
}

/// A remote session started (the user's ssh `pid`): open gtty's link,
/// copying that ssh's command line, environment and folder.
fn startRemote(w: *JobWindow, pid: c_int) void {
    if (pid == w.link_pid) return; // this session's link (or its failure)
    w.endRemote();
    w.link_pid = pid;
    var abuf: [16384]u8 = undefined;
    const na = c.gtty_proc_args(pid, &abuf, abuf.len);
    if (na <= 0) return;
    const ebuf = w.gpa.alloc(u8, 256 * 1024) catch return;
    defer w.gpa.free(ebuf);
    const ne = c.gtty_proc_env(pid, ebuf.ptr, ebuf.len);
    var cbuf: [4096]u8 = undefined;
    const nc = c.gtty_proc_cwd(pid, &cbuf, cbuf.len);
    w.link_args = w.gpa.dupe(u8, abuf[0..@intCast(na)]) catch return;
    w.link_env = w.gpa.dupe(u8, if (ne > 0) ebuf[0..@intCast(ne)] else "") catch return;
    w.link_cwd = w.gpa.dupe(u8, if (nc > 0) cbuf[0..@intCast(nc)] else w.cwd()) catch return;
    const port = c.gtty_proc_tcp_lport(pid);
    w.link_port = if (port > 0) @intCast(port) else 0;
    var argv: [64][]const u8 = undefined;
    w.link = RemoteLink.open(w.gpa, w.linkSpec(&argv), c.SDL_GetTicks()) catch null;
    if (w.link == null) w.link_off = true;
    w.info_next_ms = 0;
}

/// The remote session is over (or the window goes): close the link and
/// delete the files copied from there.
fn endRemote(w: *JobWindow) void {
    if (w.link) |l| l.close();
    w.link = null;
    _ = w.opener.clear();
    var buf: [4200]u8 = undefined;
    if (w.copiesDir(&buf)) |d| Tee.Dir.removeTree(d);
    w.link_pid = 0;
    w.gpa.free(w.link_args);
    w.gpa.free(w.link_env);
    w.gpa.free(w.link_cwd);
    w.link_args = &.{};
    w.link_env = &.{};
    w.link_cwd = &.{};
    w.rcwd_len = 0;
    w.remote_idle = false;
    w.remote_away = false;
    w.info_id = null;
    w.copies = 0;
    w.link_off = false;
    w.link_off_said = false;
}

/// The connection failed or broke: close it, forget what came from the
/// other machine (folder, branch), and stay off for this session.
fn linkLost(w: *JobWindow, gfx: *Gfx) void {
    if (w.link) |l| l.close();
    w.link = null;
    _ = w.opener.clear();
    w.link_off = true;
    w.rcwd_len = 0;
    w.remote_idle = false;
    w.info_id = null;
    w.branch_len = 0;
    w.layoutChips(gfx);
}

/// Where this session's remote copies go: gtty's temp folder,
/// `remote-<serial>-<ssh pid>/`.
fn copiesDir(w: *const JobWindow, buf: []u8) ?[:0]const u8 {
    if (w.link_pid == 0) return null;
    const log = w.log orelse return null;
    const dir = std.fs.path.dirname(log.path) orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/remote-{d}-{d}", .{ dir, w.serial, w.link_pid }) catch null;
}

/// A new local path for a copy of remote file `rpath` (its folders made):
/// `<copiesDir>/<n>/<file name>`.
pub fn newCopyPath(w: *JobWindow, buf: []u8, rpath: []const u8) ?[:0]const u8 {
    var dbuf: [4200]u8 = undefined;
    const d = w.copiesDir(&dbuf) orelse return null;
    _ = c.mkdir(d.ptr, 0o700);
    w.copies += 1;
    var sbuf: [4300]u8 = undefined;
    const sub = std.fmt.bufPrintZ(&sbuf, "{s}/{d}", .{ d, w.copies }) catch return null;
    if (c.mkdir(sub.ptr, 0o700) != 0) return null;
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ sub, std.fs.path.basename(rpath) }) catch null;
}

/// Each frame: the link's traffic; the remote folder / git info every
/// 2 s while shown. True when the chips changed.
fn tickRemote(w: *JobWindow, gfx: *Gfx, now: u64) bool {
    const l = w.link orelse return false;
    _ = l.poll(now);
    if (l.state == .failed) {
        w.linkLost(gfx);
        return true;
    }
    var changed = false;
    // The file opener's remote checks.
    while (l.take(.files)) |r| {
        defer w.gpa.free(r.text);
        changed = w.opener.remoteReply(w, r.id, r.text) or changed;
    }
    while (l.take(.window)) |r| {
        defer w.gpa.free(r.text);
        if (w.info_id != r.id) continue;
        w.info_id = null;
        changed = w.takeInfo(r.text) or changed;
    }
    if (l.state == .ready and w.grid_r == null and w.info_id == null and now >= w.info_next_ms) {
        w.info_next_ms = now + 2000;
        var sbuf: [4096]u8 = undefined;
        var sw: std.Io.Writer = .fixed(&sbuf);
        remote.infoScript(&sw, w.link_port) catch return changed;
        w.info_id = l.request(.window, sw.buffered());
    }
    if (changed) w.layoutChips(gfx);
    return changed;
}

/// `cwd=`, `idle=1`, `git=` lines from the remote side. True if the
/// branch changed.
fn takeInfo(w: *JobWindow, text: []const u8) bool {
    var rcwd: []const u8 = "";
    var git_b: []const u8 = "";
    var idle = false;
    var away = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "cwd=")) rcwd = line[4..];
        if (std.mem.startsWith(u8, line, "git=")) git_b = line[4..];
        if (std.mem.eql(u8, line, "idle=1")) idle = true;
        if (std.mem.eql(u8, line, "away=1")) away = true;
    }
    const k = @min(rcwd.len, w.rcwd_buf.len);
    @memcpy(w.rcwd_buf[0..k], rcwd[0..k]);
    w.rcwd_len = k;
    w.remote_idle = idle;
    w.remote_away = away;
    const b = git_b[0..@min(git_b.len, w.branch_buf.len)];
    if (std.mem.eql(u8, b, w.branch_buf[0..w.branch_len])) return false;
    @memcpy(w.branch_buf[0..b.len], b);
    w.branch_len = b.len;
    return true;
}

/// Ask the process for its folder and read the branch there. True when
/// either changed. In a remote session the local folder means nothing:
/// the git chip shows the remote folder's branch (from the link).
fn refreshChips(w: *JobWindow) bool {
    var rbuf: [4096]u8 = undefined;
    const dest = if (w.remoteNow(&rbuf)) |r| r.dest else "";
    var changed_remote = false;
    if (!std.mem.eql(u8, dest, w.remoteDest())) {
        const k = @min(dest.len, w.remote_buf.len);
        @memcpy(w.remote_buf[0..k], dest[0..k]);
        w.remote_len = k;
        changed_remote = true;
        w.branch_len = 0; // the other machine's branch comes from the link
    }
    if (w.remote_len > 0) {
        const pid = c.gtty_fg_pid(w.proc.out_fd);
        if (pid > 0) w.startRemote(pid);
        return changed_remote;
    }
    if (w.link_pid != 0) w.endRemote();
    var buf: [4096]u8 = undefined;
    const n = c.gtty_proc_cwd(w.proc.pid, &buf, buf.len);
    var changed = changed_remote;
    if (n > 0) {
        const d = buf[0..@intCast(n)];
        if (!std.mem.eql(u8, d, w.cwd())) {
            @memcpy(w.cwd_buf[0..d.len], d);
            w.cwd_len = d.len;
            changed = true;
            if (!w.folder_reports) w.noteFolder(d);
        }
    }
    var bbuf: [256]u8 = undefined;
    const b = git.branch(w.cwd(), &bbuf);
    if (!std.mem.eql(u8, b, w.branch_buf[0..w.branch_len])) {
        @memcpy(w.branch_buf[0..b.len], b);
        w.branch_len = b.len;
        changed = true;
    }
    return changed;
}

fn borderPx(ui: f32) f32 {
    return @max(@round(1 * ui), 1);
}

/// The frame's drawn width: 2 px when focused or finished, else 1 px.
fn frameWidth(ui: f32, thick: bool) f32 {
    return if (thick) @max(@round(2 * ui), 2) else borderPx(ui);
}

fn titleHeight(chrome: *const Gfx.Face, ui: f32) f32 {
    return @round(chrome.cell_h + 8 * ui);
}

/// Height of the title bar plus the frame (top and bottom) at this scale:
/// a grid cell is this plus the scaled-down content.
pub fn chromeHeight(gfx: *Gfx, scale: Scale) f32 {
    const chrome = gfx.face(chromePx(scale)) catch return 0;
    return titleHeight(chrome, scale.ui) + 2 * borderPx(scale.ui);
}

/// Smallest usable window at this scale (gtty's text size, not a window's
/// own zoom): `cols` × `rows` of text with the title bar and the frame.
pub fn minSize(gfx: *Gfx, scale: Scale, cols: u16, rows: u16) struct { w: f32, h: f32 } {
    const ui = scale.ui;
    const chrome = gfx.face(chromePx(scale)) catch return .{ .w = 1, .h = 1 };
    const f = gfx.face(scale.base_px) catch return .{ .w = 1, .h = 1 };
    const border = borderPx(ui);
    const pad = @round(6 * ui);
    const side = border + @round(6 * ui) + pad;
    return .{
        .w = 2 * border + 2 * side + @as(f32, @floatFromInt(cols)) * f.cell_w,
        .h = 2 * border + titleHeight(chrome, ui) + footHeight(gfx, scale) + pad * 1.5 + @as(f32, @floatFromInt(rows)) * f.cell_h,
    };
}

/// Selecting failed: show the check red for a moment.
pub fn flashCheck(w: *JobWindow) void {
    w.check_err_until = c.SDL_GetTicks() + check_err_ms;
}

const check_err_ms = 2000;

/// Title bar: content actions on the left ([copy], finished or a shell; text
/// size [A−] [A+]; [colors] on / off; [sync] typing on / off; [files] of the folder), then the title; window actions on the right: [minimize] [maximize], a gap, and the
/// red [×] (close, or kill via its menu while running).
fn layoutTitle(w: *JobWindow, chrome: *const Gfx.Face, inner: Rect, title_h: f32) void {
    const ui = w.scale.ui;
    w.title_r = .{ .x = inner.x, .y = inner.y, .w = inner.w, .h = title_h };
    const icon = @round(chrome.cell_h * 0.95);
    const iy = inner.y + @round((title_h - icon) / 2);
    const gap = @round(4 * ui);
    const edge = @round(6 * ui);
    w.check_r = .{ .x = inner.x + edge, .y = iy, .w = if (w.check == .hidden) 0 else icon, .h = icon };
    const cx = if (w.check_r.w > 0) w.check_r.x + icon + gap else w.check_r.x;
    w.copy_r = .{ .x = cx, .y = iy, .w = if (w.proc.running() and w.kind != .shell) 0 else icon, .h = icon };
    const zx = if (w.copy_r.w > 0) w.copy_r.x + w.copy_r.w + gap else w.copy_r.x;
    if (w.grid_r != null) {
        // In the job grid only the checkbox and copy (the text-size and
        // color actions come back in the windows area).
        w.zoom_out_r = .{};
        w.zoom_in_r = .{};
        w.colors_r = .{};
        w.sync_r = .{};
        w.files_r = .{};
        w.actions_end = if (w.copy_r.w > 0 or w.check_r.w > 0) zx - gap else inner.x + edge;
    } else {
        const zw = @round(icon * 1.3); // room for the letter and its sign
        w.zoom_out_r = .{ .x = zx, .y = iy, .w = zw, .h = icon };
        w.zoom_in_r = .{ .x = zx + zw + gap, .y = iy, .w = zw, .h = icon };
        // A labeled pill ("color"), so the action reads at a glance.
        const cw = @round(chrome.cell_w * colors_label.len + 8 * ui);
        w.colors_r = .{ .x = w.zoom_in_r.x + zw + gap, .y = iy, .w = cw, .h = icon };
        // A checkbox and the word, so it reads as an option to tick.
        const sw = @round(icon + chrome.cell_w * sync_label.len + 8 * ui);
        w.sync_r = .{ .x = w.colors_r.x + cw + gap, .y = iy, .w = sw, .h = icon };
        w.files_r = .{ .x = w.sync_r.x + sw + gap, .y = iy, .w = icon, .h = icon };
        w.actions_end = w.files_r.x + w.files_r.w;
    }
    w.close_r = .{ .x = inner.x + inner.w - edge - icon, .y = iy, .w = icon, .h = icon };
    if (w.grid_r != null) {
        // A grid window is minimized already, and a click brings it back
        // to the windows area: no minimize / maximize there (a narrower
        // grid). Zero-width rects at the ×, so the title's room ends there.
        const at: Rect = .{ .x = w.close_r.x - gap, .y = iy, .w = 0, .h = icon };
        w.max_r = at;
        w.min_r = at;
    } else {
        w.max_r = .{ .x = w.close_r.x - @round(12 * ui) - icon, .y = iy, .w = icon, .h = icon };
        w.min_r = .{ .x = w.max_r.x - gap - icon, .y = iy, .w = icon, .h = icon };
    }

    // Kill menu: a small drop-down under the ×, over the content.
    const menu_h = @round(chrome.cell_h * 1.9);
    const menu_w = menu_h + chrome.cell_w * 5 + @round(8 * ui);
    w.skull_r = .{ .x = w.close_r.x + w.close_r.w - menu_w, .y = inner.y + title_h + @round(2 * ui), .w = menu_w, .h = menu_h };
}

// ------------------------------------------------------------ interaction

pub fn hit(w: *const JobWindow, x: f32, y: f32) Hit {
    if (w.kill_menu and w.skull_r.contains(x, y)) return .kill;
    if (!(w.grid_r orelse w.rect).contains(x, y)) return .none;
    if (w.close_r.contains(x, y)) return .close;
    if (w.check_r.contains(x, y)) return .check;
    if (w.copy_r.contains(x, y)) return .copy;
    if (w.zoom_out_r.contains(x, y)) return .zoom_out;
    if (w.zoom_in_r.contains(x, y)) return .zoom_in;
    if (w.colors_r.contains(x, y)) return .colors;
    if (w.sync_r.contains(x, y)) return .sync;
    if (w.files_r.contains(x, y)) return .files;
    if (w.min_r.contains(x, y)) return .minimize;
    if (w.max_r.contains(x, y)) return .maximize;
    if (w.title_r.contains(x, y)) return .title;
    if (w.grid_r == null and w.scrollThumb() != null and w.scrollerHitR().contains(x, y)) return .scroller;
    if (w.git_chip_r.contains(x, y)) return .git_chip;
    if (w.folder_chip_r.contains(x, y)) return .folder_chip;
    if (w.grid_r == null and w.foot_r.contains(x, y)) return .footer;
    return .out;
}

/// Tooltip for a content action on the left of the title bar: what a
/// click does now, and the button it belongs to. Null for other parts.
pub fn tip(w: *const JobWindow, h: Hit) ?struct { text: []const u8, r: Rect } {
    return switch (h) {
        .check => .{ .r = w.check_r, .text = switch (w.check) {
            .off => "Show next to the current window",
            .on => "Back to the job grid",
            .locked => "The current window",
            .hidden => return null,
        } },
        .copy => .{ .r = w.copy_r, .text = if (w.kind == .shell and w.proc.running() and w.out.last_output != null and w.log != null)
            "Copy the last command's output"
        else
            "Copy all output" },
        .zoom_out => .{ .r = w.zoom_out_r, .text = if (w.zoom > min_zoom) "Smaller text" else "Smaller text (already 100%)" },
        .zoom_in => .{ .r = w.zoom_in_r, .text = "Larger text" },
        .colors => .{ .r = w.colors_r, .text = if (w.colors) "Colors off (plain text)" else "Colors on" },
        .sync => .{ .r = w.sync_r, .text = switch (w.sync) {
            .off => "Sync typing: what you type here goes to every window shown",
            .source => "Sync typing off",
            .follower => "Read-only (sync typing); click: sync typing off",
        } },
        .files => .{ .r = w.files_r, .text = if (w.remote_len > 0)
            "Remote folder: not yet"
        else
            if (@import("builtin").os.tag == .macos) "Open this folder in Finder" else "Open this folder in the file manager" },
        else => null,
    };
}

/// Once a frame: true when the window needs a redraw (the "↑ N" label
/// timed out).
pub fn tick(w: *JobWindow, gfx: *Gfx, now: u64) bool {
    // The folder chip's flash: redraw every frame while it shows.
    if (w.chip_flash_ms != 0) {
        if (now -| w.chip_flash_ms >= name_flash_ms) w.chip_flash_ms = 0;
        _ = w.tickNames(gfx, now);
        return true;
    }
    return w.tickNames(gfx, now);
}

fn tickNames(w: *JobWindow, gfx: *Gfx, now: u64) bool {
    // The name flash: redraw every frame while it shows.
    if (w.name_flash) |f| {
        if (now -| f.ms >= name_flash_ms) w.name_flash = null;
        _ = w.tickFx(gfx, now);
        return true;
    }
    return w.tickFx(gfx, now);
}

fn tickFx(w: *JobWindow, gfx: *Gfx, now: u64) bool {
    // The file effect: the same, until it is over.
    if (w.file_fx) |*f| {
        if (f.over(now)) w.file_fx = null;
        _ = w.tickCopyFlash(gfx, now);
        return true;
    }
    return w.tickCopyFlash(gfx, now);
}

fn tickCopyFlash(w: *JobWindow, gfx: *Gfx, now: u64) bool {
    // The copy flash: redraw every frame while it shows.
    if (w.copy_flash) |f| {
        if (now -| f.ms < copy_flash_ms) {
            _ = w.tickRest(gfx, now);
            return true;
        }
        w.copy_flash = null;
        _ = w.tickRest(gfx, now);
        return true;
    }
    return w.tickRest(gfx, now);
}

fn tickRest(w: *JobWindow, gfx: *Gfx, now: u64) bool {
    // Chips: once a second, while shown and running.
    var chips = w.tickRemote(gfx, now);
    if (!w.proc.running() and w.link_pid != 0) w.endRemote();
    if (w.grid_r == null and w.proc.running() and now >= w.chips_next_ms) {
        w.chips_next_ms = now + chips_refresh_ms;
        const before = .{ w.git_chip_r, w.folder_chip_r };
        chips = w.refreshChips() or chips;
        w.layoutChips(gfx);
        if (!std.meta.eql(before, .{ w.git_chip_r, w.folder_chip_r })) chips = true;
    }
    // Moving: redraw every frame; done after `anim_len_ms`.
    if (w.anim_from != null) {
        if (now -| w.anim_ms >= anim_len_ms) w.anim_from = null;
        return true;
    }
    // The output rested: the cursor comes back.
    if (w.busy_ms != 0 and now -| w.busy_ms >= cursor_rest_ms) {
        w.busy_ms = 0;
        if (w.focused) chips = true;
    }
    if (w.out.scroll_moves != w.scroll_seen) {
        w.scroll_seen = w.out.scroll_moves;
        w.scroll_ms = now;
    }
    if (w.scroll_ms != 0 and now - w.scroll_ms > scroll_label_ms) {
        w.scroll_ms = 0;
        return true;
    }
    if (w.check_err_until != 0 and now > w.check_err_until) {
        w.check_err_until = 0;
        return true;
    }
    return chips;
}

const chips_refresh_ms = 1000;

const scroll_label_ms = 2000;
/// Output this soon after the user's typing is its answer (the echo, the
/// command's first lines): the cursor stays.
const echo_wait_ms = 300;
/// Output nobody typed for hides the cursor until it rests this long.
const cursor_rest_ms = 250;

pub fn scrollAt(w: *JobWindow, lines: isize) void {
    w.out.scrollBy(lines);
}

// Mouse on the content (windows area only; grid copies are too small).

/// Absolute line index of the top visible row.
fn viewTop(w: *const JobWindow) usize {
    return (w.out.viewEnd() -| w.out.scroll) -| w.out.rows;
}

fn viewRow(w: *const JobWindow, y: f32) u16 {
    const r = @floor((y - w.out_r.y) / w.cell_h);
    return @intFromFloat(std.math.clamp(r, 0, @as(f32, @floatFromInt(w.out.rows -| 1))));
}

/// The caret position nearest to (x, y), clamped to the visible text.
fn posAt(w: *const JobWindow, x: f32, y: f32) Screen.Pos {
    const col = @round((x - w.out_r.x) / w.cell_w);
    return .{
        .row = w.viewTop() + w.viewRow(y),
        .col = @intFromFloat(std.math.clamp(col, 0, @as(f32, @floatFromInt(w.out.cols)))),
    };
}

// Job window text API (for the file opener; positions: Screen.TextPos).

/// The text position of the character under (x, y), or null when there
/// is no text there (or the window is a grid copy).
pub fn textPosAt(w: *const JobWindow, x: f32, y: f32) ?Screen.TextPos {
    if (w.grid_r != null or !w.out_r.contains(x, y)) return null;
    const row = w.viewTop() + w.viewRow(y);
    if (row >= w.out.lines.items.len) return null;
    const colf = @floor((x - w.out_r.x) / w.cell_w);
    if (colf < 0) return null;
    const col: usize = @intFromFloat(colf);
    if (col >= w.out.lines.items[row].items.len or col >= w.out.cols) return null;
    return w.out.textPos(row, @intCast(col));
}

/// The characters of logical line `line` (null: not in memory).
pub fn lineChars(w: *const JobWindow, line: u64, buf: []u21) ?[]u21 {
    return w.out.lineChars(line, buf);
}

/// Bumped on every change of the text (output, scrolling, clear).
pub fn textVersion(w: *const JobWindow) u64 {
    return w.out.generation;
}

/// Once per change of the text (App asks each frame): true when it changed
/// since the last call. The file opener's outline and checks are dropped
/// then (the next hover checks again).
pub fn textChanged(w: *JobWindow) bool {
    if (w.textVersion() == w.seen_version) return false;
    w.seen_version = w.textVersion();
    _ = w.opener.textChanged();
    return true;
}

/// The mouse over the window's text at (x, y): the file opener looks for
/// a name there. True: redraw.
pub fn fileHover(w: *JobWindow, x: f32, y: f32) bool {
    return w.opener.hover(w, w.textPosAt(x, y));
}

/// The outlined file name at (x, y), if any.
pub fn fileMarkAt(w: *JobWindow, x: f32, y: f32) ?*FileOpener.Mark {
    return w.opener.markAt(w.textPosAt(x, y));
}

/// A double-click at (x, y): open the outlined name there, if any (App
/// opens a file; a folder is cd'd to here).
pub fn fileOpen(w: *JobWindow, x: f32, y: f32, pick: bool) FileOpener.Action {
    return w.opener.open(w, w.textPosAt(x, y), pick);
}

/// How long the copy feedback lasts: the flash fades out over the first
/// `copy_white_ms`, the "Copied" bubble shows from `copy_bubble_ms` on.
const copy_flash_ms = 1100;
const copy_white_ms = 350;
const copy_bubble_ms = 150;

/// The rows the title-bar copy takes (`copyText`): [first, end) of the
/// screen's rows. A running shell: its last command's output (or, for a
/// program it runs that the user types into, the answer to the last line
/// typed); else everything.
pub fn copiedRows(w: *const JobWindow) [2]usize {
    const n = w.out.lines.items.len;
    if (w.kind == .shell and w.proc.running() and w.log != null) if (w.out.last_output) |o| if (w.out.out_rows) |r| {
        var a = r.start;
        var b = r.end orelse n;
        if (o.end == null) if (w.out.typedOutput()) |t| if (t.start > o.start) if (w.out.typed_row) |tr| {
            a = tr;
            b = @max(w.out.lf_row, tr);
        };
        return .{ @min(a, n), @min(@max(a, b), n) };
    };
    return .{ 0, n };
}

/// How long the name flash fades (as the copy's white flash).
const name_flash_ms = copy_white_ms;

/// File names copied / cut: a white flash over each of `ranges` (no
/// bubble: the status bar says what to do next).
pub fn flashNames(w: *JobWindow, ranges: []const Screen.TextRange) void {
    var f: @TypeOf(w.name_flash.?) = .{ .ms = c.SDL_GetTicks() };
    f.n = @min(ranges.len, f.ranges.len);
    @memcpy(f.ranges[0..f.n], ranges[0..f.n]);
    w.name_flash = f;
}

/// The folder chip's name or path copied: the chip flashes white.
pub fn flashFolderChip(w: *JobWindow) void {
    w.chip_flash_ms = @max(c.SDL_GetTicks(), 1);
}

/// The name flash: the names' boxes flash white, fading out.
fn drawNameFlash(w: *const JobWindow, gfx: *Gfx) void {
    const f = w.name_flash orelse return;
    if (w.anim_from != null) return;
    const t = c.SDL_GetTicks() -| f.ms;
    if (t >= name_flash_ms) return;
    const left = 1 - @as(f32, @floatFromInt(t)) / @as(f32, name_flash_ms);
    const alpha: u8 = @intFromFloat(@round(170 * left));
    gfx.clip(w.out_r);
    defer gfx.clip(null);
    var rects: [8]Rect = undefined;
    for (f.ranges[0..f.n]) |r| {
        for (w.rangeRects(r, &rects)) |box| gfx.fillAlpha(box, .{ .r = 255, .g = 255, .b = 255 }, alpha);
    }
}

/// Show what the title-bar copy took: a white flash over those rows, then
/// a "Copied" bubble.
pub fn flashCopied(w: *JobWindow) void {
    const r = w.copiedRows();
    w.copy_flash = .{ .first = r[0], .end = r[1], .ms = c.SDL_GetTicks() };
}

/// The copy feedback: a translucent white box over the copied rows in view
/// (fading out), then a small "Copied" bubble at its center (the text
/// area's center when none of the rows is in view).
fn drawCopyFlash(w: *const JobWindow, gfx: *Gfx, theme: *const Theme) void {
    const f = w.copy_flash orelse return;
    if (w.anim_from != null) return;
    const t = c.SDL_GetTicks() -| f.ms;
    if (t >= copy_flash_ms) return;
    const ui = w.scale.ui;
    const top = w.viewTop();
    const a = @max(f.first, top);
    const b = @min(f.end, top + w.out.rows);
    var box = w.out_r;
    gfx.clip(w.out_r);
    defer gfx.clip(null);
    if (b > a) {
        box = .{
            .x = w.out_r.x,
            .y = w.out_r.y + @as(f32, @floatFromInt(a - top)) * w.cell_h,
            .w = w.out_r.w,
            .h = @as(f32, @floatFromInt(b - a)) * w.cell_h,
        };
        if (t < copy_white_ms) {
            const left = 1 - @as(f32, @floatFromInt(t)) / copy_white_ms;
            gfx.fillAlpha(box, .{ .r = 255, .g = 255, .b = 255 }, @intFromFloat(@round(110 * left)));
        }
    }
    if (t < copy_bubble_ms) return;
    const face = w.chromeFace(gfx) catch return;
    bubble(gfx, theme, face, box, "✓ Copied", theme.ok, ui);
}

/// The feedback bubble (copy, file effects): `label` in the title-bar
/// colors, outlined in `col`, centered in `box` (its start kept in view
/// when it is wider).
pub fn bubble(gfx: *Gfx, theme: *const Theme, face: *Gfx.Face, box: Rect, label: []const u8, col: Rgb, ui: f32) void {
    const pad = @round(10 * ui);
    const bw = Gfx.textWidth(face, label) + 2 * pad;
    const bh = face.cell_h + pad;
    const br: Rect = .{
        .x = @round(@max(box.x + (box.w - bw) / 2, box.x)),
        .y = @round(box.y + (box.h - bh) / 2),
        .w = bw,
        .h = bh,
    };
    gfx.fill(br, theme.title_bg);
    gfx.outline(br, col, @max(@round(ui), 1));
    _ = gfx.text(face, br.x + pad, br.y + @round(pad / 2), label, theme.prompt_fg);
}

/// The file effect (`file_fx`): the bubble (normal size) in the middle of
/// the text, clipped to `area` (in the grid, the cell under its title
/// bar).
fn drawFileFx(w: *const JobWindow, gfx: *Gfx, theme: *const Theme, area: Rect) void {
    const f = if (w.file_fx) |*f| f else return;
    if (w.anim_from != null) return;
    const now = c.SDL_GetTicks();
    if (f.over(now)) return;
    gfx.clip(area);
    defer gfx.clip(null);
    if (!f.bubbleShown(now)) return;
    const face = w.chromeFace(gfx) catch return;
    var buf: [256]u8 = undefined;
    const label, const col = f.label(theme, now, &buf);
    bubble(gfx, theme, face, w.out_r, label, col, w.scale.ui);
}

/// The file opener's outline: dashed boxes around the name (solid while
/// the button is held on it, ready to drag).
fn drawFileMark(w: *const JobWindow, gfx: *Gfx, theme: *const Theme) void {
    const m = if (w.opener.mark) |*m| m else return;
    if (w.anim_from != null) return;
    var rects: [8]Rect = undefined;
    const ui = w.scale.ui;
    gfx.clip(w.out_r);
    defer gfx.clip(null);
    for (w.rangeRects(m.range, &rects)) |r| {
        const o = @round(1 * ui);
        const box: Rect = .{ .x = r.x - o, .y = r.y, .w = r.w + 2 * o, .h = r.h };
        if (w.opener.held) {
            gfx.outline(box, theme.focus, @max(@round(2 * ui), 1));
        } else gfx.dashedOutline(box, theme.focus, @max(@round(ui), 1), @round(3 * ui));
    }
}

/// The command that opened the window (its title).
pub fn command(w: *const JobWindow) []const u8 {
    return w.title;
}

/// The folder the window's program is in now (asked from the system
/// while it runs; once finished, the last one seen).
pub fn folder(w: *const JobWindow, buf: []u8) []const u8 {
    if (w.proc.running()) {
        const n = c.gtty_proc_cwd(w.proc.pid, buf.ptr, buf.len);
        if (n > 0) return buf[0..@intCast(n)];
    }
    const d = w.cwd();
    const k = @min(d.len, buf.len);
    @memcpy(buf[0..k], d[0..k]);
    return buf[0..k];
}

/// On-screen boxes of `range` in the view: one per row it covers (rows
/// scrolled out of view are left out).
pub fn rangeRects(w: *const JobWindow, range: Screen.TextRange, out: []Rect) []Rect {
    if (w.grid_r != null) return out[0..0];
    const a = w.out.physPos(range.start) orelse return out[0..0];
    const b = w.out.physPos(range.end) orelse return out[0..0];
    const top = w.viewTop();
    var n: usize = 0;
    var row = a.row;
    while (row <= b.row and n < out.len) : (row += 1) {
        const c0: usize = if (row == a.row) a.col else 0;
        const c1: usize = if (row == b.row) b.col else w.out.lines.items[row].items.len;
        if (c1 <= c0 or row < top or row >= top + w.out.rows) continue;
        out[n] = .{
            .x = w.out_r.x + @as(f32, @floatFromInt(c0)) * w.cell_w,
            .y = w.out_r.y + @as(f32, @floatFromInt(row - top)) * w.cell_h,
            .w = @as(f32, @floatFromInt(c1 - c0)) * w.cell_w,
            .h = w.cell_h,
        };
        n += 1;
    }
    return out[0..n];
}

/// Mouse over the window (or null when it left): track the hovered row.
/// Returns true if the gutter mark moved.
pub fn hover(w: *JobWindow, pt: ?[2]f32) bool {
    const over = if (pt) |p| w.hit(p[0], p[1]) == .scroller else false;
    const part: Hit = if (pt) |p| w.hit(p[0], p[1]) else .none;
    const over_chip = part == .git_chip;
    const over_folder = part == .folder_chip;
    const changed = over != w.over_scroller or over_chip != w.over_git_chip or over_folder != w.over_folder_chip;
    w.over_scroller = over;
    w.over_git_chip = over_chip;
    w.over_folder_chip = over_folder;
    return changed;
}

/// Left button down on the content: start a selection there. A double
/// click selects the word, a triple click the whole line.
pub fn mouseDown(w: *JobWindow, x: f32, y: f32, clicks: u8) void {
    w.key_sel = false;
    const p = w.posAt(x, y);
    w.out.sel = switch (clicks) {
        0, 1 => .{ .anchor = p, .head = p },
        2 => w.out.wordAt(p.row, @min(@as(u16, @intFromFloat(@max(@floor((x - w.out_r.x) / w.cell_w), 0))), w.out.cols)),
        else => .{ .anchor = .{ .row = p.row, .col = 0 }, .head = .{ .row = p.row, .col = w.out.cols } },
    };
    w.drag = if (clicks <= 1) .select else .none;
}

/// Left button down on the scroller: take the thumb where it was hit, or
/// jump there first when the track was hit (the thumb centers on it).
pub fn scrollerDown(w: *JobWindow, y: f32) void {
    const t = w.scrollThumb() orelse return;
    if (y >= t.y and y < t.y + t.h) {
        w.grab = y - t.y;
    } else {
        w.grab = t.h / 2;
        w.scrollerTo(y);
    }
    w.drag = .scroller;
}

/// Move the view so the thumb's top sits at `y - grab`.
fn scrollerTo(w: *JobWindow, y: f32) void {
    const t = w.scrollThumb() orelse return;
    const r = w.scroller_r;
    const room = @max(r.h - t.h, 1);
    const frac = std.math.clamp((y - w.grab - r.y) / room, 0, 1);
    const max: f32 = @floatFromInt(w.out.maxScroll());
    w.out.scrollTo(@intFromFloat(@round(max * (1 - frac))));
}

/// Mouse moved with the button held: extend the selection, scrolling when
/// dragged past the top or bottom.
pub fn mouseDrag(w: *JobWindow, x: f32, y: f32) void {
    if (w.drag == .scroller) return w.scrollerTo(y);
    if (w.drag != .select) return;
    if (y < w.out_r.y) w.out.scrollBy(1);
    if (y >= w.out_r.y + w.out_r.h) w.out.scrollBy(-1);
    if (w.out.sel) |*sel| sel.head = w.posAt(x, y);
}

pub fn mouseUp(w: *JobWindow) void {
    const was = w.drag;
    w.drag = .none;
    if (was != .select) return;
    if (w.out.sel) |sel| if (sel.empty()) {
        w.out.sel = null;
    };
}

/// The selected text, or null when nothing is selected.
pub fn selectedText(w: *const JobWindow, gpa: std.mem.Allocator) ?[]u8 {
    const sel = w.out.sel orelse return null;
    if (sel.empty()) return null;
    return w.out.selectedText(gpa, sel) catch null;
}

/// What the title bar's copy takes. A running shell: the output of its
/// last command (from the shell marks, read back from the tee file; so far,
/// while it still runs). Otherwise, or with no marks (a shell without
/// gtty's hooks): everything.
pub fn copyText(w: *JobWindow, gpa: std.mem.Allocator) ![]u8 {
    if (w.copiesLast()) if (w.out.last_output) |o| if (w.log) |*log| {
        var start = o.start;
        var end = o.end orelse log.bytes;
        // A command still running that the user types into (ssh, python…):
        // the answer to the last line typed, not the whole session.
        if (o.end == null) if (w.out.typedOutput()) |t| if (t.start > o.start) {
            start = t.start;
            end = t.end.?;
        };
        const raw = try log.readRange(gpa, start, end);
        defer gpa.free(raw);
        return w.render(gpa, raw);
    };
    return w.copyAll(gpa);
}

/// The copy action takes only the last command's output (a running shell
/// whose hooks marked one), not everything: the right-click menu names
/// it "Copy last output" then, else "Copy all output".
pub fn copiesLast(w: *const JobWindow) bool {
    return w.kind == .shell and w.proc.running() and w.out.last_output != null and w.log != null;
}

/// The window's entire output (stdout and stderr together) as plain text.
/// Once rows have left the memory window, it is rebuilt from the tee file.
pub fn copyAll(w: *JobWindow, gpa: std.mem.Allocator) ![]u8 {
    const log = if (w.log) |*l| l else return w.out.plainText(gpa);
    if (w.out.dropped == 0) return w.out.plainText(gpa);
    const raw = try log.readAll(gpa);
    defer gpa.free(raw);
    return w.render(gpa, raw);
}

/// Raw output bytes as plain text, laid out at the window's width.
fn render(w: *const JobWindow, gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var all = Screen.init(gpa);
    defer all.deinit();
    all.max_lines = std.math.maxInt(usize);
    all.resize(w.cols, w.rows);
    all.feed(raw);
    return all.plainText(gpa);
}

pub fn statusText(w: *const JobWindow, buf: []u8) []const u8 {
    if (w.proc.running()) return "running";
    const secs = @as(f32, @floatFromInt(w.ended_ms -| w.started_ms)) / 1000.0;
    return std.fmt.bufPrint(buf, "exit {d} · {d:.1}s", .{ w.proc.exit_code, secs }) catch "exited";
}

// ------------------------------------------------------------ drawing

pub fn draw(w: *JobWindow, gfx: *Gfx, theme: *const Theme) void {
    const ui = w.scale.ui;
    const chrome = w.chromeFace(gfx) catch return;
    const f = w.textFace(gfx) catch return;
    const box = w.grid_r orelse w.rect;

    gfx.fill(box, theme.bg);
    w.drawTitle(gfx, theme, chrome);
    if (w.grid_r) |g| {
        w.drawScaledContent(gfx, theme, f, g);
        const top = w.title_r.y + w.title_r.h;
        w.drawFileFx(gfx, theme, .{ .x = g.x, .y = top, .w = g.w, .h = @max(g.y + g.h - top, 1) });
    } else {
        drawPane(gfx, theme, f, &w.out, w.out_r, theme.bg, w.colors, w.showCursor(), true, w.scroll_ms != 0);
        w.drawMarks(gfx, theme);
        w.drawScroller(gfx, theme);
        w.drawFooter(gfx, theme);
        w.drawFileMark(gfx, theme);
        w.drawCopyFlash(gfx, theme);
        w.drawNameFlash(gfx);
        w.drawFileFx(gfx, theme, w.out_r);
    }
    if (w.kill_menu) killMenu(gfx, chrome, w.skull_r, theme, ui);

    // Frame last, so the title bar and content don't paint over it.
    gfx.outline(box, w.frameColor(theme), frameWidth(ui, w.focused or w.sync == .follower or !w.proc.running()));

    // Failed: the exit code in small font at the bottom (in the footer
    // strip in the windows area).
    if (!w.proc.running() and w.proc.exit_code != 0) {
        const ef = if (w.grid_r == null) chipFace(gfx, w.scale) catch chrome else chrome;
        var ebuf: [24]u8 = undefined;
        const es = std.fmt.bufPrint(&ebuf, " exit {d} ", .{w.proc.exit_code}) catch " exit ";
        const ew = Gfx.textWidth(ef, es);
        const ex = box.x + box.w - ew - @round(12 * ui);
        const ey = if (w.grid_r == null) w.foot_r.y + @round((w.foot_r.h - ef.cell_h) / 2) else box.y + box.h - ef.cell_h;
        gfx.fill(.{ .x = ex, .y = ey, .w = ew, .h = ef.cell_h }, theme.stderr_accent);
        _ = gfx.text(ef, ex, ey, es, theme.bg);
    }
}

/// The footer strip under the text: a hairline on top, the chips on the
/// left (the git chip: commit-graph icon + branch, cut with … when long).
fn drawFooter(w: *const JobWindow, gfx: *Gfx, theme: *const Theme) void {
    const ui = w.scale.ui;
    const r = w.foot_r;
    gfx.fill(r, theme.bg.mix(theme.title_bg, 0.35));
    gfx.fill(.{ .x = r.x, .y = r.y, .w = r.w, .h = @max(@round(ui), 1) }, theme.title_bg);
    const f = chipFace(gfx, w.scale) catch return;
    if (w.git_chip_r.w > 0) {
        const b = w.branch();
        drawChip(gfx, theme, f, ui, w.git_chip_r, b orelse no_git_label, b != null and (w.over_git_chip or w.git_peek_open), .git, b != null);
    }
    if (w.folderName()) |name| if (w.folder_chip_r.w > 0)
        drawChip(gfx, theme, f, ui, w.folder_chip_r, name, w.over_folder_chip or w.folder_peek_open, .folder, true);
    if (w.chip_flash_ms != 0) {
        const t = c.SDL_GetTicks() -| w.chip_flash_ms;
        if (t < name_flash_ms) {
            const left = 1 - @as(f32, @floatFromInt(t)) / @as(f32, name_flash_ms);
            gfx.fillAlpha(w.folder_chip_r, .{ .r = 255, .g = 255, .b = 255 }, @intFromFloat(@round(170 * left)));
        }
    }
}

/// A chip: its icon and label (cut with … when long); lighter while the
/// mouse is on it or its peek is open; dimmed when disabled.
fn drawChip(gfx: *Gfx, theme: *const Theme, f: *Gfx.Face, ui: f32, cr: Rect, label: []const u8, lit: bool, icon: enum { git, folder }, enabled: bool) void {
    gfx.fill(cr, theme.title_bg.mix(theme.fg, if (lit) 0.16 else if (enabled) 0.06 else 0.02));
    const icon_col = if (enabled) theme.focus else theme.dim;
    const pad = @round(7 * ui);
    const iy = cr.y + @round((cr.h - f.cell_h) / 2);
    const iw = @round(f.cell_h * 0.8);
    switch (icon) {
        .git => gitIcon(gfx, icon_col, ui, cr.x + pad, iy, iw, f.cell_h),
        .folder => folderIcon(gfx, icon_col, ui, cr.x + pad, iy, iw, f.cell_h),
    }
    const tx = cr.x + pad + chipIconW(f, ui);
    const ty = cr.y + @round((cr.h - f.cell_h) / 2);
    const cut = chipCut(label);
    const end = gfx.text(f, tx, ty, label[0..cut], if (enabled) theme.title_fg else theme.dim);
    if (cut < label.len) _ = gfx.text(f, end, ty, "…", theme.dim);
}

/// A folder outline with its tab, filling a `w` × `h` box.
fn folderIcon(gfx: *Gfx, col: Rgb, ui: f32, x: f32, y: f32, w: f32, h: f32) void {
    const t = @max(@round(h * 0.08), @max(@round(ui), 1));
    const tab_h = @round(h * 0.14);
    const body: Rect = .{ .x = x, .y = y + h * 0.18 + tab_h, .w = w, .h = h * 0.64 - tab_h };
    gfx.outline(body, col, t);
    gfx.fill(.{ .x = body.x, .y = body.y - tab_h, .w = @round(body.w * 0.45), .h = tab_h + t }, col);
}

/// Branching commits, a "Y": a first commit, then a joint commit where a
/// task branch splits off to the right while master continues straight up.
pub fn gitIcon(gfx: *Gfx, col: Rgb, ui: f32, x: f32, y: f32, w: f32, h: f32) void {
    const rad = @max(h * 0.14, 1.3 * ui);
    const t = @max(@round(h * 0.08), @max(@round(ui), 1));
    const lx = x + rad; // master line
    const rx = x + w - rad; // task branch
    const top = y + rad;
    const joint = y + h * 0.55;
    const bottom = y + h - rad;
    gfx.line(lx, bottom, lx, top, col, t); // master: first → joint → next
    gfx.line(lx, joint, rx, top, col, t); // task branch splits off
    gfx.disc(lx, bottom, rad, col);
    gfx.disc(lx, joint, rad, col);
    gfx.disc(lx, top, rad, col);
    gfx.disc(rx, top, rad, col);
}

/// Grid: render the content at full size offscreen, then draw it scaled
/// down under the (normal-size) title bar, keeping its aspect ratio.
fn drawScaledContent(w: *JobWindow, gfx: *Gfx, theme: *const Theme, f: *Gfx.Face, g: Rect) void {
    const tw: c_int = @intFromFloat(@max(@round(w.out_r.w), 1));
    const th: c_int = @intFromFloat(@max(@round(w.out_r.h), 1));
    if (w.thumb) |t| if (t.*.w != tw or t.*.h != th) {
        c.SDL_DestroyTexture(t);
        w.thumb = null;
    };
    if (w.thumb == null) {
        w.thumb = c.SDL_CreateTexture(gfx.renderer, c.SDL_PIXELFORMAT_ARGB8888, c.SDL_TEXTUREACCESS_TARGET, tw, th);
        if (w.thumb) |t| _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_LINEAR);
    }
    const tex = w.thumb orelse return;
    // Back to the current target afterwards (the screen, or App's
    // transition canvas).
    const prev = c.SDL_GetRenderTarget(gfx.renderer);
    _ = c.SDL_SetRenderTarget(gfx.renderer, tex);
    gfx.fill(.{ .x = 0, .y = 0, .w = w.out_r.w, .h = w.out_r.h }, theme.bg);
    drawPane(gfx, theme, f, &w.out, .{ .x = 0, .y = 0, .w = w.out_r.w, .h = w.out_r.h }, theme.bg, w.colors, false, false, false);
    _ = c.SDL_SetRenderTarget(gfx.renderer, prev);

    const pad = @round(3 * w.scale.ui);
    const area: Rect = .{
        .x = g.x + pad,
        .y = w.title_r.y + w.title_r.h + pad,
        .w = @max(g.w - 2 * pad, 1),
        .h = @max(g.y + g.h - (w.title_r.y + w.title_r.h) - 2 * pad, 1),
    };
    const s = @min(area.w / @max(w.out_r.w, 1), area.h / @max(w.out_r.h, 1));
    const dst: c.SDL_FRect = .{ .x = area.x, .y = area.y, .w = w.out_r.w * s, .h = w.out_r.h * s };
    _ = c.SDL_RenderTexture(gfx.renderer, tex, null, &dst);
}

/// The marks strip: each visible row's mark (`Screen.rowZone`): green
/// what the user typed, purple AI; output and prompts get none.
fn drawMarks(w: *const JobWindow, gfx: *Gfx, theme: *const Theme) void {
    const m = w.marks_r;
    if (m.w <= 0) return;
    const s = &w.out;
    const top = w.viewTop();
    var i: usize = 0;
    while (i < s.rows) : (i += 1) {
        const col = switch (s.rowZone(top + i)) {
            .none, .output => continue,
            .input => theme.mark_input,
            .ai => theme.mark_ai,
        };
        const y = m.y + @as(f32, @floatFromInt(i)) * w.cell_h;
        if (y >= m.y + m.h) break;
        gfx.fill(.{ .x = m.x, .y = y, .w = m.w, .h = w.cell_h }, col);
    }
}

/// The scroller thumb (y and height on the right strip): where the visible
/// rows sit in the scrollback, sized by the share of lines in view. Null
/// while all the output fits.
fn scrollThumb(w: *const JobWindow) ?struct { y: f32, h: f32 } {
    const total = w.out.viewEnd();
    if (total <= w.out.rows) return null;
    const r = w.scroller_r;
    const n: f32 = @floatFromInt(total);
    const h = @round(@max(r.h * @as(f32, @floatFromInt(w.out.rows)) / n, @round(12 * w.scale.ui)));
    const top = (r.h - h) * @as(f32, @floatFromInt(w.viewTop())) / @max(n - @as(f32, @floatFromInt(w.out.rows)), 1);
    return .{ .y = r.y + @round(top), .h = h };
}

/// The scroller takes clicks a bit wider than it is drawn.
fn scrollerHitR(w: *const JobWindow) Rect {
    const r = w.scroller_r;
    const extra = @round(4 * w.scale.ui);
    return .{ .x = r.x - extra, .y = r.y, .w = r.w + 2 * extra, .h = r.h };
}

/// The thumb on its track: gray at the bottom, blue while scrolled back;
/// wider while the mouse is on it or drags it.
fn drawScroller(w: *const JobWindow, gfx: *Gfx, theme: *const Theme) void {
    const t = w.scrollThumb() orelse return;
    const ui = w.scale.ui;
    const r = w.scroller_r;
    const active = w.over_scroller or w.drag == .scroller;
    const tw = if (active) r.w else @max(@round(3 * ui), 2);
    const x = r.x + @round((r.w - tw) / 2);
    gfx.fill(.{ .x = x, .y = r.y, .w = tw, .h = r.h }, theme.bg.mix(theme.divider, 0.5));
    const col = if (w.out.scroll > 0 or w.drag == .scroller) theme.focus else if (active) theme.title_fg else theme.dim;
    gfx.fill(.{ .x = x, .y = t.y, .w = tw, .h = t.h }, col);
}

/// Running: blue when focused, purple-red when read-only (sync typing),
/// else neutral. Finished: green (exit 0) or red.
fn frameColor(w: *const JobWindow, theme: *const Theme) Rgb {
    if (w.proc.running()) return if (w.focused) theme.focus else if (w.sync == .follower) theme.sync else theme.divider;
    return if (w.proc.exit_code == 0) theme.ok else theme.stderr_accent;
}

fn drawTitle(w: *JobWindow, gfx: *Gfx, theme: *const Theme, chrome: *Gfx.Face) void {
    const ui = w.scale.ui;
    gfx.fill(w.title_r, theme.title_bg);
    const ty = w.title_r.y + @round((w.title_r.h - chrome.cell_h) / 2);
    var idbuf: [16]u8 = undefined;
    const id_s = std.fmt.bufPrint(&idbuf, "#{d}", .{w.serial}) catch "#";
    var x = w.actions_end + @round(10 * ui);
    // Serial number as a small badge, so it's easy to tell windows apart
    // (filled blue on the focused window).
    const bpad = @round(4 * ui);
    const badge: Rect = .{ .x = x, .y = w.title_r.y + @round((w.title_r.h - chrome.cell_h - 2 * ui) / 2), .w = Gfx.textWidth(chrome, id_s) + 2 * bpad, .h = chrome.cell_h + @round(2 * ui) };
    gfx.fill(badge, if (w.focused) theme.focus else theme.title_bg.mix(theme.fg, 0.14));
    _ = gfx.text(chrome, x + bpad, ty, id_s, if (w.focused) theme.bg else theme.title_fg);
    x += badge.w + chrome.cell_w;

    // State dot
    const status_col = if (w.proc.running()) theme.focus else if (w.proc.exit_code == 0) theme.ok else theme.stderr_accent;
    const dot = @round(chrome.cell_h * 0.36);
    gfx.fill(.{ .x = x, .y = w.title_r.y + (w.title_r.h - dot) / 2, .w = dot, .h = dot }, status_col);
    x += dot + chrome.cell_w * 0.6;

    // Title, then the status text right before the window actions. In a
    // narrow (grid) title bar the status is dropped first, then the title
    // is cut; the action icons always stay.
    var sbuf: [48]u8 = undefined;
    const status = w.statusText(&sbuf);
    const status_w = Gfx.textWidth(chrome, status);
    const room = w.min_r.x - chrome.cell_w - x;
    const show_status = room >= status_w + chrome.cell_w * 8;
    const title_max = room - (if (show_status) status_w + chrome.cell_w else 0);
    gfx.clip(.{ .x = x, .y = w.title_r.y, .w = @max(title_max, 0), .h = w.title_r.h });
    _ = gfx.text(chrome, x, ty, w.title, theme.title_fg);
    gfx.clip(null);
    if (show_status) _ = gfx.text(chrome, w.min_r.x - status_w - chrome.cell_w, ty, status, theme.dim);

    closeIcon(gfx, w.close_r, theme, ui);
    if (w.check_r.w > 0) checkIcon(gfx, w.check_r, theme, ui, switch (w.check) {
        .hidden, .off => if (w.check_err_until != 0) .err else .off,
        .on => .on,
        .locked => .locked,
    });
    if (w.copy_r.w > 0) copyIcon(gfx, w.copy_r, theme, ui);
    if (w.colors_r.w > 0) {
        zoomIcon(gfx, chrome, w.zoom_out_r, theme, ui, false, w.zoom > min_zoom);
        zoomIcon(gfx, chrome, w.zoom_in_r, theme, ui, true, w.zoom < max_zoom);
        colorsIcon(gfx, chrome, w.colors_r, theme, ui, w.colors);
        syncIcon(gfx, chrome, w.sync_r, theme, ui, w.sync);
        filesIcon(gfx, w.files_r, theme, ui, w.remote_len == 0);
    }
    if (w.min_r.w > 0) minimizeIcon(gfx, w.min_r, theme, ui);
    if (w.max_r.w > 0) maximizeIcon(gfx, w.max_r, theme, ui, w.maximized);
}

fn showCursor(w: *const JobWindow) bool {
    return w.focused and w.proc.running() and w.out.scroll == 0 and
        !w.out.cursor_hidden and w.busy_ms == 0;
}

/// Red square with a white ×.
pub fn closeIcon(gfx: *Gfx, r: Rect, theme: *const Theme, ui: f32) void {
    gfx.fill(r, theme.stderr_accent.mix(theme.title_bg, 0.15));
    const m = @round(r.w * 0.3);
    const t = @max(@round(1.5 * ui), 1);
    gfx.line(r.x + m, r.y + m, r.x + r.w - m, r.y + r.h - m, Rgb.hex(0xffffff), t);
    gfx.line(r.x + r.w - m, r.y + m, r.x + m, r.y + r.h - m, Rgb.hex(0xffffff), t);
}

/// The kill menu: a dark drop-down with a red border, a skull and "kill".
fn killMenu(gfx: *Gfx, f: *Gfx.Face, r: Rect, theme: *const Theme, ui: f32) void {
    gfx.fill(r, theme.title_bg);
    gfx.outline(r, theme.stderr_accent, @max(@round(ui), 1));
    const pad = @round(4 * ui);
    const sk = r.h - 2 * pad;
    skull(gfx, .{ .x = r.x + pad, .y = r.y + pad, .w = sk, .h = sk }, theme.fg, theme.title_bg, ui);
    _ = gfx.text(f, r.x + pad * 2 + sk, r.y + @round((r.h - f.cell_h) / 2), "kill", theme.stderr_accent);
}

/// Pirate skull and crossbones.
fn skull(gfx: *Gfx, r: Rect, col: Rgb, bg: Rgb, ui: f32) void {
    const cx = r.x + r.w / 2;
    const t = @max(@round(r.w * 0.09), @max(@round(ui), 1));
    // Crossbones behind, with knobby ends.
    const bones = [_][4]f32{ .{ 0.1, 0.55, 0.9, 0.95 }, .{ 0.9, 0.55, 0.1, 0.95 } };
    for (bones) |b| {
        const x1 = r.x + r.w * b[0];
        const y1 = r.y + r.h * b[1];
        const x2 = r.x + r.w * b[2];
        const y2 = r.y + r.h * b[3];
        gfx.line(x1, y1, x2, y2, col, t);
        gfx.disc(x1, y1, t, col);
        gfx.disc(x2, y2, t, col);
    }
    // Cranium and jaw.
    const cr = r.w * 0.3;
    const cy = r.y + r.h * 0.38;
    gfx.disc(cx, cy, cr, col);
    gfx.fill(.{ .x = @round(cx - cr * 0.6), .y = cy, .w = @round(cr * 1.2), .h = @round(cr * 1.05) }, col);
    // Eye sockets and nose.
    gfx.disc(cx - cr * 0.42, cy + cr * 0.05, cr * 0.27, bg);
    gfx.disc(cx + cr * 0.42, cy + cr * 0.05, cr * 0.27, bg);
    gfx.disc(cx, cy + cr * 0.5, @max(cr * 0.11, 0.8), bg);
}

pub const CheckLook = enum { off, on, locked, err, partial };

/// A checkbox: an empty box, a blue box with a white check, the check
/// dimmed (locked: always selected), a red check (selecting failed), or a
/// bar (some selected: the job grid's header).
pub fn checkIcon(gfx: *Gfx, r: Rect, theme: *const Theme, ui: f32, look: CheckLook) void {
    const t = @max(@round(1.5 * ui), 1);
    const m = @round(r.w * 0.14);
    const box: Rect = .{ .x = r.x + m, .y = r.y + m, .w = r.w - 2 * m, .h = r.h - 2 * m };
    const fill: Rgb = switch (look) {
        .on, .partial => theme.focus,
        .locked => theme.focus.mix(theme.title_bg, 0.55),
        .err => theme.stderr_accent,
        .off => theme.title_bg.mix(theme.fg, 0.07),
    };
    gfx.fill(box, fill);
    if (look == .off) gfx.outline(box, theme.title_fg.mix(theme.title_bg, 0.3), @max(@round(ui), 1));
    const ink = if (look == .locked) theme.title_fg.mix(theme.title_bg, 0.3) else Rgb.hex(0xffffff);
    switch (look) {
        .off => {},
        .partial => gfx.fill(.{ .x = box.x + @round(box.w * 0.22), .y = box.y + @round((box.h - t) / 2), .w = @round(box.w * 0.56), .h = t }, ink),
        else => {
            const x1 = box.x + box.w * 0.22;
            const y1 = box.y + box.h * 0.52;
            const x2 = box.x + box.w * 0.42;
            const y2 = box.y + box.h * 0.72;
            const x3 = box.x + box.w * 0.78;
            const y3 = box.y + box.h * 0.3;
            gfx.line(x1, y1, x2, y2, ink, t);
            gfx.line(x2, y2, x3, y3, ink, t);
        },
    }
}

/// Two overlapping sheets.
pub fn copyIcon(gfx: *Gfx, r: Rect, theme: *const Theme, ui: f32) void {
    gfx.fill(r, theme.title_bg.mix(theme.fg, 0.07));
    const t = @max(@round(ui), 1);
    const m = @round(r.w * 0.15);
    const s = @round(r.w * 0.55);
    const off = @round(r.w * 0.15);
    const back: Rect = .{ .x = r.x + m, .y = r.y + m, .w = s, .h = s };
    const front: Rect = .{ .x = back.x + off, .y = back.y + off, .w = s, .h = s };
    gfx.outline(back, theme.title_fg.mix(theme.title_bg, 0.35), t);
    gfx.fill(front, theme.title_bg.mix(theme.fg, 0.07));
    gfx.outline(front, theme.title_fg, t);
}

/// A letter A with a small + or − at its top right; dimmed when it can't
/// go further (A− at 100%).
fn zoomIcon(gfx: *Gfx, f: *Gfx.Face, r: Rect, theme: *const Theme, ui: f32, plus: bool, enabled: bool) void {
    gfx.fill(r, theme.title_bg.mix(theme.fg, 0.07));
    const col = if (enabled) theme.title_fg else theme.title_fg.mix(theme.title_bg, 0.6);
    gfx.glyphAt(f, r.x + @round(r.w * 0.12), r.y + @round((r.h - f.cell_h) / 2), 'A', col);
    const t = @max(@round(1.2 * ui), 1);
    const sz = @round(r.h * 0.34);
    const cx = r.x + r.w - @round(r.w * 0.1) - sz / 2;
    const cy = r.y + @round(r.h * 0.3);
    gfx.fill(.{ .x = cx - sz / 2, .y = cy - @round(t / 2), .w = sz, .h = t }, col);
    if (plus) gfx.fill(.{ .x = cx - @round(t / 2), .y = cy - sz / 2, .w = t, .h = sz }, col);
}

const colors_label = "color";
const sync_label = "sync";

/// A checkbox and the word "sync": unchecked while sync typing is off;
/// checked, both in the focus blue, while it is on (this window types into
/// the others, or is read-only and gets their typing).
fn syncIcon(gfx: *Gfx, f: *Gfx.Face, r: Rect, theme: *const Theme, ui: f32, s: Sync) void {
    const on = s != .off;
    gfx.fill(r, if (on) theme.focus.mix(theme.title_bg, 0.8) else theme.title_bg.mix(theme.fg, 0.07));
    const box: Rect = .{ .x = r.x + @round(2 * ui), .y = r.y, .w = r.h, .h = r.h };
    checkIcon(gfx, box, theme, ui, if (on) .on else .off);
    const y = r.y + @round((r.h - f.cell_h) / 2);
    _ = gfx.text(f, box.x + box.w + @round(2 * ui), y, sync_label, if (on) theme.focus else theme.title_fg);
}

/// A pill with the word "color": each letter in its own color while colors
/// are on; dim gray and struck through while they are off.
fn colorsIcon(gfx: *Gfx, f: *Gfx.Face, r: Rect, theme: *const Theme, ui: f32, on: bool) void {
    gfx.fill(r, theme.title_bg.mix(theme.fg, 0.07));
    const cols = [_]Rgb{ theme.palette[9], theme.palette[11], theme.palette[10], theme.palette[14], theme.palette[12] };
    const off_col = theme.title_fg.mix(theme.title_bg, 0.55);
    const x0 = r.x + @round((r.w - f.cell_w * colors_label.len) / 2);
    const y = r.y + @round((r.h - f.cell_h) / 2);
    for (colors_label, 0..) |ch, i| {
        const col = if (on) cols[i % cols.len].mix(Rgb.hex(0xffffff), 0.3) else off_col;
        gfx.glyphAt(f, x0 + @as(f32, @floatFromInt(i)) * f.cell_w, y, ch, col);
    }
    if (!on) {
        const t = @max(@round(1.2 * ui), 1);
        gfx.fill(.{ .x = x0 - @round(2 * ui), .y = r.y + @round(r.h / 2), .w = f.cell_w * colors_label.len + @round(4 * ui), .h = t }, theme.title_fg.mix(theme.title_bg, 0.3));
    }
}

/// A folder (its tab on the top left); dimmed when it can't be used (a
/// remote session).
fn filesIcon(gfx: *Gfx, r: Rect, theme: *const Theme, ui: f32, enabled: bool) void {
    gfx.fill(r, theme.title_bg.mix(theme.fg, 0.07));
    const col = if (enabled) theme.title_fg else theme.title_fg.mix(theme.title_bg, 0.6);
    const t = @max(@round(1.2 * ui), 1);
    const m = @round(r.w * 0.2);
    const tab_h = @round(r.h * 0.12);
    const body: Rect = .{ .x = r.x + m, .y = r.y + m + tab_h, .w = r.w - 2 * m, .h = r.h - 2 * m - tab_h };
    gfx.outline(body, col, t);
    gfx.fill(.{ .x = body.x, .y = body.y - tab_h, .w = @round(body.w * 0.42), .h = tab_h + t }, col);
}

/// A bar at the bottom.
fn minimizeIcon(gfx: *Gfx, r: Rect, theme: *const Theme, ui: f32) void {
    gfx.fill(r, theme.title_bg.mix(theme.fg, 0.07));
    const t = @max(@round(1.5 * ui), 1);
    const m = @round(r.w * 0.25);
    gfx.fill(.{ .x = r.x + m, .y = r.y + r.h - m - t, .w = r.w - 2 * m, .h = t }, theme.title_fg);
}

/// A window outline with a thick top edge; smaller once maximized
/// (click to go back to normal).
fn maximizeIcon(gfx: *Gfx, r: Rect, theme: *const Theme, ui: f32, maximized: bool) void {
    gfx.fill(r, theme.title_bg.mix(theme.fg, 0.07));
    const t = @max(@round(ui), 1);
    const m = @round(r.w * if (maximized) @as(f32, 0.32) else 0.22);
    const box: Rect = .{ .x = r.x + m, .y = r.y + m, .w = r.w - 2 * m, .h = r.h - 2 * m };
    gfx.outline(box, theme.title_fg, t);
    gfx.fill(.{ .x = box.x, .y = box.y, .w = box.w, .h = 2 * t }, theme.title_fg);
}

fn drawPane(gfx: *Gfx, theme: *const Theme, f: *Gfx.Face, s: *Screen, r: Rect, pane_bg: Rgb, colors: bool, cursor: bool, show_sel: bool, scroll_label: bool) void {
    if (r.w <= 0 or r.h <= 0) return;
    gfx.clip(r);
    defer gfx.clip(null);

    const rows: usize = s.rows;
    const total = s.viewEnd();
    const end = total -| s.scroll;
    const start = end -| rows;

    var row: usize = start;
    while (row < end and row < s.lines.items.len) : (row += 1) {
        const y = r.y + @as(f32, @floatFromInt(row - start)) * f.cell_h;
        // Selected columns of this line: highlighted out to the right edge
        // when the selection continues onto the next line.
        const sel: ?[2]usize = if (!show_sel) null else if (s.sel) |sl| sl.colsOn(row) else null;
        if (sel) |sc| {
            const sx = r.x + @as(f32, @floatFromInt(sc[0])) * f.cell_w;
            const ex = if (sc[1] > s.cols) r.x + r.w else r.x + @as(f32, @floatFromInt(sc[1])) * f.cell_w;
            gfx.fill(.{ .x = sx, .y = y, .w = ex - sx, .h = f.cell_h }, theme.selection);
        }
        for (s.lines.items[row].items, 0..) |cell, col| {
            if (col >= s.cols) break;
            const x = r.x + @as(f32, @floatFromInt(col)) * f.cell_w;
            // Colors off: plain text color on the body; inverse, dim and
            // underline still show.
            var fg = if (colors) theme.resolveBold(cell.fg, true, cell.attrs.bold) else theme.fg;
            var bg = if (!colors or cell.bg.tag == .default) pane_bg else theme.resolve(cell.bg, false);
            if (cell.attrs.inverse) std.mem.swap(Rgb, &fg, &bg);
            const selected = if (sel) |sc| col >= sc[0] and col < sc[1] else false;
            if (selected) bg = theme.selection else if (!bg.eql(pane_bg)) gfx.fill(.{ .x = x, .y = y, .w = f.cell_w + 0.5, .h = f.cell_h }, bg);
            if (cell.attrs.dim) fg = fg.mix(bg, 0.4);
            fg = theme.readable(fg, bg);
            const cells: u2 = if (cell.attrs.wide) 2 else 1;
            gfx.glyphCells(f, x, y, cell.cp, cell.extra, cells, fg);
            if (cell.attrs.underline) gfx.fill(.{ .x = x, .y = y + f.cell_h - 2, .w = f.cell_w * @as(f32, @floatFromInt(cells)), .h = 1 }, fg);
        }
    }

    if (cursor and s.cur_row >= start and s.cur_row - start < rows) {
        const cy = r.y + @as(f32, @floatFromInt(s.cur_row - start)) * f.cell_h;
        const cx = r.x + @as(f32, @floatFromInt(s.cur_col)) * f.cell_w;
        gfx.fill(.{ .x = cx, .y = cy, .w = @max(@round(f.cell_w * 0.12), 2), .h = f.cell_h }, theme.cursor);
    }

    // "↑ N" while scrolled back, only for a moment after scrolling (it
    // covers the text under it).
    if (scroll_label and s.scroll > 0) {
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, " ↑ {d} ", .{s.scroll}) catch return;
        const tw = Gfx.textWidth(f, label);
        const lr: Rect = .{ .x = r.x + r.w - tw, .y = r.y, .w = tw, .h = f.cell_h };
        gfx.fill(lr, theme.focus.mix(pane_bg, 0.6));
        _ = gfx.text(f, lr.x, lr.y, label, theme.prompt_fg);
    }
}
