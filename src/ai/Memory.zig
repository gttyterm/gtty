// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! gtty's local memory for the AI: folders the user's shells were in (how
//! often, when last, and the file types found there), the ssh hosts they
//! used, and short notes the AI asked to keep ("tax papers are in
//! ~/Documents/Finance"). It goes into the system prompt so "my photos"
//! or "the build server" can be found without searching the whole disk.
//!
//! Kept on this computer only, in a text file the user can read or delete:
//! `$GTTY_AI_MEMORY`, else `$XDG_STATE_HOME/gtty/ai-memory`, else
//! `~/.local/state/gtty/ai-memory`. One entry per line, tab-separated:
//!
//!     folder <visits> <last, unix s> <path> <ext:count …>
//!     ssh    <uses>   <last>          <destination>
//!     note   <text>
//!
//! Only names, counts and paths: never what is inside the files.

const std = @import("std");
const c = @import("../c.zig").c;

const Memory = @This();

pub const max_folders = 150;
pub const max_hosts = 40;
pub const max_notes = 40;
/// File types kept per folder (the most common).
pub const max_types = 6;
/// Entries read when counting a folder's file types.
const scan_max = 4000;

pub const Type = struct {
    ext: [12]u8 = undefined,
    ext_len: u8 = 0,
    count: u32 = 0,

    pub fn name(t: *const Type) []const u8 {
        return t.ext[0..t.ext_len];
    }
};

pub const Folder = struct {
    path: []u8,
    visits: u32,
    last: i64,
    types: [max_types]Type = [_]Type{.{}} ** max_types,
    n_types: u8 = 0,
};

pub const Host = struct {
    dest: []u8,
    uses: u32,
    last: i64,
};

gpa: std.mem.Allocator,
folders: std.ArrayList(Folder) = .empty,
hosts: std.ArrayList(Host) = .empty,
notes: std.ArrayList([]u8) = .empty,
/// Changed since the last save.
dirty: bool = false,

pub fn init(gpa: std.mem.Allocator) Memory {
    return .{ .gpa = gpa };
}

pub fn deinit(m: *Memory) void {
    m.clear();
    m.folders.deinit(m.gpa);
    m.hosts.deinit(m.gpa);
    m.notes.deinit(m.gpa);
}

/// Forget everything (the file is rewritten empty at the next save).
pub fn clear(m: *Memory) void {
    for (m.folders.items) |f| m.gpa.free(f.path);
    for (m.hosts.items) |h| m.gpa.free(h.dest);
    for (m.notes.items) |n| m.gpa.free(n);
    m.folders.clearRetainingCapacity();
    m.hosts.clearRetainingCapacity();
    m.notes.clearRetainingCapacity();
    m.dirty = true;
}

fn now() i64 {
    return @intCast(c.time(null));
}

// ------------------------------------------------------------ recording

/// A shell is in folder `dir` now: count the visit and its file types.
pub fn visitFolder(m: *Memory, dir: []const u8) void {
    if (dir.len == 0 or dir[0] != '/') return;
    var types: [max_types]Type = undefined;
    const n = scanTypes(dir, &types);
    m.recordFolder(dir, now(), types[0..n]);
}

fn recordFolder(m: *Memory, dir: []const u8, at: i64, types: []const Type) void {
    m.dirty = true;
    for (m.folders.items) |*f| if (std.mem.eql(u8, f.path, dir)) {
        f.visits +|= 1;
        f.last = at;
        f.n_types = @intCast(types.len);
        @memcpy(f.types[0..types.len], types);
        return;
    };
    const copy = m.gpa.dupe(u8, dir) catch return;
    var f: Folder = .{ .path = copy, .visits = 1, .last = at, .n_types = @intCast(types.len) };
    @memcpy(f.types[0..types.len], types);
    if (m.folders.items.len >= max_folders) m.dropFolder();
    m.folders.append(m.gpa, f) catch m.gpa.free(copy);
}

/// Make room: the folder with the lowest score goes (few visits, long ago).
fn dropFolder(m: *Memory) void {
    var worst: usize = 0;
    for (m.folders.items, 0..) |f, i| if (score(f) < score(m.folders.items[worst])) {
        worst = i;
    };
    m.gpa.free(m.folders.orderedRemove(worst).path);
}

fn score(f: Folder) f64 {
    const age_days: f64 = @as(f64, @floatFromInt(@max(now() - f.last, 0))) / 86400.0;
    return @as(f64, @floatFromInt(f.visits)) / (1.0 + age_days / 7.0);
}

/// An ssh / mosh session to `dest` was seen.
pub fn usedHost(m: *Memory, dest: []const u8) void {
    if (dest.len == 0) return;
    m.dirty = true;
    for (m.hosts.items) |*h| if (std.mem.eql(u8, h.dest, dest)) {
        h.uses +|= 1;
        h.last = now();
        return;
    };
    const d = m.gpa.dupe(u8, dest) catch return;
    if (m.hosts.items.len >= max_hosts) {
        var old: usize = 0;
        for (m.hosts.items, 0..) |h, i| if (h.last < m.hosts.items[old].last) {
            old = i;
        };
        m.gpa.free(m.hosts.orderedRemove(old).dest);
    }
    m.hosts.append(m.gpa, .{ .dest = d, .uses = 1, .last = now() }) catch m.gpa.free(d);
}

/// A fact the AI asked to keep (one line; tabs and line breaks become
/// spaces). The oldest note goes when there are too many; repeats are
/// dropped.
pub fn addNote(m: *Memory, text_in: []const u8) void {
    const text = std.mem.trim(u8, text_in, " \t\r\n");
    if (text.len == 0) return;
    const n = m.gpa.dupe(u8, text[0..@min(text.len, 300)]) catch return;
    for (n) |*ch| if (ch.* == '\t' or ch.* == '\n' or ch.* == '\r') {
        ch.* = ' ';
    };
    for (m.notes.items) |old| if (std.mem.eql(u8, old, n)) {
        m.gpa.free(n);
        return;
    };
    if (m.notes.items.len >= max_notes) m.gpa.free(m.notes.orderedRemove(0));
    m.notes.append(m.gpa, n) catch m.gpa.free(n);
    m.dirty = true;
}

/// The most common file extensions in `dir` (files only, hidden ones
/// skipped, lower case; "(none)" for names without one), most first.
fn scanTypes(dir: []const u8, out: *[max_types]Type) usize {
    var buf: [4096]u8 = undefined;
    const dz = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir}, 0) catch return 0;
    const d = c.opendir(dz.ptr) orelse return 0;
    defer _ = c.closedir(d);
    var all: [64]Type = undefined;
    var n_all: usize = 0;
    var seen: usize = 0;
    while (c.readdir(d)) |e| {
        seen += 1;
        if (seen > scan_max) break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&e.*.d_name)));
        if (name.len == 0 or name[0] == '.') continue;
        if (e.*.d_type != c.DT_REG) continue;
        countExt(&all, &n_all, extOf(name));
    }
    return topTypes(all[0..n_all], out);
}

fn extOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "(none)";
    if (dot == 0 or dot + 1 == name.len or name.len - dot - 1 > 10) return "(none)";
    return name[dot + 1 ..];
}

fn countExt(all: *[64]Type, n: *usize, ext: []const u8) void {
    var low: [12]u8 = undefined;
    const k = @min(ext.len, low.len);
    for (ext[0..k], 0..) |ch, i| low[i] = std.ascii.toLower(ch);
    for (all[0..n.*]) |*t| if (std.mem.eql(u8, t.name(), low[0..k])) {
        t.count += 1;
        return;
    };
    if (n.* == all.len) return;
    all[n.*] = .{ .ext_len = @intCast(k), .count = 1 };
    @memcpy(all[n.*].ext[0..k], low[0..k]);
    n.* += 1;
}

fn topTypes(all: []Type, out: *[max_types]Type) usize {
    std.mem.sort(Type, all, {}, struct {
        fn more(_: void, a: Type, b: Type) bool {
            return a.count > b.count;
        }
    }.more);
    const n = @min(all.len, max_types);
    @memcpy(out[0..n], all[0..n]);
    return n;
}

// ------------------------------------------------------------ prompt text

/// The memory as the system prompt shows it: the most used folders first
/// (at most `limit`), then the notes. `home` is shown as `~`.
pub fn describe(m: *const Memory, w: *std.Io.Writer, home: []const u8, limit: usize) !void {
    if (m.folders.items.len == 0 and m.notes.items.len == 0) return w.writeAll("(nothing remembered yet)\n");
    var order: [max_folders]usize = undefined;
    const n = m.folders.items.len;
    for (0..n) |i| order[i] = i;
    const Ctx = struct {
        fs: []const Folder,
        fn more(ctx: @This(), a: usize, b: usize) bool {
            return score(ctx.fs[a]) > score(ctx.fs[b]);
        }
    };
    std.mem.sort(usize, order[0..n], Ctx{ .fs = m.folders.items }, Ctx.more);
    if (n > 0) try w.writeAll("Folders (most used first; visits; file types there):\n");
    for (order[0..@min(n, limit)]) |i| {
        const f = m.folders.items[i];
        try w.writeAll("- ");
        try writePath(w, f.path, home);
        try w.print(" ({d}x)", .{f.visits});
        for (f.types[0..f.n_types], 0..) |t, k| try w.print("{s}{s}:{d}", .{ if (k == 0) " " else ", ", t.name(), t.count });
        try w.writeAll("\n");
    }
    if (m.notes.items.len > 0) {
        try w.writeAll("Notes:\n");
        for (m.notes.items) |t| try w.print("- {s}\n", .{t});
    }
}

fn writePath(w: *std.Io.Writer, p: []const u8, home: []const u8) !void {
    if (home.len > 1 and std.mem.startsWith(u8, p, home) and (p.len == home.len or p[home.len] == '/')) {
        try w.writeAll("~");
        return w.writeAll(p[home.len..]);
    }
    try w.writeAll(p);
}

/// The ssh hosts: used ones (most first), then `Host` names from
/// ~/.ssh/config not already listed (no wildcards).
pub fn describeHosts(m: *const Memory, w: *std.Io.Writer, ssh_config: []const u8) !void {
    var any = false;
    var order: [max_hosts]usize = undefined;
    const n = m.hosts.items.len;
    for (0..n) |i| order[i] = i;
    std.mem.sort(usize, order[0..n], m.hosts.items, struct {
        fn more(hs: []const Host, a: usize, b: usize) bool {
            return hs[a].uses > hs[b].uses;
        }
    }.more);
    for (order[0..n]) |i| {
        const h = m.hosts.items[i];
        try w.print("- {s} (used {d}x)\n", .{ h.dest, h.uses });
        any = true;
    }
    var lines = std.mem.splitScalar(u8, ssh_config, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len < 5 or !std.ascii.eqlIgnoreCase(l[0..4], "host") or (l[4] != ' ' and l[4] != '\t')) continue;
        var names = std.mem.tokenizeAny(u8, l[5..], " \t");
        while (names.next()) |name| {
            if (std.mem.indexOfAny(u8, name, "*?!") != null) continue;
            var dup = false;
            for (m.hosts.items) |h| if (std.mem.eql(u8, h.dest, name) or std.mem.endsWith(u8, h.dest, name) and h.dest.len > name.len and h.dest[h.dest.len - name.len - 1] == '@') {
                dup = true;
            };
            if (dup) continue;
            try w.print("- {s} (~/.ssh/config)\n", .{name});
            any = true;
        }
    }
    if (!any) try w.writeAll("(none known)\n");
}

// ------------------------------------------------------------ file

/// Where the file is; null: no home.
pub fn path(buf: []u8) ?[:0]const u8 {
    if (c.getenv("GTTY_AI_MEMORY")) |p| return std.fmt.bufPrintSentinel(buf, "{s}", .{std.mem.span(p)}, 0) catch null;
    if (c.getenv("XDG_STATE_HOME")) |x| if (x[0] != 0)
        return std.fmt.bufPrintSentinel(buf, "{s}/gtty/ai-memory", .{std.mem.span(x)}, 0) catch null;
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/.local/state/gtty/ai-memory", .{std.mem.span(home)}, 0) catch null;
}

/// Read the file (missing: empty memory).
pub fn load(m: *Memory) void {
    var pbuf: [4096]u8 = undefined;
    const p = path(&pbuf) orelse return;
    const fp = c.fopen(p.ptr, "r") orelse return;
    defer _ = c.fclose(fp);
    var buf: [8192]u8 = undefined;
    while (c.fgets(&buf, buf.len, fp) != null) m.parseLine(std.mem.trimEnd(u8, std.mem.sliceTo(&buf, 0), "\r\n"));
    m.dirty = false;
}

pub fn parseLine(m: *Memory, line: []const u8) void {
    var it = std.mem.splitScalar(u8, line, '\t');
    const kind = it.next() orelse return;
    if (std.mem.eql(u8, kind, "note")) return m.addNote(it.rest());
    const a = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
    const last = std.fmt.parseInt(i64, it.next() orelse return, 10) catch return;
    const name = it.next() orelse return;
    if (name.len == 0) return;
    if (std.mem.eql(u8, kind, "ssh")) {
        if (m.hosts.items.len >= max_hosts) return;
        const d = m.gpa.dupe(u8, name) catch return;
        m.hosts.append(m.gpa, .{ .dest = d, .uses = a, .last = last }) catch m.gpa.free(d);
    } else if (std.mem.eql(u8, kind, "folder")) {
        var types: [max_types]Type = undefined;
        var n: usize = 0;
        var ts = std.mem.tokenizeScalar(u8, it.rest(), ' ');
        while (ts.next()) |tok| {
            if (n == max_types) break;
            const colon = std.mem.lastIndexOfScalar(u8, tok, ':') orelse continue;
            const ext = tok[0..@min(colon, 12)];
            types[n] = .{ .ext_len = @intCast(ext.len), .count = std.fmt.parseInt(u32, tok[colon + 1 ..], 10) catch continue };
            @memcpy(types[n].ext[0..ext.len], ext);
            n += 1;
        }
        if (m.folders.items.len >= max_folders) return;
        const p = m.gpa.dupe(u8, name) catch return;
        var f: Folder = .{ .path = p, .visits = a, .last = last, .n_types = @intCast(n) };
        @memcpy(f.types[0..n], types[0..n]);
        m.folders.append(m.gpa, f) catch m.gpa.free(p);
    }
}

pub fn format(m: *const Memory, w: *std.Io.Writer) !void {
    try w.writeAll("# gtty AI memory: folders your shells were in (file types there), ssh hosts,\n# notes. Kept on this computer only; edit or delete freely.\n");
    for (m.folders.items) |f| {
        try w.print("folder\t{d}\t{d}\t{s}\t", .{ f.visits, f.last, f.path });
        for (f.types[0..f.n_types], 0..) |t, k| try w.print("{s}{s}:{d}", .{ if (k == 0) "" else " ", t.name(), t.count });
        try w.writeAll("\n");
    }
    for (m.hosts.items) |h| try w.print("ssh\t{d}\t{d}\t{s}\n", .{ h.uses, h.last, h.dest });
    for (m.notes.items) |n| try w.print("note\t{s}\n", .{n});
}

/// Write the file if something changed (temp file + rename, private).
pub fn save(m: *Memory) void {
    if (!m.dirty) return;
    m.dirty = false;
    var pbuf: [4096]u8 = undefined;
    const p = path(&pbuf) orelse return;
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| mkdirs(p[0..slash]);
    var aw: std.Io.Writer.Allocating = .init(m.gpa);
    defer aw.deinit();
    m.format(&aw.writer) catch return;
    var tbuf: [4200]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tbuf, "{s}.tmp", .{p}, 0) catch return;
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

test "memory: record, round trip, describe" {
    const t = std.testing;
    var m = Memory.init(t.allocator);
    defer m.deinit();
    var ty: [2]Type = .{ .{ .ext_len = 3, .count = 12 }, .{ .ext_len = 3, .count = 2 } };
    @memcpy(ty[0].ext[0..3], "pdf");
    @memcpy(ty[1].ext[0..3], "jpg");
    m.recordFolder("/home/k/Documents", now(), &ty);
    m.recordFolder("/home/k/Documents", now(), &ty);
    m.usedHost("k@build");
    m.addNote("tax\tpapers in ~/Documents/Finance");
    m.addNote("tax papers in ~/Documents/Finance"); // the same: dropped
    try t.expectEqual(@as(u32, 2), m.folders.items[0].visits);
    try t.expectEqual(@as(usize, 1), m.notes.items.len);

    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try m.format(&aw.writer);
    var back = Memory.init(t.allocator);
    defer back.deinit();
    var it = std.mem.splitScalar(u8, aw.written(), '\n');
    while (it.next()) |l| back.parseLine(l);
    try t.expectEqualStrings("/home/k/Documents", back.folders.items[0].path);
    try t.expectEqualStrings("pdf", back.folders.items[0].types[0].name());
    try t.expectEqual(@as(u32, 12), back.folders.items[0].types[0].count);
    try t.expectEqualStrings("k@build", back.hosts.items[0].dest);
    try t.expectEqualStrings("tax papers in ~/Documents/Finance", back.notes.items[0]);

    var dw: std.Io.Writer.Allocating = .init(t.allocator);
    defer dw.deinit();
    try back.describe(&dw.writer, "/home/k", 20);
    try t.expect(std.mem.indexOf(u8, dw.written(), "- ~/Documents (2x) pdf:12, jpg:2") != null);
    var hw: std.Io.Writer.Allocating = .init(t.allocator);
    defer hw.deinit();
    try back.describeHosts(&hw.writer, "Host build *.corp\n  HostName b.example\nHost pi\n");
    try t.expectEqualStrings("- k@build (used 1x)\n- pi (~/.ssh/config)\n", hw.written());
}

test "extensions" {
    const t = std.testing;
    try t.expectEqualStrings("pdf", extOf("a.b.pdf"));
    try t.expectEqualStrings("(none)", extOf("Makefile"));
    try t.expectEqualStrings("(none)", extOf("x."));
}
