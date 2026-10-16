# 弹窗尺寸与提交树布局验收（2026-10-16）

## 实现范围

- 15 类自定义内容弹窗统一使用 `WorkbenchSheet`：提交、打开仓库、更新、初始化、仓库管理、迁移、AI 运行、AI 连接/场景编辑、作者通讯录、历史检查、搁置、冲突处理、按块提交、忽略规则。
- 设置窗口也改为最小/理想尺寸，不再固定宽高。系统提示框和菜单保持系统行为。
- `.presentationSizing(.fitted)` 与可伸缩 frame 配合，保留各页面正常操作所需的最小尺寸，不设置最大尺寸。参见 [Apple 的 fitted 说明](https://developer.apple.com/documentation/swiftui/presentationsizing/fitted)。
- 提交预检的准备中、空态、结果页取消固定尺寸；可提交路径与差异预览随宽度伸缩，说明编辑器随高度调整。
- 提交树使用全宽 leading 容器，根层缩进 7pt、每层增加 14pt；文件夹收起后也保持左对齐。
- 更新窗口的操作按钮独立置于底栏，表单可滚动。

## 原生 UI 验证

仅使用 `/private/tmp/RepHub-SoftSurface-d112a03e-476d-40c9-90f0-d6d0473d716d/git-workspace` 临时仓库。没有提交、拉取、推送、生成 AI 请求或修改正式仓库。

已检查：提交树根目录/多层目录的展开和收起、编辑区展开后底栏、嵌套 AI 面板、打开仓库、更新确认、AI 连接编辑器。

为核实系统实际状态，临时在应用自己的 sheet 中读取 NSWindow 的尺寸约束。诊断探针已从交付源代码和最终构建中移除。

| 页面 | 初始尺寸 | 最小尺寸 | 原生可调整 | 最大尺寸 |
| --- | --- | --- | --- | --- |
| 提交 | 900×720 | 680×600 | true | 无上限 |
| AI 运行 | 900×620 | 720×520 | true | 无上限 |
| 更新确认 | 560×540 | 480×420 | true | 无上限 |
| 打开仓库 | 1180×760 | 740×560 | true | 无上限 |
| AI 连接编辑 | 620×640 | 540×500 | true | 无上限 |

CUA 的边缘拖动没有引发可观察的尺寸变化，因此不将自动化拖动记为通过；可调整能力由原生 `styleMask.resizable=true`、实际 min/max 约束和官方 API 合约共同核对。没有声称已逐一拖动所有窗口验证全部尺寸。

截图：`commit-folders-collapsed.jpg`、`commit-large-editor.jpg` 展示修复后的提交树和编辑区；`commit-initial.jpg` 展示默认尺寸。

## 构建与包校验

- 最终 Release 构建通过（29.84 秒），无新增编译错误。
- `git diff --check` 通过。
- 临时仓库验收前后 porcelain 状态一致。
- 最终 DMG：`build/dist/RepHub-0.1.0-macOS-arm64-20261016-170218.dmg`。
- hdiutil 镜像校验、只读挂载后的应用 `codesign --verify --deep --strict`、SHA-256 校验均通过。
- 未提交或推送本轮源码，未覆盖 `/Applications/RepHub.app`。
