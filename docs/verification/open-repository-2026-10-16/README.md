# 打开仓库页面布局验收（2026-10-16）

- 本地选择按钮改用既有 secondary 浅灰样式，加入文件夹图标，与说明组成同一白色区域，保留居中。
- 最近记录组件的 maximumHeight 改为可选值；打开仓库传 nil，滚动区填满剩余空间。工作区欢迎页仍显式使用 236pt 上限，保持原布局。
- 直接运行最终 DMG 内应用检查 1180×760 的实际界面，列表已延伸到底部，不再停在原来的 264pt 高度。
- 列表向下滚动到末尾成功；最后一条记录完整可见。选择本地文件夹按钮成功打开原生文件选择器，随后取消，未打开或修改业务仓库。
- 截图：local-repositories.jpg（顶部）、local-repositories-bottom.jpg（列表末尾）。
- Release 编译、git diff --check、hdiutil 校验、包内 codesign --verify --deep --strict、SHA-256 校验通过。
- 安装包：build/dist/RepHub-0.1.0-macOS-arm64-20261016-170730.dmg。
- 未提交源码，未覆盖本机安装版。
