#!/bin/sh
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ICONSET="$PROJECT_ROOT/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -s format png "$PROJECT_ROOT/Resources/AppIcon.svg" --out "$PROJECT_ROOT/.build/AppIcon.png" >/dev/null
for SIZE in 16 32 128 256 512; do
    DOUBLE=$((SIZE * 2))
    sips -z "$SIZE" "$SIZE" "$PROJECT_ROOT/.build/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z "$DOUBLE" "$DOUBLE" "$PROJECT_ROOT/.build/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$PROJECT_ROOT/.build/AppIcon.icns"
