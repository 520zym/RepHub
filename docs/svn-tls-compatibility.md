# SVN TLS 兼容

## 使用

正常打开 SVN 工作副本并查看历史即可，无需选择协议版本、填写服务器规则或确认重试。RepHub 先按客户端默认方式连接，遇到可识别的 TLS / SSL 协议握手错误时，静默重试一次兼容连接。最终成功后正常显示结果；仍然失败时保留真实错误提示。

兼容成功后按规范化的 HTTPS 主机和端口缓存 15 分钟，供同一端点的后续读取使用。期限到达或重启应用后重新从默认协商开始，避免服务端升级后仍永久使用兼容配置。失败不写入缓存，其他主机、端口、HTTP、file:// 和 Git 不继承该结果。

手动“SVN 连接”设置页及持久化规则已移除；旧版本留下的 `~/Library/Application Support/RepHub/svn-connections.json` 不再读取，也不影响自动判断。缓存不保存账号、密码或仓库路径。

要求本地 SVN 使用 OpenSSL 3。RepHub 会检查当前工具 `svn --version --verbose` 的已加载库；不支持时给出明确提示。当前已验证 Homebrew SVN 1.14.5、serf 1.3.10、OpenSSL 3.6.3。应用尚未捆绑独立 SVN 运行时，也未验证其他 SSL 库的实现。

## 实现边界

- `VersionControlCore` 定义协议模式及端点模型，自动识别、重试和缓存封装在 `SVNAdapter`；应用入口只组装 `SVNProvider()`。UI 与业务层不解析 SSL 错误，也不引用具体 SVN 适配器。
- SVN 历史、修订文件及远端修订差异使用自动协商。本地识别、状态及工作区差异不依赖旧 TLS 运行时。更新先用只读 `info` 确定 TLS 模式，再以该模式执行一次 `update`；完成、取消或失败后重新读取实际状态。写命令不能直接套用只读重试。提交尚未接入。
- 仅 HTTPS 的协议 / 握手错误允许重试，包括本机实际返回的 `E120171: An error occurred during SSL communication`。`E170013` 连接失败本身不足以触发兼容；证书、主机名、认证、DNS、网络超时和取消不触发回退。通用 SSL 错误只能作为兼容尝试的依据，成功不代表已精确测定服务端协议版本。
- 只有兼容调用生成独立的临时 OpenSSL 配置，通过该 SVN 子进程的 `OPENSSL_CONF` 传入，结束后清理。没有写入全局 OpenSSL 配置、SVN servers 文件或 shell 环境。
- 配置范围为 `MinProtocol = TLSv1`、`MaxProtocol = TLSv1.3`、`CipherString = DEFAULT:@SECLEVEL=0`、`Options = UnsafeLegacyServerConnect`。自动协商允许范围内的协议，未启用 SSLv2/SSLv3，也未启用更宽泛的 `UnsafeLegacyRenegotiation`。
- TLS 1.0/1.1 和较低套件安全级别只用于必须兼容的旧服务。SVN/serf 仍执行证书链、主机名及有效期校验，并沿用本机已有信任记录；未新增 `--trust-server-cert*` 等跳过校验参数。兼容模式不能替代可信证书配置。
- SVN 仍使用 `--non-interactive --no-auth-cache`；缺少凭据或证书信任时保留失败信息，不保存新凭据，不把连接失败显示为空历史。

## 2026-10-11 验证证据

服务端 `192.168.131.32:8443` 的握手实测为 TLS 1.0、`DHE-RSA-AES256-SHA`。仅降低套件安全级别仍返回 `unsafe legacy renegotiation disabled`；启用限定的旧服务器连接选项后握手成功。不是简单的 macOS 内置 SVN 版本限制，本机实际使用的是 Homebrew SVN 及其 OpenSSL 3 库。

在未添加证书绕过参数的情况下，真实 SVN 命令先读到 TV 仓库的 `r15730`、`r15635`；更新后的原生应用验证如下：

| 工作副本 | 原生应用结果 |
| --- | --- |
| `EFB-ROOT-Service/ROOT-3.6.0.01-TV`（Git + SVN） | SVN 150 条历史；`r15730` 的 1 个文件及 `VersionService.java` 并排差异成功；状态为就绪 |
| `EFB-ROOT-Service/ROOT-3.6.5.01-EU`（SVN） | 150 条历史；`r15263` 的 1 个文件及 `ReceiptFileUtils.java` 并排差异成功；状态为就绪 |

最初的显式端点规则版本已完成上述验证；后续改为自动识别，业务服务器地址未硬编码为应用默认值。上述业务仓库只读，未更新或提交。

自动识别版本也已重启实测：无需设置即可打开 TV 的 150 条 SVN 历史及 `r15730` 差异，同次运行切换到 EU ROOT 后读取 150 条历史及 `r15263` 差异成功。设置页不再显示 TLS 控件。自动回退、端点隔离、缓存失效、失败分类、运行时检查、四版本握手、本地 SVN 及双仓库集成共 16 项针对性测试通过，编译和打包通过。

本地回环测试分别启动仅支持 TLS 1.0、1.1、1.2、1.3 的 OpenSSL 服务端，使用生产配置且不强制客户端协议版本，四种握手均成功。每种协议下的错误主机名、不受信任的证书均被拒绝；现代默认路径仍拒绝测试 TLS 1.0 服务端。这是配置握手矩阵，实际 SVN 远端验证对应上述 TLS 1.0 服务端，不代表所有古老服务端及密码套件都已覆盖。

另有端点精确匹配、IPv6、拒绝凭据地址、子进程环境隔离、配置权限及清理、OpenSSL 运行时识别测试。历史验证截图位于 `build/verification/tls-tv-svn-history.png`、`tls-eu-svn-history.png`；`tls-svn-settings.png` 仅记录已移除的旧手动设置页，不代表当前交互。截图不纳入 Git。

当前自动版本截图：`build/verification/auto-tls-tv-history.png`、`auto-tls-eu-history.png`、`auto-tls-settings.png`。

## 依据

- [TLS 1.3 标准 RFC 8446](https://www.rfc-editor.org/info/rfc8446/)
- [OpenSSL SSL_CONF_cmd：协议、套件和旧服务器连接选项](https://docs.openssl.org/3.6/man3/SSL_CONF_cmd/)
- [OpenSSL 配置与 system_default](https://docs.openssl.org/3.5/man5/config/)
- [Apache serf 1.3.10 SSL 实现](https://raw.githubusercontent.com/apache/serf/1.3.10/buckets/ssl_buckets.c)
