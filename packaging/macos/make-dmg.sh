#!/bin/sh
# make-dmg.sh - build RimeTtsReadback.app and a DMG from the compiled binaries.
#
#   ./make-dmg.sh <version> <bin-dir> <out-dir>
#
# <bin-dir> is the output of macos/build.sh (rime-tts-menubar,
# rime-tts-watcher).  The app bundle keeps the watcher and rime.lua next to the
# menubar executable, which is exactly where RimeTtsMenuBar.swift looks for
# them, so the installed .app is self-contained.
set -eu

version=${1:?usage: make-dmg.sh <version> <bin-dir> <out-dir>}
bin_dir=${2:?usage: make-dmg.sh <version> <bin-dir> <out-dir>}
out_dir=${3:?usage: make-dmg.sh <version> <bin-dir> <out-dir>}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

for f in rime-tts-menubar rime-tts-watcher; do
    [ -x "$bin_dir/$f" ] || {
        echo "missing binary: $bin_dir/$f" >&2
        exit 1
    }
done

# CFBundleVersion must look like a version number; a dev-<sha> build still
# needs a valid value.
bundle_version=$(printf '%s' "$version" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')
[ -n "$bundle_version" ] || bundle_version="1.0.0"

work=$(mktemp -d "${TMPDIR:-/tmp}/rime-tts-dmg.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

app="$work/RimeTtsReadback.app"
macos_dir="$app/Contents/MacOS"
res_dir="$app/Contents/Resources"
mkdir -p "$macos_dir" "$res_dir"

cp "$bin_dir/rime-tts-menubar" "$macos_dir/"
cp "$bin_dir/rime-tts-watcher" "$macos_dir/"
cp "$root/rime/rime.lua" "$macos_dir/rime.lua"
chmod +x "$macos_dir/rime-tts-menubar" "$macos_dir/rime-tts-watcher"

icon_line=""
if [ -f "$root/icons/rime-tts-readback.png" ] && command -v sips >/dev/null 2>&1 \
        && command -v iconutil >/dev/null 2>&1; then
    iconset="$work/AppIcon.iconset"
    mkdir -p "$iconset"
    src="$root/icons/rime-tts-readback.png"
    for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" \
                "64 icon_32x32@2x" "128 icon_128x128" "256 icon_128x128@2x" \
                "256 icon_256x256" "512 icon_256x256@2x" "512 icon_512x512" \
                "1024 icon_512x512@2x"; do
        size=${spec%% *}
        name=${spec#* }
        sips -z "$size" "$size" "$src" --out "$iconset/$name.png" >/dev/null
    done
    if iconutil -c icns "$iconset" -o "$res_dir/AppIcon.icns" >/dev/null 2>&1; then
        icon_line='    <key>CFBundleIconFile</key>'
        icon_line="$icon_line
    <string>AppIcon</string>"
    fi
fi

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Rime TTS Readback</string>
    <key>CFBundleExecutable</key>
    <string>rime-tts-menubar</string>
$icon_line
    <key>CFBundleIdentifier</key>
    <string>com.graychan.rime-tts-readback</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Rime TTS Readback</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$bundle_version</string>
    <key>CFBundleVersion</key>
    <string>$bundle_version</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$app/Contents/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$app" >/dev/null 2>&1 || \
        echo "warning: ad-hoc codesign failed; the app is unsigned" >&2
fi

stage="$work/dmg"
mkdir -p "$stage"
cp -a "$app" "$stage/"
ln -s /Applications "$stage/Applications"

cat > "$stage/README.txt" <<TXT
Rime TTS Readback $version

1. Drag RimeTtsReadback.app into Applications.
2. Open it from Applications. If macOS refuses to open it, right-click the app
   and choose Open once.
3. Click the menu bar icon, open the control panel and press Deploy.
4. Requires Squirrel (Rime for macOS). Audio uses the system voice.

This build is ad-hoc signed and not notarized. The app is a menu bar agent
(LSUIElement), so it has no Dock icon.
TXT

mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd)
out="$out_dir/rime-tts-readback-$version.dmg"

hdiutil create -quiet -volname "Rime TTS Readback" -srcfolder "$stage" \
    -format UDZO -ov "$out"
hdiutil verify -quiet "$out" >/dev/null

echo "built: $out"
