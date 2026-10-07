# Hacking on gtty

Building, testing and the source layout. The notes for coding agents
in `CLAUDE.md` go into more detail (every feature, test hooks,
conventions).

## Building

```sh
xcode-select --install                 # once: Command Line Tools (macOS)
brew install zig sdl3 sdl3_ttf         # Zig 0.16.0

cd gtty                                # your clone
zig build run                          # build + start gtty
```

The program is built to `zig-out/bin/gtty`. Linux: install SDL3 + SDL3_ttf
(from your distro or from source), then the same commands.

Release binaries (self-contained, SDL built from source):
`scripts/build-bin.sh`; packages (dmg, deb, rpm, tarball):
`scripts/package.sh` (needs nfpm). Signed + notarized:
`scripts/sign-macos.sh` (checks the signing setup first; the signing
files stay outside the repo, in `$GTTY_SIGNING_DIR`, default `~/tmp`).
`scripts/set-github-secrets.sh` loads them into the GitHub environment
`release` for CI. Details in CLAUDE.md ("Signed releases").

CI (`.github/workflows/ci.yml`) builds and runs the unit tests on Linux
and macOS for every push and pull request. A release is a tag:
`git tag v<version> && git push origin v<version>` (the version in
`build.zig.zon`); `.github/workflows/release.yml` builds, signs,
notarizes and publishes the packages as a GitHub release.

Not yet: full-screen programs (vim, htop, less), bold/italic, and scrolling back past the memory window. New commands from the
prompt still start in gtty's own folder (a shell window's `cd` doesn't carry
over to them).

## Development

```sh
zig build test                            # unit tests
zig build run -- --script test/smoke.gt   # scripted smoke test
```

Script mode (`gtty --script file`) types each line into the prompt. Test
hooks (slash only): `/wait <ms>`, `/shot <file.bmp>`, `/type <text>` (text +
Enter), `/text <text>` (no Enter), `/key <keys>` (e.g. `cmd+v`,
`ctrl+shift+left`), `/click <x> <y>`, `/rclick <x> <y>`, `/dclick <x> <y>`,
`/down <x> <y>`, `/up <x> <y>`, `/move <x> <y>`, `/drag <x1> <y1> <x2> <y2>`, `/resize <w> <h>`, `/mods cmd+shift | none`
(modifier keys held), `/menu run | settings | copy |
paste | select-all | new-shell | new-window | sync-typing | about` (a menu pick), `/target main | settings` (which OS window the
next clicks, keys and shots go to), `/quit`. For demos: `/record start
<dir> [fps]` … `/record stop` (frames + their times, with a drawn mouse
pointer), `/slow <text>` (typed one character at a time), `/glide <x> <y>
[ms]` (a smooth mouse move), `/pace <ms>` (gap between lines, default
400), `/dropover <x> <y>` and `/drop <x> <y> <path>` (files from another
app dragged over / dropped on gtty). A script starts with no shell
window unless `-c` is given, and reads no settings file unless
`GTTY_CONFIG` names one. `GTTY_MENU_BAR=1` shows Linux's drawn menu bar on
macOS. `GTTY_AI_REPLY=<file>` turns the AI on without a provider: the
file's text is its answer (`test/ai.gt`); `GTTY_AI_MEMORY=<file>` puts the
AI memory there (a script keeps none otherwise).

**README animations** (`docs/images/*.webp`): `docs/demo/make.sh`
re-records all of them (or `make.sh copy files` for some), one gtty
script per animation in `docs/demo/<name>.gt`, in a neutral demo world
built by `docs/demo/setup.sh`. Needs img2webp (libwebp) and a display;
keep the mouse off the window while it records, and note that the demos
use the clipboard.

**Reporting a key or paste problem:** start gtty with
`GTTY_TRACE=/tmp/gtty-trace.log gtty`. The file records every key, window
event, terminal resize and the bytes sent to each job, with times. Send
it together with the job's output log (`$TMPDIR/gtty-<pid>/job-<N>.log`,
kept while the window is open).

The UX concept and terminology live in the gtty design doc (see CLAUDE.md).

**File opener** (part of every job window, `ui/FileOpener.zig`, the
window's `opener`): App tells the window under the mouse where the mouse
is; the window finds a file name there
(positions are line + column, with wrapped rows joined), outlines it and
draws the outline itself. A double-click opens the file with `show`
(Shift: `show -a`) or `cd`s the shell to a folder; a long press + move
drags it out (`sys/gtty_drag.m`: NSDraggingSession; `gtty_drag.c`:
Wayland `wl_data_device`, libwayland-client via dlopen); files dropped
on gtty are copied in (`sys/gtty_copy.c`); in ssh sessions the
names are checked over the window's own connection to the remote machine
(`core/RemoteLink.zig`). When the window's text changes, the outline goes.
Its help line shows under the prompt.

```
src/
  main.zig            entry point, CLI flags
  App.zig             OS window, window system (current job + job grid),
                      input, command resolution
  ui/JobWindow.zig    job window object: owns its process + PTY, draws itself,
                      handles resize / zoom / HiDPI and tells the PTY the new size
  ui/Prompt.zig       2-line command area
  ui/StatusBar.zig    status bar (short notices)
  ui/Peek.zig         a chip's peek / expanded peek (git branches: filter, switch)
  ui/Menu.zig         pop-up menus: right-click (Copy / Paste), app picker,
                      the menus of the drawn menu bar (Linux)
  ui/SettingsWindow.zig the settings window (an OS window of its own, tabs)
  ui/FileOpener.zig   a job window's file opener (hover outline, double-click opens, drag out)
  sys/gtty_drag.m     drag a file out (macOS; gtty_drag.c: Linux drag helper)
  ui/file_path.zig    finding a file name around a column of a line
  core/remote.zig     ssh / mosh sessions: detection, gtty's connection
                      options, remote scripts (pure, unit-tested)
  core/RemoteLink.zig gtty's own connection to the remote machine; Fetch
  core/Config.zig     settings file (~/.config/gtty/config): load, save
  sys/gtty_menu.m     gtty / Edit in the macOS menu bar (gtty_menu.c: none)
  ui/tiling.zig       how many windows fit in the windows area, and where
  core/git.zig        current branch from .git/HEAD; git commands in the background
  ui/commands.zig     gtty command parser (`name`, `/name`)
  core/ShellNames.zig aliases/functions/builtins the user's shell knows (asked at startup)
  ui/ids.zig          unique window ids
  ui/beep.zig         error beep (sys/gtty_beep.c on macOS, SDL tone elsewhere)
  core/oscmd.zig      does the OS know a command? ($PATH, paths, shell builtins)
  sys/gtty_open.c     default app / app list / open-with (`show`)
  core/Process.zig    child process on a PTY
  core/Screen.zig     scrollback buffer + VT escape parser (colors, CR, erase…)
  core/Tee.zig        every job's full output in a temp file (copy-all)
  core/shell_hooks.zig zsh / bash hooks: output marks (OSC 133), word-jump keys
  core/wcwidth.zig    character widths (Unicode 16: wide, emoji, zero-width)
  core/trace.zig      GTTY_TRACE debug log (keys, resizes, bytes to jobs)
  ai/Ai.zig           AI requests (curl in the background), answers → plans,
                      the danger check
  ai/system_prompt.md what the AI is told (embedded scrambled; {{…}} filled
                      per request; not shown or changeable in the app)
  ai/Memory.zig       the AI's local memory (folders + file types, ssh, notes)
  core/color.zig      colors kept as sent, resolved at draw time, contrast fix
  render/Gfx.zig      SDL renderer helpers, glyph cache per pixel size,
                      fallback fonts for symbols and color emoji
  sys/gtty_pty.c      openpty/fork/exec (Linux <pty.h>, macOS <util.h>)
test/smoke.gt         scripted smoke test
test/paste.gt         paste + right-click menu test
test/show.gt          show + app picker test (GTTY_SHOW_DRY=1)
test/settings.gt      menus + settings window test (GTTY_CONFIG, GTTY_MENU_BAR)
test/fileopener.gt    file opener test (GTTY_SHOW_DRY=1)
test/remote.gt        ssh sessions with a stand-in ssh (test/fake-ssh/ssh.c)
test/remote-off.gt    can't connect / another hop: remote helpers off
```

Rendering goes through SDL3's renderer: Metal on macOS, OpenGL on Linux.
Font: JetBrains Mono (SIL Open Font License, see `src/assets`).
