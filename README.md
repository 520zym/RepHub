# RepHub

个人使用的原生 macOS Git / Subversion 客户端。使用 SwiftUI 和 AppKit；版本控制工具通过独立 Swift 模块接入，主界面不嵌入网页。

## 当前版本：已有仓库读取与更新

- 从“文件 → 打开本地文件夹…”（⌘O）或“项目 → 打开仓库…”进入已有工作目录。
- 自动识别 Git、SVN，以及同目录内的双重管控；从当前工作区内的工具选择器切换读取来源。
- 工作区采用文件树、并排差异、提交说明栏与可收起的底部历史；打开后自动读取首个代码变更。
- 差异支持并排 / 统一切换、真实行号、增删底色与基础词法高亮；长代码可横向滚动。
- 历史采用分支栏、提交表格 / Git 图谱、右侧详情与下方差异，支持分支引用和提交搜索。读取最近 150 条历史，SVN 展示真实修订记录。
- 工作区或提交详情中的文件支持右键查看文件历史，也可从历史页选择一个本地文件；独立读取最近 150 条文件记录，支持追溯改名和历史差异。
- 历史行显示“待更新 / 待推送 / 需核对”。Git 比较当前分支与已获取的真实上游，SVN 按工作副本或单文件 BASE 判断，混合修订不冒充已同步。详见 [文件历史与同步状态](docs/file-history.md)。
- 原生设置（⌘,）提供温润翡翠 / 石墨灰主题、浅色 / 深色 / 跟随系统，以及独立的代码配色，立即生效并保存。
- SVN 自动识别旧 TLS 握手问题并静默尝试 TLS 1.0–1.3 兼容，无需手动配置；保留现有证书校验。详见 [SVN TLS 兼容](docs/svn-tls-compatibility.md)。
- 命令执行支持超时和取消；快速切换目录、来源或修订时丢弃过期结果。检测失败与未受管理目录分别显示。
- 顶部“更新”支持 Git 获取远端引用、快进更新与 SVN 更新；双管控目录单选一个更新来源，结束后刷新两侧状态。进度、取消、冲突和失败结果均在原生窗口展示。详见 [更新行为与测试边界](docs/repository-update.md)。

克隆 / 检出、初始化、暂存、提交 / 推送、AI 场景与 API / CLI 连接尚未接入；提交按钮目前禁用。未管理目录只能查看提示，不能初始化。SVN 认证沿用本机已有配置，尚无应用内登录和证书信任管理界面。

## 构建与运行

需要 macOS 26 或更新版本、Xcode 26 / Swift 6.2 或更新版本，以及本地 Git。读取 SVN 还需要安装 `svn`；本地 SVN 集成测试另需 `svnadmin`。工具按常见安装目录和当前 PATH 查找。

旧 TLS 兼容要求 SVN 实际加载 OpenSSL 3，本机已验证 Homebrew SVN 1.14.5 / OpenSSL 3.6.3；不满足时显示明确提示。协议矩阵测试另需 Homebrew OpenSSL 3。

```sh
swift test
./scripts/build-app.sh
open build/RepHub.app
```

也可以在 Xcode 中打开 `Package.swift`。打包脚本生成本地临时签名的 `.app`，不是公证分发包。构建产物在 `build/` 与 `.build/`，不纳入 Git。

## 模块

| 模块 | 职责 |
| --- | --- |
| VersionControlCore | 提供者契约、能力、仓库 / 文件 / 修订模型 |
| ToolExecution | 无 shell 的参数数组执行、工具定位、输出上限与超时取消 |
| GitAdapter / SVNAdapter | 具体命令构造和输出解析 |
| RepositoryApplication | 多提供者识别、读取、单目标写操作与全绑定刷新，只依赖契约 |
| DesignSystem | 独立的应用主题、代码配色、外观模式及持久化 |
| RepHubUI | 原生工作区、差异、历史图与设置交互 |
| RepHubApp | 窗口、菜单、依赖组装 |

更新测试在独立 Git / file:// SVN 仓库中执行，自动化测试使用隔离 HOME 和工具配置，不使用业务仓库。`python3 scripts/create-update-fixtures.py` 可建立可重复的原生界面验收样本，所有远端和副本均位于 `系统临时目录/RepHub-UpdateFixtures/<uuid>`。原生架构与后续流程边界见 [架构说明](docs/native-architecture.md)，完整目标见 [需求](docs/requirements.md)。

文件历史和同步状态的界面样本使用 `python3 scripts/create-history-fixtures.py` 创建，位于 `系统临时目录/RepHub-HistoryFixtures/<uuid>`；包含 Git 分叉与中文改名文件，以及 SVN 待更新、改名和混合修订样本。

## 下一阶段

接下来完成克隆 / 检出与初始化入口，再接入明确文件范围的单目标 / 双目标提交，分别保留每个目标结果。之后接入 AI 场景、模型 API 和本地 CLI；新增 SVN 写操作先以只读探测确定 TLS 模式，不能无感重试可能已经执行的写命令。
