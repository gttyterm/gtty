// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Finding a file name in a line of output, around one column (the file
//! opener). Pure text work: which spans could be a path, written out as
//! the path to try. The file opener then checks each one on disk, in
//! order, and takes the first that exists.
//!
//! What counts (any OS's style, since output can come from anywhere):
//!   * a quoted string around the column ("my file.txt", 'x', `x`);
//!   * else the run of characters around it up to a blank or one of
//!     `| ; < > ( ) [ ] { } , =` and quotes; `\ ` (escaped blank) stays
//!     in it (`my\ file.txt`);
//!   * dropped from its ends: leading `( [ <`, trailing `. , : ; ! ?` and
//!     closing brackets; a trailing `:line` / `:line:col` (compilers,
//!     grep -n) or `(line)` / `(line,col)` (MSVC);
//!   * `file://` URLs (with %xx escapes); other URLs (`https://`) are not
//!     files;
//!   * `a/` and `b/` of `git diff` headers (tried without them too);
//!   * Windows separators: `src\main.c` is also tried as `src/main.c`
//!     (a drive letter `C:\…` can't exist here, it is tried as is).
//!
//! Names with blanks or punctuation in them (`My File.txt`, `a (1).pdf`)
//! can't be told from the text alone: `longestKnown` tries the spans
//! around the column that start and end at word edges and keeps the
//! longest one the caller knows (FileOpener asks the folder listings,
//! DirCache).

const std = @import("std");
const wcwidth = @import("../core/wcwidth.zig");

pub const max_path = 1024;

pub const Candidate = struct {
    /// Columns of the name in the line [start, end): what gets outlined.
    start: u32,
    end: u32,
    buf: [max_path]u8 = undefined,
    len: usize = 0,

    pub fn text(c: *const Candidate) []const u8 {
        return c.buf[0..c.len];
    }
};

pub const max_candidates = 6;

pub const List = struct {
    items: [max_candidates]Candidate = undefined,
    n: usize = 0,

    fn add(l: *List, c: Candidate) void {
        if (c.len == 0 or l.n == max_candidates) return;
        for (l.items[0..l.n]) |*o| if (std.mem.eql(u8, o.text(), c.text())) return;
        l.items[l.n] = c;
        l.n += 1;
    }

    pub fn slice(l: *const List) []const Candidate {
        return l.items[0..l.n];
    }
};

fn isBlank(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == 0;
}

fn isQuote(cp: u21) bool {
    return cp == '"' or cp == '\'' or cp == '`';
}

fn isDelim(cp: u21) bool {
    return isBlank(cp) or isQuote(cp) or switch (cp) {
        '|', ';', '<', '>', '(', ')', '[', ']', '{', '}', ',', '=' => true,
        else => false,
    };
}

/// The candidates around column `col` of `line`, most likely first.
pub fn candidates(line: []const u21, col: usize) List {
    var out: List = .{};
    if (col >= line.len) return out;

    // A quoted string around the column (not when the column is on a quote).
    if (!isQuote(line[col])) if (quotedAround(line, col)) |q| {
        addVariants(&out, line, q[0], q[1], false);
    };
    if (isBlank(line[col]) and !(col > 0 and line[col - 1] == '\\')) return out;

    // The run of path characters around the column.
    if (isDelim(line[col]) and !(line[col] == ' ' and col > 0 and line[col - 1] == '\\')) return out;
    var start = col;
    while (start > 0) {
        const p = line[start - 1];
        if (p == ' ' and start >= 2 and line[start - 2] == '\\') {
            start -= 2;
            continue;
        }
        if (isDelim(p)) break;
        start -= 1;
    }
    var end = col;
    while (end < line.len) {
        const ch = line[end];
        if (ch == '\\' and end + 1 < line.len and line[end + 1] == ' ') {
            end += 2;
            continue;
        }
        if (isDelim(ch)) break;
        end += 1;
    }
    addVariants(&out, line, start, end, true);
    return out;
}

/// Most word edges looked at on each side of the column (long titles
/// have many words), and the most characters a name with blanks can have.
const max_edges = 40;
const max_span = 255;

/// Ends a word: a blank, a delimiter, or end-of-sentence punctuation.
fn isEdgeChar(cp: u21) bool {
    return isDelim(cp) or switch (cp) {
        '.', ':', '!', '?' => true,
        else => false,
    };
}

/// A character `isSpecial` names have: one that splits the plain run.
pub fn isSpecial(cp: u21) bool {
    return isDelim(cp) and cp != 0;
}

/// A name the plain run can't find: it has a blank or a delimiter in it,
/// or ends with punctuation the run drops.
pub fn specialName(name: []const u8) bool {
    var it = (std.unicode.Utf8View.init(name) catch return false).iterator();
    while (it.nextCodepoint()) |cp| if (isSpecial(cp)) return true;
    return name.len > 0 and switch (name[name.len - 1]) {
        '.', ',', ':', ';', '!', '?' => true,
        else => false,
    };
}

/// Names with blanks or punctuation: of the spans around `col` that
/// start after a blank / delimiter (or the line's start) and end before
/// one (or end-of-sentence punctuation, or the line's end), the longest
/// with a blank or delimiter inside it that `known(ctx, text)` accepts.
/// The text is the span as written (`\ ` → blank).
/// On a blank (`My   File.txt`, the mouse between the words): a name
/// must go on to the right of it, so the line has to have more text
/// there (a line's trailing blanks are cut: past them is its end); the
/// spans then start left of the blank and end right of it.
/// A wide character (`？`, CJK, emoji) is followed by a spacer cell (0)
/// on the screen: the spans are looked for without them, and the columns
/// given back cover both cells.
pub fn longestKnown(line: []const u21, col: usize, ctx: anytype, comptime known: fn (@TypeOf(ctx), []const u8) bool) ?Candidate {
    if (col >= line.len) return null;
    var buf: [4096]u21 = undefined;
    var at: [4097]u32 = undefined; // line column of each character, + the end
    var n: usize = 0;
    var ccol: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < buf.len) : (n += 1) {
        if (i <= col) ccol = n;
        buf[n] = line[i];
        at[n] = @intCast(i);
        i += 1;
        if (line[i - 1] != 0 and wcwidth.width(line[i - 1]) == 2 and i < line.len and line[i] == 0) i += 1;
    }
    at[n] = @intCast(i);
    if (ccol >= n) return null;
    var c = longestKnownIn(buf[0..n], ccol, ctx, known) orelse return null;
    c.start = at[c.start];
    c.end = at[c.end];
    return c;
}

fn longestKnownIn(line: []const u21, col: usize, ctx: anytype, comptime known: fn (@TypeOf(ctx), []const u8) bool) ?Candidate {
    if (col >= line.len) return null;
    if (isBlank(line[col])) {
        const right = for (line[col + 1 ..]) |cp| {
            if (!isBlank(cp)) break true;
        } else false;
        const left = for (line[0..col]) |cp| {
            if (!isBlank(cp)) break true;
        } else false;
        if (!right or !left) return null;
    }
    var starts: [max_edges]usize = undefined;
    var ns: usize = 0;
    var s = col + 1;
    while (s > 0 and ns < max_edges and col + 1 - s < max_span) {
        s -= 1;
        if (isBlank(line[s])) continue;
        if (s == 0 or isDelim(line[s - 1])) {
            starts[ns] = s;
            ns += 1;
        }
    }
    var ends: [max_edges]usize = undefined;
    var ne: usize = 0;
    var e = col + 1;
    while (e <= line.len and ne < max_edges and e - col < max_span) : (e += 1) {
        if (isBlank(line[e - 1])) continue;
        if (e == line.len or isDelim(line[e]) or (isEdgeChar(line[e]) and (e + 1 == line.len or isDelim(line[e + 1])))) {
            ends[ne] = e;
            ne += 1;
        }
    }
    var best: ?Candidate = null;
    for (starts[0..ns]) |a| for (ends[0..ne]) |b| {
        if (b - a > max_span) continue;
        if (best) |bc| if (b - a <= bc.end - bc.start) continue;
        const span = line[a..b];
        const inner = for (span) |cp| {
            if (isSpecial(cp)) break true;
        } else false;
        // No blank / delimiter inside: only a name ending in punctuation
        // the plain run drops ("notes.").
        if (!inner and !isEdgeChar(span[span.len - 1])) continue;
        var c: Candidate = .{ .start = @intCast(a), .end = @intCast(b) };
        if (!encode(&c, span, false)) continue;
        if (known(ctx, c.text())) best = c;
    };
    return best;
}

/// The inside of the nearest quotes around `col` on this line.
fn quotedAround(line: []const u21, col: usize) ?[2]usize {
    var i = col;
    while (i > 0) {
        i -= 1;
        if (isQuote(line[i])) {
            const q = line[i];
            var j = col;
            while (j < line.len) : (j += 1) if (line[j] == q) {
                return if (j > i + 1) .{ i + 1, j } else null;
            };
            return null;
        }
    }
    return null;
}

/// The span [start, end) cleaned up, then written out as paths to try.
fn addVariants(out: *List, line: []const u21, start_in: usize, end_in: usize, token: bool) void {
    var start = start_in;
    var end = end_in;
    if (token) {
        // Leading openers, trailing punctuation / closers.
        while (start < end and (line[start] == '(' or line[start] == '[' or line[start] == '<')) start += 1;
        while (end > start) {
            switch (line[end - 1]) {
                '.', ',', ':', ';', '!', '?', ')', ']', '}', '>' => end -= 1,
                else => break,
            }
        }
        // A trailing ":12" / ":12:5" (also after stripping a final ':').
        end = stripLineCol(line, start, end);
    }
    if (end <= start) return;
    const span = line[start..end];

    // Other URLs aren't files; file:// is.
    var skip: usize = 0;
    if (startsWith(span, "file://")) {
        skip = 7;
    } else if (urlScheme(span)) return;

    var c: Candidate = .{ .start = @intCast(start), .end = @intCast(end) };
    if (!encode(&c, span[skip..], skip > 0)) return;
    out.add(c);

    // git diff's a/ b/ prefixes.
    if (startsWith(c.text(), "a/") or startsWith(c.text(), "b/")) {
        var d = c;
        std.mem.copyForwards(u8, d.buf[0 .. d.len - 2], d.buf[2..d.len]);
        d.len -= 2;
        out.add(d);
    }
    // Windows separators (not an escaped blank, not a drive letter).
    if (std.mem.indexOfScalar(u8, c.text(), '\\') != null and std.mem.indexOf(u8, c.text(), "\\ ") == null and !driveLetter(c.text())) {
        var d = c;
        std.mem.replaceScalar(u8, d.buf[0..d.len], '\\', '/');
        out.add(d);
    }
}

fn stripLineCol(line: []const u21, start: usize, end_in: usize) usize {
    var end = end_in;
    // MSVC: name(12) / name(12,5) — the '(' was a delimiter, so the run
    // already stopped before it; nothing to do here.
    var k: usize = 0;
    while (k < 2) : (k += 1) {
        var i = end;
        while (i > start and line[i - 1] >= '0' and line[i - 1] <= '9') i -= 1;
        if (i == end or i <= start + 1 or line[i - 1] != ':') break;
        end = i - 1;
    }
    return end;
}

fn startsWith(span: anytype, prefix: []const u8) bool {
    if (span.len < prefix.len) return false;
    for (prefix, 0..) |ch, i| if (span[i] != ch) return false;
    return true;
}

/// "https://", "ssh://": a scheme of letters then "://".
fn urlScheme(span: []const u21) bool {
    var i: usize = 0;
    while (i < span.len and ((span[i] >= 'a' and span[i] <= 'z') or (span[i] >= 'A' and span[i] <= 'Z'))) i += 1;
    return i >= 2 and i + 3 <= span.len and span[i] == ':' and span[i + 1] == '/' and span[i + 2] == '/';
}

fn driveLetter(s: []const u8) bool {
    return s.len >= 2 and std.ascii.isAlphabetic(s[0]) and s[1] == ':';
}

/// UTF-8 into the candidate; `\ ` → blank; %xx decoded for URLs. False
/// when it doesn't fit or has control characters.
fn encode(c: *Candidate, span: []const u21, url: bool) bool {
    var i: usize = 0;
    while (i < span.len) : (i += 1) {
        var cp = span[i];
        if (cp < 0x20 or cp == 0x7f) return false;
        if (cp == '\\' and i + 1 < span.len and span[i + 1] == ' ') {
            cp = ' ';
            i += 1;
        } else if (url and cp == '%' and i + 2 < span.len) {
            const hi = std.fmt.charToDigit(@intCast(@min(span[i + 1], 127)), 16) catch 255;
            const lo = std.fmt.charToDigit(@intCast(@min(span[i + 2], 127)), 16) catch 255;
            if (hi < 16 and lo < 16) {
                if (c.len == c.buf.len) return false;
                c.buf[c.len] = hi * 16 + lo;
                c.len += 1;
                i += 2;
                continue;
            }
        }
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return false;
        if (c.len + n > c.buf.len) return false;
        @memcpy(c.buf[c.len..][0..n], tmp[0..n]);
        c.len += n;
    }
    return true;
}

// ------------------------------------------------------------ tests

fn lineOf(comptime s: []const u8) [std.unicode.utf8CountCodepoints(s) catch unreachable]u21 {
    @setEvalBranchQuota(10_000);
    var out: [std.unicode.utf8CountCodepoints(s) catch unreachable]u21 = undefined;
    var it = (std.unicode.Utf8View.init(s) catch unreachable).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) out[i] = cp;
    return out;
}

fn first(comptime s: []const u8, col: usize) []const u8 {
    const S = struct {
        var l: List = .{};
    };
    const line = lineOf(s);
    S.l = candidates(&line, col);
    return if (S.l.n > 0) S.l.items[0].text() else "";
}

fn knownIn(names: []const []const u8, text: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, text)) return true;
    return false;
}

fn longest(comptime s: []const u8, col: usize, names: []const []const u8) []const u8 {
    const S = struct {
        var c: ?Candidate = null;
    };
    const line = lineOf(s);
    S.c = longestKnown(&line, col, names, knownIn);
    return if (S.c) |*c| c.text() else "";
}

test "names with blanks, from a listing" {
    const t = std.testing;
    const names: []const []const u8 = &.{ "My File.txt", "a (1).pdf", "Screen Shot 1.png", "My", "notes.", "src/Big Plan.md" };
    const names2: []const []const u8 = &.{"My   File.txt"};
    try t.expectEqualStrings("My File.txt", longest("My File.txt  other.txt", 0, names));
    try t.expectEqualStrings("My File.txt", longest("My File.txt  other.txt", 5, names));
    try t.expectEqualStrings("", longest("My File.txt  other.txt", 15, names)); // plain: the run finds it
    try t.expectEqualStrings("My File.txt", longest("-rw-r--r--  1 me  staff  0 Oct  7 12:00 My File.txt", 45, names));
    try t.expectEqualStrings("a (1).pdf", longest("saved to a (1).pdf.", 12, names));
    try t.expectEqualStrings("Screen Shot 1.png", longest("x 'Screen Shot 1.png' y", 10, names));
    try t.expectEqualStrings("src/Big Plan.md", longest("open src/Big Plan.md now", 14, names));
    try t.expectEqualStrings("", longest("My Other.txt", 1, names)); // "My" alone has no blank
    try t.expectEqualStrings("notes.", longest("cat notes. done", 6, names));
    // On a blank inside the name: found from the text to its right.
    try t.expectEqualStrings("My File.txt", longest("My File.txt", 2, names));
    try t.expectEqualStrings("My   File.txt", longest("x My   File.txt  y", 5, names2));
    try t.expectEqualStrings("My   File.txt", longest("-rw-r--r--  1 me  staff  0 Oct  7 12:00 My   File.txt", 42, names2));
    try t.expectEqualStrings("a (1).pdf", longest("saved to a (1).pdf.", 10, names));
    // A blank between names, or after the last one: nothing.
    try t.expectEqualStrings("", longest("My File.txt   other.txt", 12, names));
    try t.expectEqualStrings("", longest("My File.txt   ", 12, names));
    try t.expectEqualStrings("", longest("   My File.txt", 1, names));
}

test "a long name with a wide character" {
    const t = std.testing;
    const name = "Widowmaker X D.Va - Can You Help Me with this Stuck Butt Plug？ [27013].mp4";
    const names: []const []const u8 = &.{name};
    // As on the screen: a spacer cell (0) after the full-width ？.
    const shown = comptime blk: {
        const l = lineOf("-rw-r--r--  1 me  staff  0 Oct  8 12:00 " ++ name);
        var out: [l.len + 1]u21 = undefined;
        var j: usize = 0;
        for (l) |cp| {
            out[j] = cp;
            j += 1;
            if (cp == 0xFF1F) {
                out[j] = 0;
                j += 1;
            }
        }
        break :blk out;
    };
    const start = 40;
    for ([_]usize{ start, start + 3, start + 11, start + 60, start + 61, start + 62, shown.len - 1 }) |col| {
        const c = longestKnown(&shown, col, names, knownIn) orelse return error.NotFound;
        try t.expectEqualStrings(name, c.text());
        try t.expectEqual(@as(u32, start), c.start);
        try t.expectEqual(@as(u32, shown.len), c.end);
    }
}

test "special names" {
    const t = std.testing;
    try t.expect(specialName("My File.txt"));
    try t.expect(specialName("a(1).pdf"));
    try t.expect(specialName("notes."));
    try t.expect(!specialName("README.md"));
    try t.expect(!specialName("src-main_2.c"));
}

test "file names around a column" {
    const t = std.testing;
    try t.expectEqualStrings("src/App.zig", first("src/App.zig:120:5: error: x", 3));
    try t.expectEqualStrings("README.md", first("see README.md.", 6));
    try t.expectEqualStrings("my file.txt", first("open \"my file.txt\" now", 8));
    try t.expectEqualStrings("my file.txt", first("ls my\\ file.txt", 4));
    try t.expectEqualStrings("main.c", first("main.c(12,5): warning", 2));
    try t.expectEqualStrings("/tmp/a b.pdf", first("file:///tmp/a%20b.pdf", 10));
    try t.expectEqualStrings("", first("https://example.com/x", 10));
    try t.expectEqualStrings("notes.txt", first("--out=notes.txt", 8));
    try t.expectEqualStrings("", first("a  b", 2)); // on a blank
    try t.expectEqualStrings("~/x.log", first("(~/x.log)", 3));

    const line = lineOf("+++ b/src/main.zig");
    const l = candidates(&line, 8);
    try t.expectEqualStrings("b/src/main.zig", l.items[0].text());
    try t.expectEqualStrings("src/main.zig", l.items[1].text());
    try t.expectEqual(@as(u32, 4), l.items[0].start);
    try t.expectEqual(@as(u32, 18), l.items[0].end);

    const win = lineOf("at src\\util\\x.cs line 4");
    const w = candidates(&win, 5);
    try t.expectEqualStrings("src/util/x.cs", w.items[1].text());
    const drive = lineOf("C:\\Users\\me\\a.txt");
    try t.expectEqual(@as(usize, 1), candidates(&drive, 4).n);
}
