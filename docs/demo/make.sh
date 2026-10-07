#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# Re-records the README animations (docs/images/<name>.webp).
#
#   docs/demo/make.sh            all of them
#   docs/demo/make.sh copy files only these (docs/demo/<name>.gt)
#
# Each docs/demo/<name>.gt is a gtty script (`gtty --script`) that records
# its frames with `/record start @FRAMES@` … `/record stop`; @FRAMES@ and
# @ROOT@ (the demo world, see setup.sh) are filled in here. Frames are
# PPM files plus frames.txt (each frame's time); identical frames are
# merged, the last one is held 1.5 s, and img2webp (libwebp:
# `brew install webp`, `apt install webp`) makes the looping WebP.
#
# Needs a built gtty (`zig build`; or GTTY=path) and a display: the window
# opens on screen while it records. Keep the mouse off it.
set -eu
cd "$(dirname "$0")/../.."
REPO=$PWD
GTTY=${GTTY:-$REPO/zig-out/bin/gtty}
ROOT=${GTTY_DEMO_ROOT:-/tmp/gtty-demo}
OUT=$REPO/docs/images
WORK=${TMPDIR:-/tmp}/gtty-demo-frames
QUALITY=${GTTY_DEMO_QUALITY:-80}
HOLD_MS=1500

command -v img2webp >/dev/null || { echo "make.sh: needs img2webp (libwebp)"; exit 1; }
[ -x "$GTTY" ] || { echo "make.sh: no $GTTY (run zig build)"; exit 1; }

# frames dir → out.webp
encode() {
    dir=$1 out=$2
    args=$dir/img2webp.args
    printf -- '-loop 0\n-lossy\n-q %s\n-m 4\n' "$QUALITY" > "$args"
    prev= prev_t= n=0
    # One line per kept frame: "-d <ms> <file>"; a frame equal to the one
    # before only adds its time to it.
    while read -r f t; do
        if [ -n "$prev" ] && cmp -s "$dir/$prev" "$dir/$f"; then continue; fi
        [ -n "$prev" ] && printf -- '-d %s\n%s\n' "$((t - prev_t))" "$dir/$prev" >> "$args"
        prev=$f prev_t=$t n=$((n + 1))
    done < "$dir/frames.txt"
    [ -n "$prev" ] || { echo "make.sh: no frames in $dir"; return 1; }
    printf -- '-d %s\n%s\n-o\n%s\n' "$HOLD_MS" "$dir/$prev" "$out" >> "$args"
    img2webp "$args" >/dev/null
    echo "$(basename "$out"): $n frames, $(du -k "$out" | cut -f1) KB"
}

names=${*:-$(cd docs/demo && ls *.gt | sed 's/\.gt$//')}
mkdir -p "$OUT"
for name in $names; do
    script=docs/demo/$name.gt
    [ -f "$script" ] || { echo "make.sh: no $script"; exit 1; }
    GTTY_DEMO_ROOT=$ROOT docs/demo/setup.sh
    rm -rf "$WORK/$name"
    mkdir -p "$WORK/$name"
    sed -e "s#@FRAMES@#$WORK/$name#g" -e "s#@ROOT@#$ROOT#g" "$script" > "$WORK/$name.gt"
    # A neutral world: the demo's own home and zsh config, the
    # project as gtty's folder; open / drag only say what they'd do.
    (cd "$ROOT/shop" && env HOME="$ROOT/home" ZDOTDIR="$ROOT/home" SHELL=/bin/zsh \
        GIT_PAGER=cat PAGER=cat GTTY_FONT_SIZE=16 GTTY_ANIM_MS=260 GTTY_SHOW_DRY=1 GTTY_DRAG_DRY=1 \
        "$GTTY" --script "$WORK/$name.gt")
    encode "$WORK/$name" "$OUT/$name.webp"
done
