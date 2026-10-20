# 打包与发布

GitHub Actions 工作流位于 [release.yml](../.github/workflows/release.yml)。版本标签使用不带 `v` 的三段数字，例如 `0.0.1`。

## 触发规则

| 入口 | 行为 |
| --- | --- |
| 推送版本标签，例如 `0.0.1` | 从标签对应的源码构建并验证两种架构，全部成功后发布同名 GitHub Release |
| Actions → 打包与发布 → Run workflow | 验证所选分支 / 标签的打包流程，只保存 Actions 产物，不创建或修改 Release |
| 普通分支提交 | 不触发此工作流 |

## 发布步骤

1. 将 `Resources/Info.plist` 的 `CFBundleShortVersionString` 更新为目标版本，并按需更新 `CFBundleVersion`。
2. 可在 `docs/releases/<版本>.md` 编写发布说明；没有对应文件时，由 GitHub 自动生成说明。
3. 提交并推送这些改动。在 Actions 手动运行一次，确认测试、两种架构的编译和打包均通过。
4. 在已验证的提交上创建标签并推送。以首个版本为例：

   ```sh
   git tag -a 0.0.1 -m "RepHub 0.0.1"
   git push origin refs/tags/0.0.1
   ```

标签必须与应用版本完全一致，版本不匹配时流水线会停止。后续版本使用新的数字标签；已经发布的标签和安装包不覆盖、不移动。

## 构建与产物

- 使用 GitHub 官方 `macos-26` 与 `macos-26-intel` 运行环境，分别构建 Apple Silicon 和 Intel 版本。
- 在两种架构上运行现有 `CoreTests` 与 `DesignSystemTests`；这不包含所有 Git / SVN 集成测试，也不代表真实服务端或原生界面验收。
- 复用 `scripts/build-dmg.sh`：以 Release 配置编译、校验应用签名和 DMG，再核对实际架构、版本与 SHA-256。
- Actions 产物保留 14 天；正式发布的 DMG 及校验文件保存在同名 Release 中。

| 产物 | 命名 |
| --- | --- |
| Apple Silicon DMG | `RepHub-<版本>-macOS-arm64.dmg` |
| Intel DMG | `RepHub-<版本>-macOS-x86_64.dmg` |
| 校验文件 | 在对应 DMG 文件名后追加 `.sha256` |

流水线先创建 Release 草稿，全部安装包上传成功后再发布。失败时可以重新运行；已有草稿可继续上传，已公开发布的版本会拒绝覆盖。

本地 `build-dmg.sh` 仍生成带时间戳的文件名，流水线才使用固定的发布文件名。当前均为临时签名，尚未接入 Apple Developer ID 签名或公证。
