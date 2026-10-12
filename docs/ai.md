# AI 场景与连接

AI 功能只在点击“生成提交说明”或“开始审查”后运行，不会自动提交代码。

## 使用方式

1. 在“RepHub → Settings… → AI 与场景”添加连接，可选择 DeepSeek、Kimi、MiniMax 或 GLM 预设。预设填写地址及默认模型，只需提供 API Key；前三者保存时会查询模型列表，GLM 使用明确标识的官方预设。也可选择自定义 API（Chat Completions、OpenAI Responses、Anthropic Messages）或本机 CLI。协议由独立适配器实现。密钥保存到 macOS 钥匙串。本机 localhost / 127.0.0.1 / ::1 可以使用 HTTP 和无密钥服务。
2. API 地址可以填完整端点、以 `/v1` 结尾的基地址，或适配器对应的根地址。`api.openai.com` 与 `api.anthropic.com` 的根地址会按所选协议自动补为 `/v1/chat/completions`、`/v1/responses` 或 `/v1/messages`；自定义服务根地址则按所选协议补 `/chat/completions`、`/responses` 或 `/messages`，应按该服务文档填写其基路径。已是对应端点的完整路径不会重复追加。
3. CLI 连接可选 Codex CLI 或 Claude Code。路径留空时检测常用安装位置；找不到时填写可执行文件路径。模型留空沿用工具默认值。CLI 复用自身登录状态，RepHub 不读取登录令牌。
4. 内置“生成提交说明”和“代码审查”两个场景；可编辑提示词、新建场景并指定默认连接和模型。模型可继承连接默认值，也可为该场景单独指定。运行面板展示实际将使用的模型；如果临时切换到其他连接，使用新连接的默认模型，不把原厂商的模型名带过去。
5. 工作区底部“AI 生成”先打开提交准备窗口；为 Git、SVN 分别选好文件，再点击相应说明旁的“AI 生成”。生成后点击“填入提交说明”，可继续手工编辑，最后才由原有提交按钮执行提交。
6. 顶部“AI 审查”审查当前工作区；在历史页面审查所选提交，也可点击“审查此提交”。面板可选择要审查的文件。输出包含模型给出的文件、行号、问题依据与建议；这些属于模型判断，需人工复核。

## 范围与失效

- 每次只提供所选文件的实际差异、版本控制来源和比较基准，不扫描额外上下文。提交说明使用所选文件的完整工作区版本，保留原有提交语义。
- 差异读取后再次核对基准及文件指纹；模型返回后、填入说明前也再次核对。文件、范围、场景或连接配置改变后旧结果失效。
- 超过 256 KiB 或版本控制适配器已截断的差异会拒绝发送，需要减少文件数量。二进制文件和无文本差异显示明确标记，不伪装成完成代码分析。
- 提交准备过期时，应关闭提交窗口、刷新并重新准备提交，不沿用旧快照。
- 设置“检查配置”只校验 API 配置是否合法，或查询 CLI 版本与必要参数；不发送代码、不调用模型，也不能证明账户已登录或远程服务可用。
- API 请求展示等待状态，收到完整、非流式的文本响应后才展示结果；CLI 可展示已返回的文本。两者支持取消和超时，失败或取消的部分文本不能自动填入提交说明。

## 厂商模型发现

| 预设 | 默认 API 基地址 | 模型来源 |
| --- | --- | --- |
| DeepSeek | `https://api.deepseek.com` | `GET /models` |
| Kimi | `https://api.moonshot.cn/v1` | `GET /v1/models` |
| MiniMax | `https://api.minimax.cn/v1` | `GET /v1/models` |
| GLM（智谱） | `https://open.bigmodel.cn/api/paas/v4` | 官方预设，支持手动模型 ID |

预设默认中国大陆平台。其他区域或代理服务可在高级配置中修改地址，密钥必须与平台匹配；不会自动切换到另一个主机重试密钥。模型列表会随连接保存，可手动刷新。模型查询只读取元数据，不上传代码，不触发推理；查询成功不保证账户余额或每个模型的调用权限。401、异常响应和网络错误会显示失败，不能当作成功检测。GLM 暂未找到官方公开的模型查询契约，显示“官方预设”，不声称已验证 API Key。

## 输出中的代码

审查结果中的 Markdown 围栏代码块按语言高亮，使用当前代码主题，支持单独复制代码。正文仍可选择复制；填入提交说明使用原始响应，不带展示层改写。未闭合围栏会按任务状态提示；超过 256 KiB 的单个代码块保持完整纯文本显示。

## Token 用量

- 运行结果下方显示输入、输出、合计，以及服务实际返回的缓存命中、缓存写入和推理 token。缓存属于输入、推理属于输出，不再次加进合计；Anthropic 的输入按普通输入、缓存读取与缓存写入合并。
- 优先使用响应的总量；未给总量但输入和输出均已报告时求和。未返回的字段显示“未返回”，不以字符数或字节数冒充 token，也不记成零。
- 本机设置页保留最近 1,000 次执行，提供当前保留记录的统计和明细。成功、失败、取消分别记录；即使输出不可用，只要收到用量也会计入。请求前的本地配置校验失败不产生执行记录。取消或断网导致没有收到用量时，记录不能证明服务未计费。
- CLI 仅使用 Codex / Claude Code 返回的终态用量字段。工具未提供时保持未知，不读取 CLI 的历史会话或账户凭据。
- 用量记录仅含日期、连接和场景名称/ID、模型、耗时、结果状态与 token 数，不保存代码、提示词、输出或 API Key；清空只影响本地统计。费用以厂商账单为准，本功能不估算价格。

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
- [DeepSeek 模型列表](https://api-docs.deepseek.com/api/list-models/)、[Chat 用量字段](https://api-docs.deepseek.com/api/create-chat-completion/)
- [Kimi 模型列表](https://platform.kimi.com/docs/api/list-models)、[Chat 用量字段](https://platform.kimi.com/docs/api/chat)
- [MiniMax 中国区模型列表](https://platform.minimax.cn/docs/api-reference/models/openai/list-models)、[OpenAI 兼容接口](https://platform.minimax.cn/docs/api-reference/text-chat-openai)
- [GLM OpenAI 兼容接入](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction)、[GLM-5](https://docs.bigmodel.cn/cn/guide/models/text/glm-5)

本机只读检查版本为 Codex CLI 0.148.0、Claude Code 2.1.177；实际运行仍以所安装版本支持的参数为准。

## 本轮验证（2026-10-12）

- AI 核心、适配器及运行面板针对性测试：58 项通过；2 项真实本机 CLI 检查按测试开关跳过。覆盖旧配置兼容、场景模型覆盖、跨主机密钥保护、用量缺失与缓存计数、失败/取消记录、模型列表与错误响应。
- 原生应用使用独立 Bundle ID、无密钥的本地 HTTP 模拟服务和临时 Git 仓库验证：模型发现与保存、场景模型生效、审查输出与统计明细、重启持久化、GLM 预设布局，以及发现失败后的手动保存路径。
- 模拟审查实际请求使用场景模型 `fixture-review`；返回输入 1200、输出 180、合计 1380、缓存命中 800、推理 60，界面与持久化结果一致。
- `scripts/build-app.sh` 与应用签名检查通过。未向真实厂商发送代码或发起付费推理，未使用正式业务仓库测试。
