# 暖灰界面实机验收

2026-10-16 完成。详细对照与取舍见 [design-qa.md](../../../design-qa.md)。

- [工作区](workspace.jpg)：文件树、真实差异、提交说明与独立提交区。
- [提交历史](history.jpg)：列表、说明、文件树与差异的分区。
- [SVN 检出](svn-checkout.jpg)：步骤导航、目录元数据、所选目录摘要。
- [目录筛选](svn-filter.jpg)：只筛选已经读取的内容并保留祖先路径。
- [较窄阅读区](history-narrow-pane.jpg)：摘要与文件列表上下排列。
- [深色](history-dark.jpg) / [深色搭配浅色代码](history-dark-light-code.jpg)。

图片是 macOS 实际窗口的 JPEG 截图，未对内容进行合成。工作区/历史 1440×963，检出向导 1180×760。

62 项针对性测试全部通过；最终 Release 构建成功，`codesign --verify --deep --strict` 通过。应用位于 `build/RepHub.app`，没有创建新的 QA 应用。

最终应用可执行文件 SHA-256：

```
850d1af047de0ec9197118e687c2d61f340a3670766230b5cb642c907d07be65
```

测试覆盖 Git 文件勾选、说明编辑、预检取消保留草稿、历史说明展开、分栏调整、主题切换，以及从本地 `file://` SVN 仓库实际检出到临时目录。检出结果为 r7、零变更。测试未访问生产 SVN 服务，也未向 SVN 提交任何内容。

夹具脚本及运行说明见 [fixture.md](fixture.md)。
