# 代码行号验证（2026-10-15）

- 范围：工作区文本预览、统一／并排差异、冲突对照与最终编辑区、迁移差异预览。
- 使用临时 Git 测试仓库；未对用户正式仓库执行写操作，也未保存或提交测试冲突结果。
- 测试应用使用独立 bundle ID `com.zym.RepHub.lineNumbersQA`，不改正式应用的最近仓库或偏好。

## 自动检查

`swift test --filter 'CodeLineIndexTests|CodeLineNumberRulerTests|LocalFileHighlightTests|PatchLineParserTests|PreparedDiffCacheTests|NumberedCodeEditorSynchronizerTests'`

覆盖 UTF-16／中文／emoji、混合换行、空行和末尾空行、深行号定位、行号栏宽度、主题变更保持原文和选择、差异真实行号与缓存、输入法组合期间的模型同步、原生多行插入及撤销。

## 原生界面核对

- 未跟踪的 Swift 文件正常显示高亮及行号；滚动至第 121 行（末尾空行）仍与代码对齐。
- CRLF 文本包含中文、emoji、中间空行和末尾空行，显示 5 行；空文件显示第 1 行。
- 统一差异同时显示旧、新行号，新增行仅显示新行号；并排视图各自显示原版本的行号。
- 冲突基准／本地／传入三栏均显示 9 行；最终结果 13 行。粘贴一行后变为 14 行，Cmd+Z 恢复原文及 13 行。
- 修正了 native 验证发现的 ruler 绘制越界及编辑器撤销响应链问题。
- 迁移差异复用已测试的 PatchLineParser，本轮未执行真实迁移操作。

截图：[普通代码预览](file-preview.png)、[统一差异](unified-diff.png)、[冲突编辑器](conflict-editor.png)。

构建产物：`build/RepHub.app`；已执行 `scripts/build-app.sh debug` 与 `codesign --verify --deep --strict build/RepHub.app`。
