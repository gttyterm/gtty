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

const std = @import("std");

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
