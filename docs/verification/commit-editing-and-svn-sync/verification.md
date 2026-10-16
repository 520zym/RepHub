# 提交说明编辑与 SVN 同步状态验证

日期：2026-10-16。

## 修改

- 工作区和确认窗口使用原生多行编辑器，支持换行、滚动、复制粘贴和撤销；可直接展开／收起编辑区。
- 确认窗口的说明占据完整宽度，取消和提交按钮放在独立底栏。
- SVN 混合修订仅对最高修订进行一次变更范围查询，批量读取受影响普通文件的本地 BASE 与 URL。完整匹配才确认已同步；不执行 update、不缓存同步结论。

## 定向测试

`swift test --filter 'SVNHistoryTests|SVNCommitTests|SVNDirectoryCommitAndRootComparisonTests|RepositoryCommitModelTests|WorkspaceCommitSelectionTests|MultiWindowWorkspaceTests|RepositoryCommitTests'`

40 项 XCTest 和 6 项 Swift Testing 全部通过，无失败。覆盖提交后混合修订、只更新部分文件、回退后重新判定、中文／空格／@／尾空格路径、提交选择范围、多目标草稿和窗口隔离。

日志：`/tmp/rephub-commit-feedback-tests.log`。补充祖先目录边界后再次运行 SVNHistoryTests，6 项全部通过，日志：`/tmp/rephub-commit-feedback-history-final.log`。未运行全量测试。

最终 `scripts/build-app.sh release` 构建成功，`codesign --verify --deep --strict build/RepHub.app` 通过，已重新启动正式应用。构建日志：`/tmp/rephub-commit-feedback-release-final.log`。

## 原生界面验收

使用独立 bundle ID 的测试应用和 `scripts/create-commit-fixture.py` 生成的临时 Git/SVN 共管目录；远端为本地 bare Git 与 SVN `file://`，未使用生产仓库。

- 工作区和确认窗口输入超过 24 行中文说明，能自动换行并滚动到最后一行；展开后操作按钮仍完整可见。
- 原生 Enter 换行和撤销正常；分别修改 Git 与 SVN 说明，切换目标和取消后重新打开均保留各自草稿。
- 取消 Git 目标，仅向本地 SVN 提交 4 个修改文件和 1 个新增文件，得到 r4。
- 提交后直接点击“查看提交”，r4 没有问号，显示 0 个提交需核对。没有点击刷新或更新。
- 命令核对 SVN 仍为 `3:4` 混合修订且工作区干净；Git HEAD 保持原 fixture 提交，原有修改、新文件和暂存内容均保留。

## 保守边界

这次精确核对只处理混合范围最高修订的普通新增／修改文件。目录（含绑定目录祖先）、复制、删除、缺失、稀疏／切换及无法完整核实的情况保留“需核对”，不隐式修改工作副本来消除提示。
