// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! What is in a folder, for the file opener: the names a plain run of
//! text can't find (`file_path.specialName`: a blank, a bracket, a quote
//! … inside, or punctuation at the end: `My File.txt`, `a (1).pdf`), so a
//! name with blanks in a window's output can be matched against them
//! (`file_path.longestKnown`). The other names are found by the run and a
//! check on disk, as before.
//!
//! Names are kept by their text without the blanks they start or end
//! with (` Buck Rogers E01.mp4` is looked up as `Buck Rogers E01.mp4`):
//! the outline goes around what can be seen, `find` gives back the real
//! name for the file itself.
//!
//! The last `max_dirs` folders asked about are kept (the least recently
//! used one goes). A folder is read again when its modification time
//! changed (a file added, removed or renamed in it), looked at no more
//! than every `restat_ms`. Very large folders: the first `max_scan`
//! entries.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const file_path = @import("file_path.zig");

const max_dirs = 8;
const max_scan = 50_000;
const restat_ms = 500;

const gpa = std.heap.c_allocator;

const Dir = struct {
    path: []u8,
    mtime: [2]i64,
    /// Name without its outer blanks → the name.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,
    /// Last used (`clock`), last looked at on disk (ms).
    used: u64 = 0,
    stat_ms: u64 = 0,

    fn deinit(d: *Dir) void {
        d.names.deinit(gpa);
        d.arena.deinit();
        gpa.free(d.path);
    }
};

var dirs: [max_dirs]?Dir = [_]?Dir{null} ** max_dirs;
var clock: u64 = 0;

/// The entry of folder `dir` (absolute) shown as `text` (no outer
/// blanks): `text` itself, or a name that starts / ends with blanks.
/// Only names the plain run misses (`specialName`, or outer blanks).
pub fn find(dir: []const u8, text: []const u8) ?[]const u8 {
    const d = get(dir) orelse return null;
    return d.names.get(text);
}

/// `name` without the blanks it starts or ends with.
pub fn trimmed(name: []const u8) []const u8 {
    return std.mem.trim(u8, name, " \t");
}

/// Forget everything (at exit).
pub fn deinit() void {
    for (&dirs) |*slot| if (slot.*) |*d| {
        d.deinit();
        slot.* = null;
    };
}

fn mtimeOf(z: [:0]const u8) ?[2]i64 {
    var st: c.struct_stat = undefined;
    if (c.stat(z.ptr, &st) != 0) return null;
    if (st.st_mode & 0o170000 != 0o040000) return null; // not a folder
    const ts = if (builtin.os.tag == .macos) st.st_mtimespec else st.st_mtim;
    return .{ @intCast(ts.tv_sec), @intCast(ts.tv_nsec) };
}

/// The listing of `dir`, read now if it isn't kept or changed on disk.
fn get(dir_in: []const u8) ?*Dir {
    const dir = if (dir_in.len > 1) std.mem.trimEnd(u8, dir_in, "/") else dir_in;
    var zbuf: [4097]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{dir}) catch return null;
    clock += 1;
    const now = c.SDL_GetTicks();
    var free_slot: ?usize = null;
    var oldest: usize = 0;
    for (&dirs, 0..) |*slot, i| {
        const d = if (slot.*) |*d| d else {
            if (free_slot == null) free_slot = i;
            continue;
        };
        if (std.mem.eql(u8, d.path, dir)) {
            d.used = clock;
            if (now -| d.stat_ms < restat_ms) return d;
            d.stat_ms = now;
            const m = mtimeOf(z) orelse {
                d.deinit();
                slot.* = null;
                return null;
            };
            if (std.mem.eql(i64, &m, &d.mtime)) return d;
            d.deinit();
            slot.* = null;
            return load(slot, dir, z, now);
        }
        if (dirs[oldest] == null or d.used < dirs[oldest].?.used) oldest = i;
    }
    const i = free_slot orelse blk: {
        dirs[oldest].?.deinit();
        dirs[oldest] = null;
        break :blk oldest;
    };
    return load(&dirs[i], dir, z, now);
}

fn load(slot: *?Dir, dir: []const u8, z: [:0]const u8, now: u64) ?*Dir {
    const m = mtimeOf(z) orelse return null;
    const p = gpa.dupe(u8, dir) catch return null;
    slot.* = .{ .path = p, .mtime = m, .arena = .init(gpa), .used = clock, .stat_ms = now };
    const d = &slot.*.?;
    const h = c.opendir(z.ptr) orelse return d;
    defer _ = c.closedir(h);
    var seen: usize = 0;
    while (c.readdir(h)) |e| {
        seen += 1;
        if (seen > max_scan) break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&e.*.d_name)));
        const key = trimmed(name);
        if (key.len == 0) continue;
        const outer = key.len != name.len;
        if (!outer and !file_path.specialName(name)) continue;
        const copy = d.arena.allocator().dupe(u8, name) catch break;
        const kcopy = copy[@intFromPtr(key.ptr) - @intFromPtr(name.ptr) ..][0..key.len];
        // `a b` and ` a b` both there: the text as shown is the name.
        const gop = d.names.getOrPut(gpa, kcopy) catch break;
        if (!gop.found_existing or !outer) gop.value_ptr.* = copy;
    }
    return d;
}
