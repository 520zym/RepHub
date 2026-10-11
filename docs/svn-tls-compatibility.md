# SVN TLS 兼容

## 使用

打开 RepHub 设置（⌘,）中的“SVN 连接”，输入无账号密码的完整 HTTPS 地址，点击“加入旧 TLS 兼容”。可粘贴仓库完整 URL，但只保存主机、端口与兼容模式，不保存仓库路径或认证信息。删除规则后恢复客户端默认协商。

规则文件为 `~/Library/Application Support/RepHub/svn-connections.json`，文件权限 0600、目录权限 0700。只有匹配的 HTTPS 主机和端口会启用兼容；其他端口、HTTP、file:// 和 Git 不受影响。配置文件无法解析时不启用旧 TLS，设置页显示读取错误并保留原文件。

要求本地 SVN 使用 OpenSSL 3。RepHub 会检查当前工具 `svn --version --verbose` 的已加载库；不支持时给出明确提示。当前已验证 Homebrew SVN 1.14.5、serf 1.3.10、OpenSSL 3.6.3。应用尚未捆绑独立 SVN 运行时，也未验证其他 SSL 库的实现。

## 实现边界

- `VersionControlCore` 定义协议模式及端点规则，`RepositoryApplication` 保存连接设置；`RepHubApp` 通过闭包向 `SVNProvider` 注入策略。UI 不引用具体 SVN 适配器。
- SVN 历史、修订文件及远端修订差异按规则启用兼容。本地识别、状态及工作区差异不依赖旧 TLS 运行时。
- 每次远端调用生成独立的临时 OpenSSL 配置，通过该 SVN 子进程的 `OPENSSL_CONF` 传入，结束后清理。没有写入全局 OpenSSL 配置、SVN servers 文件或 shell 环境。
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

本机连接规则按用户要求保存，未将业务服务器地址硬编码为应用默认值。上述业务仓库只读，未更新或提交。

本地回环测试分别启动仅支持 TLS 1.0、1.1、1.2、1.3 的 OpenSSL 服务端，使用生产配置且不强制客户端协议版本，四种握手均成功。每种协议下的错误主机名、不受信任的证书均被拒绝；现代默认路径仍拒绝测试 TLS 1.0 服务端。这是配置握手矩阵，实际 SVN 远端验证对应上述 TLS 1.0 服务端，不代表所有古老服务端及密码套件都已覆盖。

另有端点精确匹配、IPv6、拒绝凭据地址、持久化、子进程环境隔离、配置权限及清理、OpenSSL 运行时识别测试。原生截图位于 `build/verification/tls-tv-svn-history.png`、`tls-eu-svn-history.png`、`tls-svn-settings.png`，不纳入 Git。

## 依据

- [TLS 1.3 标准 RFC 8446](https://www.rfc-editor.org/info/rfc8446/)
- [OpenSSL SSL_CONF_cmd：协议、套件和旧服务器连接选项](https://docs.openssl.org/3.6/man3/SSL_CONF_cmd/)
- [OpenSSL 配置与 system_default](https://docs.openssl.org/3.5/man5/config/)
- [Apache serf 1.3.10 SSL 实现](https://raw.githubusercontent.com/apache/serf/1.3.10/buckets/ssl_buckets.c)
