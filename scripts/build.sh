#!/bin/bash
# 编译并打包 QuickTrans.app（不需要 Xcode，只要命令行工具）。
# 用法：
#   scripts/build.sh            只编译到 build/QuickTrans.app
#   scripts/build.sh --install  编译后安装到 /Applications 并启动
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/QuickTrans.app
mkdir -p build

swift build -c release

# 图标只需生成一次
if [ ! -f build/AppIcon.icns ]; then
  swiftc -O scripts/make_icon.swift -o build/make_icon
  build/make_icon build/icon_1024.png
  rm -rf build/AppIcon.iconset
  mkdir -p build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/QuickTrans "$APP/Contents/MacOS/QuickTrans"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 如果钥匙串里有名为 "QuickTrans Local" 的代码签名证书就用它签名（重新编译后辅助功能授权不会失效），
# 否则用临时签名（每次重新编译都要重新授权）。创建证书的方法见 README。
SIGN_ID="-"
IDENTITIES=$(security find-identity -p codesigning 2>/dev/null || true)
if [[ "$IDENTITIES" == *"QuickTrans Local"* ]]; then
  SIGN_ID="QuickTrans Local"
fi
if ! codesign --force --sign "$SIGN_ID" --identifier com.atlamtiz.QuickTrans "$APP" 2>/dev/null; then
  SIGN_ID="-"
  codesign --force --sign - --identifier com.atlamtiz.QuickTrans "$APP"
fi
if [ "$SIGN_ID" = "-" ]; then
  echo "已生成 $APP（临时签名：重新安装后需要重新授权辅助功能）"
else
  echo "已生成 $APP（证书签名：$SIGN_ID）"
fi

if [ "${1:-}" = "--install" ]; then
  pkill -x QuickTrans 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/QuickTrans.app
  cp -R "$APP" /Applications/
  open /Applications/QuickTrans.app
  echo "已安装到 /Applications/QuickTrans.app 并启动"
fi
