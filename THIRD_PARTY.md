# Third-party components

gtty itself is GPL-3.0-or-later (see `LICENSE`). This is everything in
the repository or in a gtty binary that someone else wrote, with its
license and whether it can go with GPL-3.0.

## In the repository

| Component | Where | License | With GPL-3.0 |
|---|---|---|---|
| JetBrains Mono (font) | `src/assets/JetBrainsMono-Regular.ttf`, embedded in the binary (`@embedFile`) | SIL Open Font License 1.1 (`src/assets/JetBrainsMono-OFL.txt`) | **Check** (see note 1) |

The app icon (`src/assets/gtty-icon.png`, `src/assets/AppIcon.icns`)
is gtty's own: generated with Claude (Anthropic) for this project. It
is not third-party and goes with gtty under GPL-3.0-or-later.

## Built from source into the release binaries (`-Dbundled-sdl`)

Fetched by `build.zig.zon` (not in git; unpacked into `zig-pkg/`) and
linked statically by `scripts/build-bin.sh`. A plain `zig build` links the
system's SDL3 / SDL3_ttf instead.

| Component | Version | License | With GPL-3.0 |
|---|---|---|---|
| SDL3 (packaged for Zig by castholm/SDL) | 3.4.16 | Zlib; a few files also MIT, Apache-2.0, BSD-3-Clause, CC0 / Unlicense; `src/hidapi` is "GPL-3.0-only OR BSD-3-Clause OR HIDAPI" (gtty can take BSD-3-Clause) | Yes |
| castholm/SDL build scripts | b72b367 | MIT | Yes |
| sdl_linux_deps (Linux build headers: X11, Wayland, ALSA, PipeWire, DRM, fribidi, liburing, …; pulled in by castholm/SDL) | 0.0.0 | MIT, X11, ISC, HPND, AFL, LGPL-2.1-or-later, "(GPL-2.0-only WITH Linux-syscall-note) OR MIT" (per `REUSE.toml`) | Yes (headers only; the libraries are loaded at run time by SDL) |
| SDL3_ttf | 3.2.2 | Zlib | Yes |
| FreeType | 2.13.3 | FreeType License (FTL), or GPL-2.0-or-later | Yes (FTL is GPL-3.0-compatible) |
| libpng | 1.6.44 | PNG Reference Library License v2 | Yes |
| zlib | 1.3.1 | Zlib | Yes |

## Used at run time, not shipped

- System libraries and frameworks: libc, Cocoa / CoreServices /
  AudioToolbox (macOS), libwayland-client (Linux, opened with `dlopen`,
  MIT), SDL3 / SDL3_ttf from Homebrew or the distribution for a plain
  `zig build`.
- Fallback fonts for symbols and emoji (Menlo, Apple Symbols, Apple
  Color Emoji, DejaVu, Noto, …): opened from the system, not bundled.
- The user's shell, git, ssh, curl, `xdg-open`, `gio` / `gtk-launch`.
- bash-preexec: used if the user's bash config already loads it; not
  bundled.

## Data and protocols (no code copied)

- `src/core/wcwidth.zig`: tables generated from Unicode 16.0 data
  (Python's `unicodedata`). Unicode License v3: Yes.
- `src/core/color.zig`: xterm's 16 default colors (the RGB values only).
- `src/sys/gtty_drag.c`: Wayland request opcodes from `wayland.xml`
  (numbers only; MIT).
- OSC 7 / OSC 133 / xterm escape sequences: protocols, no code.

## Tools for building, packaging and demos (not shipped)

Zig, nfpm, Xcode command line tools, img2webp (libwebp, BSD-3-Clause),
`cc` for `test/fake-ssh/ssh.c` (gtty's own test stand-in).

## Flags

1. **JetBrains Mono, OFL-1.1.** The OFL is a free license, and the FSF
   says bundling an OFL font with GPL software is fine. The OFL is not
   GPL-compatible for *merging*, though. The font is embedded in the
   binary as data, so this is usually treated as an aggregate. Keep
   `JetBrainsMono-OFL.txt` with every binary and package (they all do
   today: `share/doc/gtty` on Linux, `Contents/Resources` in gtty.app). Don't sell or rename the font on its
   own. Worth a look, but not a blocker.
