#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

output_dir="$PWD/build/dist"
mkdir -p "$output_dir"
staging_root="$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT HUP INT TERM
payload="$staging_root/payload"
mkdir -p "$payload"

# 安装包只保留磁盘映像；临时应用不注册到 LaunchServices，避免出现重复入口。
REPHUB_APP_OUTPUT="$payload/RepHub.app" REPHUB_REGISTER_APP=0 \
    scripts/build-app.sh release
app="$payload/RepHub.app"
/usr/bin/codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
architecture="$(/usr/bin/lipo -archs "$app/Contents/MacOS/RepHub" | tr ' ' '-')"
build_stamp="$(TZ=Asia/Shanghai date '+%Y%m%d-%H%M%S')"
image_name="RepHub-$version-macOS-$architecture-$build_stamp.dmg"
image_path="$output_dir/$image_name"

ln -s /Applications "$payload/Applications"
cat > "$payload/安装说明.txt" <<'EOF'
RepHub 安装

1. 将 RepHub 拖入 Applications（应用程序）文件夹。
2. 从“应用程序”启动 RepHub，然后推出此磁盘映像。

需要 macOS 26 或更新版本；Git、SVN 使用本机已安装的工具。
此安装包使用本机临时签名，尚未经过 Apple 公证。
EOF

/usr/bin/hdiutil create -srcfolder "$payload" -volname "RepHub 安装" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$staging_root/RepHub.dmg"
/usr/bin/hdiutil verify "$staging_root/RepHub.dmg"
mv "$staging_root/RepHub.dmg" "$image_path"
(cd "$output_dir" && /usr/bin/shasum -a 256 "$image_name" > "$image_name.sha256")
print "已生成安装包：$image_path"
