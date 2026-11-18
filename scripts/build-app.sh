#!/bin/bash
# Assembles BoxingBuffalo.app by hand — no Xcode project, no xcodebuild.
# Writes into ./dist/BoxingBuffalo.app and ad-hoc signs it so Gatekeeper lets it run
# locally.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/BoxingBuffalo.app"
BIN="$ROOT/.build/$CONFIG/BoxingBuffalo"

echo "==> 编译 ($CONFIG)"
cd "$ROOT"
swift build --disable-sandbox -c "$CONFIG"

echo "==> 组装 app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BoxingBuffalo"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY='<key>CFBundleIconFile</key><string>AppIcon</string>'
else
    ICON_KEY=''
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BoxingBuffalo</string>
    <key>CFBundleDisplayName</key><string>BoxingBuffalo</string>
    <key>CFBundleExecutable</key><string>BoxingBuffalo</string>
    <key>CFBundleIdentifier</key><string>com.xurenfei.boxingbuffalo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>NSHumanReadableCopyright</key><string>FATX parsing derived from CLKsFATXLib (GPL-3.0)</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>FATX 镜像</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.data</string>
                <string>public.disk-image</string>
            </array>
        </dict>
    </array>
    ${ICON_KEY}
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 签名"
# An ad-hoc signature changes its cdhash on every rebuild, which invalidates
# the TCC "Removable Volumes" grant and makes macOS prompt again at launch.
# A real development certificate gives the app a stable designated requirement
# (bundle id + team + Apple anchor), so the grant survives future rebuilds.
# Override with BOXINGBUFFALO_SIGN_IDENTITY if a different identity is preferred.
SIGN_IDENTITY="${BOXINGBUFFALO_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/Apple Development:/ {print $2; exit}' || true)"
fi
if [ -n "$SIGN_IDENTITY" ] && \
   codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1; then
    echo "    已用开发证书签名：${SIGN_IDENTITY}"
else
    codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
        echo "    (签名失败，仍可运行)"
    echo "    开发证书不可用，退回 ad-hoc（重签名后 TCC 授权需重新点允许）"
fi

echo "==> 完成：$APP"
du -sh "$APP" | awk '{print "    体积 "$1}'
