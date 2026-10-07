#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# Installable packages from the self-contained binaries of build-bin.sh
# (SDL3, SDL3_ttf, freetype linked in), into dist/:
# - gtty-<v>-macos.dmg        gtty.app (icon src/assets/AppIcon.icns), arm64, macOS 13+
# - gtty_<v>_amd64.deb        Ubuntu / Debian      } /usr/bin/gtty, a launcher and
# - gtty-<v>-1.x86_64.rpm     Fedora               } icons (src/assets/gtty-icon.png)
# - gtty-<v>-linux-x86_64.tar.gz  the same files, for any other distro
# The version is the one in build.zig.zon. Needs nfpm (brew install nfpm).
#
# Signing (macOS), optional:
#   GTTY_SIGN_ID="Developer ID Application: Name (TEAMID)"  sign the app + dmg
#   GTTY_NOTARY_PROFILE=name   notarize + staple with a notarytool keychain
#     profile (scripts/sign-macos.sh sets both and checks them first), or
#   GTTY_NOTARY_KEY=AuthKey_X.p8 GTTY_NOTARY_KEY_ID=X GTTY_NOTARY_ISSUER=…
#     the same with an App Store Connect API key (CI)
# Without GTTY_SIGN_ID the app is signed ad hoc: it runs here, but a new Mac
# says it can't verify it (right click → Open, or xattr -dr com.apple.quarantine).
#
# SKIP_BUILD=1 packages the binaries already in bin/.
set -eu
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon | head -1)
[ -n "$VERSION" ] || { echo "no version in build.zig.zon" >&2; exit 1; }
command -v nfpm >/dev/null || { echo "nfpm not found: brew install nfpm" >&2; exit 1; }

[ "${SKIP_BUILD:-}" = 1 ] || scripts/build-bin.sh
for f in bin/macos/gtty bin/linux/gtty; do
    [ -x "$f" ] || { echo "$f missing: run scripts/build-bin.sh" >&2; exit 1; }
done

STAGE=.zig-cache/package
rm -rf "$STAGE" && mkdir -p "$STAGE" dist

# ---- macOS: gtty.app in a dmg ---------------------------------------------
echo "== macOS app"
APP="$STAGE/dmg/gtty.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp bin/macos/gtty "$APP/Contents/MacOS/gtty"
cp src/assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp src/assets/JetBrainsMono-OFL.txt LICENSE THIRD_PARTY.md "$APP/Contents/Resources/"
sed "s/@VERSION@/$VERSION/g" packaging/macos/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint -s "$APP/Contents/Info.plist"

if [ -n "${GTTY_SIGN_ID:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$GTTY_SIGN_ID" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

# The usual dmg: a window with gtty, an arrow and Applications to drag it
# to. Finder lays it out on a writable copy, then it is compressed.
ln -s /Applications "$STAGE/dmg/Applications"
mkdir "$STAGE/dmg/.background"
cp packaging/macos/dmg-background.tiff "$STAGE/dmg/.background/background.tiff"
cp src/assets/AppIcon.icns "$STAGE/dmg/.VolumeIcon.icns"
VOL="gtty $VERSION"
RW="$STAGE/rw.dmg"
hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE/dmg" -fs HFS+ -format UDRW -size 40m "$RW"
# Mounted where Finder sees it (/Volumes/<name>), as it will be for users.
MNT=$(hdiutil attach -noautoopen "$RW" | sed -n 's|^/dev/[^[:space:]]*[[:space:]]*Apple_HFS[[:space:]]*||p')
[ -d "$MNT" ] || { echo "dmg did not mount" >&2; exit 1; }
SetFile -a C "$MNT"   # use .VolumeIcon.icns
if ! osascript <<EOF
tell application "Finder"
    set d to disk "$VOL"
    open d
    set w to container window of d
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set bounds of w to {200, 120, 800, 548}
    set o to icon view options of w
    set arrangement of o to not arranged
    set icon size of o to 128
    set text size of o to 13
    set background picture of o to file ".background:background.tiff" of d
    set position of item "gtty.app" of d to {150, 190}
    set position of item "Applications" of d to {450, 190}
    close w
    open d
    delay 1
    close container window of d
end tell
EOF
then
    echo "warning: Finder layout failed (allow Terminal to control Finder in System Settings → Privacy → Automation); the dmg works, unarranged" >&2
fi
rm -rf "$MNT/.fseventsd" "$MNT/.Trashes"
sync
hdiutil detach -quiet "$MNT" || { sleep 2; hdiutil detach -quiet -force "$MNT"; }
DMG="dist/gtty-$VERSION-macos.dmg"
rm -f "$DMG"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
if [ -n "${GTTY_SIGN_ID:-}" ]; then
    codesign --force --timestamp --sign "$GTTY_SIGN_ID" "$DMG"
    if [ -n "${GTTY_NOTARY_KEY:-}" ]; then
        echo "== notarizing (a few minutes)"
        xcrun notarytool submit "$DMG" --key "$GTTY_NOTARY_KEY" \
            --key-id "$GTTY_NOTARY_KEY_ID" --issuer "$GTTY_NOTARY_ISSUER" --wait
        xcrun stapler staple "$DMG"
    elif [ -n "${GTTY_NOTARY_PROFILE:-}" ]; then
        echo "== notarizing (a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$GTTY_NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

# ---- Linux: deb, rpm, tar.gz ----------------------------------------------
echo "== Linux packages"
LROOT="$STAGE/linux"
mkdir -p "$LROOT"
cp bin/linux/gtty "$LROOT/gtty"
for n in 16 24 32 48 64 128 256 512; do
    d="$LROOT/icons/${n}x${n}/apps"
    mkdir -p "$d"
    sips -s format png -z "$n" "$n" src/assets/gtty-icon.png --out "$d/gtty.png" >/dev/null
done

export VERSION ARCH=amd64 # files: $LROOT (path fixed in nfpm.yaml)
nfpm package --config packaging/linux/nfpm.yaml --packager deb --target dist/
nfpm package --config packaging/linux/nfpm.yaml --packager rpm --target dist/

# Same layout as the packages, under a prefix: install.sh copies it to
# /usr/local (or PREFIX).
T="$STAGE/gtty-$VERSION-linux-x86_64"
mkdir -p "$T/bin" "$T/share/applications" "$T/share/icons" "$T/share/doc/gtty"
cp "$LROOT/gtty" "$T/bin/"
cp packaging/linux/gtty.desktop "$T/share/applications/"
cp -R "$LROOT/icons" "$T/share/icons/hicolor"
install -m 644 src/assets/JetBrainsMono-OFL.txt LICENSE THIRD_PARTY.md "$T/share/doc/gtty/"
cat > "$T/install.sh" <<'EOF'
#!/bin/sh
# Copy gtty to $PREFIX (default /usr/local; ~/.local for just you).
set -eu
PREFIX=${PREFIX:-/usr/local}
cd "$(dirname "$0")"
mkdir -p "$PREFIX"
cp -R bin share "$PREFIX/"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$PREFIX/share/applications" || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f "$PREFIX/share/icons/hicolor" || true
echo "gtty installed in $PREFIX/bin"
EOF
chmod +x "$T/install.sh"
tar -C "$STAGE" -czf "dist/gtty-$VERSION-linux-x86_64.tar.gz" "gtty-$VERSION-linux-x86_64"

ls -l dist/

# Distribution folder (Google Drive), next to build-bin.sh's GTTY/bin.
GTTY_DIR="$HOME/Library/CloudStorage/GoogleDrive-feralkeep.studios@gmail.com/My Drive/GTTY"
PKG_DIST=${GTTY_PKG_DIST:-"$GTTY_DIR/packages"}
if [ -d "$(dirname "$PKG_DIST")" ]; then
    mkdir -p "$PKG_DIST"
    for f in "dist/gtty-$VERSION-macos.dmg" "dist/gtty_${VERSION}_amd64.deb" \
             "dist/gtty-$VERSION-1.x86_64.rpm" "dist/gtty-$VERSION-linux-x86_64.tar.gz"; do
        cp "$f" "$PKG_DIST/"
    done
    echo "copied to $PKG_DIST"
fi
