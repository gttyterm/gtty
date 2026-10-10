// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The folders the user worked in lately (the recent chip): a folder
//! under home (not home itself) counts a use each time a command that
//! does something is run there (`countsAsUse`: not cd, ls, find, pwd, …).
//! Kept: what was used within `window_s` (3 days) of the newest use, so
//! a week away doesn't empty it. Shown: the `shown_max` most used there
//! (ties: the most recent).
//!
//! The file, shared by every gtty process (New Window is another one):
//! `$GTTY_RECENT`, else `$XDG_STATE_HOME/gtty/recent-folders`, else
//! `~/.local/state/gtty/recent-folders`; one line per folder,
//! tab-separated `<uses> <last, unix s> <path>`. Each process counts its
//! own new uses (`added`) and `sync` merges them into what is on disk.

const std = @import("std");
const c = @import("../c.zig").c;

const RecentFolders = @This();

/// Uses older than this before the newest one are forgotten.
pub const window_s: i64 = 3 * 24 * 3600;
/// Folders on the chip's list.
pub const shown_max = 7;
/// Folders kept at most (the least used go).
const keep_max = 200;

pub const Entry = struct {
    path: []u8,
    uses: u32,
    last: i64,
    /// Uses this process added since its last `sync`.
    added: u32 = 0,
};

gpa: std.mem.Allocator,
entries: std.ArrayList(Entry) = .empty,
/// Changed since the last `sync`.
dirty: bool = false,

pub fn init(gpa: std.mem.Allocator) RecentFolders {
    return .{ .gpa = gpa };
}

pub fn deinit(r: *RecentFolders) void {
    for (r.entries.items) |e| r.gpa.free(e.path);
    r.entries.deinit(r.gpa);
}

fn now() i64 {
    return @intCast(c.time(null));
}

/// A command was run in `dir`: count a use, when `dir` is a folder under
/// `home` (home itself is easy to get to).
pub fn use(r: *RecentFolders, dir: []const u8, home: []const u8) void {
    if (!underHome(dir, home)) return;
    r.useAt(dir, now());
}

pub fn useAt(r: *RecentFolders, dir: []const u8, at: i64) void {
    r.dirty = true;
    defer r.prune();
    for (r.entries.items) |*e| if (std.mem.eql(u8, e.path, dir)) {
        e.uses +|= 1;
        e.added +|= 1;
        e.last = @max(e.last, at);
        return;
    };
    const copy = r.gpa.dupe(u8, dir) catch return;
    r.entries.append(r.gpa, .{ .path = copy, .uses = 1, .last = at, .added = 1 }) catch r.gpa.free(copy);
}

/// Strictly inside `home` (`/Users/me/src`, not `/Users/me` or `/Users/meg`).
pub fn underHome(dir: []const u8, home: []const u8) bool {
    const h = std.mem.trimEnd(u8, home, "/");
    if (h.len == 0) return false;
    return dir.len > h.len + 1 and std.mem.startsWith(u8, dir, h) and dir[h.len] == '/';
}

/// Forget what was last used more than `window_s` before the newest use,
/// then the least used beyond `keep_max`.
fn prune(r: *RecentFolders) void {
    var newest: i64 = 0;
    for (r.entries.items) |e| newest = @max(newest, e.last);
    var i: usize = 0;
    while (i < r.entries.items.len) {
        if (r.entries.items[i].last < newest - window_s) {
            r.gpa.free(r.entries.swapRemove(i).path);
        } else i += 1;
    }
    if (r.entries.items.len > keep_max) {
        std.mem.sort(Entry, r.entries.items, {}, better);
        for (r.entries.items[keep_max..]) |e| r.gpa.free(e.path);
        r.entries.shrinkRetainingCapacity(keep_max);
    }
}

/// More used first; ties: the more recent.
fn better(_: void, a: Entry, b: Entry) bool {
    if (a.uses != b.uses) return a.uses > b.uses;
    return a.last > b.last;
}

/// The chip's list: up to `out.len` folders, most used first, that still
/// exist and are under `home`. The slices point into the entries (valid
/// until the next change).
pub fn top(r: *RecentFolders, home: []const u8, out: [][]const u8) []const []const u8 {
    std.mem.sort(Entry, r.entries.items, {}, better);
    var n: usize = 0;
    for (r.entries.items) |e| {
        if (n == out.len) break;
        if (!underHome(e.path, home) or !isDir(r.gpa, e.path)) continue;
        out[n] = e.path;
        n += 1;
    }
    return out[0..n];
}

fn isDir(gpa: std.mem.Allocator, p: []const u8) bool {
    const z = gpa.dupeZ(u8, p) catch return false;
    defer gpa.free(z);
    var st: c.struct_stat = undefined;
    return c.stat(z.ptr, &st) == 0 and (st.st_mode & c.S_IFMT) == c.S_IFDIR;
}

// ------------------------------------------------------------ commands

/// A command line that does something in its folder (a use): its first
/// word (after `VAR=value`s) is not a folder look-up or shell bookkeeping
/// (cd, ls, find, pwd, echo, …). Empty lines don't count.
pub fn countsAsUse(cmd: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    const first = while (it.next()) |w| {
        if (std.mem.indexOfScalar(u8, w, '=')) |eq| if (eq > 0) continue;
        break w;
    } else return false;
    // `\ls`, `command ls`: the word itself.
    const name = std.mem.trimStart(u8, first, "\\");
    for (lookups) |l| if (std.mem.eql(u8, name, l)) return false;
    return true;
}

const lookups = [_][]const u8{
    // moving around
    "cd",    "pushd",  "popd",    "dirs",   "z",     "zi",   "j",      "autojump", "zoxide",   "..",       "...",      "-",
    // listing / finding / asking about the folder
    "ls",    "ll",     "la",      "l",      "lsd",   "exa",  "eza",    "tree",     "dir",      "vdir",     "gls",      "find",
    "fd",    "fdfind", "locate",  "pwd",    "du",    "df",   "stat",   "file",     "realpath", "readlink", "basename", "dirname",
    "which", "whence", "where",   "type",   "hash",
    // shell bookkeeping
     "echo", "printf", "clear",    "reset",    "exit",     "logout",   "history",
    "fc",    "alias",  "unalias", "export", "unset", "set",  "setopt", "unsetopt", "source",   ".",        "true",     "false",
    ":",     "jobs",   "fg",      "bg",     "wait",  "read", "let",    "declare",  "typeset",  "local",    "rehash",
};

// ------------------------------------------------------------ file

/// Where the file is; null: no home.
pub fn path(buf: []u8) ?[:0]const u8 {
    if (c.getenv("GTTY_RECENT")) |p| return std.fmt.bufPrintSentinel(buf, "{s}", .{std.mem.span(p)}, 0) catch null;
    if (c.getenv("XDG_STATE_HOME")) |x| if (x[0] != 0)
        return std.fmt.bufPrintSentinel(buf, "{s}/gtty/recent-folders", .{std.mem.span(x)}, 0) catch null;
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/.local/state/gtty/recent-folders", .{std.mem.span(home)}, 0) catch null;
}

/// Read the file again and fold in this process's new uses; write it
/// back when they were any. The list is then the file's (other gtty
/// processes' uses included).
pub fn sync(r: *RecentFolders) void {
    var pbuf: [4096]u8 = undefined;
    const p = path(&pbuf) orelse return;
    var disk = RecentFolders.init(r.gpa);
    defer disk.deinit();
    disk.load(p);
    const write = r.dirty;
    r.mergeInto(&disk);
    std.mem.swap(std.ArrayList(Entry), &r.entries, &disk.entries);
    r.dirty = false;
    if (write) r.save(p);
}

/// Add this process's new uses to `disk` (theirs stay).
fn mergeInto(r: *RecentFolders, disk: *RecentFolders) void {
    for (r.entries.items) |*e| {
        if (e.added == 0) continue;
        const found = for (disk.entries.items) |*d| {
            if (std.mem.eql(u8, d.path, e.path)) break d;
        } else null;
        if (found) |d| {
            d.uses +|= e.added;
            d.last = @max(d.last, e.last);
        } else {
            const copy = r.gpa.dupe(u8, e.path) catch continue;
            disk.entries.append(r.gpa, .{ .path = copy, .uses = e.added, .last = e.last }) catch r.gpa.free(copy);
        }
        e.added = 0;
    }
    disk.prune();
}

fn load(r: *RecentFolders, p: [:0]const u8) void {
    const fp = c.fopen(p.ptr, "r") orelse return;
    defer _ = c.fclose(fp);
    var buf: [4200]u8 = undefined;
    while (c.fgets(&buf, buf.len, fp) != null) r.parseLine(std.mem.trimEnd(u8, std.mem.sliceTo(&buf, 0), "\r\n"));
}

pub fn parseLine(r: *RecentFolders, line: []const u8) void {
    if (line.len == 0 or line[0] == '#') return;
    var it = std.mem.splitScalar(u8, line, '\t');
    const uses = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
    const last = std.fmt.parseInt(i64, it.next() orelse return, 10) catch return;
    const dir = it.rest();
    if (dir.len == 0 or dir[0] != '/') return;
    const copy = r.gpa.dupe(u8, dir) catch return;
    r.entries.append(r.gpa, .{ .path = copy, .uses = uses, .last = last }) catch r.gpa.free(copy);
}

pub fn format(r: *const RecentFolders, w: *std.Io.Writer) !void {
    try w.writeAll("# gtty recent folders (the recent chip): uses, last use (unix s), folder\n");
    for (r.entries.items) |e| try w.print("{d}\t{d}\t{s}\n", .{ e.uses, e.last, e.path });
}

/// Temp file + rename, private.
fn save(r: *const RecentFolders, p: [:0]const u8) void {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| mkdirs(p[0..slash]);
    var aw: std.Io.Writer.Allocating = .init(r.gpa);
    defer aw.deinit();
    r.format(&aw.writer) catch return;
    var tbuf: [4200]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tbuf, "{s}.{d}.tmp", .{ p, c.getpid() }, 0) catch return;
    const fp = c.fopen(tmp.ptr, "w") orelse return;
    _ = c.chmod(tmp.ptr, 0o600);
    const data = aw.written();
    const ok = c.fwrite(data.ptr, 1, data.len, fp) == data.len;
    if (c.fclose(fp) != 0 or !ok) {
        _ = c.unlink(tmp.ptr);
        return;
    }
    _ = c.rename(tmp.ptr, p.ptr);
}

fn mkdirs(dir: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (dir.len == 0 or dir.len >= buf.len) return;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir[0..i]}, 0) catch return;
            _ = c.mkdir(z.ptr, 0o700);
        }
    }
}

test "commands that count as a use" {
    const t = std.testing;
    try t.expect(countsAsUse("make"));
    try t.expect(countsAsUse("git status"));
    try t.expect(countsAsUse("CC=clang make -j8"));
    try t.expect(countsAsUse("vim x.c"));
    try t.expect(!countsAsUse("ls -la"));
    try t.expect(!countsAsUse("\\ls"));
    try t.expect(!countsAsUse("cd src"));
    try t.expect(!countsAsUse("find . -name x"));
    try t.expect(!countsAsUse("pwd"));
    try t.expect(!countsAsUse("FOO=1"));
    try t.expect(!countsAsUse("   "));
}

test "under home only, not home itself" {
    const t = std.testing;
    try t.expect(underHome("/Users/me/src", "/Users/me"));
    try t.expect(underHome("/Users/me/src", "/Users/me/"));
    try t.expect(!underHome("/Users/me", "/Users/me"));
    try t.expect(!underHome("/Users/me/", "/Users/me"));
    try t.expect(!underHome("/Users/meg/src", "/Users/me"));
    try t.expect(!underHome("/tmp/x", "/Users/me"));
    try t.expect(!underHome("/Users/me/src", ""));
}

test "kept: 3 days before the newest use; most used first" {
    const t = std.testing;
    var r = RecentFolders.init(t.allocator);
    defer r.deinit();
    const day = 24 * 3600;
    r.useAt("/h/old", 1000);
    r.useAt("/h/a", 9 * day);
    r.useAt("/h/b", 10 * day + 5);
    r.useAt("/h/b", 10 * day + 6);
    // 13 days: /h/a (4 days before) goes, /h/b (under 3) stays; /h/old
    // went already.
    r.useAt("/h/c", 13 * day);
    try t.expectEqual(@as(usize, 2), r.entries.items.len);
    std.mem.sort(Entry, r.entries.items, {}, better);
    try t.expectEqualStrings("/h/b", r.entries.items[0].path);
    try t.expectEqualStrings("/h/c", r.entries.items[1].path);
}

test "merge adds only this process's new uses" {
    const t = std.testing;
    var mine = RecentFolders.init(t.allocator);
    defer mine.deinit();
    var disk = RecentFolders.init(t.allocator);
    defer disk.deinit();
    disk.parseLine("5\t100\t/h/a");
    disk.parseLine("2\t90\t/h/b");
    mine.parseLine("5\t100\t/h/a"); // loaded earlier
    mine.useAt("/h/a", 120);
    mine.useAt("/h/c", 130);
    mine.mergeInto(&disk);
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try disk.format(&aw.writer);
    try t.expect(std.mem.indexOf(u8, aw.written(), "6\t120\t/h/a\n") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "2\t90\t/h/b\n") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "1\t130\t/h/c\n") != null);
    // Merged once: a second merge adds nothing.
    mine.mergeInto(&disk);
    try t.expectEqual(@as(u32, 6), disk.entries.items[0].uses);
}
