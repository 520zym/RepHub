# Prototype Instructions

Run the local server yourself and open the preview in the browser available to this environment. Do not give the user server-start instructions when you can run it.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

Build app UI in `src/`. Keep `.openai/hosting.json`, `worker/index.js`, `scripts/prepare-sites-build.mjs`, and `tests/sites-worker.test.mjs` intact so the same local prototype can be handed to Sites. Before a Sites handoff, run `npm run build` and `npm run test:sites`; the build must leave `dist/client/index.html`, `dist/server/index.js`, and `dist/.openai/hosting.json`.

## 本轮稳定设计决定

- 原型采用 IDE 式单仓库工作区：通过“项目”菜单打开、切换、克隆或检出仓库；左侧只显示当前仓库的文件与变更，不展示全局仓库列表。
- 主工作区以代码差异阅读为中心，可在并排／统一差异之间切换；提交历史以可收起、可放大的底部面板呈现，Git 使用提交图，SVN 使用修订历史。
- AI 设置分为场景与连接。场景和非密钥连接配置保存在当前浏览器的 `localStorage`；API 密钥只在设置弹窗内存中短暂存在，原型不发送请求。
- 提交目标支持 Git、SVN 或两者，目标各自记录结果；部分失败时仅重试失败目标，已成功的目标保持原结果。
- 所有仓库、版本控制、AI 和网络行为均为 mock，不调用真实命令、不访问仓库或服务。帮助菜单可恢复当前仓库的演示数据。
- 视觉以温润、克制的 macOS 工作台为准：导航和操作区域轻玻璃化，代码差异和历史列表保持稳定对比度，圆角与动效轻量，并尊重系统减少动态效果设置。
- 本地文件夹流程先区分 Git、SVN、双版本控制、未受版本控制和检测失败。未受版本控制时才能单选 Git 或 SVN 并确认模拟初始化；初始化只能选择一种，已有 Git + SVN 共管目录仍可识别和打开；检测失败只允许重试，不能误导为可初始化状态。当前仅模拟目录选择、检测与初始化，其他 VCS 保留适配入口。

- 顶部工具栏只保留更新与 AI 审查等常用操作，不在 AI 审查右侧重复放置设置齿轮；场景和连接设置从左下角或 AI 菜单进入。
