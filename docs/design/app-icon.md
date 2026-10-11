# RepHub 应用图标

正式图标源文件为 `Resources/AppIcon.png`，来自用户在会话
`01a12a4d-e617-7100-b6a6-8f7a969dace5` 最终确认的“翡翠分支”方案。

`scripts/generate-app-icon.sh` 通过 macOS 原生 AppKit 仅生成各标准尺寸的 RGBA
位图并打包为 `Resources/RepHub.icns`，不裁剪、重绘或调整原始图案与配色。打包
脚本会把该 `.icns` 放入 `RepHub.app/Contents/Resources`。
