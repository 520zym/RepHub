# 迁移进度、批处理和作者通讯录验证

验证日期：2026-10-15。正式 EFB 仓库和服务器未参与测试。

## 问题与改动

- 两条迁移流程原先没有在 `planning` 阶段展示进度面板；现在点击预检即显示活动状态、具体检查阶段、耗时和取消按钮。
- Git 快照写入原先每个普通文件调用一次 `hash-object`，导出核对原先每个文件调用一次 `cat-file`；改为按数量和字节预算分批。保留特殊路径、二进制、符号链接、可执行位、隔离配置和原有 16 MiB 单对象读取上限。
- 当前工作副本迁移在新修订核对成功后释放上一修订的完整中间树，不再保留全部旧树。仍逐条导出、转换和核对 SVN 修订，没有跳过历史或降级为快照。
- 分开显示整体修订完成数和当前阶段；切换阶段清除旧速度。长时间无新输出时明确告知等待状态，不产生虚假心跳或进度。
- 作者邮箱拆为前缀和后缀，前缀默认 SVN 用户名。通讯录按 SVN 服务端隔离保存，支持后缀管理、默认值、搜索、编辑和重新填入当前计划。生成预览前会保存映射，保存失败不会继续转换。
- 当前工作副本转换失败或取消后，重试使用新隔离作业；已应用但未发布的重试仍沿用原有发布语义。

## 自动化验证

`swift test --filter 'WorkingCopyMigrationModelTests|RepositoryMigrationModelTests|TransferProgressTests|MigrationAuthorDirectoryTests|GitMigrationTargetProviderTests|GitWorkingCopyMigrationTests|WorkingCopyMigrationServiceTests|RepositoryMigrationResumeTests|WorkingCopyMigrationIntegrationTests|RepositoryMigrationIntegrationTests'`

共 60 项通过、0 失败：21 项 XCTest 和 39 项 Swift Testing。覆盖预检即时状态及取消、通讯录持久化与服务端隔离、无效映射保护、失败重试、批量对象完整性、15 MiB+1 文件兼容，以及真实临时 Git/SVN 的首次迁移、补迁、冲突保护、发布重试和检查点恢复。不是全量测试。

`scripts/build-app.sh debug` 编译通过；`codesign --verify --deep --strict build/RepHub.app` 通过。

## 原生操作验证

使用独立 bundle ID 的验证应用，不改正式应用偏好。临时本地 SVN 仓库有 6 条所选目录历史（r2 至 r7）、5 位作者；追加 320 个 Swift 文件，并保留二进制、中文路径、空目录和本地未跟踪文件。

实际操作：只读预检 → 添加 `example.test` 后缀 → 统一本次后缀 → 保存 5 位作者 → 通讯录中将 alice 的 Git 名称改为 Alice Example → 回填计划 → 生成转换预览。进度中观察到“已完成 3/6，当前 r5，文件对象 257–324 / 324”；最终预览展示 6 条历史、327 项文件核对。未点击“应用到当前目录并发布”。

退出并重新打开验证应用后，在“设置 → 作者通讯录”确认 5 位作者、Alice Example 和默认后缀仍保留。最终源文件 SHA-256 清单和 `.svn/wc.db` SHA-256 未变化，源目录没有 `.git`，目标本地裸 Git 仓库仍无引用。

本地预检很快结束，截图记录的是完成计划；慢预检的即时状态与取消由延迟源适配器测试覆盖。未对用户截图中的 1599 条正式历史作耗时承诺。

- [预检完成的计划](plan.png)
- [拆分邮箱的作者映射](author-mapping.png)
- [集中管理通讯录](author-directory.png)
- [转换中的真实进度](conversion-progress.png)
- [完成的转换预览](preview.png)
- [重启后设置中的持久化记录](settings-persisted.png)

## Git 环节性能样本

复现：`python3 scripts/benchmark-migration-git.py`。脚本只使用自动创建并清理的本地临时仓库，无网络访问；隔离 Git 配置。

320 个 1 KiB 文件，本机一次测量：

| 环节 | 逐文件启动 Git | 分为 2 批 | 内容核对 |
| --- | ---: | ---: | --- |
| 对象写入 | 3162.2 ms | 159.8 ms | 对象 ID 一致 |
| 对象读取 | 2856.5 ms | 30.9 ms | 原始字节一致 |

这只测 Git 对象处理，不包含 SVN 网络导出、文件树扫描和复制，不能换算成整个迁移的提速倍数。真实总耗时仍取决于历史数量、文件规模、网络和服务器。
