# 历史节点文档预览验证（2026-10-15）

Word、PowerPoint、Excel、PDF 在工作区及历史页面均显示“不支持内容差异比较”的提示。历史页面读取所选节点的原始文件，工作区读取当前本地文件。节点中不存在文件、读取失败、超过限制均明确提示，不以本地文件或父版本代替。

## 自动验证

针对性验证共 61 项通过，未运行全量测试：

| 范围 | 数量 | 主要覆盖 |
| --- | ---: | --- |
| Git 历史文件内容 | 3 | 精确节点、原始字节、删除、特殊路径、大小限制、目录及符号链接拒绝 |
| SVN 历史文件内容 | 3 | 修订内容、重命名后的 peg 追溯、删除、错误传播、目录及符号链接拒绝 |
| 历史文档服务及工作区文件服务 | 10 | 临时快照、权限、生命周期、取消、大小限制、工作区预览回归 |
| 历史文档模型 | 7 | 节点切换、工作区隔离、过期结果、文件历史、缺失及失败、文本差异回归 |
| 分页及工作区模型回归 | 38 | 分页、关联工作区、现有工作区交互 |

Git 初次运行有一项测试夹具未创建所断言的目录，补全夹具后该套 3 项全部通过。最终运行日志为 `/tmp/rephub-git-document-final.log`；其余日志为 `/tmp/rephub-svn-document-fix.log`、`/tmp/rephub-history-document-tests.log`。

`scripts/build-app.sh debug` 完成，`codesign --verify --deep --strict build/RepHub.app` 和 `git diff --check` 通过。

## 原生界面验证

使用单独的 QA 应用及临时 Git、SVN 仓库。四种文档均为本地生成的样本，不包含业务资料；未读写正式仓库，未调用远端推送或提交操作。

| 场景 | 实际结果 |
| --- | --- |
| Git 工作区 PDF | 显示“未提交本地版本三” |
| Git `0e3ce3bd` 的 PDF、DOCX、XLSX、PPTX | 四种格式均显示“历史版本二” |
| Git `c57aea6b` 的 PDF 及该文件历史 | 显示“历史版本一” |
| SVN r3 的 PDF | 显示“历史版本二” |
| SVN r2 的 PDF | 显示“历史版本一” |
| SVN 历史→工作区→历史 | 依次显示版本一、本地版本三、版本一，保留 r2 选择 |
| 格式及节点切换、正常退出 | Quick Look 正常显示，本轮未新增 RepHub 崩溃报告 |

截图：

- [Git 工作区 PDF](git-workspace-pdf.png)
- [Git 历史 PDF](git-history-pdf-v2.png)
- [Git 历史 PowerPoint](git-history-pptx-v2.png)
- [Git 单文件历史 PDF](git-file-history-pdf-v1.png)
- [SVN 历史 PDF](svn-history-pdf-r2.png)

## 边界

历史文档沿用工具输出限制，单文件最大 16 MiB，超限不生成截断文档；工作区沿用现有 256 MiB 预览限制。具体文档格式由 macOS Quick Look 渲染。本轮真实样本验证 PDF、DOCX、XLSX、PPTX，旧版 DOC、XLS、PPT 未单独准备样本。

历史快照位于应用创建的私有临时目录，正常释放后清理；异常退出时不保证立即清理。本轮 SVN 使用本地 `file://` 仓库，未重新验证生产服务器或 TLS 链路。

构建产物为 `build/RepHub.app`，本轮界面验证运行独立的 `/private/tmp/RepHub-Readability-QA.app`，未覆盖 `/Applications` 中的应用。
