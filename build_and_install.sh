#!/bin/bash
# FlClashAppRouter 构建 + 自动安装到 /Applications
# 用法：bash build_and_install.sh
set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJ"

APP_NAME="FlClashAppRouter"
APP_BUNDLE="$PROJ/$APP_NAME.app"
BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> 编译 (swiftc, 绕过 SwiftPM 沙箱; 双架构通用二进制)"
swiftc -O \
  Sources/AppRouterModel.swift \
  Sources/ContentView.swift \
  Sources/FlClashAppRouterApp.swift \
  -o "$APP_NAME.arm64" \
  -framework SwiftUI -framework AppKit -framework Foundation -framework CoreServices \
  -target arm64-apple-macosx14.0
swiftc -O \
  Sources/AppRouterModel.swift \
  Sources/ContentView.swift \
  Sources/FlClashAppRouterApp.swift \
  -o "$APP_NAME.x86_64" \
  -framework SwiftUI -framework AppKit -framework Foundation -framework CoreServices \
  -target x86_64-apple-macosx14.0
lipo -create "$APP_NAME.arm64" "$APP_NAME.x86_64" -output "$APP_NAME"
lipo -info "$APP_NAME"

echo "==> 组装 .app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$APP_NAME" "$BIN"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
# 应用图标（Info.plist 里 CFBundleIconFile=AppIcon）
[ -f Assets/AppIcon.icns ] && cp Assets/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
chmod +x "$BIN"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> 安装到 /Applications（需要管理员密码授权）"
osascript -e "do shell script \"rm -rf /Applications/$APP_NAME.app && cp -R '$APP_BUNDLE' /Applications/$APP_NAME.app && xattr -dr com.apple.quarantine /Applications/$APP_NAME.app && codesign --force --deep --sign - /Applications/$APP_NAME.app\" with administrator privileges"

echo "==> 完成：/Applications/$APP_NAME.app 已更新"
