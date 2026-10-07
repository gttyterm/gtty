// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The complete output of every job, teed to a file: the job window's
//! Screen keeps only a memory window (the last N rows), the file keeps
//! everything, as the raw bytes the program wrote (stdout and stderr
//! together — one PTY).
//!
//! Files live in a temp folder per gtty instance, `$TMPDIR/gtty-<pid>/`,
//! one `job-<serial>.log` per job window. A job's file is deleted when its
//! window closes; the folder when gtty exits. Folders left by a gtty that
//! crashed are swept at the next start.

const std = @import("std");
const c = @import("../c.zig").c;

/// The per-instance temp folder.
pub const Dir = struct {
    path: [:0]u8,

    pub fn create(gpa: std.mem.Allocator) !Dir {
        const tmp = if (c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
        const base = std.mem.trimEnd(u8, tmp, "/");
        sweep(gpa, base);
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/gtty-{d}", .{ base, c.getpid() }, 0);
        errdefer gpa.free(path);
        if (c.mkdir(path.ptr, 0o700) != 0) return error.TempDir;
        return .{ .path = path };
    }

    /// Delete `gtty-<pid>` folders whose gtty is no longer running.
    fn sweep(gpa: std.mem.Allocator, base: []const u8) void {
        const base_z = gpa.dupeZ(u8, base) catch return;
        defer gpa.free(base_z);
        const d = c.opendir(base_z.ptr) orelse return;
        defer _ = c.closedir(d);
        while (c.readdir(d)) |e| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&e.*.d_name)));
            if (!std.mem.startsWith(u8, name, "gtty-")) continue;
            const pid = std.fmt.parseInt(c.pid_t, name[5..], 10) catch continue;
            if (c.kill(pid, 0) == 0 or std.c._errno().* != @intFromEnum(std.c.E.SRCH)) continue;
            var buf: [4096]u8 = undefined;
            const dir = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ base, name }, 0) catch continue;
            removeTree(dir);
        }
    }

    /// A folder and everything in it (job logs, hook files, remote copies).
    pub fn removeTree(dir: [:0]const u8) void {
        removeTreeDepth(dir, 4);
    }

    fn removeTreeDepth(dir: [:0]const u8, depth: u8) void {
        if (c.opendir(dir.ptr)) |d| {
            defer _ = c.closedir(d);
            while (c.readdir(d)) |e| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&e.*.d_name)));
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                var buf: [4096]u8 = undefined;
                const f = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0) catch continue;
                if (c.unlink(f.ptr) != 0 and depth > 0) removeTreeDepth(f, depth - 1);
            }
        }
        _ = c.rmdir(dir.ptr);
    }

    /// Remove the folder (the job windows have deleted their files by now;
    /// the shell hook files go with it).
    pub fn remove(d: *Dir, gpa: std.mem.Allocator) void {
        removeTree(d.path);
        gpa.free(d.path);
    }
};

/// One job's output file.
pub const Log = struct {
    file: *c.FILE,
    path: [:0]u8,
    bytes: u64 = 0,

    pub fn open(gpa: std.mem.Allocator, dir: []const u8, serial: u32) !Log {
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/job-{d}.log", .{ dir, serial }, 0);
        errdefer gpa.free(path);
        const f = c.fopen(path.ptr, "wb") orelse return error.LogOpen;
        return .{ .file = f, .path = path };
    }

    pub fn write(l: *Log, bytes: []const u8) void {
        l.bytes += c.fwrite(bytes.ptr, 1, bytes.len, l.file);
    }

    pub fn flush(l: *Log) void {
        _ = c.fflush(l.file);
    }

    /// Everything written so far.
    pub fn readAll(l: *Log, gpa: std.mem.Allocator) ![]u8 {
        _ = c.fflush(l.file);
        const f = c.fopen(l.path.ptr, "rb") orelse return error.LogOpen;
        defer _ = c.fclose(f);
        const buf = try gpa.alloc(u8, @intCast(l.bytes));
        errdefer gpa.free(buf);
        const n = c.fread(buf.ptr, 1, buf.len, f);
        return if (n == buf.len) buf else gpa.realloc(buf, n);
    }

    /// Bytes [start, end) written so far.
    pub fn readRange(l: *Log, gpa: std.mem.Allocator, start: u64, end: u64) ![]u8 {
        _ = c.fflush(l.file);
        const to = @min(end, l.bytes);
        if (start >= to) return gpa.alloc(u8, 0);
        const f = c.fopen(l.path.ptr, "rb") orelse return error.LogOpen;
        defer _ = c.fclose(f);
        if (c.fseeko(f, @intCast(start), c.SEEK_SET) != 0) return error.LogRead;
        const buf = try gpa.alloc(u8, @intCast(to - start));
        errdefer gpa.free(buf);
        const n = c.fread(buf.ptr, 1, buf.len, f);
        return if (n == buf.len) buf else gpa.realloc(buf, n);
    }

    /// Close and delete the file.
    pub fn close(l: *Log, gpa: std.mem.Allocator) void {
        _ = c.fclose(l.file);
        _ = c.unlink(l.path.ptr);
        gpa.free(l.path);
    }
};
