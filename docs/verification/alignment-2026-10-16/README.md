# 暖灰界面对齐修正验收

日期：2026-10-16。基于 `32d76c6` 后的本地修改，参考 `docs/design/soft-surfaces-2026-10-16/`。

## 本轮修正

- 统一主页面外边距 14 pt、卡片内边距 20 pt、区块间隔 12 pt、标题行高度 32 pt。
- 横向分栏明确顶部对齐并填满高度；纵向分栏明确左侧对齐并填满宽度，避免短内容居中或卡片随内容缩小。
- 工作区文件树、差异区、提交面板的标题和内容对齐；去掉提交面板的重复缩进。
- 历史摘要和文件卡片上下边缘对齐；长说明、告警和换行操作栏按实际高度分配空间。窄布局改为上下排列，保留内部滚动和分栏拖动。
- 打开仓库的说明、模式切换和最近仓库列表采用共同边界；远程获取各步骤的表单、摘要和操作栏统一宽度及边距。
- 提交确认页的提示横跨两列，两列标题对齐；仓库管理的表单标签和下拉选项左对齐。

## 实机截图

均由正式 `build/RepHub.app` 原生窗口截取，不是设计稿或网页模拟。

| 页面 | 修正前 | 修正后 |
| --- | --- | --- |
| 工作区 | [01](01-workspace-before.jpg) | [11](11-workspace-after.jpg) |
| 提交历史 | [02](02-history-before.jpg) | [12](12-history-after.jpg) |
| 历史长说明 | — | [13](13-history-long-after.jpg) |
| 历史窄布局 | — | [14](14-history-narrow-after.jpg) |
| 打开本地仓库 | [03](03-open-before.jpg) | [15](15-open-after.jpg) |
| 远程连接 | [05](05-connection-before.jpg) | [16](16-connection-after.jpg) |
| SVN 浏览目录 | [04](04-connection-before.jpg) | [17](17-svn-after.jpg) |
| 本地保存位置 | — | [18](18-destination-after.jpg) |
| 确认检出 | — | [21](21-review-after.jpg) |
| 提交确认 | [06](06-commit-before.jpg) | [19](19-commit-after.jpg) |
| 仓库管理 | [07](07-management-before.jpg) | [20](20-management-after.jpg) |

`04-connection-before.jpg` 实际记录的是 SVN 目录页。`14-history-narrow-check.jpg` 是中间版本暴露空间不足时的检查记录，已由 `14-history-narrow-after.jpg` 替代，不代表最终效果。

## 验证结果

- 相关测试通过 28 项：多窗口 3、仓库获取模型 13、提交选择 6、代码编辑器同步 3、分栏状态保存 3。
- 测试命令：`swift test --filter 'SplitLayoutStoreTests|WorkspaceCommitSelectionTests|NumberedCodeEditorSynchronizerTests|MultiWindowWorkspaceTests|RepositoryAcquisitionModelTests'`。
- 随后的历史页空间计算与向导宽度收尾修改，经最终 Release 编译和实机检查；未宣称重跑完整测试套件。
- 最终 Release 编译成功，用时 43.41 秒；最终应用通过 `codesign --verify --deep --strict build/RepHub.app`；`git diff --check` 通过。
- 验收了历史摘要、长说明、窄分栏、打开本地仓库、远程连接、SVN 目录浏览、本地位置、检出确认、提交预检和管理表单。临时 Git 提交预检显示 6/6 路径，取消后保留草稿；没有执行提交。
- 使用 `/private/tmp/RepHub-SoftSurface-d112a03e-476d-40c9-90f0-d6d0473d716d/` 下的隔离 Git/SVN 测试仓库。此次检出流程停在确认页后关闭，没有执行最终检出。
- 未操作生产仓库，未向 SVN 提交，未提交或推送本轮 RepHub 代码；未创建额外 QA 应用。

本次覆盖常用页面和窄分栏状态，不代表所有弹窗、所有系统缩放比例都已逐一验收。窄布局中的长说明和文件树仍通过各自滚动查看。
