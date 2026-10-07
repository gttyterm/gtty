// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! A one-line text field's editing (a modal's input: renaming a file):
//! the text, the cursor and a selection (`anchor` … `cursor`). The usual
//! keys: ←/→ (by words with ⌥ / Ctrl), Home / End (⌘ + ←/→), Shift
//! extends the selection, Backspace / Delete (by words with ⌥ / Ctrl),
//! typing or pasting replaces the selection. Pure: no drawing, no keys
//! (Modal maps the keys).

const std = @import("std");

const LineEdit = @This();

pub const max = 255;

buf: [max]u21 = undefined,
len: usize = 0,
cursor: usize = 0,
/// The other end of the selection (== cursor: none).
anchor: usize = 0,

pub fn init(s: []const u8) LineEdit {
    var e: LineEdit = .{};
    e.insert(s);
    return e;
}

pub fn chars(e: *const LineEdit) []const u21 {
    return e.buf[0..e.len];
}

/// The text as UTF-8 in `out`.
pub fn text(e: *const LineEdit, out: []u8) []const u8 {
    var n: usize = 0;
    for (e.chars()) |cp| {
        var tmp: [4]u8 = undefined;
        const k = std.unicode.utf8Encode(cp, &tmp) catch continue;
        if (n + k > out.len) break;
        @memcpy(out[n..][0..k], tmp[0..k]);
        n += k;
    }
    return out[0..n];
}

/// The selection [lo, hi) (lo == hi: none).
pub fn selection(e: *const LineEdit) [2]usize {
    return .{ @min(e.anchor, e.cursor), @max(e.anchor, e.cursor) };
}

/// Select [lo, hi), the cursor at its end.
pub fn select(e: *LineEdit, lo: usize, hi: usize) void {
    e.anchor = @min(lo, e.len);
    e.cursor = @min(hi, e.len);
}

/// A file name being renamed: select the name up to its last dot (all of
/// it when there is none, or only a leading one: ".profile").
pub fn selectStem(e: *LineEdit) void {
    var dot: ?usize = null;
    for (e.chars(), 0..) |cp, i| if (cp == '.' and i > 0) {
        dot = i;
    };
    e.select(0, dot orelse e.len);
}

fn deleteSel(e: *LineEdit) bool {
    const s = e.selection();
    if (s[0] == s[1]) return false;
    std.mem.copyForwards(u21, e.buf[s[0] .. e.len - (s[1] - s[0])], e.buf[s[1]..e.len]);
    e.len -= s[1] - s[0];
    e.cursor = s[0];
    e.anchor = s[0];
    return true;
}

/// Typed or pasted text (line ends and control characters dropped)
/// replaces the selection.
pub fn insert(e: *LineEdit, s: []const u8) void {
    _ = e.deleteSel();
    var it = (std.unicode.Utf8View.init(s) catch return).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or cp == 0x7f or e.len == max) continue;
        std.mem.copyBackwards(u21, e.buf[e.cursor + 1 .. e.len + 1], e.buf[e.cursor..e.len]);
        e.buf[e.cursor] = cp;
        e.len += 1;
        e.cursor += 1;
    }
    e.anchor = e.cursor;
}

fn isWord(cp: u21) bool {
    return switch (cp) {
        ' ', '.', '-', '_', '/', '(', ')', '[', ']', ',' => false,
        else => true,
    };
}

fn wordLeftOf(e: *const LineEdit, from: usize) usize {
    var i = from;
    while (i > 0 and !isWord(e.buf[i - 1])) i -= 1;
    while (i > 0 and isWord(e.buf[i - 1])) i -= 1;
    return i;
}

fn wordRightOf(e: *const LineEdit, from: usize) usize {
    var i = from;
    while (i < e.len and !isWord(e.buf[i])) i += 1;
    while (i < e.len and isWord(e.buf[i])) i += 1;
    return i;
}

pub const Move = enum { left, right, word_left, word_right, home, end };

/// Move the cursor; `extend` (Shift) keeps the selection's other end,
/// else a plain ←/→ on a selection goes to its edge.
pub fn move(e: *LineEdit, m: Move, extend: bool) void {
    const s = e.selection();
    const to: usize = switch (m) {
        .left => if (!extend and s[0] != s[1]) s[0] else e.cursor -| 1,
        .right => if (!extend and s[0] != s[1]) s[1] else @min(e.cursor + 1, e.len),
        .word_left => e.wordLeftOf(e.cursor),
        .word_right => e.wordRightOf(e.cursor),
        .home => 0,
        .end => e.len,
    };
    e.cursor = to;
    if (!extend) e.anchor = to;
}

/// Backspace (`word`: the word before the cursor): the selection, else
/// what is before the cursor.
pub fn backspace(e: *LineEdit, word: bool) void {
    if (e.deleteSel()) return;
    e.anchor = if (word) e.wordLeftOf(e.cursor) else e.cursor -| 1;
    _ = e.deleteSel();
}

/// Delete (`word`: the word after the cursor): the selection, else what
/// is after the cursor.
pub fn delete(e: *LineEdit, word: bool) void {
    if (e.deleteSel()) return;
    e.anchor = if (word) e.wordRightOf(e.cursor) else @min(e.cursor + 1, e.len);
    _ = e.deleteSel();
}

pub fn selectAll(e: *LineEdit) void {
    e.select(0, e.len);
}

test "line editing" {
    const t = std.testing;
    var buf: [300]u8 = undefined;
    var e = LineEdit.init("My File.txt");
    e.selectStem();
    try t.expectEqual([2]usize{ 0, 7 }, e.selection());
    e.insert("Report");
    try t.expectEqualStrings("Report.txt", e.text(&buf));
    e.move(.end, false);
    e.backspace(true);
    try t.expectEqualStrings("Report.", e.text(&buf));
    e.move(.word_left, false);
    try t.expectEqual(@as(usize, 0), e.cursor);
    e.move(.word_right, true);
    try t.expectEqual([2]usize{ 0, 6 }, e.selection());
    e.delete(false);
    try t.expectEqualStrings(".", e.text(&buf));

    var d = LineEdit.init(".profile");
    d.selectStem();
    try t.expectEqual([2]usize{ 0, 8 }, d.selection());
    var a = LineEdit.init("archive.tar.gz");
    a.selectStem();
    try t.expectEqual([2]usize{ 0, 11 }, a.selection());
    a.move(.left, false);
    try t.expectEqual(@as(usize, 0), a.cursor);
    a.insert("x\ny");
    try t.expectEqualStrings("xyarchive.tar.gz", a.text(&buf));
}
