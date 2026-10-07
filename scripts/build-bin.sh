#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# Build self-contained release binaries into bin/macos/gtty and
# bin/linux/gtty (from macOS or Linux; Zig cross-compiles).
#
# SDL3, SDL3_ttf and freetype are compiled from source and linked in
# (-Dbundled-sdl), so nothing needs installing on the machine that runs them:
# - macOS: Apple system frameworks only (arm64; MACOS_TARGET to change).
# - Linux: glibc 2.31+ only (x86_64; LINUX_TARGET to change). SDL picks up
#   X11 / Wayland, GL / Vulkan and audio from the desktop at run time.
set -eu
cd "$(dirname "$0")/.."

MACOS_TARGET=${MACOS_TARGET:-aarch64-macos.13.0}
MACOS_SDK=${MACOS_SDK:-$(xcrun --show-sdk-path 2>/dev/null || true)}
LINUX_TARGET=${LINUX_TARGET:-x86_64-linux-gnu.2.31}
WORK=.zig-cache/bin
mkdir -p bin/macos bin/linux

build() { # build <target> <out folder> [zig build options]
    echo "== $1"
    t=$1 out=$2; shift 2
    zig build -Dbundled-sdl -Dstrip -Doptimize=ReleaseSafe -Dtarget="$t" --prefix "$WORK/$out" "$@"
    cp "$WORK/$out/bin/gtty" "bin/$out/gtty"
}
[ -n "$MACOS_SDK" ] || { echo "macOS SDK not found: install Xcode command line tools or set MACOS_SDK" >&2; exit 1; }
build "$MACOS_TARGET" macos -Dmacos-sdk="$MACOS_SDK"
build "$LINUX_TARGET" linux

file bin/macos/gtty bin/linux/gtty

# Distribution folder (Google Drive), when it exists on this machine.
DIST=${GTTY_DIST:-"$HOME/Library/CloudStorage/GoogleDrive-feralkeep.studios@gmail.com/My Drive/GTTY/bin"}
if [ -d "$DIST" ]; then
    cp -R bin/ "$DIST/"
    echo "copied to $DIST"
fi
