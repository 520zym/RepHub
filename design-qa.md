# 2026-10-13 原生布局核对

## 参考与结果

| 区域 | 用户选定的设计稿 | 原生截图 |
| --- | --- | --- |
| 当前工作区 | [方案 2 + 3 组合](docs/design/workflow-redesign-2026-10-13/workspace-combined-preview.png) | [日间](docs/design/workflow-redesign-2026-10-13/implemented/workspace.png) |
| 提交历史 | [历史方案 2](docs/design/workflow-redesign-2026-10-13/history/option-2-history-reader.png) | [历史阅读器](docs/design/workflow-redesign-2026-10-13/implemented/history.png) |
| 单文件历史 | [历史方案 3](docs/design/workflow-redesign-2026-10-13/history/option-3-svn-file-history.png) | [SVN 文件历史](docs/design/workflow-redesign-2026-10-13/implemented/file-history-svn.png) |
| 冲突与窄面板 | 同工作区组合稿 | [冲突状态](docs/design/workflow-redesign-2026-10-13/implemented/workspace-conflict.png)、[205pt 提交区](docs/design/workflow-redesign-2026-10-13/implemented/workspace-narrow.png)、[深色](docs/design/workflow-redesign-2026-10-13/implemented/workspace-dark.png) |

截图由 macOS 原生窗口捕获，1440 × 965；未使用 HTML 或模拟数据替换原生界面。使用真实临时 Git、本机 file:// SVN 和共管工作副本，应用标识为 `com.zym.RepHub.layoutQA`，与正式应用偏好隔离。

## 核对结论

- 工作区左文件选择、中间全高差异、右提交草稿；没有底部历史。正常状态不占用冲突提示空间。区域通过背景、留白与选中底色区分。
- 提交勾选与当前浏览文件独立。共管目录仅勾选 `Sources/Main.swift` 后，Git 和 SVN 预检均为 1/5，未勾选文件没有进入范围；关闭预检保留提交草稿。最终额外验证了 Git/SVN 不同说明关闭再进入后仍分别保留。未在原生验收中执行提交或推送。
- 历史为左侧两行提交列表和真实 Git Graph、右摘要／文件树／差异。分支树在左上内联展开；SVN 不显示 Git Graph 或推送。历史摘要已压缩为标题与动作、引用标签、元数据，不再沿用旧窄检查器的逐字段纵排。
- 文件历史显示完整范围入口、返回全部历史、修订列表及并排差异；不显示重复文件树。文件历史独立保存摘要高度，默认 156pt，避免继承仓库历史 310pt 的空白。
- 冲突工作区明确阻止提交，按钮可打开三方编辑器；取消后冲突仍在，没有写入最终结果。提交检查器缩窄至 205pt、收起并恢复，按钮与文字未出现遮挡。
- 日夜模式使用既有语义配色；深色下冲突、选择、差异仍可区分。统一差异行背景已修正为至少铺满当前视口。

## 验证边界

61 项不同定向测试通过（首轮 60 项；草稿修复后提交模型 12 项重跑，其中新增 1 项）；最新排版编译、应用打包及签名校验通过。没有执行全量测试，没有访问正式业务仓库、生产 SVN 或真实 AI 服务。此轮没有重新测量大仓库切换耗时，也没有完成全部窗口尺寸、VoiceOver 或所有主题组合的全面验收。

原生提交列表保留系统选择和键盘行为，失焦时选中行采用 macOS 中性色，而非强制复制生成稿颜色。生成稿中的示例字样、计数和图拓扑不作为像素级要求；实窗展示适配器的实际数据。
