# AI 场景与连接

AI 功能只在点击“生成提交说明”或“开始审查”后运行，不会自动提交代码。

## 使用方式

1. 在“RepHub → Settings… → AI 与场景”添加连接，并明确选择协议：Chat Completions、OpenAI Responses 或 Anthropic Messages。三者是独立适配器，不能仅凭同一个地址推断可互换。密钥保存到 macOS 钥匙串。本机 localhost / 127.0.0.1 / ::1 可以使用 HTTP 和无密钥服务。
2. API 地址可以填完整端点、以 `/v1` 结尾的基地址，或适配器对应的根地址。`api.openai.com` 与 `api.anthropic.com` 的根地址会按所选协议自动补为 `/v1/chat/completions`、`/v1/responses` 或 `/v1/messages`；自定义服务根地址则按所选协议补 `/chat/completions`、`/responses` 或 `/messages`，应按该服务文档填写其基路径。已是对应端点的完整路径不会重复追加。
3. CLI 连接可选 Codex CLI 或 Claude Code。路径留空时检测常用安装位置；找不到时填写可执行文件路径。模型留空沿用工具默认值。CLI 复用自身登录状态，RepHub 不读取登录令牌。
4. 内置“生成提交说明”和“代码审查”两个场景；可编辑提示词、新建场景并指定默认连接。场景与连接相互独立，执行时也可切换连接。
5. 工作区底部“AI 生成”先打开提交准备窗口；为 Git、SVN 分别选好文件，再点击相应说明旁的“AI 生成”。生成后点击“填入提交说明”，可继续手工编辑，最后才由原有提交按钮执行提交。
6. 顶部“AI 审查”审查当前工作区；在历史页面审查所选提交，也可点击“审查此提交”。面板可选择要审查的文件。输出包含模型给出的文件、行号、问题依据与建议；这些属于模型判断，需人工复核。

## 范围与失效

- 每次只提供所选文件的实际差异、版本控制来源和比较基准，不扫描额外上下文。提交说明使用所选文件的完整工作区版本，保留原有提交语义。
- 差异读取后再次核对基准及文件指纹；模型返回后、填入说明前也再次核对。文件、范围、场景或连接配置改变后旧结果失效。
- 超过 256 KiB 或版本控制适配器已截断的差异会拒绝发送，需要减少文件数量。二进制文件和无文本差异显示明确标记，不伪装成完成代码分析。
- 提交准备过期时，应关闭提交窗口、刷新并重新准备提交，不沿用旧快照。
- 设置“检查配置”只校验 API 配置是否合法，或查询 CLI 版本与必要参数；不发送代码、不调用模型，也不能证明账户已登录或远程服务可用。
- API 请求展示等待状态，收到完整、非流式的文本响应后才展示结果；CLI 可展示已返回的文本。两者支持取消和超时，失败或取消的部分文本不能自动填入提交说明。

## 实现边界

`AICore` 定义连接、场景、输入快照与提供者契约；`AIApplication` 负责配置及执行编排；`AIAdapters` 实现 HTTP、CLI、钥匙串。仓库上下文由 `RepositoryApplication` 通过版本控制契约读取，界面不执行 Git/SVN 或 AI 命令。

API 支持 Chat Completions、OpenAI Responses 与 Anthropic Messages 三种协议。Responses 和 Messages 首版只发起单轮、非流式、只读文本请求；Responses 关闭服务端存储，Messages 固定 `max_tokens` 为 4096，并拒绝工具、拒绝、未完成或非文本响应。当前未以真实模型服务完成端到端验证；“检查配置”仍不联网调用模型。禁止凭据嵌入地址及跨地址重定向，远程连接要求 HTTPS。

CLI 在空临时目录运行，代码和提示词通过有界内存 stdin 传入，不进入命令参数。Codex 使用只读沙箱、临时会话、忽略用户配置/规则；Claude 使用安全模式、禁用内置工具/MCP、禁用会话持久化。CLI 仍是独立外部程序，读取权限受其自身实现及管理策略约束；特别是 Codex 只读模式不等同于操作系统级“只能读取 stdin”。RepHub 不传入正式仓库目录或扩大权限，也不会因参数不支持而降级安全设置。

当前 Claude 采用 `--permission-mode dontAsk`、`--tools ""`、`--disallowedTools "mcp__*"` 与 `--safe-mode`，通过一次性 `-p` 调用输出。Codex 的 `--ask-for-approval never` 放在顶层，npm 符号链接安装会优先使用同一安装目录的 Node。

## 文档依据

- [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
- [OpenAI 从 Chat Completions 迁移到 Responses](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [Anthropic Messages API](https://platform.claude.com/docs/en/api/messages/create)
- [Codex 非交互执行](https://developers.openai.com/codex/noninteractive)
- [Codex CLI 参数](https://developers.openai.com/codex/cli/reference)
- [Claude Code CLI](https://code.claude.com/docs/en/cli-usage)

本机只读检查版本为 Codex CLI 0.148.0、Claude Code 2.1.177；实际运行仍以所安装版本支持的参数为准。
