#!/bin/bash
# FlClashAppRouter 一键安装脚本
# 双击本文件即可安装到「应用程序」并自动打开。
# 作用：清除 macOS Gatekeeper 隔离属性 + 重新签名 + 复制到 /Applications

set -e
cd "$(dirname "$0")"
SRC="$(pwd)/FlClashAppRouter.app"

echo "========================================"
echo "  FlClashAppRouter 安装程序"
echo "========================================"
echo ""

if [ ! -d "$SRC" ]; then
  echo "✗ 找不到 FlClashAppRouter.app，请确保 DMG 内容完整。"
  read -n 1 -s -r -p "按任意键关闭窗口..."
  exit 1
fi

# 清除下载隔离属性（从网络来的 DMG 会带 quarantine，导致双击被 Gatekeeper 拦）
xattr -dr com.apple.quarantine "$SRC" 2>/dev/null || true

echo "正在安装到「应用程序」文件夹…"
echo "（会弹出密码输入框，请输入你的 Mac 登录密码）"
echo ""

osascript <<APPLESCRIPT
do shell script "rm -rf '/Applications/FlClashAppRouter.app' && ditto '$SRC' '/Applications/FlClashAppRouter.app' && xattr -dr com.apple.quarantine '/Applications/FlClashAppRouter.app' && codesign --force --deep --sign - '/Applications/FlClashAppRouter.app'" with administrator privileges
APPLESCRIPT

echo ""
echo "✓ 安装完成！"
echo ""
echo "接下来："
echo "  1. 已自动为你打开 FlClashAppRouter"
echo "  2. 它需要配合 FLClash 使用（请先确保已安装并运行 FLClash）"
echo "  3. 在 FLClash 中开启 TUN 模式后，回到本工具开关 App 规则即可"
echo ""
echo "以后直接从「启动台」或「应用程序」打开 FlClashAppRouter 即可。"
echo ""

open "/Applications/FlClashAppRouter.app" 2>/dev/null || true

echo "按回车键关闭此窗口…"
read -r
