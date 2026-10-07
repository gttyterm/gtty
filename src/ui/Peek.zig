// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The peek of a chip (UX doc: "Status bar behavior: chips and peeks"):
//! the git chip and the folder chip in a job window's footer.
//!
//!   * **Folder chip** (`kind` folder): the same box; expanded, the list is
//!     the folders above the current one (`/` on top, the parent at the
//!     bottom, next to the chip). Picking one asks App to `cd` there
//!     (`Action.cd`, the shell at its prompt only).
//!
//!   * **Peek:** a plain floating box over the chip, in the normal text
//!     size: [copy] [expand]  full branch name  [×].
//!   * **Expanded peek:** the same box grown upward into a list of the
//!     local branches (the current one marked) with a filter box on top
//!     that has the keyboard. Picking one runs `git switch` in the window's
//!     folder, in the background: green border and closed after 1 s, or a
//!     red border with git's message (the peek stays open).
//!   * **Dismissal:** the mouse leaving starts a 5 s countdown, shown by
//!     the thicker bottom border emptying right to left; coming back stops
//!     it. A click anywhere else or Esc closes it at once.
//!
//! App owns at most one Peek, routes the mouse and (while expanded) the
//! keyboard to it, and acts on what it returns.

const std = @import("std");
const c = @import("../c.zig").c;
const color = @import("../core/color.zig");
const Theme = color.Theme;
const Rgb = color.Rgb;
const Gfx = @import("../render/Gfx.zig");
const Rect = Gfx.Rect;
const ids = @import("ids.zig");
const git = @import("../core/git.zig");
const Process = @import("../core/Process.zig");
const JobWindow = @import("JobWindow.zig");

const Peek = @This();

gpa: std.mem.Allocator,
/// The job window whose chip opened it.
uid: ids.Id,
kind: Kind = .git,
/// The folder git runs in, and the full branch name (the chip's text).
dir: [:0]u8,
full: []u8,
/// The chip on screen (the peek covers it and grows up from it).
anchor: Rect,
expanded: bool = false,

/// Local branches (owned) and the ones matching the filter (indexes),
/// in git's order.
branches: std.ArrayList([]u8) = .empty,
shown: std.ArrayList(usize) = .empty,
filter: std.ArrayList(u8) = .empty,
/// Selected entry of `shown` (keyboard), first visible row, row under
/// the mouse.
sel: usize = 0,
top: usize = 0,
hover_row: ?usize = null,
over: Part = .none,

list_run: ?git.Run = null,
switch_run: ?git.Run = null,
/// Branch being switched to (owned).
target: []u8 = &.{},
state: State = .idle,
/// The picked branch was the current one (nothing to do).
already: bool = false,
state_ms: u64 = 0,
/// Git's message when switching failed (last lines).
err_msg: std.ArrayList(u8) = .empty,
/// When the mouse left the peek (the countdown runs); 0 while it is over it.
leave_ms: u64 = 0,

// Layout (pixels), from `layout`.
box: Rect = .{},
copy_r: Rect = .{},
expand_r: Rect = .{},
close_r: Rect = .{},
text_r: Rect = .{},
filter_r: Rect = .{},
list_r: Rect = .{},
msg_r: Rect = .{},
row_h: f32 = 1,
rows: usize = 0,
bar_h: f32 = 3,

pub const Kind = enum { git, folder };
pub const State = enum { idle, busy, ok, err };
pub const Part = enum { none, copy, expand, close };

/// What App should do after an event.
pub const Action = enum { none, redraw, copy, close, cd };

/// Mouse away this long: the peek closes (the countdown bar). A setting.
pub var dismiss_ms: u64 = 5000;
/// After a successful action: green border this long, then closed.
const ok_ms = 1000;
/// Most rows in the expanded list before it scrolls.
const max_rows = 10;

pub fn open(gpa: std.mem.Allocator, uid: ids.Id, dir: []const u8, full: []const u8, anchor: Rect) !Peek {
    const d = try gpa.dupeZ(u8, dir);
    errdefer gpa.free(d);
    return .{ .gpa = gpa, .uid = uid, .dir = d, .full = try gpa.dupe(u8, full), .anchor = anchor };
}

/// The folder chip's peek: `dir` in the header, the folders above it in
/// the list (`/` first, the parent last).
pub fn openFolder(gpa: std.mem.Allocator, uid: ids.Id, dir: []const u8, anchor: Rect) !Peek {
    var p = try open(gpa, uid, dir, dir, anchor);
    errdefer p.deinit(undefined);
    p.kind = .folder;
    var end = dir.len;
    while (end > 1) {
        const parent = std.fs.path.dirname(dir[0..end]) orelse break;
        const copy = try gpa.dupe(u8, parent);
        p.branches.insert(gpa, 0, copy) catch {
            gpa.free(copy);
            return error.OutOfMemory;
        };
        end = parent.len;
    }
    p.refilter();
    return p;
}

/// The folder picked (`Action.cd`): the shell went there (green, closes
/// after 1 s), or couldn't (a red message; the peek stays).
pub fn cdDone(p: *Peek, ok: bool, msg: []const u8) void {
    if (ok) {
        p.state = .ok;
        p.state_ms = c.SDL_GetTicks();
    } else p.fail(msg);
}

pub fn deinit(p: *Peek, reaper: *Process.Reaper) void {
    if (p.list_run) |*r| r.deinit(p.gpa, reaper);
    if (p.switch_run) |*r| r.deinit(p.gpa, reaper);
    for (p.branches.items) |b| p.gpa.free(b);
    p.branches.deinit(p.gpa);
    p.shown.deinit(p.gpa);
    p.filter.deinit(p.gpa);
    p.err_msg.deinit(p.gpa);
    p.gpa.free(p.target);
    p.gpa.free(p.dir);
    p.gpa.free(p.full);
}

/// The chip's text changed while open (e.g. the shell switched branch).
pub fn setFull(p: *Peek, full: []const u8) void {
    if (std.mem.eql(u8, full, p.full)) return;
    const copy = p.gpa.dupe(u8, full) catch return;
    p.gpa.free(p.full);
    p.full = copy;
}

/// Has the keyboard (the filter box): only while expanded.
pub fn wantsKeys(p: *const Peek) bool {
    return p.expanded;
}

pub fn contains(p: *const Peek, x: f32, y: f32) bool {
    return p.box.contains(x, y);
}

// ------------------------------------------------------------ actions

/// Grow into the expanded peek (and load the branches), or back.
fn toggleExpand(p: *Peek) void {
    p.expanded = !p.expanded;
    if (!p.expanded) return;
    p.filter.clearRetainingCapacity();
    if (p.kind == .git and p.list_run == null and p.branches.items.len == 0)
        p.list_run = git.Run.start(p.gpa, p.dir, &git.list_branches) catch null;
    p.refilter();
}

/// Switch to the selected branch (in the background).
fn pick(p: *Peek) Action {
    if (p.state == .busy or p.sel >= p.shown.items.len) return .none;
    const name = p.branches.items[p.shown.items[p.sel]];
    p.err_msg.clearRetainingCapacity();
    p.gpa.free(p.target);
    p.target = p.gpa.dupe(u8, name) catch &.{};
    p.state_ms = c.SDL_GetTicks();
    if (p.kind == .folder) return .cd;
    p.already = std.mem.eql(u8, name, p.full);
    if (p.already) {
        p.state = .ok; // nothing to do
        return .redraw;
    }
    const args = [_][]const u8{ "switch", name };
    p.switch_run = git.Run.start(p.gpa, p.dir, &args) catch {
        p.fail("could not run git");
        return .redraw;
    };
    p.state = .busy;
    return .redraw;
}

fn fail(p: *Peek, msg: []const u8) void {
    p.state = .err;
    p.state_ms = c.SDL_GetTicks();
    p.err_msg.clearRetainingCapacity();
    p.err_msg.appendSlice(p.gpa, msg) catch {};
}

/// The last few lines of git's output, for the error message.
fn takeError(p: *Peek, out: []const u8) void {
    var all: [8][]const u8 = undefined;
    var n: usize = 0;
    const S = struct {
        fn add(ctx: struct { *[8][]const u8, *usize }, l: []const u8) void {
            const arr, const k = ctx;
            if (k.* == arr.len) {
                std.mem.copyForwards([]const u8, arr[0 .. arr.len - 1], arr[1..]);
                k.* -= 1;
            }
            arr[k.*] = l;
            k.* += 1;
        }
    };
    git.lines(out, .{ &all, &n }, S.add);
    const keep = @min(n, 4);
    p.err_msg.clearRetainingCapacity();
    for (all[n - keep .. n], 0..) |l, i| {
        if (i > 0) p.err_msg.append(p.gpa, '\n') catch {};
        p.err_msg.appendSlice(p.gpa, l) catch {};
    }
    if (p.err_msg.items.len == 0) p.err_msg.appendSlice(p.gpa, "git failed") catch {};
}

/// The first line of the error (for a status-bar notice).
pub fn errorLine(p: *const Peek) []const u8 {
    var it = std.mem.splitScalar(u8, p.err_msg.items, '\n');
    return it.first();
}

/// Rebuild `shown` from the filter (case-insensitive substring).
fn refilter(p: *Peek) void {
    p.shown.clearRetainingCapacity();
    for (p.branches.items, 0..) |b, i| {
        if (p.filter.items.len == 0 or std.ascii.indexOfIgnoreCase(b, p.filter.items) != null)
            p.shown.append(p.gpa, i) catch break;
    }
    p.sel = 0;
    p.top = 0;
    // Start on the current branch (folders: the parent, next to the chip)
    // when nothing is typed.
    if (p.filter.items.len == 0) for (p.shown.items, 0..) |i, k| {
        if (std.mem.eql(u8, p.branches.items[i], p.full)) p.sel = k;
    };
    if (p.kind == .folder and p.filter.items.len == 0) p.sel = p.shown.items.len -| 1;
    p.keepSelVisible();
}

fn keepSelVisible(p: *Peek) void {
    const rows = @max(p.visibleRows(), 1);
    if (p.sel < p.top) p.top = p.sel;
    if (p.sel >= p.top + rows) p.top = p.sel + 1 - rows;
}

fn visibleRows(p: *const Peek) usize {
    return @min(p.shown.items.len, max_rows);
}

fn moveSel(p: *Peek, delta: isize) void {
    if (p.shown.items.len == 0) return;
    const last: isize = @intCast(p.shown.items.len - 1);
    p.sel = @intCast(std.math.clamp(@as(isize, @intCast(p.sel)) + delta, 0, last));
    p.keepSelVisible();
}

// ------------------------------------------------------------ events

/// Once a frame: collect the git runs, run the timers.
pub fn tick(p: *Peek, now: u64, reaper: *Process.Reaper) enum { none, redraw, close, switched, failed } {
    if (p.list_run) |*r| if (r.tick(p.gpa, reaper)) {
        if (r.code == 0) {
            const S = struct {
                fn add(pk: *Peek, l: []const u8) void {
                    const b = pk.gpa.dupe(u8, l) catch return;
                    pk.branches.append(pk.gpa, b) catch pk.gpa.free(b);
                }
            };
            git.lines(r.out.items, p, S.add);
        } else p.takeError(r.out.items);
        if (r.code != 0) p.state = .err;
        r.deinit(p.gpa, reaper);
        p.list_run = null;
        p.refilter();
        return .redraw;
    };
    if (p.switch_run) |*r| if (r.tick(p.gpa, reaper)) {
        const ok = r.code == 0;
        if (ok) {
            p.state = .ok;
            p.state_ms = now;
        } else p.takeError(r.out.items);
        if (!ok) {
            p.state = .err;
            p.state_ms = now;
        }
        r.deinit(p.gpa, reaper);
        p.switch_run = null;
        return if (ok) .switched else .failed;
    };
    if (p.state == .ok and now -| p.state_ms >= ok_ms) return .close;
    if (p.leave_ms != 0 and p.state != .busy) {
        if (now -| p.leave_ms >= dismiss_ms) return .close;
        return .redraw; // the countdown bar moves
    }
    return .none;
}

/// The mouse moved (anywhere): track the row and button under it, and
/// start / stop the countdown.
pub fn motion(p: *Peek, x: f32, y: f32, now: u64) bool {
    const inside = p.contains(x, y);
    const was = .{ p.leave_ms != 0, p.hover_row, p.over };
    if (inside) p.leave_ms = 0 else if (p.leave_ms == 0) p.leave_ms = now;
    p.over = if (!inside) .none else if (p.copy_r.contains(x, y)) .copy else if (p.expand_r.contains(x, y)) .expand else if (p.close_r.contains(x, y)) .close else .none;
    p.hover_row = p.rowAt(x, y);
    return was[0] != (p.leave_ms != 0) or !std.meta.eql(was[1], p.hover_row) or was[2] != p.over;
}

fn rowAt(p: *const Peek, x: f32, y: f32) ?usize {
    if (!p.expanded or !p.list_r.contains(x, y)) return null;
    const k = p.top + @as(usize, @intFromFloat(@floor((y - p.list_r.y) / p.row_h)));
    return if (k < p.shown.items.len) k else null;
}

/// A left click inside the peek.
pub fn click(p: *Peek, x: f32, y: f32) Action {
    if (p.copy_r.contains(x, y)) return .copy;
    if (p.close_r.contains(x, y)) return .close;
    if (p.expand_r.contains(x, y)) {
        p.toggleExpand();
        return .redraw;
    }
    if (p.rowAt(x, y)) |k| {
        p.sel = k;
        return p.pick();
    }
    return .none;
}

pub fn wheel(p: *Peek, dy: f32) void {
    if (!p.expanded) return;
    const rows = p.visibleRows();
    const max_top = p.shown.items.len -| rows;
    const lines: isize = @intFromFloat(@round(-dy * 2));
    p.top = @intCast(std.math.clamp(@as(isize, @intCast(p.top)) + lines, 0, @as(isize, @intCast(max_top))));
}

/// A key while expanded: arrows move through the list, Enter picks, Esc
/// closes, Backspace edits the filter. Typing keeps it open (the
/// countdown starts over).
pub fn key(p: *Peek, k: c.SDL_Keycode) Action {
    if (p.leave_ms != 0) p.leave_ms = c.SDL_GetTicks();
    switch (k) {
        c.SDLK_ESCAPE => return .close,
        c.SDLK_UP => p.moveSel(-1),
        c.SDLK_DOWN => p.moveSel(1),
        c.SDLK_PAGEUP => p.moveSel(-max_rows),
        c.SDLK_PAGEDOWN => p.moveSel(max_rows),
        c.SDLK_HOME => p.moveSel(-@as(isize, @intCast(p.shown.items.len))),
        c.SDLK_END => p.moveSel(@intCast(p.shown.items.len)),
        c.SDLK_RETURN, c.SDLK_KP_ENTER => return p.pick(),
        c.SDLK_BACKSPACE => if (p.filter.items.len > 0) {
            // Drop the last code point.
            var i = p.filter.items.len - 1;
            while (i > 0 and p.filter.items[i] & 0xc0 == 0x80) i -= 1;
            p.filter.shrinkRetainingCapacity(i);
            p.refilter();
        },
        else => return .none,
    }
    return .redraw;
}

/// Typed text goes into the filter.
pub fn text(p: *Peek, s: []const u8) void {
    if (p.leave_ms != 0) p.leave_ms = c.SDL_GetTicks();
    for (s) |ch| if (ch >= ' ' or ch >= 0x80) p.filter.append(p.gpa, ch) catch return;
    p.refilter();
}

// ------------------------------------------------------------ layout & draw

/// Size and place the box over the chip, growing up from it; kept on the
/// screen (`bounds`). `f` is the normal text size, `sf` the small one.
pub fn layout(p: *Peek, f: *const Gfx.Face, sf: *const Gfx.Face, ui: f32, bounds: Rect) void {
    const pad = @round(6 * ui);
    const gap = @round(5 * ui);
    const icon = @round(f.cell_h * 0.95);
    const head_h = @round(f.cell_h + 10 * ui);
    p.bar_h = @max(@round(3 * ui), 2);
    p.row_h = @round(f.cell_h + 4 * ui);

    var w = pad + icon + gap + icon + 2 * gap + Gfx.textWidth(f, p.full) + 2 * gap + icon + pad;
    var h = head_h + p.bar_h;
    var msg_lines: usize = 0;
    if (p.state == .busy or p.state == .ok or p.state == .err) {
        msg_lines = if (p.state == .err) std.mem.count(u8, p.err_msg.items, "\n") + 1 else 1;
    }
    if (p.expanded) {
        var longest: f32 = Gfx.textWidth(f, p.filterHint());
        for (p.branches.items) |b| longest = @max(longest, Gfx.textWidth(f, b));
        w = @max(w, @max(longest + 2 * f.cell_w + 2 * pad, f.cell_w * 30));
        p.rows = @max(p.visibleRows(), 1);
        h += f.cell_h + @round(10 * ui) + @as(f32, @floatFromInt(p.rows)) * p.row_h + pad;
    }
    if (msg_lines > 0) {
        var longest: f32 = 0;
        var it = std.mem.splitScalar(u8, p.err_msg.items, '\n');
        while (it.next()) |l| longest = @max(longest, Gfx.textWidth(sf, l));
        w = @max(w, @min(longest + 2 * pad, f.cell_w * 80));
        h += @as(f32, @floatFromInt(msg_lines)) * sf.cell_h + pad;
    }
    w = @min(w, bounds.w - 2 * gap);
    h = @min(h, bounds.h - 2 * gap);

    const x = std.math.clamp(p.anchor.x - pad, bounds.x + gap, bounds.x + bounds.w - gap - w);
    const y = std.math.clamp(p.anchor.y + p.anchor.h - h, bounds.y + gap, bounds.y + bounds.h - h);
    p.box = .{ .x = x, .y = y, .w = w, .h = h };

    const iy = y + @round((head_h - icon) / 2);
    p.copy_r = .{ .x = x + pad, .y = iy, .w = icon, .h = icon };
    p.expand_r = .{ .x = p.copy_r.x + icon + gap, .y = iy, .w = icon, .h = icon };
    p.close_r = .{ .x = x + w - pad - icon, .y = iy, .w = icon, .h = icon };
    const tx = p.expand_r.x + icon + 2 * gap;
    p.text_r = .{ .x = tx, .y = y, .w = @max(p.close_r.x - 2 * gap - tx, 0), .h = head_h };

    var cy = y + head_h;
    if (p.expanded) {
        p.filter_r = .{ .x = x + pad, .y = cy, .w = w - 2 * pad, .h = f.cell_h + @round(6 * ui) };
        cy += p.filter_r.h + @round(4 * ui);
        p.list_r = .{ .x = x + pad, .y = cy, .w = w - 2 * pad, .h = @as(f32, @floatFromInt(p.rows)) * p.row_h };
        cy += p.list_r.h + pad;
    } else {
        p.filter_r = .{};
        p.list_r = .{};
    }
    p.msg_r = if (msg_lines > 0) .{ .x = x + pad, .y = cy, .w = w - 2 * pad, .h = @as(f32, @floatFromInt(msg_lines)) * sf.cell_h } else .{};
}

pub fn draw(p: *const Peek, gfx: *Gfx, theme: *const Theme, f: *Gfx.Face, sf: *Gfx.Face, ui: f32, now: u64) void {
    const b = p.box;
    const t = @max(@round(ui), 1);
    gfx.fill(b, theme.title_bg);

    // Header: [copy] [expand]  full text  [×]
    JobWindow.copyIcon(gfx, p.copy_r, theme, ui);
    if (p.over == .copy) gfx.outline(p.copy_r, theme.title_fg, t);
    expandIcon(gfx, p.expand_r, theme, ui, p.expanded, p.over == .expand);
    JobWindow.closeIcon(gfx, p.close_r, theme, ui);
    gfx.clip(p.text_r);
    _ = gfx.text(f, p.text_r.x, p.text_r.y + @round((p.text_r.h - f.cell_h) / 2), p.full, theme.prompt_fg);
    gfx.clip(null);

    if (p.expanded) {
        // Filter box (has the keyboard): the typed text and a caret, or a
        // hint while empty.
        const fr = p.filter_r;
        gfx.fill(fr, theme.bg);
        gfx.outline(fr, theme.focus, t);
        const fy = fr.y + @round((fr.h - f.cell_h) / 2);
        const fx = fr.x + @round(5 * ui);
        gfx.clip(fr);
        const end = if (p.filter.items.len == 0) blk: {
            _ = gfx.text(f, fx, fy, p.filterHint(), theme.dim);
            break :blk fx;
        } else gfx.text(f, fx, fy, p.filter.items, theme.prompt_fg);
        gfx.fill(.{ .x = end, .y = fy, .w = @max(@round(f.cell_w * 0.12), 2), .h = f.cell_h }, theme.cursor);
        gfx.clip(null);

        // The list: the current branch marked with a green dot.
        const lr = p.list_r;
        gfx.clip(lr);
        if (p.shown.items.len == 0) {
            const msg = if (p.kind == .folder) (if (p.branches.items.len == 0) "no folder above" else "no folder matches") else if (p.list_run != null) "loading branches…" else if (p.branches.items.len == 0) "no local branches" else "no branch matches";
            _ = gfx.text(f, lr.x + f.cell_w * 2, lr.y + @round((p.row_h - f.cell_h) / 2), msg, theme.dim);
        }
        var k = p.top;
        while (k < p.shown.items.len and k < p.top + p.rows) : (k += 1) {
            const name = p.branches.items[p.shown.items[k]];
            const ry = lr.y + @as(f32, @floatFromInt(k - p.top)) * p.row_h;
            const row: Rect = .{ .x = lr.x, .y = ry, .w = lr.w, .h = p.row_h };
            if (k == p.sel) gfx.fill(row, theme.selection) else if (p.hover_row == k) gfx.fill(row, theme.title_bg.mix(theme.fg, 0.08));
            const ty = ry + @round((p.row_h - f.cell_h) / 2);
            const current = std.mem.eql(u8, name, p.full);
            if (current) {
                const d = @round(f.cell_h * 0.32);
                gfx.disc(lr.x + f.cell_w * 0.9, ry + p.row_h / 2, d / 2, theme.ok);
            }
            const switching = p.state == .busy and std.mem.eql(u8, name, p.target);
            _ = gfx.text(f, lr.x + f.cell_w * 2, ty, name, if (current) theme.ok else if (switching) theme.focus else theme.prompt_fg);
        }
        gfx.clip(null);
        // More rows than fit: a thin scroll mark on the right.
        if (p.shown.items.len > p.rows) {
            const n: f32 = @floatFromInt(p.shown.items.len);
            const th = @max(lr.h * @as(f32, @floatFromInt(p.rows)) / n, 8 * ui);
            const ty = lr.y + (lr.h - th) * @as(f32, @floatFromInt(p.top)) / @max(n - @as(f32, @floatFromInt(p.rows)), 1);
            gfx.fill(.{ .x = lr.x + lr.w - @round(3 * ui), .y = ty, .w = @round(3 * ui), .h = th }, theme.dim);
        }
    }

    // What the action is doing / did.
    if (p.msg_r.h > 0) {
        gfx.clip(p.msg_r);
        switch (p.state) {
            .busy => _ = gfx.text(sf, p.msg_r.x, p.msg_r.y, "switching…", theme.focus),
            .ok => _ = gfx.text(sf, p.msg_r.x, p.msg_r.y, if (p.kind == .folder) "cd sent" else if (p.already) "already on this branch" else "switched", theme.ok),
            .err => {
                var y = p.msg_r.y;
                var it = std.mem.splitScalar(u8, p.err_msg.items, '\n');
                while (it.next()) |l| : (y += sf.cell_h) _ = gfx.text(sf, p.msg_r.x, y, l, theme.stderr_accent);
            },
            .idle => {},
        }
        gfx.clip(null);
    }

    // Border: thin, colored by the action's result; the bottom one thicker,
    // doubling as the countdown bar (empties right to left).
    const edge: Rgb = switch (p.state) {
        .idle => theme.title_fg.mix(theme.title_bg, 0.45),
        .busy => theme.focus,
        .ok => theme.ok,
        .err => theme.stderr_accent,
    };
    const thick = if (p.state == .idle) t else 2 * t;
    gfx.outline(b, edge, thick);
    const bar: Rect = .{ .x = b.x, .y = b.y + b.h - p.bar_h, .w = b.w, .h = p.bar_h };
    gfx.fill(bar, edge);
    if (p.leave_ms != 0 and p.state != .busy) {
        const left = 1 - @min(@as(f32, @floatFromInt(now -| p.leave_ms)) / @as(f32, @floatFromInt(@max(dismiss_ms, 1))), 1);
        gfx.fill(bar, theme.title_bg.mix(edge, 0.3));
        gfx.fill(.{ .x = bar.x, .y = bar.y, .w = @round(bar.w * left), .h = bar.h }, theme.focus);
    }
}

fn filterHint(p: *const Peek) []const u8 {
    return if (p.kind == .folder) "filter folders" else "filter branches";
}

/// A chevron: up (grow into the list) while collapsed, down once expanded.
fn expandIcon(gfx: *Gfx, r: Rect, theme: *const Theme, ui: f32, expanded: bool, hot: bool) void {
    gfx.fill(r, theme.title_bg.mix(theme.fg, if (hot) 0.16 else 0.07));
    const t = @max(@round(1.5 * ui), 1);
    const mx = r.x + r.w / 2;
    const dx = r.w * 0.28;
    const dy = r.h * 0.16;
    const cy = r.y + r.h / 2;
    const tip_y = if (expanded) cy + dy else cy - dy;
    const arm_y = if (expanded) cy - dy else cy + dy;
    gfx.line(mx - dx, arm_y, mx, tip_y, theme.title_fg, t);
    gfx.line(mx, tip_y, mx + dx, arm_y, theme.title_fg, t);
}

test "filter keeps git's order, case-insensitive" {
    const t = std.testing;
    var p: Peek = .{ .gpa = t.allocator, .uid = 1, .dir = try t.allocator.dupeZ(u8, "/"), .full = try t.allocator.dupe(u8, "main"), .anchor = .{} };
    var reaper: Process.Reaper = .{ .gpa = t.allocator };
    defer reaper.deinit();
    defer p.deinit(&reaper);
    for ([_][]const u8{ "feature/Login", "main", "fix-login" }) |b| try p.branches.append(t.allocator, try t.allocator.dupe(u8, b));
    p.refilter();
    try t.expectEqual(@as(usize, 3), p.shown.items.len);
    try t.expectEqual(@as(usize, 1), p.sel); // starts on the current branch
    p.text("LOG");
    try t.expectEqual(@as(usize, 2), p.shown.items.len);
    try t.expectEqual(@as(usize, 0), p.shown.items[0]);
    try t.expectEqual(@as(usize, 2), p.shown.items[1]);
    _ = p.key(c.SDLK_BACKSPACE);
    try t.expectEqualStrings("LO", p.filter.items);
}

test "folder peek: the folders above, / first, starting on the parent" {
    const t = std.testing;
    var p = try Peek.openFolder(t.allocator, 1, "/Users/me/src", .{});
    var reaper: Process.Reaper = .{ .gpa = t.allocator };
    defer reaper.deinit();
    defer p.deinit(&reaper);
    try t.expectEqual(@as(usize, 3), p.branches.items.len);
    try t.expectEqualStrings("/", p.branches.items[0]);
    try t.expectEqualStrings("/Users", p.branches.items[1]);
    try t.expectEqualStrings("/Users/me", p.branches.items[2]);
    try t.expectEqual(@as(usize, 2), p.sel);
    p.expanded = true;
    try t.expectEqual(Action.cd, p.key(c.SDLK_RETURN));
    try t.expectEqualStrings("/Users/me", p.target);
    var root = try Peek.openFolder(t.allocator, 1, "/", .{});
    defer root.deinit(&reaper);
    try t.expectEqual(@as(usize, 0), root.branches.items.len);
}
