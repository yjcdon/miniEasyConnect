#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$PROJECT_ROOT/.build"
APP="$PROJECT_ROOT/dist/miniEasyConnect.app"
HELPERS="$APP/Contents/Helpers"
APP_ID=io.github.yjcdon.miniEasyConnect
SIGN_ID=${MINIEASY_SIGN_ID:-}
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:|Developer ID Application:/{print $2; exit}')
fi
if [ -z "$SIGN_ID" ]; then
    echo '需要 Apple 代码签名身份以验证辅助服务，请设置 MINIEASY_SIGN_ID。' >&2
    exit 1
fi
mkdir -p "$BUILD_DIR" "$HELPERS" "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Resources"
"$PROJECT_ROOT/Scripts/build-icon.sh"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

(cd "$PROJECT_ROOT/Core/upstream" && GOTOOLCHAIN=go1.27.3 GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 go build -trimpath -ldflags='-s -w' -o "$HELPERS/minieasyconnect-core" ./cmd/minieasyconnect-core)

swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx13.0 \
    "$PROJECT_ROOT"/Sources/Shared/*.swift "$PROJECT_ROOT"/Sources/Helper/*.swift \
    -o "$HELPERS/miniEasyConnectHelper"

codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" --identifier "$APP_ID.helper" "$HELPERS/miniEasyConnectHelper"
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" --identifier "$APP_ID.core" "$HELPERS/minieasyconnect-core"
TEAM_ID=$(codesign -dv --verbose=4 "$HELPERS/miniEasyConnectHelper" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = not\ set ]; then
    echo '无法确定签名团队。' >&2
    exit 1
fi

swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx13.0 \
    "$PROJECT_ROOT"/Sources/Shared/*.swift "$PROJECT_ROOT"/Sources/App/*.swift \
    -o "$APP/Contents/MacOS/miniEasyConnect"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$APP_ID</string>
<key>CFBundleName</key><string>miniEasyConnect</string>
<key>CFBundleDisplayName</key><string>miniEasyConnect</string>
<key>CFBundleExecutable</key><string>miniEasyConnect</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>SigningTeamIdentifier</key><string>$TEAM_ID</string>
</dict></plist>
EOF
cat > "$APP/Contents/Library/LaunchDaemons/$APP_ID.helper.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$APP_ID.helper</string>
<key>BundleProgram</key><string>Contents/Helpers/miniEasyConnectHelper</string>
<key>MachServices</key><dict><key>$APP_ID.helper</key><true/></dict>
</dict></plist>
EOF
cp "$PROJECT_ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$PROJECT_ROOT/Resources/ThirdParty/Tabler-LICENSE" "$APP/Contents/Resources/Tabler-LICENSE"
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
