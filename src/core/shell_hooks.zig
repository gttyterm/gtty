// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Shell integration: small hooks gtty adds to the user's zsh or bash so a
//! shell window knows where each command's output starts and ends.
//!
//! The hooks print the standard OSC 133 marks (as iTerm2, VS Code, kitty):
//! `ESC ] 133 ; C BEL` just before a command runs (its output follows) and
//! `ESC ] 133 ; D ; <exit code> BEL` when it is done, before the next prompt,
//! followed by `ESC ] 7 ; file://<host><folder> BEL` (the folder the shell
//! is in; `%` written as `%25`): the window's folder history. The prompt
//! ends with `ESC ] 133 ; B BEL` (added to PS1 after the user's config set
//! it): what follows is typed (the green left-edge mark).
//! Screen records where they fall in the output; copy on a running shell
//! then takes only the last command's output.
//!
//! The user's own startup files are still loaded, unchanged:
//!   * zsh: ZDOTDIR points at gtty's folder. Its `.zshenv` sources the
//!     user's (with their ZDOTDIR); its `.zprofile`, `.zshrc`, `.zlogin`
//!     source the user's files of those names, then add the hooks, so a
//!     config that resets `preexec_functions` / `precmd_functions` can't
//!     drop them. The user's ZDOTDIR is back once startup is done.
//!   * bash: `--rcfile` runs gtty's file, which sources what bash itself
//!     would (the login files, or `~/.bashrc`) and then adds the hooks:
//!     through bash-preexec when the config loaded it (atuin, starship),
//!     else a DEBUG trap (chained after one the config set) and
//!     PROMPT_COMMAND.
//! Other shells (fish, sh) and other programs run as before, unmarked.
//!
//! The hooks also bind the keys gtty sends for word jumps in the input
//! line — Ctrl or ⌥ + ←/→ (xterm's `ESC [1;5D`, `ESC [1;3D`, …) — and
//! Home / End, in the emacs and vi-insert keymaps. They are bound before
//! the user's own config loads, so the user's bindings win. A paste is
//! not highlighted (zsh `zle_highlight`, bash `enable-active-region`),
//! also overridable by the user's config.
//!
//! `gtty-ai N 'request'` runs the AI's script N (`ai-N.sh` in gtty's temp
//! folder) in a subshell: gtty types that line for the user's request at
//! the prompt, so the shell's own line shows what was asked.

const std = @import("std");
const c = @import("../c.zig").c;

const zshenv =
    \\# gtty shell integration (zsh). Load the user's .zshenv with their
    \\# ZDOTDIR; for an interactive shell keep ZDOTDIR on gtty's folder, so
    \\# zsh reads gtty's .zprofile / .zshrc / .zlogin next (they load the
    \\# user's own and add the hooks last).
    \\__gtty_dir=$ZDOTDIR
    \\if [[ -n "${GTTY_ZDOTDIR+x}" ]]; then
    \\  ZDOTDIR=$GTTY_ZDOTDIR
    \\  unset GTTY_ZDOTDIR
    \\else
    \\  unset ZDOTDIR
    \\fi
    \\[[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"
    \\if [[ -o interactive ]]; then
    \\  for __gtty_km in emacs viins; do
    \\    builtin bindkey -M $__gtty_km '\e[1;5D' backward-word
    \\    builtin bindkey -M $__gtty_km '\e[1;5C' forward-word
    \\    builtin bindkey -M $__gtty_km '\e[1;3D' backward-word
    \\    builtin bindkey -M $__gtty_km '\e[1;3C' forward-word
    \\    builtin bindkey -M $__gtty_km '\e[H' beginning-of-line
    \\    builtin bindkey -M $__gtty_km '\e[F' end-of-line
    \\  done
    \\  unset __gtty_km
    \\  # A paste shows as typed text, not highlighted (the user's .zshrc
    \\  # can still set zle_highlight).
    \\  zle_highlight=(paste:none)
    \\  __gtty_preexec() { builtin print -n '\e]133;C\a' }
    \\  __gtty_precmd() { builtin printf '\e]133;D;%s\a\e]7;file://%s%s\a' $? "$HOST" "${PWD//\%/%25}" }
    \\  # First in both lists (the D mark needs the command's $?), added
    \\  # after the user's startup files so a config that resets the lists
    \\  # can't drop them.
    \\  # The end of the prompt (OSC 133 B: what follows is typed), put on
    \\  # the prompt after everything else in precmd has set it.
    \\  __gtty_prompt_end() { [[ $PS1 == *$'\e]133;B\a'* ]] || PS1+=$'%{\e]133;B\a%}' }
    \\  __gtty_hooks() {
    \\    preexec_functions=(__gtty_preexec ${preexec_functions:#__gtty_preexec})
    \\    precmd_functions=(__gtty_precmd ${${precmd_functions:#__gtty_precmd}:#__gtty_prompt_end} __gtty_prompt_end)
    \\  }
    \\  # gtty's AI: run its script N in a subshell (`gtty-ai N 'request'`;
    \\  # the request words are only there to be read).
    \\  gtty-ai() { ( builtin . "@DIR@/ai-$1.sh" ) }
    \\  __gtty_zd=${ZDOTDIR-}
    \\  __gtty_zd_set=${ZDOTDIR+x}
    \\  ZDOTDIR=$__gtty_dir
    \\else
    \\  unset __gtty_dir
    \\fi
    \\
;

/// gtty's .zprofile / .zshrc / .zlogin: load the user's file of that name
/// with their ZDOTDIR (which it may change), then `after`.
fn zshWrap(comptime name: []const u8, comptime after: []const u8) []const u8 {
    return "# gtty shell integration (zsh): the user's " ++ name ++ ", then gtty's hooks.\n" ++
        "if [[ -n $__gtty_zd_set ]]; then ZDOTDIR=$__gtty_zd; else unset ZDOTDIR; fi\n" ++
        "[[ -f \"${ZDOTDIR:-$HOME}/" ++ name ++ "\" ]] && builtin source \"${ZDOTDIR:-$HOME}/" ++ name ++ "\"\n" ++
        "__gtty_zd=${ZDOTDIR-}\n" ++
        "__gtty_zd_set=${ZDOTDIR+x}\n" ++
        after;
}

/// Back to gtty's folder: zsh reads another of its files next.
const zsh_next = "ZDOTDIR=$__gtty_dir\n";
/// The last startup file: the user's ZDOTDIR stays.
const zsh_done = "unset __gtty_dir __gtty_zd __gtty_zd_set\n";

const zprofile = zshWrap(".zprofile", zsh_next);
const zshrc = zshWrap(".zshrc", "__gtty_hooks\nif [[ -o login ]]; then " ++ zsh_next ++ "else " ++ zsh_done ++ "fi\n");
const zlogin = zshWrap(".zlogin", "__gtty_hooks\n" ++ zsh_done);

const bashrc =
    \\# gtty shell integration (bash). Load what bash would load, then mark
    \\# each command's output (OSC 133 C / D). Word jumps and Home / End
    \\# first, so the user's own bindings win.
    \\for __gtty_km in emacs vi-insert; do
    \\  bind -m $__gtty_km '"\e[1;5D": backward-word'
    \\  bind -m $__gtty_km '"\e[1;5C": forward-word'
    \\  bind -m $__gtty_km '"\e[1;3D": backward-word'
    \\  bind -m $__gtty_km '"\e[1;3C": forward-word'
    \\  bind -m $__gtty_km '"\e[H": beginning-of-line'
    \\  bind -m $__gtty_km '"\e[F": end-of-line'
    \\done
    \\unset __gtty_km
    \\# A paste shows as typed text, not highlighted (bash 5.1+; the user's
    \\# own config can turn it back on).
    \\bind 'set enable-active-region off' 2>/dev/null
    \\if [ -n "$GTTY_BASH_LOGIN" ]; then
    \\  unset GTTY_BASH_LOGIN
    \\  [ -r /etc/profile ] && . /etc/profile
    \\  if [ -r ~/.bash_profile ]; then . ~/.bash_profile
    \\  elif [ -r ~/.bash_login ]; then . ~/.bash_login
    \\  elif [ -r ~/.profile ]; then . ~/.profile
    \\  fi
    \\else
    \\  [ -r ~/.bashrc ] && . ~/.bashrc
    \\fi
    \\__gtty_ready=
    \\__gtty_preexec() {
    \\  [ -n "$__gtty_ready" ] || return 0
    \\  [ -n "$COMP_LINE" ] && return 0
    \\  # Inside PROMPT_COMMAND (an empty line runs it again): not a command.
    \\  [ -n "$__gtty_in_prompt" ] && return 0
    \\  case "$BASH_COMMAND" in __gtty_status=*) return 0 ;; esac
    \\  __gtty_ready=
    \\  printf '\033]133;C\007'
    \\}
    \\__gtty_precmd() {
    \\  printf '\033]133;D;%s\007\033]7;file://%s%s\007' "$__gtty_status" "$HOSTNAME" "${PWD//\%/%25}"
    \\  __gtty_in_prompt=
    \\  __gtty_ready=1
    \\  __gtty_prompt_end
    \\}
    \\# The end of the prompt (OSC 133 B: what follows is typed).
    \\__gtty_prompt_end() {
    \\  case "$PS1" in *'133;B'*) ;; *) PS1="$PS1"'\[\033]133;B\007\]' ;; esac
    \\}
    \\# gtty's AI: run its script N in a subshell (`gtty-ai N 'request'`).
    \\gtty-ai() { ( builtin . "@DIR@/ai-$1.sh" ); }
    \\if [ -n "${bash_preexec_imported:-}${__bp_imported:-}" ]; then
    \\  # bash-preexec (atuin, starship, …) owns the DEBUG trap and
    \\  # PROMPT_COMMAND: hook in through it.
    \\  __gtty_bp_preexec() { printf '\033]133;C\007'; }
    \\  __gtty_bp_precmd() { printf '\033]133;D;%s\007\033]7;file://%s%s\007' "$?" "$HOSTNAME" "${PWD//\%/%25}"; }
    \\  precmd_functions=(__gtty_bp_precmd "${precmd_functions[@]}" __gtty_prompt_end)
    \\  preexec_functions+=(__gtty_bp_preexec)
    \\else
    \\  # A DEBUG trap the user's config set keeps running, first (it may
    \\  # read $_).
    \\  __gtty_prior=$(trap -p DEBUG)
    \\  if [ -n "$__gtty_prior" ]; then
    \\    eval "__gtty_prior=( $__gtty_prior )"
    \\    trap -- "${__gtty_prior[2]}"$'\n''__gtty_preexec' DEBUG
    \\  else
    \\    trap '__gtty_preexec' DEBUG
    \\  fi
    \\  unset __gtty_prior
    \\  PROMPT_COMMAND=$'__gtty_status=$? __gtty_in_prompt=1\n'"${PROMPT_COMMAND}"$'\n__gtty_precmd'
    \\fi
    \\
;

/// Write the hook files into gtty's temp folder. False if that failed
/// (shells then start without hooks).
pub fn install(dir: []const u8) bool {
    return writeHooks(dir, ".zshenv", zshenv) and writeFile(dir, ".zprofile", zprofile) and
        writeFile(dir, ".zshrc", zshrc) and writeFile(dir, ".zlogin", zlogin) and
        writeHooks(dir, "bash-rc", bashrc);
}

/// A hook file with `@DIR@` replaced by gtty's temp folder.
fn writeHooks(dir: []const u8, name: []const u8, text: []const u8) bool {
    var buf: [16 * 1024]u8 = undefined;
    const n = std.mem.replacementSize(u8, text, "@DIR@", dir);
    if (n > buf.len) return false;
    _ = std.mem.replace(u8, text, "@DIR@", dir, buf[0..n]);
    return writeFile(dir, name, buf[0..n]);
}

fn writeFile(dir: []const u8, name: []const u8, text: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0) catch return false;
    const f = c.fopen(path.ptr, "wb") orelse return false;
    const n = c.fwrite(text.ptr, 1, text.len, f);
    return c.fclose(f) == 0 and n == text.len;
}

/// How to start a shell with the hooks: its argv and extra environment
/// ("NAME=value"). Allocated in `a`.
pub const Launch = struct {
    argv: []const []const u8,
    env: []const [:0]const u8 = &.{},
};

/// `prog` is the shell (path or name); `login` asks for a login shell.
/// Null for shells gtty has no hooks for.
pub fn launch(a: std.mem.Allocator, prog: []const u8, login: bool, dir: []const u8) !?Launch {
    const name = std.fs.path.basename(prog);
    if (std.mem.eql(u8, name, "zsh")) {
        var env: std.ArrayList([:0]const u8) = .empty;
        if (c.getenv("ZDOTDIR")) |z| try env.append(a, try std.fmt.allocPrintSentinel(a, "GTTY_ZDOTDIR={s}", .{std.mem.span(z)}, 0));
        try env.append(a, try std.fmt.allocPrintSentinel(a, "ZDOTDIR={s}", .{dir}, 0));
        const argv = try a.dupe([]const u8, if (login) &.{ prog, "-l" } else &.{prog});
        return .{ .argv = argv, .env = env.items };
    }
    if (std.mem.eql(u8, name, "bash")) {
        const rc = try std.fmt.allocPrint(a, "{s}/bash-rc", .{dir});
        const argv = try a.dupe([]const u8, &.{ prog, "--rcfile", rc, "-i" });
        const env = try a.dupe([:0]const u8, if (login) &.{"GTTY_BASH_LOGIN=1"} else &.{});
        return .{ .argv = argv, .env = env };
    }
    return null;
}
