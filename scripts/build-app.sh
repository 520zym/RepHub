#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

configuration="${1:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
    print -u2 '用法：scripts/build-app.sh [debug|release]'
    exit 2
fi
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
bundle="$PWD/build/RepHub.app"
scripts/generate-app-icon.sh
mkdir -p "$bundle/Contents/MacOS"
cp "$binary_dir/RepHub" "$bundle/Contents/MacOS/RepHub"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
mkdir -p "$bundle/Contents/Resources"
cp Resources/RepHub.icns "$bundle/Contents/Resources/RepHub.icns"
codesign --force --sign - "$bundle"
# 原地重建不会必然更新顶层目录时间；让 LaunchServices 重新读取本包的图标元数据。
touch "$bundle"
launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$launch_services" ]]; then
    "$launch_services" -f "$bundle"
fi
print "已生成：$bundle"
