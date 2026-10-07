// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Does a command line mean something to the OS? Checked before gtty's own
//! commands (see ui/commands.zig). Asks the file system the way a shell
//! would, without starting one:
//!   * a path (`./build.sh`, `/bin/ls`, `~/bin/x`): an executable file,
//!   * a shell keyword or builtin (`cd`, `export`, `for`, `[[`, …),
//!   * a program on $PATH.
//! Leading `VAR=value` assignments are skipped. Lines a shell would expand
//! first (`$CMD`, `` `cmd` ``, `(…)`) are left to the shell.
//!
//! The user's own aliases and functions come from the shell itself, see
//! ShellNames.zig (App checks both).

const std = @import("std");
const c = @import("../c.zig").c;

pub fn knows(line: []const u8) bool {
    const word = commandWord(line) orelse return false;
    switch (word[0]) {
        '$', '`', '(', '{', '!' => return true, // expanded / grouped by the shell
        else => {},
    }
    return isShellWord(word) or isProgram(word);
}

/// A file that can be run: an executable path, or a program on $PATH.
pub fn isProgram(word: []const u8) bool {
    if (std.mem.indexOfScalar(u8, word, '/') != null) return executablePath(word);
    return onPath(word);
}

/// The command word: the first word after any `NAME=value` assignments,
/// with surrounding quotes removed. Null if there is none.
pub fn commandWord(line: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |w| {
        if (isAssignment(w)) continue;
        const unq = std.mem.trim(u8, w, "'\"");
        return if (unq.len > 0) unq else null;
    }
    return null;
}

fn isAssignment(w: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, w, '=') orelse return false;
    if (eq == 0) return false;
    for (w[0..eq], 0..) |ch, i| {
        const ok = ch == '_' or std.ascii.isAlphabetic(ch) or (i > 0 and std.ascii.isDigit(ch));
        if (!ok) return false;
    }
    return true;
}

/// Keywords and builtins common to sh/bash/zsh (plus a few zsh ones).
/// `help` is left out on purpose: zsh has no such builtin, so it falls
/// through to gtty's own help.
const shell_words = [_][]const u8{
    // keywords
    "if",       "then",     "else",    "elif",     "fi",      "case",    "esac",
    "for",      "while",    "until",   "do",       "done",    "function", "select",
    "time",     "coproc",   "[[",      "[",        ".",       ":",
    // builtins
    "alias",    "bg",       "bind",    "break",    "builtin", "cd",      "command",
    "continue", "declare",  "dirs",    "disown",   "echo",    "eval",    "exec",
    "exit",     "export",   "false",   "fc",       "fg",      "getopts", "hash",
    "history",  "jobs",     "kill",    "let",      "local",   "logout",  "popd",
    "printf",   "pushd",    "pwd",     "read",     "readonly", "return", "set",
    "shift",    "shopt",    "source",  "suspend",  "test",    "times",   "trap",
    "true",     "type",     "typeset", "ulimit",   "umask",   "unalias", "unset",
    "wait",     "whence",   "where",   "which",    "autoload", "bindkey", "emulate",
    "functions", "setopt",  "unsetopt", "zmodload", "rehash", "print",   "noglob",
};

pub fn isShellWord(w: []const u8) bool {
    for (shell_words) |sw| if (std.mem.eql(u8, sw, w)) return true;
    return false;
}

fn executablePath(word: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const path = if (std.mem.startsWith(u8, word, "~/")) blk: {
        const home = c.getenv("HOME") orelse return false;
        break :blk std.fmt.bufPrintZ(&buf, "{s}{s}", .{ std.mem.span(home), word[1..] }) catch return false;
    } else std.fmt.bufPrintZ(&buf, "{s}", .{word}) catch return false;
    return c.access(path.ptr, c.X_OK) == 0;
}

fn onPath(word: []const u8) bool {
    const path_env = c.getenv("PATH") orelse return false;
    var dirs = std.mem.tokenizeScalar(u8, std.mem.span(path_env), ':');
    var buf: [4096]u8 = undefined;
    while (dirs.next()) |dir| {
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, word }) catch continue;
        if (c.access(full.ptr, c.X_OK) == 0) return true;
    }
    return false;
}

test "command word and OS lookup" {
    const t = std.testing;
    try t.expectEqualStrings("make", commandWord("CC=clang FOO_1=x make -j8").?);
    try t.expectEqualStrings("ls", commandWord("  'ls' -l").?);
    try t.expect(commandWord("A=1") == null);
    try t.expect(knows("ls -la")); // /bin/ls
    try t.expect(knows("cd /tmp")); // builtin
    try t.expect(knows("for i in 1 2; do echo $i; done"));
    try t.expect(knows("/bin/sh -c true"));
    try t.expect(knows("$EDITOR file"));
    try t.expect(!knows("quit"));
    try t.expect(!knows("frobnicate-xyz-123"));
    try t.expect(!knows("./no/such/script.sh"));
}
