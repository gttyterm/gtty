// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Remote sessions (ssh / mosh in a job window). gtty stays transparent:
//! it never wraps or changes the user's ssh, their environment or config;
//! it only looks. The program in front on the window's terminal (its argv,
//! gtty_fg_args) being ssh or mosh means the text and the folder belong to
//! another machine; its arguments, as the user typed them, give the
//! destination and every option gtty's own connection copies (RemoteLink).
//!
//! This file is the pure part: reading command lines, quoting for the
//! remote shell, and the small scripts gtty's connection runs there.

const std = @import("std");

pub const Kind = enum { ssh, mosh };

pub const Session = struct {
    kind: Kind,
    /// As typed: "host", "user@host", "ssh://user@host:port".
    dest: []const u8,
};

/// ssh options that take a value (`-p 22`, `-p22`, `-vp 22`).
const ssh_with_value = "BbcDEeFIiJLlmOoPpQRSWw";

/// Where the destination is in an ssh command line (before it: ssh and
/// its options; after it: the remote command), or null.
pub fn sshDestIndex(argv: []const []const u8) ?usize {
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--")) return if (i + 1 < argv.len) i + 1 else null;
        if (a.len < 2 or a[0] != '-') return i;
        // A flag group: the first flag that takes a value takes the rest
        // of the group, or the next argument.
        for (a[1..], 1..) |ch, k| if (std.mem.indexOfScalar(u8, ssh_with_value, ch) != null) {
            if (k == a.len - 1) i += 1;
            break;
        };
    }
    return null;
}

/// The session for a command line (argv), or null when it isn't one.
pub fn sessionOf(argv: []const []const u8) ?Session {
    if (argv.len == 0) return null;
    const prog = std.fs.path.basename(argv[0]);
    if (std.mem.eql(u8, prog, "ssh")) {
        const i = sshDestIndex(argv) orelse return null;
        return .{ .kind = .ssh, .dest = argv[i] };
    }
    if (std.mem.eql(u8, prog, "mosh-client")) {
        // mosh runs `mosh-client -# 'user@host' | IP PORT`.
        for (argv[1..], 1..) |a, i| if (std.mem.eql(u8, a, "-#") and i + 1 < argv.len)
            return .{ .kind = .mosh, .dest = argv[i + 1] };
        return .{ .kind = .mosh, .dest = if (argv.len > 1) argv[argv.len - 2] else "" };
    }
    if (std.mem.eql(u8, prog, "mosh")) {
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            const a = argv[i];
            if (std.mem.eql(u8, a, "--")) return if (i + 1 < argv.len) .{ .kind = .mosh, .dest = argv[i + 1] } else null;
            if (a.len > 0 and a[0] == '-') {
                if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--port") or std.mem.eql(u8, a, "--ssh") or std.mem.eql(u8, a, "--server")) i += 1;
                continue;
            }
            return .{ .kind = .mosh, .dest = a };
        }
        return null;
    }
    return null;
}

/// Split arguments each ending in a NUL (gtty_fg_args) into `out`.
pub fn splitNul(args: []const u8, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, args, "\x00"), 0);
    while (it.next()) |a| {
        if (n == out.len) break;
        out[n] = a;
        n += 1;
    }
    return out[0..n];
}

/// From arguments each ending in a NUL (as gtty_fg_args gives them).
pub fn sessionOfNul(args: []const u8) ?Session {
    var argv: [64][]const u8 = undefined;
    return sessionOf(splitNul(args, &argv));
}

/// From a command line as typed ("ssh -p 22 host"): words split at blanks.
pub fn sessionOfLine(line: []const u8) ?Session {
    var argv: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |a| {
        if (n == argv.len) break;
        argv[n] = a;
        n += 1;
    }
    return sessionOf(argv[0..n]);
}

/// gtty's own connection, as the user's: their ssh and every option they
/// gave (up to the destination; their remote command is dropped), then
/// gtty's additions, which only change gtty's connection: never ask
/// anything (BatchMode), no port forwardings (the user's are already
/// bound), never become a ControlMaster (use the user's if one runs), no
/// terminal. mosh: its ssh with just the destination.
pub fn linkArgv(user_argv: []const []const u8, remote_cmd: []const u8, out: [][]const u8) ?[][]const u8 {
    const s = sessionOf(user_argv) orelse return null;
    var n: usize = 0;
    const add = struct {
        fn f(o: [][]const u8, k: *usize, a: []const u8) bool {
            if (k.* == o.len) return false;
            o[k.*] = a;
            k.* += 1;
            return true;
        }
    }.f;
    switch (s.kind) {
        .ssh => {
            const di = sshDestIndex(user_argv).?;
            for (user_argv[0..di]) |a| if (!add(out, &n, a)) return null;
        },
        .mosh => if (!add(out, &n, "ssh")) return null,
    }
    const extra = [_][]const u8{
        "-o", "BatchMode=yes",          "-o", "ClearAllForwardings=yes",
        "-o", "ControlMaster=no",       "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=30", "-T",
    };
    for (extra) |a| if (!add(out, &n, a)) return null;
    if (!add(out, &n, s.dest)) return null;
    if (!add(out, &n, remote_cmd)) return null;
    return out[0..n];
}

/// `s` in single quotes for a POSIX shell ('it'\''s').
pub fn shQuote(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    for (s) |ch| if (ch == '\'') try w.writeAll("'\\''") else try w.writeByte(ch);
    try w.writeByte('\'');
}

/// A remote path for the shell: `~/x` from the remote home, else quoted.
fn remotePath(w: *std.Io.Writer, p: []const u8) !void {
    if (std.mem.startsWith(u8, p, "~/")) {
        try w.writeAll("\"$HOME\"/");
        try shQuote(w, p[2..]);
    } else try shQuote(w, p);
}

/// The remote side of a session: the user's terminal there, found
/// through gtty's connection, then the program in front on it. The
/// terminal is the one of this user's session whose SSH connection has the
/// user's local port (`port`; 0 when unknown: then only a single
/// interactive session there is taken):
///   * Linux: a process with that SSH_CONNECTION in its environment and a
///     terminal on its stdin (/proc);
///   * else (macOS, BSD) or when that finds nothing: the session's sshd
///     process, named `sshd: user@tty` (`sshd-session: …` in newer
///     OpenSSH), whose TCP connection has that port (lsof).
/// Prints `cwd=` (the folder of the program in front on that terminal),
/// `idle=1` when that program is a shell waiting for a command, and `git=`
/// (the branch there); nothing when the session isn't found. When that
/// program takes the user somewhere else (another ssh / mosh / telnet, a
/// container shell: docker, podman, kubectl …) or runs as another user
/// (`sudo -i`, `su`), the folder there is unknown: only `away=1`.
pub fn infoScript(w: *std.Io.Writer, port: u16) !void {
    try w.print(
        \\p={d}; tty=; n=0; seen=
        \\if [ -d /proc/self/fd ]; then
        \\ for d in /proc/[0-9]*; do
        \\  [ -O "$d" ] || continue
        \\  t=$(readlink "$d/fd/0" 2>/dev/null) || continue
        \\  case $t in /dev/pts/*|/dev/tty*) ;; *) continue;; esac
        \\  c=$(tr '\0' '\n' < "$d/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p')
        \\  [ -n "$c" ] || continue
        \\  set -- $c
        \\  if [ "$p" != 0 ] && [ "$2" != "$p" ]; then continue; fi
        \\  case " $seen " in *" $t "*) continue;; esac
        \\  seen="$seen $t"; n=$((n+1)); tty=${{t#/dev/}}
        \\ done
        \\fi
        \\if [ -z "$tty" ]; then
        \\ n=0
        \\ for l in $(ps -U "$(id -u)" -o pid= -o command= | sed -n 's/^ *\([0-9][0-9]*\) sshd[a-z-]*: [^@ ]*@\([a-z][a-z0-9/]*\).*/\1:\2/p'); do
        \\  pid=${{l%%:*}}; t=${{l#*:}}
        \\  [ "$t" = notty ] && continue
        \\  if [ "$p" != 0 ]; then lsof -a -p "$pid" -iTCP -Fn 2>/dev/null | grep -q ":$p\$" || continue; fi
        \\  n=$((n+1)); tty=$t
        \\ done
        \\fi
        \\if [ "$p" = 0 ] && [ "$n" != 1 ]; then tty=; fi
        \\if [ -n "$tty" ]; then
        \\ fg=$(ps -t "$tty" -o tpgid= 2>/dev/null | head -1 | tr -d ' ')
        \\ comm=$(ps -o comm= -p "$fg" 2>/dev/null); comm=${{comm##*/}}; comm=${{comm#-}}
        \\ away=
        \\ case $comm in ssh|mosh|mosh-client|telnet|docker|podman|kubectl|lxc|nsenter) away=1;; esac
        \\ [ "$(ps -o uid= -p "$fg" 2>/dev/null | tr -d ' ')" = "$(id -u)" ] || away=1
        \\ if [ -n "$away" ]; then echo away=1
        \\ else
        \\  if [ -d /proc/self/fd ]; then cwd=$(readlink "/proc/$fg/cwd" 2>/dev/null)
        \\  else cwd=$(lsof -a -p "$fg" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'); fi
        \\  if [ -n "$cwd" ]; then
        \\   echo "cwd=$cwd"
        \\   case $comm in bash|zsh|sh|dash|ksh|fish|tcsh|csh) echo idle=1;; esac
        \\   echo "git=$(cd "$cwd" 2>/dev/null && {{ git symbolic-ref --short -q HEAD || git rev-parse --short -q HEAD; }} 2>/dev/null)"
        \\  fi
        \\ fi
        \\fi
    , .{port});
}

/// One line per path: `d` folder, `f` file that may be opened (not
/// executable), `-` anything else.
pub fn checkScript(w: *std.Io.Writer, paths: []const []const u8) !void {
    try w.writeAll("for p in");
    for (paths) |p| {
        try w.writeByte(' ');
        try remotePath(w, p);
    }
    try w.writeAll(
        \\; do if [ -d "$p" ]; then echo d; elif [ -f "$p" ] && [ ! -x "$p" ]; then echo f; else echo -; fi; done
    );
}

/// The remote command that sends a file: its size in bytes on the first
/// line, then its bytes.
pub fn fetchCommand(w: *std.Io.Writer, path: []const u8) !void {
    try w.writeAll("p=");
    try remotePath(w, path);
    try w.writeAll("; wc -c < \"$p\" && exec cat -- \"$p\"");
}

test "ssh / mosh sessions and their destination" {
    const t = std.testing;
    try t.expectEqualStrings("host", sessionOfLine("ssh host").?.dest);
    try t.expectEqualStrings("me@host", sessionOfLine("/usr/bin/ssh -p 2222 -i ~/.ssh/k me@host ls").?.dest);
    try t.expectEqualStrings("box", sessionOfLine("ssh -vp22 -A box").?.dest);
    try t.expectEqualStrings("box", sessionOfLine("ssh -o ProxyJump=x -J jump box").?.dest);
    try t.expectEqualStrings("box", sessionOfLine("ssh -- box").?.dest);
    try t.expect(sessionOfLine("ssh -v") == null);
    try t.expect(sessionOfLine("sshd -D") == null);
    try t.expect(sessionOfLine("zsh") == null);
    try t.expectEqualStrings("me@box", sessionOfLine("mosh --ssh=\"ssh -A\" me@box").?.dest);
    try t.expectEqualStrings("me@box", sessionOfLine("mosh -p 60001 me@box").?.dest);
    try t.expectEqualStrings("me@box", sessionOfNul("mosh-client\x00-#\x00me@box\x00|\x001.2.3.4\x0060001\x00").?.dest);
    try t.expectEqualStrings("host", sessionOfNul("ssh\x00host\x00").?.dest);
}

test "gtty's connection copies the user's options" {
    const t = std.testing;
    var out: [64][]const u8 = undefined;
    const user = [_][]const u8{ "ssh", "-p", "2222", "-i", "k", "-L", "8080:x:80", "me@box", "tail", "-f", "log" };
    const a = linkArgv(&user, "sh", &out).?;
    try t.expectEqualStrings("ssh", a[0]);
    try t.expectEqualStrings("2222", a[2]); // the user's options, as given
    try t.expectEqualStrings("8080:x:80", a[6]); // cleared by ClearAllForwardings
    try t.expectEqualStrings("BatchMode=yes", a[8]);
    try t.expectEqualStrings("me@box", a[a.len - 2]);
    try t.expectEqualStrings("sh", a[a.len - 1]); // not the user's `tail -f log`
}

test "quoting and scripts" {
    const t = std.testing;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try shQuote(&w, "it's");
    try t.expectEqualStrings("'it'\\''s'", w.buffered());
    w = .fixed(&buf);
    try checkScript(&w, &.{ "~/a b", "/x" });
    try t.expect(std.mem.startsWith(u8, w.buffered(), "for p in \"$HOME\"/'a b' '/x'; do"));
    w = .fixed(&buf);
    try infoScript(&w, 52044);
    try t.expect(std.mem.startsWith(u8, w.buffered(), "p=52044;"));
    try t.expect(std.mem.indexOf(u8, w.buffered(), "pid=${l%%:*}") != null);
}
