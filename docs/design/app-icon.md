# RepHub 应用图标

正式图标源文件为 `Resources/AppIcon.png`，来自用户在会话
`01a12a4d-e617-7100-b6a6-8f7a969dace5` 最终确认的“翡翠分支”方案。

`scripts/generate-app-icon.sh` 通过 macOS 原生 AppKit 仅生成各标准尺寸的 RGBA
位图并打包为 `Resources/RepHub.icns`，不裁剪、重绘或调整原始图案与配色。打包
脚本会把该 `.icns` 放入 `RepHub.app/Contents/Resources`。

本地应用包原地重建后，打包脚本更新包的修改时间并仅重新注册 RepHub，确保
LaunchServices 重新读取图标。应用启动时也从包内 `.icns` 显式设置运行时图标。
不清空系统图标缓存，也不重启 Dock。2026-10-11 已复现“资源正确但系统仍显示
占位图标”，刷新注册并重启后，系统“关于 RepHub”面板实际显示了翡翠分支。
