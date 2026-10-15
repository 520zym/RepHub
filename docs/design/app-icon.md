# RepHub 应用图标

## 2026-10-15：视觉居中与线条加粗

根据用户反馈，继续使用“翡翠分支”三个节点和圆角白底板，调整符号的视觉重心，并加粗竖线与曲线连接部分。没有引入新的图形或文字。正式源文件仍为 `Resources/AppIcon.png`，外部保留透明通道。

使用内置 imagegen 编辑，最终生成文件为 `exec-59cfd414-97b9-4a12-b087-7e2a725e49a8.png`。通过原生脚本重新生成各标准尺寸及 `Resources/RepHub.icns`，并检查打包后的 128px 小图显示。旧图保留在 Git 历史中。

最终提示词要点：保留原品牌的深翡翠竖线、上下两节点、弧形分支及右上浅翡翠节点；连接线较原稿加粗约三成，整体符号向右、向下作光学补偿，适度缩小以保留右侧留白；白色圆角底板居中，外部真实透明，无新增底板或外框。生成预览不替代打包后的小尺寸检查。

以下保留首次图标接入和透明底修复记录。

正式图标源文件为 `Resources/AppIcon.png`，来自用户在会话
`01a12a4d-e617-7100-b6a6-8f7a969dace5` 最终确认的“翡翠分支”方案。

2026-10-11 根据用户反馈去掉圆角底板之外的不透明方形背景。使用内置 imagegen
编辑原图，保留翡翠分支构图、三个节点与白色圆角底板；外部改为真实透明通道。
最终生成文件为 `exec-b13e89f9-6dcb-4e43-82b8-3d3b9612f266.png`，已复制到
`Resources/AppIcon.png`。原始不透明版本保留在 Git 历史中。

`scripts/generate-app-icon.sh` 通过 macOS 原生 AppKit 仅缩放生成各标准尺寸的 RGBA
位图并打包为 `Resources/RepHub.icns`。位图与绘制上下文统一使用预乘 alpha，
绘制前清空画布，避免透明背景和半透明边缘在转换时出现异常。打包脚本会把该
`.icns` 放入 `RepHub.app/Contents/Resources`。

本地应用包原地重建后，打包脚本更新包的修改时间并仅重新注册 RepHub，确保
LaunchServices 重新读取图标。应用启动时也从包内 `.icns` 显式设置运行时图标。
不清空系统图标缓存，也不重启 Dock。2026-10-11 已复现“资源正确但系统仍显示
占位图标”，刷新注册并重启后，系统“关于 RepHub”面板实际显示了翡翠分支。

透明版本已核对源 PNG 及从应用包 `.icns` 解出的 16、64、256、1024 像素图标：
四角及画布四边中点 alpha 均为 0，白色底板内部采样 alpha 为 254/255 或 1；
64 像素实际预览保留圆角轮廓，没有外层方形底色。已通过应用构建与签名校验，
重启后系统“关于 RepHub”面板实际显示新的圆角图标。

## 透明版本最终提示词

模式：内置 imagegen；输入：原始 `Resources/AppIcon.png`；`transparent_background: true`。

```text
Recreate this simple macOS app icon as a precisely rendered, clean flat vector-like icon on true transparent alpha background. Keep the reference design: one ivory-white rounded square tile, with a dark jade-green fork/branch symbol consisting of a vertical stem, two circles at its top and bottom, and a curved branch from the middle to a light green circle at upper right. Keep exactly these three nodes, the same composition and proportions, the same greens. The tile is 82% of canvas width, centered. IMPORTANT: perfectly smooth mathematical-looking rounded-square outer contour, with a hairline pale gray-green edge (#d4ddd6) distinguishing the solid white tile from the transparent exterior. Completely clean edge, no texture, no grain, no mottling, no irregularities, no cutout residue, no speckles, no shadow. Do not perform a rough background cutout of the old image: render this straightforward geometric icon cleanly afresh. No square backdrop, no frame. Entire area outside the single rounded tile is transparent. Opaque white inside the tile. Crisp scalable logo quality.
```
