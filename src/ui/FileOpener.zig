// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The file opener: part of every job window (`JobWindow.opener`). When
//! the mouse rests on the window's text, it looks for a file name there:
//! the line around the text position → candidate paths (file_path.zig) →
//! resolved against the window's folder → an existing regular file that
//! isn't a program, or a folder. Names with blanks or punctuation in them
//! (`My File.txt`) come first: the longest span around the mouse that is
//! a name in the window's folder (or in the folder its `dir/` part
//! names), from that folder's listing (DirCache). That name gets a dashed outline
//! (JobWindow draws `mark`), the pointer becomes a hand.
//!   * Double-click inside the outline: open the file with its default app
//!     (`show`; Shift+double-click: pick the app, `show -a`). A folder: type
//!     `cd <folder>` into the window's shell (so folders get an outline only
//!     in a zsh / bash window waiting at its prompt).
//!   * Hold the button on it (`hold_ms`, the outline turns solid) and drag:
//!     the file leaves gtty as from the file manager (App: gtty_drag).
//!   * A quick press and drag still selects text; a single click is a
//!     normal click.
//!
//! In a remote session (ssh / mosh) the names are checked on the other
//! machine through the window's own connection (RemoteLink; the reply
//! comes later, `remoteReply`), relative ones from the remote shell's
//! folder; a file is copied to a read-only local copy first (App's fetch:
//! progress, cancel), a folder is cd'd to when the remote shell waits for
//! a command. Remote files can't be dragged out (yet).
//!
//! The window calls it (hover, leave, open, text changed, remote reply);
//! opening and dragging a file are App's (`Action`), since they need
//! gtty's `show` and its OS window.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const Screen = @import("../core/Screen.zig");
const path = @import("file_path.zig");
const remote = @import("../core/remote.zig");
const JobWindow = @import("JobWindow.zig");
const DirCache = @import("DirCache.zig");

const FileOpener = @This();

/// The file name outlined: where in the window's text, and the file it is
/// (absolute path).
pub const Mark = struct {
    range: Screen.TextRange,
    /// A folder: the click cd's the window's shell there.
    folder: bool = false,
    /// On the machine of the window's remote session.
    remote: bool = false,
    buf: [4096]u8 = undefined,
    len: usize = 0,

    pub fn file(m: *const Mark) []const u8 {
        return m.buf[0..m.len];
    }
};

/// What a double-click asks App to do (the path lives in the mark, valid until
/// the next hover).
pub const Action = union(enum) {
    /// Not on an outlined name: gtty does its usual thing.
    none,
    /// Done here (a cd was typed into the shell).
    done,
    /// `show` / `show -a` this local file.
    show: struct { path: []const u8, pick: bool },
    /// Copy this remote file to a read-only local copy, then open it.
    fetch: struct { path: []const u8, pick: bool },
};

/// On for every window (the settings window's General tab).
pub var enabled: bool = true;

/// Files from another app are being dragged over gtty (App): only folder
/// names are outlined (anywhere, not only at a shell's prompt): the drop
/// copies into the one under the mouse.
pub var drop_mode: bool = false;

/// How long the button is held on an outlined name before moving drags
/// the file (moving sooner selects text).
pub const hold_ms = 300;

mark: ?Mark = null,
/// The button is held on the mark long enough: moving now drags the file
/// (the outline is drawn solid).
held: bool = false,
/// The mouse is over the window's text (for the help line), and the
/// remote session's state then.
over: bool = false,
over_remote: enum { local, connecting, ready, failed, away } = .local,
over_dest_buf: [128]u8 = undefined,
over_dest_len: usize = 0,
/// A check sent to the remote machine, waiting for its reply: the
/// request id and the candidates, in order (the first that exists wins).
pending: ?struct { id: u32, n: usize, marks: [path.max_candidates]Mark } = null,
/// The last place checked (position, text version): the same spot again
/// doesn't touch the disk again.
checked: ?struct { pos: Screen.TextPos, version: u64 } = null,
/// Remote: the name last asked about (its range): moving along the same
/// word doesn't ask the other machine again.
asked: ?Screen.TextRange = null,

/// For the status bar while the mouse is over the window's text: on an
/// outlined name, what the mouse does with it; remote helpers off: why.
pub fn help(fo: *const FileOpener, buf: []u8) []const u8 {
    if (!enabled) return "";
    if (fo.mark) |*m| {
        const name = std.fs.path.basename(m.file());
        return (if (m.folder)
            std.fmt.bufPrint(buf, "double-click: cd to {s}  ·  hold and drag: drag it out", .{name})
        else if (m.remote)
            std.fmt.bufPrint(buf, "double-click: copy {s} here (read-only) and open it  (Shift: choose the app)", .{name})
        else
            std.fmt.bufPrint(buf, "double-click: open {s}  (Shift: choose the app)  ·  hold and drag: drag it out", .{name})) catch "";
    }
    if (!fo.over) return "";
    const dest = fo.over_dest_buf[0..fo.over_dest_len];
    return switch (fo.over_remote) {
        .local, .ready, .connecting => "",
        .away => std.fmt.bufPrint(buf, "file opener off: you're on another machine or user inside the session on {s}", .{dest}) catch "",
        .failed => std.fmt.bufPrint(buf, "file opener off: can't connect to {s} (needs ssh keys or an agent); back after this ssh session", .{dest}) catch "",
    };
}

/// Drop the outline and any check in flight. True if something was shown.
pub fn clear(fo: *FileOpener) bool {
    fo.checked = null;
    fo.pending = null;
    fo.asked = null;
    fo.held = false;
    if (fo.mark == null) return false;
    fo.mark = null;
    return true;
}

/// Turned off: forget everything.
pub fn reset(fo: *FileOpener) bool {
    const was = fo.over;
    fo.over = false;
    return fo.clear() or was;
}

/// The mouse left the window's text. True: redraw.
pub fn leave(fo: *FileOpener) bool {
    const was = fo.over;
    fo.over = false;
    return fo.clear() or was;
}

/// The window's text changed (output, scrolling, resize): the outline may
/// be off now, and a check waiting for its reply is stale. The next hover
/// checks again. True: redraw.
pub fn textChanged(fo: *FileOpener) bool {
    if (fo.pending != null) {
        fo.pending = null;
        fo.checked = null;
    }
    return fo.clear();
}

/// The mouse at text position `pos` (null: no text there). True: redraw
/// (outline or help line changed).
pub fn hover(fo: *FileOpener, w: *JobWindow, pos: ?Screen.TextPos) bool {
    if (!enabled) return false;
    // Selecting text: no outlines on the way.
    if (w.drag != .none) return fo.clear();
    var redraw = !fo.over;
    fo.over = true;
    // In an ssh / mosh session the names belong to another machine.
    var rbuf: [4096]u8 = undefined;
    const sess = w.remoteNow(&rbuf);
    const state: @TypeOf(fo.over_remote) = if (sess == null) .local else if (w.linkFailed()) .failed else if (w.linkReady() == null) .connecting else if (w.remote_away) .away else .ready;
    if (state != fo.over_remote) {
        fo.over_remote = state;
        if (sess) |r| {
            fo.over_dest_len = @min(r.dest.len, fo.over_dest_buf.len);
            @memcpy(fo.over_dest_buf[0..fo.over_dest_len], r.dest[0..fo.over_dest_len]);
        }
        redraw = true;
    }
    if (state != .local and state != .ready) return fo.clear() or redraw;
    if (drop_mode and state != .local) return fo.clear() or redraw;
    const p = pos orelse return fo.clear() or redraw;
    const version = w.textVersion();
    if (fo.checked) |k| if (std.meta.eql(k.pos, p) and k.version == version) return redraw;
    fo.checked = .{ .pos = p, .version = version };
    // Still inside the outlined name: nothing new to find.
    if (fo.mark) |m| if (m.range.contains(p)) return redraw;

    const had = fo.mark != null;
    fo.mark = null;
    fo.held = false;
    fo.find(w, p, state == .ready);
    return redraw or had or fo.mark != null;
}

fn find(fo: *FileOpener, w: *JobWindow, pos: Screen.TextPos, is_remote: bool) void {
    var lbuf: [4096]u21 = undefined;
    const line = w.lineChars(pos.line, &lbuf) orelse return;
    const list = path.candidates(line, pos.col);
    if (is_remote) return fo.askRemote(w, pos, list.slice());
    fo.pending = null;
    var fbuf: [4096]u8 = undefined;
    const dir = w.folder(&fbuf);
    if (dir.len > 0) if (path.longestKnown(line, pos.col, Listed{ .dir = dir }, Listed.known)) |*cand| {
        if (fo.tryName(w, pos, cand, dir)) return;
    };
    for (list.slice()) |*cand| if (fo.tryName(w, pos, cand, dir)) return;
}

/// Candidate `cand` resolved against `dir`: an existing file (a folder at
/// a shell's prompt, or while dropping) → the mark. True: found.
fn tryName(fo: *FileOpener, w: *JobWindow, pos: Screen.TextPos, cand: *const path.Candidate, dir: []const u8) bool {
    var m: Mark = .{ .range = .{
        .start = .{ .line = pos.line, .col = cand.start },
        .end = .{ .line = pos.line, .col = cand.end },
    } };
    m.len = (resolve(&m.buf, dir, cand.text()) orelse return false).len;
    switch (kindOf(m.buf[0..m.len :0])) {
        .none => return false,
        .file => if (drop_mode) return false,
        // cd needs a shell waiting at its prompt (a drop doesn't).
        .folder => if (drop_mode or w.atPrompt()) {
            m.folder = true;
        } else return false,
    }
    fo.mark = m;
    return true;
}

/// For `file_path.longestKnown`: is this text a name with blanks /
/// punctuation in a folder's listing? `My File.txt`: in the window's
/// folder; `docs/My File.txt`, `~/x/a b`: in that folder. A plain name
/// under a folder with blanks (`My Dir/notes.txt`) isn't in any listing
/// (only the names a run misses are): checked on disk.
const Listed = struct {
    dir: []const u8,

    fn known(l: Listed, text: []const u8) bool {
        const slash = std.mem.lastIndexOfScalar(u8, text, '/') orelse
            return DirCache.has(l.dir, text);
        const name = text[slash + 1 ..];
        if (name.len == 0) return false;
        var buf: [4096]u8 = undefined;
        if (!path.specialName(name)) {
            const full = resolve(&buf, l.dir, text) orelse return false;
            return kindOf(full) != .none;
        }
        const parent = if (slash == 0) "/" else text[0..slash];
        const pdir = resolve(&buf, l.dir, parent) orelse return false;
        return DirCache.has(pdir, name);
    }
};

/// The outlined name at `pos`, if there is one there.
pub fn markAt(fo: *FileOpener, pos: ?Screen.TextPos) ?*Mark {
    if (!enabled) return null;
    const m = if (fo.mark) |*m| m else return null;
    const p = pos orelse return null;
    return if (m.range.contains(p)) m else null;
}

/// A double-click at `pos`: on the outlined name, open it (`pick`: with
/// the app picker).
pub fn open(fo: *FileOpener, w: *JobWindow, pos: ?Screen.TextPos, pick: bool) Action {
    const m = fo.markAt(pos) orelse return .none;
    if (m.folder) {
        if (!(if (m.remote) w.remote_idle else w.atPrompt())) return .none;
        // `cd '<dir>'` + Enter (Ctrl+U first: the line is just the cd).
        w.cdTo(m.file());
        return .done;
    }
    if (m.remote) return .{ .fetch = .{ .path = m.file(), .pick = pick } };
    return .{ .show = .{ .path = m.file(), .pick = pick } };
}

/// Remote: check the candidates on the other machine (relative ones from
/// the remote shell's folder; none known: absolute and ~ only). The reply
/// comes back through `remoteReply`.
fn askRemote(fo: *FileOpener, w: *JobWindow, pos: Screen.TextPos, cands: []const path.Candidate) void {
    // The same name as last time (moving along it): its answer is coming
    // or came (no outline: not a file there).
    if (cands.len > 0) {
        const first: Screen.TextRange = .{ .start = .{ .line = pos.line, .col = cands[0].start }, .end = .{ .line = pos.line, .col = cands[0].end } };
        if (fo.asked) |a| if (std.meta.eql(a, first)) return;
        fo.asked = first;
    } else fo.asked = null;
    fo.pending = null;
    const rcwd = w.remoteCwd();
    var pd: @typeInfo(@TypeOf(fo.pending)).optional.child = .{ .id = 0, .n = 0, .marks = undefined };
    var paths: [path.max_candidates][]const u8 = undefined;
    for (cands) |*cand| {
        const t = cand.text();
        var m: Mark = .{ .remote = true, .range = .{
            .start = .{ .line = pos.line, .col = cand.start },
            .end = .{ .line = pos.line, .col = cand.end },
        } };
        const p = if (t[0] == '/' or std.mem.startsWith(u8, t, "~/"))
            std.fmt.bufPrint(&m.buf, "{s}", .{t}) catch continue
        else if (rcwd.len > 0)
            std.fmt.bufPrint(&m.buf, "{s}/{s}", .{ std.mem.trimEnd(u8, rcwd, "/"), t }) catch continue
        else
            continue;
        m.len = p.len;
        pd.marks[pd.n] = m;
        pd.n += 1;
    }
    if (pd.n == 0) return;
    for (pd.marks[0..pd.n], 0..) |*m, i| paths[i] = m.file();
    var cbuf: [8192]u8 = undefined;
    var cw: std.Io.Writer = .fixed(&cbuf);
    remote.checkScript(&cw, paths[0..pd.n]) catch return;
    const l = w.linkReady() orelse return;
    pd.id = l.request(.files, cw.buffered()) orelse return;
    fo.pending = pd;
}

/// The reply to a remote check: one line per candidate (`f` file, `d`
/// folder, `-` neither). A stale reply (a newer check went out) is
/// dropped. True: redraw.
pub fn remoteReply(fo: *FileOpener, w: *const JobWindow, id: u32, text: []const u8) bool {
    const pd = fo.pending orelse return false;
    if (pd.id != id) return false;
    fo.pending = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i >= pd.n) break;
        const kind = std.mem.trim(u8, line, " \r");
        if (std.mem.eql(u8, kind, "f") or (std.mem.eql(u8, kind, "d") and w.remote_idle)) {
            fo.mark = pd.marks[i];
            fo.mark.?.folder = kind[0] == 'd';
            return true;
        }
    }
    return false;
}

/// The absolute path of `p` ("~" = home, relative = from `dir`),
/// NUL-terminated in `buf`.
pub fn resolve(buf: []u8, dir: []const u8, p: []const u8) ?[:0]const u8 {
    if (p.len == 0) return null;
    if (p[0] == '/') return std.fmt.bufPrintZ(buf, "{s}", .{p}) catch null;
    if (p[0] == '~' and (p.len == 1 or p[1] == '/')) {
        const home = std.mem.span(c.getenv("HOME") orelse return null);
        return std.fmt.bufPrintZ(buf, "{s}{s}", .{ home, p[1..] }) catch null;
    }
    if (dir.len == 0) return null;
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), p }) catch null;
}

pub const Kind = enum { none, file, folder };

/// `file`: an existing regular file that isn't a program (no exec bit,
/// and on macOS not .command / .terminal / .tool: opening those runs
/// code); `folder`: an existing folder; else `none`.
pub fn kindOf(p: [:0]const u8) Kind {
    var st: c.struct_stat = undefined;
    if (c.stat(p.ptr, &st) != 0) return .none;
    const fmt = st.st_mode & 0o170000;
    if (fmt == 0o040000) return .folder; // S_ISDIR
    if (fmt != 0o100000) return .none; // S_ISREG
    if (st.st_mode & 0o111 != 0) return .none;
    if (builtin.os.tag == .macos) {
        const ext = std.fs.path.extension(p);
        for ([_][]const u8{ ".command", ".terminal", ".tool" }) |bad| if (std.ascii.eqlIgnoreCase(ext, bad)) return .none;
    }
    return .file;
}

test "resolving" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("/a/b/c.txt", resolve(&buf, "/a/b/", "c.txt").?);
    try t.expectEqualStrings("/x", resolve(&buf, "/a", "/x").?);
    try t.expectEqual(Kind.none, kindOf("/nonexistent-gtty-file"));
    try t.expectEqual(Kind.none, kindOf("/bin/ls")); // a program
    try t.expectEqual(Kind.folder, kindOf("/tmp"));
}
