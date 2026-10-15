# SVN 历史迁移增量读取验收

日期：2026-10-15。范围：新目录 SVN → Git、当前 SVN 工作副本首次迁移、后续补迁的来源读取。只使用临时本地仓库；没有操作用户 EFB 工作副本或业务远端。

## 修复内容

旧实现对每一条 SVN 修订执行远端 `svn export -r`，导致大量未改变的文件被反复下载。新实现通过独立的 `RepositoryMigrationSnapshotSession` 契约复用一个隔离缓存：

- 新目录迁移：首次 `checkout`，随后按固定 `URL@anchor` 逐修订 `switch`，再本地 `export`。
- 当前工作副本首次迁移：只读核对并复制干净 BASE 和 `.svn` 到隔离缓存；未跟踪文件不进入缓存。若只导出当前 BASE，来源快照步骤可在 SVN 服务端不可访问时完成；预检和发布仍有各自的远端核对。
- 补迁：从上次 SVN 锚点建立隔离缓存，再增量获取新增修订，不使用可能已被 Git 改动的 SVN 工作区作为干净种子。
- 所有切换仅在缓存中执行。取消或失败后会话失效并清理来源缓存，恢复使用新缓存；已核对 Git 检查点的既有保护保留。

## 下载量对照

脚本：`scripts/benchmark-migration-svn.py`。原始结果：[network-benchmark.json](network-benchmark.json)。本机 SVN 1.14.5，临时 `svnadmin` 仓库、仅监听 127.0.0.1 的 `svnserve` 和 TCP 计数代理。夹具有 120 个 32 KiB 随机二进制文件，以及 10 次小文本修改，共 11 个快照。代理测量服务端到客户端的字节，不含夹具创建。

| 策略 | 远端全树 export | checkout | switch | 下行字节 | 本机样本耗时 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 原策略 | 11 | 0 | 0 | 44,164,787 | 0.925 秒 |
| 增量缓存 | 0 | 1 | 10 | 4,032,984 | 11.135 秒 |

11 个快照逐一 SHA-256 核对一致，网络下行减少 **90.87%**。这验证了重复全量传输被消除，不证明整体迁移加速 90.87%。在本机零延迟环境，新策略的工作副本处理反而更慢；真实服务端的耗时还取决于延迟、带宽和实际变更量。该脚本没有测量 seed 复用，也不包含生成和核对 Git 历史的全部成本。

## 验证结果

共 59 项不同的针对性测试通过；失败修复后只复跑受影响用例，不将重复运行计入总数。

| 范围 | 数量 | 结果 |
| --- | ---: | --- |
| SVN 迁移会话与历史读取 | 11 | 通过；含一次缓存递进、离线 seed、源文件与 wc.db 字节不变、未跟踪文件排除、失败会话拒绝复用、152 条真实提交、501 条分页样本 |
| 新目录与当前工作副本迁移集成 | 9 | 通过；含复制/改名的 5 条历史逐一与标准 SVN 导出对照，二进制、符号链接、可执行位、换行、关键字、删除、补迁、冲突与并发远端保护 |
| 迁移编排与检查点恢复 | 13 | 通过；含单次会话复用、seed 传递、进度阶段保留、已核对检查点恢复与未核对提交拒绝恢复 |
| TLS 自动兼容策略 | 10 | 通过；策略单测，没有访问真实旧 TLS 服务器 |
| Git、SVN 和界面进度状态 | 16 | 通过；阶段切换清除旧速度，同时保留整体修订进度 |

执行的测试筛选组合为 `SVNMigrationSessionTests`、`SVNMigrationTests`、`RepositoryMigrationResumeTests`、`WorkingCopyMigrationServiceTests`、`RepositoryMigrationIntegrationTests`、`WorkingCopyMigrationIntegrationTests`、`SVNTLSPolicyTests`、`TransferProgressTests`（包含 Git/SVN 同名后缀套件）。复杂历史用例最终单独以 `incrementalSnapshotsPreserveCopiedHistoryAndComplexTrees` 复跑通过。

新增复杂历史夹具曾因混合 BASE 的复制来源、测试文件路径的 `/var` 别名处理而断言失败，已按真实 SVN 语义和文件列表修正，未削弱逐修订内容对照。对照强制要求 SVN 导出非空，并比较完整文件字节、链接文字和可执行位。本次没有更改界面布局，验证界面进度状态而未重复进行原生页面截图验收。

`scripts/build-app.sh debug` 成功生成 `build/RepHub.app`，`codesign --verify --deep --strict build/RepHub.app` 通过。旧进程不会热更新到新算法，使用新应用重新生成预览后生效。

## 保留的边界

`.svn` 通常包含当前 BASE 和工作副本元数据，不是完整历史库。`svn log` 返回提交元数据，不包含所有历史文件内容；保留历史仍需获取缺失内容。迁移仍逐修订在本地生成和核对 Git 文件树，未省略修订或降级为单快照。此次没有对真实老 TLS 服务器或用户 1,599 条历史执行迁移，不能据此给出该仓库完成时间。
