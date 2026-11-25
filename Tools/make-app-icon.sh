#!/bin/zsh
# Regenerates the app icon from Resources/AppIcon.svg (macOS only).
# Requires librsvg: brew install librsvg
set -euo pipefail
project_dir="${0:A:h:h}"
res="$project_dir/Resources"
iconset="$res/AppIcon.iconset"
command -v rsvg-convert >/dev/null || { print -u2 "rsvg-convert not found (brew install librsvg)"; exit 1; }
rsvg-convert -w 2048 -h 2048 "$res/AppIcon.svg" -o "$res/AppIcon.png"
rm -rf "$iconset" && mkdir -p "$iconset"
for base in 16 32 128 256 512; do
  rsvg-convert -w $base -h $base "$res/AppIcon.svg" -o "$iconset/icon_${base}x${base}.png"
  rsvg-convert -w $((base * 2)) -h $((base * 2)) "$res/AppIcon.svg" -o "$iconset/icon_${base}x${base}@2x.png"
done
iconutil -c icns "$iconset" -o "$res/AppIcon.icns"
print "Updated AppIcon.png, AppIcon.iconset and AppIcon.icns"
