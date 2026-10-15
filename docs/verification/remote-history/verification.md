# 远程地址与 SVN 账号历史验证（2026-10-15）

## 行为

- Git、SVN 地址分别记忆，按最近成功使用排序、去重，每种最多 20 条；可选择填入和移除。选择历史只填表，不连接服务器。
- SVN 根目录浏览成功或检出成功后记住账号。账号按协议、主机、端口隔离，同服务器可保存多个账号，默认填入最近成功使用的账号。
- 密码存入 macOS 钥匙串；UserDefaults 只含地址和账号元数据。密码默认遮挡，保留查看入口，提供账号切换与忘记入口。
- 手动编辑、换服务器、关闭窗口、忘记账号会使旧读取失效。失败、取消不覆盖已保存的账号密码；钥匙串异常不会把已成功的仓库操作改判为失败。
- 获取成功后重开入口回到连接步骤，可直接使用地址历史。Git 地址变化时更新建议目录名，保留用户手动填写的名称。

## 针对性测试

命令：`swift test --filter 'RemoteRepositoryHistoryStoreTests|KeychainRepositoryCredentialStoreTests|RepositoryAcquisitionModelTests|RecentRepositoryStoreTests'`。

最终 33 项通过：远程历史存储 9 项、已有本地最近仓库 8 项、钥匙串适配器 3 项、获取模型 13 项。

覆盖持久化与去重、每来源数量限制、敏感 URL 拒绝、服务器及端口隔离、IPv6、默认端口归一、密码不落普通配置、钥匙串拒绝访问、同服务器路径编辑、手工输入、过期响应、忘记账号、失败浏览、关闭重开、Git 成功获取后的历史和入口状态。

测试使用独立 UserDefaults、内存或隔离的钥匙串客户端替身，以及临时工作目录。最终日志：`/tmp/rephub-remote-history-final-tests.log`。

`scripts/build-app.sh debug`、`codesign --verify --deep --strict build/RepHub.app` 与 `git diff --check` 均通过。

## 原生交互验证

使用单独的 `/private/tmp/RepHub-RemoteHistory-QA.app`（bundle ID `com.zym.RepHub.remoteHistoryQA`）。所有仓库均在临时目录；未读取、修改正式工作副本或连接正式服务器。

| 验证 | 结果 |
| --- | --- |
| SVN 真实认证 | 本机 `svnserve` 仅监听 `127.0.0.1`，禁止匿名、只读；虚构账号成功浏览根目录后出现地址与账号历史 |
| 重启后恢复 | 退出并重新启动 QA 应用，选择 SVN 最近地址，用户名和遮挡的密码自动填入；直接下一步可再次成功浏览 |
| 忘记账号 | 从账号菜单忘记虚构账号，输入清空；再次重启并选择原地址时保持空白，地址历史仍保留 |
| Git 地址历史 | 从本机 `file://` bare 仓库真实克隆到临时新目录，自动打开成功；重启后 Git 最近地址仍保留且可点击填入 |
| 来源隔离与布局 | Git、SVN 各显示自身记录；表单、历史列表、账号菜单和密码显隐按钮无重叠；Git 历史地址的建议目录名正确 |
| 普通配置 | QA 偏好设置含远程地址历史，不含测试密码；测试结束后保存账号数量为零 |

截图：

- [SVN 重启后自动填入](svn-autofill-after-relaunch.png)
- [Git 克隆后的地址历史](git-history-after-clone.png)
- [SVN 忘记账号后重启](svn-forgotten-after-relaunch.png)

测试结束后已退出 QA 应用、删除虚构账号的钥匙串条目，并停止本轮的本机 SVN 服务。未验证生产服务器、远程 Git 登录或旧 TLS 链路；这些适配器行为未修改。

最新版产物为 `build/RepHub.app`，未另外安装到 `/Applications`。
