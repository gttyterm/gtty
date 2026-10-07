// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! A scrollback text buffer plus a small VT/xterm escape-sequence parser.
//!
//! This is deliberately "terminal-lite": it handles text, colors (SGR),
//! carriage return / backspace / tab, line erase, cursor movement within
//! the visible area, and skips everything else (OSC titles, mode switches)
//! so it never prints garbage. Of the OSCs it reads only the shell marks
//! (OSC 133 C / D, see core/shell_hooks.zig): where the last command's
//! output starts and ends, as byte offsets into the output. Full-screen programs (vim, htop) will get a
//! proper alternate-screen grid in a later step.
//!
//! The buffer is a memory window over the output: the last `max_lines`
//! rows. (The job window tees the complete output to a file.) Rows that
//! wrapped at the right edge are marked, so a width change can reflow the
//! text: wrapped rows are joined back into their lines and wrapped again at
//! the new width.

const std = @import("std");
const color = @import("color.zig");
const wcwidth = @import("wcwidth.zig");
const Color = color.Color;

pub const Attrs = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    /// A wide character (2 cells, see wcwidth.zig); the next cell is its
    /// spacer.
    wide: bool = false,
    /// What the cell was written as (the left-edge marks).
    zone: Zone = .none,

    /// The same look (the wide flag and zone aren't part of it).
    pub fn sameLook(a: Attrs, b: Attrs) bool {
        var x = a;
        var y = b;
        x.wide = false;
        y.wide = false;
        x.zone = .none;
        y.zone = .none;
        return x == y;
    }
};

/// What a cell is, for the marks on a job window's left edge: written by
/// the shell as its prompt (no mark), typed by the user (input), the
/// commands' output, or AI-related (gtty's AI, later).
pub const Zone = enum(u2) { none, input, output, ai };

/// One cell. `cp` 0 is no character: the spacer after a wide character,
/// or the pad left in the last column when a wide character didn't fit
/// and went on to the next row. Text exports skip it.
pub const Cell = struct {
    cp: u21 = ' ',
    /// A zero-width character that followed (combining accent, variation
    /// selector, ZWJ), kept so copied text is what was printed; 0 = none.
    extra: u21 = 0,
    fg: Color = .{},
    bg: Color = .{},
    attrs: Attrs = .{},
};

pub const Line = std.ArrayList(Cell);

/// A caret position in the buffer: absolute line index (into `lines`) and a
/// column boundary (0 = before the first cell, `cols` = after the last).
pub const Pos = struct {
    row: usize,
    col: u16,

    pub fn before(a: Pos, b: Pos) bool {
        return a.row < b.row or (a.row == b.row and a.col < b.col);
    }
};

/// Selected text, from where the mouse went down (`anchor`) to where it is
/// now (`head`); either may come first.
pub const Selection = struct {
    anchor: Pos,
    head: Pos,

    pub fn ordered(s: Selection) [2]Pos {
        return if (s.head.before(s.anchor)) .{ s.head, s.anchor } else .{ s.anchor, s.head };
    }

    pub fn empty(s: Selection) bool {
        return s.anchor.row == s.head.row and s.anchor.col == s.head.col;
    }

    /// Selected columns [start, end) of line `row`; `end` is maxInt when the
    /// selection goes on past this line. Null when the line isn't selected.
    pub fn colsOn(s: Selection, row: usize) ?[2]usize {
        const a, const b = s.ordered();
        if (row < a.row or row > b.row) return null;
        const start: usize = if (row == a.row) a.col else 0;
        const end: usize = if (row == b.row) b.col else std.math.maxInt(usize);
        return if (end > start) .{ start, end } else null;
    }
};

const State = enum { ground, esc, esc_skip_one, csi, osc, osc_esc, str, str_esc };

const Screen = @This();

pub const default_max_lines: usize = 65_536;

gpa: std.mem.Allocator,
lines: std.ArrayList(Line) = .empty,
/// Parallel to `lines`: the row ends in a soft wrap (the text hit the right
/// edge and went on to the next row), as opposed to a newline.
wrapped: std.ArrayList(bool) = .empty,
cols: u16 = 80,
rows: u16 = 24,
/// Absolute index into `lines` of the cursor row.
cur_row: usize = 0,
cur_col: u16 = 0,
saved_row: usize = 0,
saved_col: u16 = 0,
pen: Cell = .{},
/// Rows kept in memory; older ones are dropped from the top.
max_lines: usize = default_max_lines,
/// Rows dropped from the top so far.
dropped: usize = 0,
/// Logical line number (text API: wrapped rows joined, counted since the
/// window opened, never reused) of the line row 0 belongs to.
line_base: u64 = 0,
/// Row 0 continues a line whose start was dropped: that line is gone for
/// the text API.
head_partial: bool = false,
/// How many lines the view is scrolled up from the bottom (0 = follow output).
scroll: usize = 0,
/// Bumped each time the user moves the view (not when output arrives).
scroll_moves: u32 = 0,
/// Bumped on every change; the job window uses it to know when to redraw.
generation: u64 = 0,
/// Text selected with the mouse (kept in line positions, so it stays on its
/// text while new output scrolls the view).
sel: ?Selection = null,

/// Bytes fed so far (offsets into the job's output, as in the tee file).
fed: u64 = 0,
/// The last command's output (shell marks): bytes [start, end) of the
/// output; `end` is null while the command still runs.
last_output: ?Range = null,
/// The shell is at its prompt, editing the input line (between a 133;D
/// and the next 133;C). Only shells with gtty's hooks send the marks.
at_prompt: bool = false,
/// The folder the shell last reported (OSC 7, a file:// URL, decoded),
/// and a counter bumped on each report.
osc_cwd: [4096]u8 = undefined,
osc_cwd_len: usize = 0,
osc_cwd_gen: u32 = 0,
/// What text written now is (`Zone`): the shell marks move it (B: input,
/// C: output, D / A: prompt); without marks everything is output, except
/// the echo of what the user typed (`echo`).
zone: Zone = .output,
/// gtty typed an AI request line into the shell (`armed`): its echo and
/// the output of the command it starts (`running`, from the C mark to the
/// next D) are AI text (the purple mark); the user's own typing stays
/// input.
ai: enum { off, armed, running } = .off,
/// A shell with gtty's marks (seen one).
has_marks: bool = false,
/// The user just typed into a program without marks: what comes back
/// until the next line feed is its echo (input). JobWindow ends it after
/// a short while too.
echo: bool = false,
/// Byte offsets: just after the last line the user typed (its echoed line
/// feed), and just after the last line feed.
typed_end: u64 = 0,
lf_end: u64 = 0,
/// The same places as rows, for showing what a copy took (the title-bar
/// copy's flash): the last command's output rows [start, end) (`end` null
/// while it runs), and the rows of the answer to the last typed line
/// [typed_row, lf_row). Kept right when rows are dropped or reflowed.
out_rows: ?struct { start: usize, end: ?usize } = null,
typed_row: ?usize = null,
lf_row: usize = 0,
/// The program asked for bracketed paste (DEC private mode 2004, as zsh,
/// bash and vim do): a paste is sent wrapped in ESC[200~ … ESC[201~ so it
/// is taken as text, not typed keys (no line runs on its newline).
bracketed_paste: bool = false,

state: State = .ground,
/// OSC being read: its first bytes, its length, where its ESC was.
osc_buf: [4100]u8 = undefined,
osc_len: usize = 0,
osc_start: u64 = 0,
params: [16]u32 = [_]u32{0} ** 16,
nparams: usize = 0,
param_started: bool = false,
private: u8 = 0,
utf8_buf: [4]u8 = undefined,
utf8_len: u3 = 0,
utf8_need: u3 = 0,

pub const Range = struct { start: u64, end: ?u64 = null };

pub fn init(gpa: std.mem.Allocator) Screen {
    return .{ .gpa = gpa };
}

pub fn deinit(s: *Screen) void {
    for (s.lines.items) |*l| l.deinit(s.gpa);
    s.lines.deinit(s.gpa);
    s.wrapped.deinit(s.gpa);
}

/// New grid size. A new width reflows the text to fill it.
pub fn resize(s: *Screen, cols: u16, rows: u16) void {
    const new_cols = @max(cols, 1);
    s.rows = @max(rows, 1);
    if (new_cols != s.cols) {
        s.reflow(new_cols) catch {};
        s.cols = new_cols;
    }
    if (s.cur_col >= s.cols) s.cur_col = s.cols - 1;
    s.scrollBy(0); // keep the scroll in range
    s.generation +%= 1;
}

pub fn clear(s: *Screen) void {
    const n_rows = s.lines.items.len;
    for (s.lines.items) |*l| l.deinit(s.gpa);
    s.lines.clearRetainingCapacity();
    s.wrapped.clearRetainingCapacity();
    s.dropped = 0;
    s.line_base += n_rows + 1; // numbers are never reused
    s.head_partial = false;
    s.cur_row = 0;
    s.cur_col = 0;
    s.scroll = 0;
    s.sel = null;
    s.out_rows = null;
    s.typed_row = null;
    s.lf_row = 0;
    s.generation +%= 1;
}

/// First line of the "live" screen area (what cursor addressing is relative to).
pub fn screenTop(s: *const Screen) usize {
    const n = @max(s.lines.items.len, s.cur_row + 1);
    return if (n > s.rows) n - s.rows else 0;
}

pub fn lineCount(s: *const Screen) usize {
    // Don't count a trailing empty line under the cursor as content.
    var n = s.lines.items.len;
    while (n > 0 and s.lines.items[n - 1].items.len == 0 and n - 1 >= s.cur_row) n -= 1;
    return @max(n, s.cur_row + 1);
}

pub fn scrollBy(s: *Screen, delta: isize) void {
    const total = s.lineCount();
    const max_scroll: usize = if (total > s.rows) total - s.rows else 0;
    const cur: isize = @intCast(s.scroll);
    const next = std.math.clamp(cur + delta, 0, @as(isize, @intCast(max_scroll)));
    if (next != cur and delta != 0) s.scroll_moves +%= 1;
    s.scroll = @intCast(next);
    s.generation +%= 1;
}

pub fn scrollTo(s: *Screen, lines_up: usize) void {
    s.scrollBy(@as(isize, @intCast(lines_up)) - @as(isize, @intCast(s.scroll)));
}

/// Rows the view can scroll up.
pub fn maxScroll(s: *const Screen) usize {
    return s.lineCount() -| s.rows;
}

// ---------------------------------------------------------------- feeding

pub fn feed(s: *Screen, bytes: []const u8) void {
    for (bytes) |b| {
        s.feedByte(b);
        s.fed += 1;
    }
    s.generation +%= 1;
}

fn feedByte(s: *Screen, b: u8) void {
    switch (s.state) {
        .ground => s.ground(b),
        .esc => s.escape(b),
        .esc_skip_one => s.state = .ground,
        .csi => s.csi(b),
        .osc => switch (b) {
            0x07 => s.oscEnd(),
            0x1b => s.state = .osc_esc,
            else => {
                if (s.osc_len < s.osc_buf.len) s.osc_buf[s.osc_len] = b;
                s.osc_len +|= 1;
            },
        },
        .osc_esc => if (b == '\\') s.oscEnd() else {
            s.state = .osc;
        },
        .str => switch (b) {
            0x1b => s.state = .str_esc,
            else => {},
        },
        .str_esc => s.state = if (b == '\\') .ground else .str,
    }
}

fn ground(s: *Screen, b: u8) void {
    if (s.utf8_need > 0) {
        if (b & 0xc0 == 0x80) {
            s.utf8_buf[s.utf8_len] = b;
            s.utf8_len += 1;
            if (s.utf8_len == s.utf8_need) {
                const cp = std.unicode.utf8Decode(s.utf8_buf[0..s.utf8_len]) catch 0xfffd;
                s.utf8_need = 0;
                s.utf8_len = 0;
                s.put(cp);
            }
            return;
        }
        // Broken sequence: emit replacement and reprocess this byte.
        s.utf8_need = 0;
        s.utf8_len = 0;
        s.put(0xfffd);
    }
    switch (b) {
        0x1b => s.state = .esc,
        '\n', 0x0b, 0x0c => {
            // The end of a line the user typed (its echo): what follows is
            // the answer (copy in an ssh session, a REPL: `typedOutput`).
            const typed = s.echo;
            if (s.echo) s.typed_end = s.fed + 1;
            s.echo = false;
            s.lf_end = s.fed + 1;
            s.lineFeed();
            if (typed) s.typed_row = s.cur_row;
            s.lf_row = s.cur_row;
        },
        '\r' => s.cur_col = 0,
        0x08 => {
            if (s.cur_col > 0) s.cur_col -= 1;
        },
        '\t' => {
            const next = (s.cur_col / 8 + 1) * 8;
            s.cur_col = @min(next, s.cols - 1);
        },
        0x07, 0x00, 0x7f => {},
        0x01...0x06, 0x0e...0x1a, 0x1c...0x1f => {},
        0x20...0x7e => s.put(b),
        0x80...0xbf => s.put(0xfffd),
        else => {
            const len = std.unicode.utf8ByteSequenceLength(b) catch {
                s.put(0xfffd);
                return;
            };
            s.utf8_buf[0] = b;
            s.utf8_len = 1;
            s.utf8_need = len;
        },
    }
}

fn escape(s: *Screen, b: u8) void {
    s.state = .ground;
    switch (b) {
        '[' => {
            s.state = .csi;
            s.nparams = 0;
            s.param_started = false;
            s.private = 0;
            @memset(&s.params, 0);
        },
        ']' => {
            s.state = .osc;
            s.osc_len = 0;
            s.osc_start = s.fed -| 1; // its ESC
        },
        'P', 'X', '^', '_' => s.state = .str, // DCS / SOS / PM / APC
        '(', ')', '*', '+', '#', '%' => s.state = .esc_skip_one,
        '7' => s.saveCursor(),
        '8' => s.restoreCursor(),
        'M' => { // reverse index
            const top = s.screenTop();
            if (s.cur_row > top) s.cur_row -= 1;
        },
        'D' => s.lineFeed(),
        'E' => {
            s.lineFeed();
            s.cur_col = 0;
        },
        'c' => {
            s.pen = .{};
            s.clear();
        },
        else => {},
    }
}

/// An OSC ended (the current byte is its last). Shell marks: 133;C — a
/// command starts, its output follows; 133;D[;code] — it is done. A D
/// with no command running (an empty line, the first prompt) changes
/// nothing.
fn oscEnd(s: *Screen) void {
    s.state = .ground;
    if (s.osc_len > s.osc_buf.len) return; // too long to read
    const p = s.osc_buf[0..s.osc_len];
    if (std.mem.startsWith(u8, p, "7;")) return s.oscFolder(p[2..]);
    if (!std.mem.startsWith(u8, p, "133;") or p.len < 5 or (p.len > 5 and p[5] != ';')) return;
    s.has_marks = true;
    switch (p[4]) {
        'A' => s.zone = .none,
        'B' => s.zone = .input,
        'C' => {
            if (s.ai == .armed) s.ai = .running;
            s.last_output = .{ .start = s.fed + 1 };
            s.out_rows = .{ .start = s.cur_row + @intFromBool(s.cur_col > 0), .end = null };
            s.at_prompt = false;
            s.zone = .output;
        },
        'D' => {
            if (s.ai == .running) s.ai = .off;
            s.at_prompt = true;
            s.zone = .none;
            if (s.last_output) |*o| if (o.end == null) {
                o.end = s.osc_start;
            };
            if (s.out_rows) |*r| if (r.end == null) {
                r.end = @max(s.cur_row + @intFromBool(s.cur_col > 0), r.start);
            };
        },
        else => {},
    }
}

/// OSC 7: `file://<host><path>`, the path %-encoded where needed.
fn oscFolder(s: *Screen, url: []const u8) void {
    if (!std.mem.startsWith(u8, url, "file://")) return;
    const rest = url["file://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return;
    const path = rest[slash..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < path.len and n < s.osc_cwd.len) : (n += 1) {
        if (path[i] == '%' and i + 2 < path.len) {
            if (std.fmt.parseInt(u8, path[i + 1 .. i + 3], 16)) |v| {
                s.osc_cwd[n] = v;
                i += 3;
                continue;
            } else |_| {}
        }
        s.osc_cwd[n] = path[i];
        i += 1;
    }
    s.osc_cwd_len = n;
    s.osc_cwd_gen +%= 1;
}

/// The mark of row `row`: input if anything on it was typed, else AI, else
/// output; none for prompt-only and empty rows.
pub fn rowZone(s: *const Screen, row: usize) Zone {
    if (row >= s.lines.items.len) return .none;
    var z: Zone = .none;
    for (s.lines.items[row].items) |cell| switch (cell.attrs.zone) {
        .input => return .input,
        .ai => z = .ai,
        .output => if (z == .none) {
            z = .output;
        },
        .none => {},
    };
    return z;
}

/// What a program without shell marks (ssh, python, …) answered to the
/// last line the user typed: from that line's end to the start of the
/// line the cursor is on (its prompt). Null before anything was typed.
pub fn typedOutput(s: *const Screen) ?Range {
    if (s.typed_end == 0) return null;
    return .{ .start = s.typed_end, .end = @max(s.lf_end, s.typed_end) };
}

/// The folder the shell last reported (OSC 7), or "".
pub fn reportedFolder(s: *const Screen) []const u8 {
    return s.osc_cwd[0..s.osc_cwd_len];
}

fn csi(s: *Screen, b: u8) void {
    switch (b) {
        '0'...'9' => {
            if (s.nparams == 0) s.nparams = 1;
            const i = s.nparams - 1;
            s.params[i] = s.params[i] *| 10 +| (b - '0');
            s.param_started = true;
        },
        ';', ':' => {
            if (s.nparams == 0) s.nparams = 1;
            if (s.nparams < s.params.len) s.nparams += 1;
        },
        '?', '>', '<', '=' => s.private = b,
        0x20...0x2f => {}, // intermediates
        0x40...0x7e => {
            s.state = .ground;
            s.dispatchCsi(b);
        },
        0x1b => s.state = .esc,
        else => {},
    }
}

fn param(s: *const Screen, i: usize, default: u32) u32 {
    if (i >= s.nparams) return default;
    return if (s.params[i] == 0) default else s.params[i];
}

/// DEC private modes (`ESC[?…h` / `ESC[?…l`): only bracketed paste is
/// kept for now; the rest are ignored.
fn privateMode(s: *Screen, final: u8) void {
    if (s.private != '?' or (final != 'h' and final != 'l')) return;
    for (s.params[0..s.nparams]) |p| if (p == 2004) {
        s.bracketed_paste = final == 'h';
    };
}

fn dispatchCsi(s: *Screen, final: u8) void {
    if (s.private != 0) return s.privateMode(final);
    const top = s.screenTop();
    switch (final) {
        'm' => s.sgr(),
        'A' => {
            const n = s.param(0, 1);
            const up = @min(n, s.cur_row -| top);
            s.cur_row -= up;
        },
        'B', 'e' => {
            const n = s.param(0, 1);
            s.cur_row = @min(s.cur_row + n, top + s.rows - 1);
            s.ensureLine(s.cur_row);
        },
        'C', 'a' => s.cur_col = @intCast(@min(@as(u32, s.cur_col) + s.param(0, 1), s.cols - 1)),
        'D' => s.cur_col -|= @intCast(@min(s.param(0, 1), s.cols)),
        'G', '`' => s.cur_col = @intCast(@min(s.param(0, 1) - 1, s.cols - 1)),
        'd' => {
            s.cur_row = top + @min(s.param(0, 1) - 1, s.rows - 1);
            s.ensureLine(s.cur_row);
        },
        'H', 'f' => {
            s.cur_row = top + @min(s.param(0, 1) - 1, s.rows - 1);
            s.cur_col = @intCast(@min(s.param(1, 1) - 1, s.cols - 1));
            s.ensureLine(s.cur_row);
        },
        'K' => {
            s.eraseLine(if (s.nparams == 0) 0 else s.params[0]);
            s.repairWide(s.cur_row);
        },
        'J' => s.eraseDisplay(if (s.nparams == 0) 0 else s.params[0]),
        'P' => { // delete chars
            const l = s.line(s.cur_row);
            const n = @min(s.param(0, 1), l.items.len -| s.cur_col);
            if (n > 0) l.replaceRangeAssumeCapacity(s.cur_col, n, &.{});
            s.repairWide(s.cur_row);
        },
        '@' => { // insert blanks (never more than fit: random input can ask for billions)
            const l = s.line(s.cur_row);
            if (s.cur_col < l.items.len) {
                const n = @min(s.param(0, 1), s.cols -| s.cur_col);
                l.ensureUnusedCapacity(s.gpa, n) catch return;
                var i: u32 = 0;
                while (i < n) : (i += 1) l.insertAssumeCapacity(s.cur_col, s.blank());
                if (l.items.len > s.cols) l.shrinkRetainingCapacity(s.cols);
                s.repairWide(s.cur_row);
            }
        },
        'X' => { // erase chars
            const l = s.line(s.cur_row);
            var i: usize = s.cur_col;
            const end = @min(l.items.len, s.cur_col + s.param(0, 1));
            while (i < end) : (i += 1) l.items[i] = s.blank();
            s.repairWide(s.cur_row);
        },
        's' => s.saveCursor(),
        'u' => s.restoreCursor(),
        else => {},
    }
}

fn sgr(s: *Screen) void {
    if (s.nparams == 0) {
        s.pen = .{};
        return;
    }
    var i: usize = 0;
    while (i < s.nparams) : (i += 1) {
        const p = s.params[i];
        switch (p) {
            0 => s.pen = .{},
            1 => s.pen.attrs.bold = true,
            2 => s.pen.attrs.dim = true,
            3 => s.pen.attrs.italic = true,
            4 => s.pen.attrs.underline = true,
            7 => s.pen.attrs.inverse = true,
            21, 22 => {
                s.pen.attrs.bold = false;
                s.pen.attrs.dim = false;
            },
            23 => s.pen.attrs.italic = false,
            24 => s.pen.attrs.underline = false,
            27 => s.pen.attrs.inverse = false,
            30...37 => s.pen.fg = Color.indexed(@intCast(p - 30)),
            39 => s.pen.fg = .{},
            40...47 => s.pen.bg = Color.indexed(@intCast(p - 40)),
            49 => s.pen.bg = .{},
            90...97 => s.pen.fg = Color.indexed(@intCast(p - 90 + 8)),
            100...107 => s.pen.bg = Color.indexed(@intCast(p - 100 + 8)),
            38, 48 => {
                var c: Color = .{};
                if (i + 1 < s.nparams and s.params[i + 1] == 5 and i + 2 < s.nparams) {
                    c = Color.indexed(@intCast(@min(s.params[i + 2], 255)));
                    i += 2;
                } else if (i + 1 < s.nparams and s.params[i + 1] == 2 and i + 4 < s.nparams) {
                    c = Color.rgb(
                        @intCast(@min(s.params[i + 2], 255)),
                        @intCast(@min(s.params[i + 3], 255)),
                        @intCast(@min(s.params[i + 4], 255)),
                    );
                    i += 4;
                } else break;
                if (p == 38) s.pen.fg = c else s.pen.bg = c;
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------- editing

fn blank(s: *const Screen) Cell {
    return .{ .cp = ' ', .bg = s.pen.bg };
}

fn ensureLine(s: *Screen, row: usize) void {
    while (s.lines.items.len <= row) {
        s.wrapped.append(s.gpa, false) catch return;
        s.lines.append(s.gpa, .empty) catch {
            _ = s.wrapped.pop();
            return;
        };
    }
}

/// The row continues on the next one (it wrapped at the right edge).
pub fn isWrapped(s: *const Screen, row: usize) bool {
    return row < s.wrapped.items.len and s.wrapped.items[row];
}

fn setWrapped(s: *Screen, row: usize, v: bool) void {
    if (row < s.wrapped.items.len) s.wrapped.items[row] = v;
}

fn line(s: *Screen, row: usize) *Line {
    s.ensureLine(row);
    return &s.lines.items[row];
}

fn put(s: *Screen, cp: u21) void {
    const w = wcwidth.width(cp);
    if (w == 0) return s.combine(cp);
    // A wide character in the last column goes on to the next row (that
    // column keeps a pad).
    const no_room = w == 2 and s.cols >= 2 and s.cur_col + 1 == s.cols;
    if (s.cur_col >= s.cols or no_room) {
        if (no_room) {
            var pad = s.blank();
            pad.cp = 0;
            s.setCell(s.cur_col, pad);
        }
        s.ensureLine(s.cur_row);
        s.setWrapped(s.cur_row, true);
        s.lineFeed();
        s.cur_col = 0;
    }
    var cell = s.pen;
    cell.cp = cp;
    cell.attrs.wide = w == 2 and s.cols >= 2;
    cell.attrs.zone = if (s.echo) .input else if (s.ai != .off and s.zone != .none) .ai else s.zone;
    if (cell.attrs.wide) s.setCell(s.cur_col + 1, s.blank()); // the old pair there is split first
    s.setCell(s.cur_col, cell);
    if (cell.attrs.wide) {
        var spacer = cell;
        spacer.cp = 0;
        spacer.extra = 0;
        spacer.attrs.wide = false;
        s.line(s.cur_row).items[s.cur_col + 1] = spacer;
        s.cur_col += 2;
    } else s.cur_col += 1;
}

/// Write cell `col` of the cursor row. A wide character it overwrites
/// half of loses its other half (made blank).
fn setCell(s: *Screen, col: usize, cell: Cell) void {
    const l = s.line(s.cur_row);
    while (l.items.len <= col) l.append(s.gpa, .{}) catch return;
    const old = l.items[col];
    if (old.attrs.wide and col + 1 < l.items.len) l.items[col + 1] = s.blank();
    if (old.cp == 0 and col > 0 and l.items[col - 1].attrs.wide) l.items[col - 1] = s.blank();
    l.items[col] = cell;
}

/// A zero-width character: kept with the character before the cursor.
fn combine(s: *Screen, cp: u21) void {
    if (s.cur_col == 0 or s.cur_row >= s.lines.items.len) return;
    const l = s.lines.items[s.cur_row].items;
    var col: usize = @min(s.cur_col, l.len) -| 1;
    if (col >= l.len) return;
    if (l[col].cp == 0 and col > 0 and l[col - 1].attrs.wide) col -= 1;
    if (l[col].extra == 0 and l[col].cp != 0) l[col].extra = cp;
}

/// After an edit that moved or cut cells (delete / insert / erase): a
/// wide character without its spacer, or a spacer without its character,
/// becomes a blank. The pad before a wrap stays.
fn repairWide(s: *Screen, row: usize) void {
    if (row >= s.lines.items.len) return;
    const l = s.lines.items[row].items;
    for (l, 0..) |*cell, i| {
        if (cell.attrs.wide and (i + 1 >= l.len or l[i + 1].cp != 0)) {
            cell.cp = ' ';
            cell.attrs.wide = false;
            cell.extra = 0;
        } else if (cell.cp == 0 and !(i > 0 and l[i - 1].attrs.wide) and !(i + 1 == l.len and s.isWrapped(row))) {
            cell.cp = ' ';
        }
    }
}

fn lineFeed(s: *Screen) void {
    s.cur_row += 1;
    s.ensureLine(s.cur_row);
    if (s.scroll > 0) s.scroll += 1; // keep the user's scrolled view stable
    s.trim();
}

fn trim(s: *Screen) void {
    const step: usize = 512;
    if (s.lines.items.len <= s.max_lines +| step) return;
    // Usually one step; more after a burst of rows added without line feeds.
    const chunk = (s.lines.items.len - s.max_lines) / step * step;
    for (s.wrapped.items[0..chunk]) |wr| {
        if (!wr) s.line_base += 1;
    }
    s.head_partial = s.wrapped.items[chunk - 1];
    for (s.lines.items[0..chunk]) |*l| l.deinit(s.gpa);
    s.lines.replaceRangeAssumeCapacity(0, chunk, &.{});
    s.wrapped.replaceRangeAssumeCapacity(0, chunk, &.{});
    s.dropped += chunk;
    s.cur_row -|= chunk;
    s.saved_row -|= chunk;
    if (s.sel) |*sel| {
        const a, _ = sel.ordered();
        if (a.row < chunk) {
            s.sel = null; // its text is gone
        } else {
            sel.anchor.row -= chunk;
            sel.head.row -= chunk;
        }
    }
    if (s.out_rows) |*r| {
        r.start -|= chunk;
        if (r.end) |*e| e.* -|= chunk;
    }
    if (s.typed_row) |*t| t.* -|= chunk;
    s.lf_row -|= chunk;
}

fn eraseLine(s: *Screen, mode: u32) void {
    const l = s.line(s.cur_row);
    if (mode == 2 or (mode == 0 and s.cur_col == 0)) s.setWrapped(s.cur_row, false);
    switch (mode) {
        0 => if (s.cur_col < l.items.len) l.shrinkRetainingCapacity(s.cur_col),
        1 => {
            var i: usize = 0;
            while (i <= s.cur_col and i < l.items.len) : (i += 1) l.items[i] = s.blank();
        },
        else => l.clearRetainingCapacity(),
    }
}

fn eraseDisplay(s: *Screen, mode: u32) void {
    switch (mode) {
        0 => {
            s.eraseLine(0);
            var r = s.cur_row + 1;
            while (r < s.lines.items.len) : (r += 1) {
                s.lines.items[r].clearRetainingCapacity();
                s.wrapped.items[r] = false;
            }
        },
        1 => {
            const top = s.screenTop();
            var r = top;
            while (r < s.cur_row) : (r += 1) {
                s.lines.items[r].clearRetainingCapacity();
                s.wrapped.items[r] = false;
            }
            s.eraseLine(1);
        },
        2 => {
            // Like a classic terminal: push the current screen into scrollback.
            const used = s.lineCount();
            const rel = s.cur_row - s.screenTop();
            s.ensureLine(used + s.rows - 1);
            s.cur_row = used + rel;
            s.ensureLine(s.cur_row);
            s.trim();
        },
        3 => s.clear(),
        else => {},
    }
}

fn saveCursor(s: *Screen) void {
    s.saved_row = s.cur_row;
    s.saved_col = s.cur_col;
}

fn restoreCursor(s: *Screen) void {
    s.cur_row = s.saved_row;
    s.cur_col = @min(s.saved_col, s.cols - 1);
    s.ensureLine(s.cur_row);
}

// ---------------------------------------------------------------- reflow

/// A position carried through a reflow (cursor, selection ends, view top).
const Mark = struct { row: usize, col: usize };

fn blankCell(c: Cell) bool {
    return c.cp == ' ' and c.bg.tag == .default and !c.attrs.inverse and !c.attrs.underline;
}

/// Re-wrap the whole buffer at `new_cols`: every run of soft-wrapped rows
/// is joined into one line and split again at the new width. The cursor,
/// saved cursor, selection and the top of a scrolled-back view keep their
/// place in the text.
fn reflow(s: *Screen, new_cols: u16) !void {
    if (s.lines.items.len == 0) return;
    const old: usize = s.cols;
    const new: usize = new_cols;

    var marks = [_]Mark{
        .{ .row = s.cur_row, .col = s.cur_col },
        .{ .row = s.saved_row, .col = s.saved_col },
        .{ .row = 0, .col = 0 }, // selection anchor
        .{ .row = 0, .col = 0 }, // selection head
        .{ .row = (s.lineCount() -| s.scroll) -| s.rows, .col = 0 }, // view top
        // The copy-flash rows (out_rows, typed_row, lf_row), at their
        // rows' starts.
        .{ .row = if (s.out_rows) |r| r.start else 0, .col = 0 },
        .{ .row = if (s.out_rows) |r| r.end orelse 0 else 0, .col = 0 },
        .{ .row = s.typed_row orelse 0, .col = 0 },
        .{ .row = s.lf_row, .col = 0 },
    };
    if (s.sel) |sel| {
        marks[2] = .{ .row = sel.anchor.row, .col = sel.anchor.col };
        marks[3] = .{ .row = sel.head.row, .col = sel.head.col };
    }
    // Rows of the new buffer that a mark landed past the end of its
    // line's text (only matters for the cursor).
    var past_end = [_]?usize{null} ** marks.len;

    var lines: std.ArrayList(Line) = .empty;
    var wraps: std.ArrayList(bool) = .empty;
    errdefer {
        for (lines.items) |*l| l.deinit(s.gpa);
        lines.deinit(s.gpa);
        wraps.deinit(s.gpa);
    }
    try lines.ensureTotalCapacity(s.gpa, s.lines.items.len);
    try wraps.ensureTotalCapacity(s.gpa, s.lines.items.len);
    var joined: std.ArrayList(Cell) = .empty;
    defer joined.deinit(s.gpa);

    var first: usize = 0;
    while (first < s.lines.items.len) {
        var last = first;
        while (last + 1 < s.lines.items.len and s.wrapped.items[last]) last += 1;
        const new_first = lines.items.len;

        // Which marks sit on these rows (placed once the line is split).
        var on_line = [_]bool{false} ** marks.len;
        for (&marks, 0..) |m, k| on_line[k] = m.row >= first and m.row <= last;

        const one = &s.lines.items[first];
        var used = one.items.len;
        while (used > 0 and blankCell(one.items[used - 1])) used -= 1;
        if (first == last and used <= new) {
            // Fits on one row as it is: move it over without copying.
            lines.appendAssumeCapacity(one.*);
            wraps.appendAssumeCapacity(false);
            one.* = .empty;
            for (&marks, 0..) |*m, k| if (on_line[k]) {
                m.row = new_first + m.col / new;
                m.col %= new;
                past_end[k] = new_first;
            };
        } else {
            // Join the rows (a wrapped row is padded to the old width; the
            // pad a wide character left before the wrap is dropped), with
            // each mark's offset in the joined cells.
            joined.clearRetainingCapacity();
            var offs = [_]usize{0} ** marks.len;
            for (s.lines.items[first .. last + 1], first..) |*l, r| {
                const base = joined.items.len;
                var n = l.items.len;
                const padded = r < last and n > 0 and l.items[n - 1].cp == 0 and !(n > 1 and l.items[n - 2].attrs.wide);
                if (padded) n -= 1;
                for (&marks, 0..) |m, k| if (on_line[k] and m.row == r) {
                    offs[k] = base + if (padded) @min(m.col, n) else m.col;
                };
                try joined.appendSlice(s.gpa, l.items[0..n]);
                if (r < last and !padded) while (joined.items.len < base + old) try joined.append(s.gpa, .{});
            }
            var len = joined.items.len;
            while (len > 0 and blankCell(joined.items[len - 1])) len -= 1;
            var at: usize = 0;
            while (true) {
                var n = @min(new, len - at);
                // A wide character never splits from its spacer: it goes to
                // the next row, leaving a pad.
                const pad = at + n < len and n > 1 and joined.items[at + n - 1].attrs.wide;
                if (pad) n -= 1;
                var l: Line = .empty;
                try l.appendSlice(s.gpa, joined.items[at .. at + n]);
                if (pad) {
                    var p = joined.items[at + n];
                    p = .{ .cp = 0, .bg = p.bg };
                    try l.append(s.gpa, p);
                }
                const row = lines.items.len;
                try lines.append(s.gpa, l);
                for (&marks, 0..) |*m, k| if (on_line[k] and offs[k] >= at and offs[k] < at + n) {
                    m.row = row;
                    m.col = offs[k] - at;
                    on_line[k] = false;
                };
                at += n;
                try wraps.append(s.gpa, at < len);
                if (at >= len) break;
            }
            // Marks past the text: counted on from the end of the last row.
            const last_row = lines.items.len - 1;
            for (&marks, 0..) |*m, k| if (on_line[k]) {
                const pos = lines.items[last_row].items.len + (offs[k] -| len);
                m.row = last_row + pos / new;
                m.col = pos % new;
                past_end[k] = new_first;
            };
        }
        for (&past_end) |*p| if (p.*) |nf| if (nf == new_first) {
            p.* = lines.items.len - 1; // the line's last row
        };
        first = last + 1;
    }

    for (s.lines.items) |*l| l.deinit(s.gpa);
    s.lines.deinit(s.gpa);
    s.wrapped.deinit(s.gpa);
    s.lines = lines;
    s.wrapped = wraps;

    // The cursor may sit past the end of its line's text (after a prompt's
    // trailing space, say): rows up to it continue the same line.
    if (past_end[0]) |last_row| {
        s.ensureLine(marks[0].row);
        var r = last_row;
        while (r < marks[0].row) : (r += 1) s.wrapped.items[r] = true;
    }
    const top = s.lines.items.len - 1;
    s.cur_row = marks[0].row;
    s.cur_col = @intCast(@min(marks[0].col, new - 1));
    s.saved_row = @min(marks[1].row, top);
    s.saved_col = @intCast(@min(marks[1].col, new - 1));
    if (s.sel) |*sel| {
        sel.anchor = .{ .row = @min(marks[2].row, top), .col = @intCast(@min(marks[2].col, new)) };
        sel.head = .{ .row = @min(marks[3].row, top), .col = @intCast(@min(marks[3].col, new)) };
    }
    if (s.scroll > 0) s.scroll = (s.lineCount() -| s.rows) -| marks[4].row;
    if (s.out_rows) |*r| {
        r.start = @min(marks[5].row, top + 1);
        if (r.end) |*e| e.* = @min(marks[6].row, top + 1);
    }
    if (s.typed_row) |*t| t.* = @min(marks[7].row, top + 1);
    s.lf_row = @min(marks[8].row, top + 1);
    s.trim();
}

// ---------------------------------------------------------------- export

/// A cell's text: its character and the zero-width one kept with it;
/// nothing for a spacer / pad.
fn appendCell(out: *std.ArrayList(u8), gpa: std.mem.Allocator, c: Cell) !void {
    if (c.cp == 0) return;
    var buf: [4]u8 = undefined;
    for ([_]u21{ c.cp, c.extra }) |cp| if (cp != 0) {
        const len = std.unicode.utf8Encode(cp, &buf) catch 1;
        try out.appendSlice(gpa, buf[0..len]);
    };
}

/// Plain text of the whole buffer, trailing spaces and blank lines removed.
pub fn plainText(s: *const Screen, gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const n = s.lineCount();
    for (s.lines.items[0..@min(n, s.lines.items.len)], 0..) |l, i| {
        const wrap = s.isWrapped(i);
        var end = l.items.len;
        if (!wrap) while (end > 0 and l.items[end - 1].cp == ' ') {
            end -= 1;
        };
        for (l.items[0..end]) |c| try appendCell(&out, gpa, c);
        if (i + 1 < n and !wrap) try out.append(gpa, '\n');
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
    return out.toOwnedSlice(gpa);
}

/// Plain text of the selection: trailing spaces cut on each line, lines
/// joined with newlines.
pub fn selectedText(s: *const Screen, gpa: std.mem.Allocator, sel: Selection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const a, const b = sel.ordered();
    var row = a.row;
    while (row <= b.row and row < s.lines.items.len) : (row += 1) {
        const l = s.lines.items[row].items;
        const r = sel.colsOn(row) orelse .{ 0, 0 };
        const start = @min(r[0], l.len);
        var end = @min(r[1], l.len);
        const joined = row < b.row and s.isWrapped(row);
        if (!joined) while (end > start and l[end - 1].cp == ' ') {
            end -= 1;
        };
        for (l[start..end]) |c| try appendCell(&out, gpa, c);
        if (row < b.row and !joined) try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// The word (run of non-blank cells) around column `col` of line `row`,
/// as a selection; an empty one on a blank.
pub fn wordAt(s: *const Screen, row: usize, col: u16) Selection {
    const here: Pos = .{ .row = row, .col = col };
    if (row >= s.lines.items.len) return .{ .anchor = here, .head = here };
    const l = s.lines.items[row].items;
    if (col >= l.len or l[col].cp == ' ') return .{ .anchor = here, .head = here };
    var start: usize = col;
    while (start > 0 and l[start - 1].cp != ' ') start -= 1;
    var end: usize = col;
    while (end < l.len and l[end].cp != ' ') end += 1;
    return .{ .anchor = .{ .row = row, .col = @intCast(start) }, .head = .{ .row = row, .col = @intCast(end) } };
}

// ---------------------------------------------------------------- text API
//
// Positions for the file opener (the job window text API): `line` is a logical
// line (rows that wrapped at the edge joined), numbered since the window
// opened, so resizing / reflow never moves a position; `col` is the
// character in that line. Ranges end-exclusive.

pub const TextPos = struct {
    line: u64,
    col: u32,

    pub fn before(a: TextPos, b: TextPos) bool {
        return a.line < b.line or (a.line == b.line and a.col < b.col);
    }
};

pub const TextRange = struct {
    start: TextPos,
    end: TextPos,

    pub fn contains(r: TextRange, p: TextPos) bool {
        return !p.before(r.start) and p.before(r.end);
    }
};

/// The first row of the logical line holding `row`.
fn lineStartRow(s: *const Screen, row: usize) usize {
    var r = row;
    while (r > 0 and s.isWrapped(r - 1)) r -= 1;
    return r;
}

/// Logical position of cell (row, col); null for the head of a line whose
/// start was dropped, or a row out of range.
pub fn textPos(s: *const Screen, row: usize, col: u16) ?TextPos {
    if (row >= s.lines.items.len) return null;
    const first = s.lineStartRow(row);
    if (first == 0 and s.head_partial) return null;
    var line_no = s.line_base;
    for (s.wrapped.items[0..first]) |wr| {
        if (!wr) line_no += 1;
    }
    var off: u32 = 0;
    for (s.lines.items[first..row]) |l| off += @intCast(l.items.len);
    return .{ .line = line_no, .col = off + col };
}

/// Rows [first, last] of logical line `line`; null when it isn't in memory.
pub fn rowsOf(s: *const Screen, line_no: u64) ?[2]usize {
    if (line_no < s.line_base + @intFromBool(s.head_partial)) return null;
    var n = s.line_base;
    var first: usize = 0;
    for (0..s.lines.items.len) |r| {
        if (!s.isWrapped(r) or r + 1 == s.lines.items.len) {
            if (n == line_no) return .{ first, r };
            n += 1;
            first = r + 1;
        }
    }
    return null;
}

/// The characters of logical line `line` (into `buf`; trailing blanks
/// cut), or null when the line isn't in memory.
pub fn lineChars(s: *const Screen, line_no: u64, buf: []u21) ?[]u21 {
    const rows = s.rowsOf(line_no) orelse return null;
    var n: usize = 0;
    for (s.lines.items[rows[0] .. rows[1] + 1]) |l| for (l.items) |cell| {
        if (n == buf.len) break;
        buf[n] = cell.cp;
        n += 1;
    };
    while (n > 0 and buf[n - 1] == ' ') n -= 1;
    return buf[0..n];
}

/// Row and column of a logical position (a column past the line's end:
/// the end of its last row).
pub fn physPos(s: *const Screen, p: TextPos) ?Pos {
    const rows = s.rowsOf(p.line) orelse return null;
    var left: usize = p.col;
    var r = rows[0];
    while (r < rows[1]) : (r += 1) {
        const len = s.lines.items[r].items.len;
        if (left < len) break;
        left -= len;
    }
    return .{ .row = r, .col = @intCast(@min(left, s.cols)) };
}

/// Text with the original colors re-encoded as ANSI SGR sequences.
pub fn ansiText(s: *const Screen, gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const n = s.lineCount();
    var buf: [64]u8 = undefined;
    var pen: Cell = .{};
    for (s.lines.items[0..@min(n, s.lines.items.len)], 0..) |l, i| {
        const wrap = s.isWrapped(i);
        var end = l.items.len;
        if (!wrap) while (end > 0 and l.items[end - 1].cp == ' ' and l.items[end - 1].bg.tag == .default) {
            end -= 1;
        };
        for (l.items[0..end]) |c| {
            if (c.cp == 0) continue;
            if (!c.fg.eql(pen.fg) or !c.bg.eql(pen.bg) or !c.attrs.sameLook(pen.attrs)) {
                try out.appendSlice(gpa, "\x1b[0");
                if (c.attrs.bold) try out.appendSlice(gpa, ";1");
                if (c.attrs.dim) try out.appendSlice(gpa, ";2");
                if (c.attrs.italic) try out.appendSlice(gpa, ";3");
                if (c.attrs.underline) try out.appendSlice(gpa, ";4");
                if (c.attrs.inverse) try out.appendSlice(gpa, ";7");
                try out.appendSlice(gpa, try sgrColor(&buf, c.fg, 38));
                try out.appendSlice(gpa, try sgrColor(&buf, c.bg, 48));
                try out.append(gpa, 'm');
                pen = c;
            }
            try appendCell(&out, gpa, c);
        }
        if (i + 1 < n and !wrap) try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "\x1b[0m");
    return out.toOwnedSlice(gpa);
}

fn sgrColor(buf: []u8, c: Color, base: u8) ![]const u8 {
    return switch (c.tag) {
        .default => "",
        .indexed => try std.fmt.bufPrint(buf, ";{d};5;{d}", .{ base, c.v[0] }),
        .rgb => try std.fmt.bufPrint(buf, ";{d};2;{d};{d};{d}", .{ base, c.v[0], c.v[1], c.v[2] }),
    };
}

// ---------------------------------------------------------------- tests

fn textOf(s: *const Screen) ![]u8 {
    return s.plainText(std.testing.allocator);
}

test "plain text, CR/LF and colors" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(20, 5);
    s.feed("hello\r\n\x1b[31mred\x1b[0m world\r\n");
    const t = try textOf(&s);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("hello\nred world", t);
    try std.testing.expectEqual(Color.Tag.indexed, s.lines.items[1].items[0].fg.tag);
}

test "carriage return overwrite and erase line (progress bars)" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(20, 5);
    s.feed("10%\r50%\r\x1b[K100% done");
    const t = try textOf(&s);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("100% done", t);
}

test "osc title is skipped, utf8 decoded, wrap at cols" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(4, 5);
    s.feed("\x1b]0;title\x07שלום!");
    const t = try textOf(&s);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("שלום!", t); // a wrapped row copies as one line
    try std.testing.expect(s.isWrapped(0));
}

test "wide characters take two cells" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(6, 3);
    s.feed("a✅b");
    try std.testing.expectEqual(@as(u16, 4), s.cur_col);
    const l = s.lines.items[0].items;
    try std.testing.expect(l[1].attrs.wide);
    try std.testing.expectEqual(@as(u21, 0), l[2].cp);
    try std.testing.expectEqual(@as(u21, 'b'), l[3].cp);
    // Last column left: the next wide one wraps, leaving a pad.
    s.feed("c😀d");
    try std.testing.expect(s.isWrapped(0));
    try std.testing.expectEqual(@as(u21, 0), s.lines.items[0].items[5].cp);
    const t = try textOf(&s);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("a✅bc😀d", t);
}

test "wide characters: overwriting half of one blanks the other half" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(10, 3);
    s.feed("✅✅\rx\x1b[3Gy");
    const t = try textOf(&s);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("x y", t);
}

test "wide characters: combining marks, emoji sequences copy as sent" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(20, 3);
    const text = "e\u{301} ❤\u{FE0F} 👍\u{1F3FD} ✔";
    s.feed(text);
    const t = try textOf(&s);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings(text, t);
    try std.testing.expectEqual(@as(u16, 10), s.cur_col); // é 1, ❤ 1, 👍🏽 2+2, ✔ 1, spaces 3
}

test "wide characters: reflow keeps them whole" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(7, 5);
    s.feed("ab✅✅✅cd");
    try std.testing.expect(s.isWrapped(0)); // "ab✅✅" + pad
    s.resize(5, 5);
    for (s.lines.items) |l| for (l.items, 0..) |cell, i| {
        if (cell.attrs.wide) try std.testing.expect(i + 1 < l.items.len and l.items[i + 1].cp == 0);
    };
    const t = try textOf(&s);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("ab✅✅✅cd", t);
    s.resize(40, 5);
    try std.testing.expectEqual(@as(usize, 10), s.lines.items[0].items.len);
    try std.testing.expect(!s.isWrapped(0));
}

test "zones: an AI request line and its output" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(30, 6);
    s.feed("\x1b]133;D;0\x07% \x1b]133;B\x07");
    s.ai = .armed;
    s.feed("gtty-ai 1 'x'\r\n\x1b]133;C\x07out\r\n\x1b]133;D;0\x07% \x1b]133;B\x07ls\r\n");
    try std.testing.expectEqual(Zone.ai, s.rowZone(0));
    try std.testing.expectEqual(Zone.ai, s.rowZone(1));
    try std.testing.expectEqual(Zone.input, s.rowZone(2)); // after the D: the user's again
    try std.testing.expect(s.ai == .off);
}

test "zones: prompt, typed command, output" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(30, 6);
    s.feed("\x1b]133;D;0\x07~ %\x1b]133;B\x07 ls\r\n\x1b]133;C\x07a b\r\nc\r\n\x1b]133;D;0\x07~ %\x1b]133;B\x07");
    try std.testing.expectEqual(Zone.input, s.rowZone(0)); // prompt + typed
    try std.testing.expectEqual(Zone.output, s.rowZone(1));
    try std.testing.expectEqual(Zone.output, s.rowZone(2));
    try std.testing.expectEqual(Zone.none, s.rowZone(3)); // a prompt, nothing typed yet
    // No marks (cat): the echo of typed text is input, the rest output.
    var p = Screen.init(std.testing.allocator);
    defer p.deinit();
    p.resize(30, 6);
    p.echo = true;
    p.feed("hello\r\nhello\r\n");
    try std.testing.expectEqual(Zone.input, p.rowZone(0));
    try std.testing.expectEqual(Zone.output, p.rowZone(1));
}

test "typed output: the answer to the last line typed (ssh, no marks)" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(40, 6);
    const head = "\x1b]133;C\x07remote$ ";
    s.feed(head);
    try std.testing.expect(s.typedOutput() == null);
    s.echo = true; // typed: ls
    s.feed("ls\r\n");
    const answer = "a b\r\nc\r\n";
    s.feed(answer ++ "remote$ ");
    const r = s.typedOutput().?;
    const all = head ++ "ls\r\n" ++ answer;
    try std.testing.expectEqual(@as(u64, head.len + 4), r.start);
    try std.testing.expectEqual(@as(u64, all.len), r.end.?);
    s.echo = true; // typed: an empty line, nothing came back yet
    s.feed("\r\n");
    const e = s.typedOutput().?;
    try std.testing.expectEqual(e.start, e.end.?);
}

test "OSC 7: the folder the shell is in" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.feed("\x1b]7;file://host/Users/me/my%20dir\x07$ ");
    try std.testing.expectEqualStrings("/Users/me/my dir", s.reportedFolder());
    try std.testing.expectEqual(@as(u32, 1), s.osc_cwd_gen);
    s.feed("\x1b]7;file:///tmp/100%25\x1b\\");
    try std.testing.expectEqualStrings("/tmp/100%", s.reportedFolder());
    s.feed("\x1b]7;http://x/y\x07"); // not a folder: kept
    try std.testing.expectEqualStrings("/tmp/100%", s.reportedFolder());
    const t = try textOf(&s);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("$", t);
}

test "shell marks: several commands, the range is the last one's" {
    const session = "% echo one\r\n\x1b]133;C\x07one\r\n\x1b]133;D;0\x07% echo two\r\n\x1b]133;C\x07two\r\n" ++
        "\x1b]133;D;0\x07% \x1b]133;D;0\x07% ls x\r\n\x1b]133;C\x1b\\ls: x: No such file\r\n\x1b]133;D;1\x1b\\% ";
    // Whole, and in chunks that split the marks.
    for ([_]usize{ session.len, 1, 3, 7 }) |step| {
        var s = Screen.init(std.testing.allocator);
        defer s.deinit();
        s.resize(40, 5);
        var i: usize = 0;
        while (i < session.len) : (i += step) s.feed(session[i..@min(i + step, session.len)]);
        const o = s.last_output.?;
        try std.testing.expectEqualStrings("ls: x: No such file\r\n", session[o.start..o.end.?]);
    }
}

test "shell marks: the last command's output range" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(20, 5);
    const first = "$ ls\r\n\x1b]133;C\x07";
    s.feed(first ++ "a b\r\n\x1b]133;D;0\x07$ ");
    try std.testing.expectEqual(Range{ .start = first.len, .end = first.len + 5 }, s.last_output.?);
    s.feed("\x1b]133;D;0\x1b\\$ "); // empty line: keeps the range
    try std.testing.expectEqual(@as(?u64, first.len + 5), s.last_output.?.end);
    const at = s.fed;
    try std.testing.expect(s.at_prompt);
    s.feed("\x1b]133;C\x1b\\run"); // running: open range
    try std.testing.expect(!s.at_prompt);
    try std.testing.expectEqual(Range{ .start = at + 9 }, s.last_output.?);
    const t = try textOf(&s);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("$ ls\na b\n$ $ run", t);
}

test "selection text across lines, word at" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(20, 5);
    s.feed("hello world\r\nsecond line   \r\nthird");
    const sel: Selection = .{ .anchor = .{ .row = 2, .col = 3 }, .head = .{ .row = 0, .col = 6 } };
    const t = try s.selectedText(std.testing.allocator, sel);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("world\nsecond line\nthi", t);
    const w = s.wordAt(1, 9);
    try std.testing.expectEqual(@as(u16, 7), w.anchor.col);
    try std.testing.expectEqual(@as(u16, 11), w.head.col);
    try std.testing.expect(s.wordAt(1, 6).empty());
}

test "reflow joins wrapped rows and re-wraps at the new width" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(10, 5);
    s.feed("0123456789abcdefghij\r\nshort\r\n$ ");
    try std.testing.expectEqual(@as(usize, 4), s.lines.items.len); // 2 wrapped rows
    s.resize(25, 5);
    try std.testing.expectEqual(@as(usize, 20), s.lines.items[0].items.len);
    try std.testing.expect(!s.isWrapped(0));
    try std.testing.expectEqual(@as(usize, 2), s.cur_row);
    try std.testing.expectEqual(@as(u16, 2), s.cur_col);
    s.resize(7, 5);
    try std.testing.expectEqual(@as(usize, 4), s.cur_row); // 20 chars → 3 rows, then "short"
    const t = try textOf(&s);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("0123456789abcdefghij\nshort\n$", t);
    s.feed("x");
    try std.testing.expectEqual(@as(u21, 'x'), s.lines.items[s.cur_row].items[2].cp);
}

test "memory window drops old rows" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(10, 5);
    s.max_lines = 100;
    var i: usize = 0;
    while (i < 1000) : (i += 1) s.feed("x\r\n");
    try std.testing.expect(s.lines.items.len <= 100 + 512);
    try std.testing.expect(s.dropped > 0);
    try std.testing.expectEqual(s.lines.items.len, s.wrapped.items.len);
}

test "hostile counts are clamped (cat /dev/random must not hang)" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(10, 5);
    s.max_lines = 100;
    s.feed("abcdef\r\x1b[99999999999@x");
    try std.testing.expectEqual(@as(usize, 10), s.lines.items[s.cur_row].items.len);
    var i: usize = 0;
    while (i < 2000) : (i += 1) s.feed("\x1b[2J");
    try std.testing.expect(s.lines.items.len <= 100 + 512);
    var prng = std.Random.DefaultPrng.init(42);
    var junk: [64 * 1024]u8 = undefined;
    i = 0;
    while (i < 32) : (i += 1) {
        prng.random().bytes(&junk);
        s.feed(&junk);
    }
    try std.testing.expect(s.lines.items.len <= 100 + 512);
    try std.testing.expectEqual(s.lines.items.len, s.wrapped.items.len);
}

test "bracketed paste mode follows ESC[?2004h / l" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(20, 5);
    try std.testing.expect(!s.bracketed_paste);
    s.feed("\x1b[?1;2004h$ ");
    try std.testing.expect(s.bracketed_paste);
    s.feed("\x1b[?25l"); // another private mode: no change
    try std.testing.expect(s.bracketed_paste);
    s.feed("\x1b[?2004l");
    try std.testing.expect(!s.bracketed_paste);
}

test "text API: logical lines survive wrapping, reflow and dropped rows" {
    const t = std.testing;
    var s = Screen.init(t.allocator);
    defer s.deinit();
    s.resize(10, 5);
    s.feed("first\r\n0123456789abcdefghij\r\nlast");
    // Row 2 is the wrapped half of line 1.
    try t.expectEqual(TextPos{ .line = 1, .col = 12 }, s.textPos(2, 2).?);
    var buf: [64]u21 = undefined;
    try t.expectEqual(@as(usize, 20), s.lineChars(1, &buf).?.len);
    try t.expectEqual(Pos{ .row = 2, .col = 2 }, s.physPos(.{ .line = 1, .col = 12 }).?);
    // Wider: no wrap; the same position, one row.
    s.resize(30, 5);
    try t.expectEqual(TextPos{ .line = 1, .col = 12 }, s.textPos(1, 12).?);
    try t.expectEqual(TextPos{ .line = 2, .col = 0 }, s.textPos(2, 0).?);
    try t.expect(s.lineChars(9, &buf) == null);

    // Dropping rows keeps the numbers; dropped lines are gone.
    var d = Screen.init(t.allocator);
    defer d.deinit();
    d.resize(10, 5);
    d.max_lines = 100;
    for (0..1000) |_| d.feed("x\r\n");
    const top = d.textPos(0, 0).?;
    try t.expectEqual(@as(u64, d.dropped), top.line);
    try t.expect(d.lineChars(top.line - 1, &buf) == null);
    try t.expectEqualSlices(u21, &.{'x'}, d.lineChars(top.line, &buf).?);
}

test "copy flash rows: the last command's output, through reflow" {
    var s = Screen.init(std.testing.allocator);
    defer s.deinit();
    s.resize(20, 5);
    s.feed("% ls\r\n\x1b]133;C\x07one\r\ntwo\r\n\x1b]133;D;0\x07% ");
    try std.testing.expectEqual(@as(usize, 1), s.out_rows.?.start);
    try std.testing.expectEqual(@as(?usize, 3), s.out_rows.?.end);
    // A second command: its rows replace the first's.
    s.feed("cat x\r\n\x1b]133;C\x07a line long enough to wrap twice here\r\n\x1b]133;D;0\x07% ");
    try std.testing.expectEqual(@as(usize, 4), s.out_rows.?.start);
    try std.testing.expectEqual(@as(?usize, 6), s.out_rows.?.end); // wrapped over 2 rows
    // Wider: the wrapped line joins into one row.
    s.resize(60, 5);
    try std.testing.expectEqual(@as(usize, 4), s.out_rows.?.start);
    try std.testing.expectEqual(@as(?usize, 5), s.out_rows.?.end);
}
