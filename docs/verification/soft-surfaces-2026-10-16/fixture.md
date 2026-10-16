# 暖灰界面本地验收夹具

运行：

```zsh
python3 scripts/create-soft-surface-fixture.py
```

脚本输出 `manifest.json` 的绝对路径。它只会在 `/private/tmp/RepHub-SoftSurface-<uuid>` 下创建内容：本地 bare Git 远端、本地 `file://` SVN 仓库和两个工作副本；不会读取业务仓库、访问网络或使用个人认证。

`manifest.json` 给出 Git/SVN 工作副本、SVN 目录浏览地址、建议的子目录检出位置和验收交互。

Git 工作副本含 6 个未提交修改：`HttpClient.java`、`RequestOptions.java`、`ResponseHandler.java`、`application.yml`、`docs/更新说明.md`、`README.md`。历史含长中文提交说明，以及 `feature/soft-surface` 和 `hotfix/response-status` 两条已合并分支，供工作区、提交历史和 Git 图验收。

SVN 工作副本及其 `file://` 远端包含同名源码、配置和文档；远端有多层目录、多个作者和连续修订，可用于检出向导的目录浏览和子目录选择。测试结束后可手动删除该次 `/private/tmp/RepHub-SoftSurface-*` 目录。
