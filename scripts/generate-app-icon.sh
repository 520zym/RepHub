#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

source_image="Resources/AppIcon.png"
output_image="Resources/RepHub.icns"

if [[ ! -f "$source_image" ]]; then
    print -u2 "缺少应用图标源文件：$source_image"
    exit 1
fi

if [[ -f "$output_image" && "$output_image" -nt "$source_image" && "$output_image" -nt scripts/render-app-icon.swift ]]; then
    exit 0
fi

temporary_parent="$(mktemp -d "${TMPDIR%/}/RepHub-icon.XXXXXX")"
iconset_dir="$temporary_parent/RepHub.iconset"
trap 'rm -rf "$temporary_parent"' EXIT HUP INT TERM
mkdir "$iconset_dir"

/usr/bin/swift scripts/render-app-icon.swift "$source_image" "$iconset_dir"

iconutil -c icns "$iconset_dir" -o "$output_image"
print "已生成：$output_image"
