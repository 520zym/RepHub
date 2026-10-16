#!/usr/bin/env python3
"""创建暖灰界面改版的本地 Git/SVN 验收夹具。

所有内容只写入 /private/tmp/RepHub-SoftSurface-<uuid>。Git 远端是本地 bare
仓库，SVN 远端是本地 file:// 仓库；脚本不读取正式工作区、不访问网络，也不使用
用户的 Git/SVN 认证或全局配置。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path


PARENT = Path("/private/tmp").resolve()
PREFIX = "RepHub-SoftSurface-"


def inside(root: Path, value: Path) -> Path:
    resolved = value.resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as error:
        raise RuntimeError(f"测试操作越出隔离根目录：{value}") from error
    return resolved


def tool(name: str) -> str:
    candidates = [shutil.which(name)]
    if name in {"svn", "svnadmin"}:
        candidates[0:0] = [f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}"]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise RuntimeError(f"缺少本地测试工具：{name}")


def env(home: Path, extra: dict[str, str] | None = None) -> dict[str, str]:
    result = {
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"),
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/usr/bin/false",
        "SSH_ASKPASS": "/usr/bin/false",
        "GIT_PAGER": "cat",
        "LC_ALL": "en_US.UTF-8",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }
    if extra:
        result.update(extra)
    return result


def run(
    root: Path,
    home: Path,
    tools: dict[str, str],
    executable: str,
    *arguments: str,
    cwd: Path | None = None,
    extra: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    if cwd is not None:
        inside(root, cwd)
    for argument in arguments:
        if argument.startswith("/"):
            inside(root, Path(argument))
        if "://" in argument and not argument.startswith("file://"):
            raise RuntimeError(f"拒绝非本地远端：{argument}")
        if argument.startswith("file://"):
            inside(root, Path(argument.removeprefix("file://")))
    invocation = [tools[executable]]
    if executable == "svn":
        invocation.extend(("--config-dir", str(home / ".subversion")))
    invocation.extend(arguments)
    return subprocess.run(
        invocation, cwd=cwd, env=env(home, extra), check=True, stdin=subprocess.DEVNULL,
        text=True, capture_output=True,
    )


def write(root: Path, path: Path, content: str) -> None:
    inside(root, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def git_commit(
    root: Path, home: Path, tools: dict[str, str], writer: Path, subject: str, body: str,
    author: tuple[str, str], stamp: datetime,
) -> None:
    run(root, home, tools, "git", "add", "--all", cwd=writer)
    iso = stamp.isoformat()
    run(
        root, home, tools, "git", "-c", f"user.name={author[0]}", "-c", f"user.email={author[1]}",
        "commit", "-m", subject, "-m", body, cwd=writer,
        extra={"GIT_AUTHOR_DATE": iso, "GIT_COMMITTER_DATE": iso},
    )


def create_git(root: Path, home: Path, tools: dict[str, str]) -> tuple[Path, str]:
    remote = root / "remotes" / "soft-surface-git.git"
    writer = root / "git-writer"
    workspace = root / "git-workspace"
    run(root, home, tools, "git", "init", "--bare", str(remote))
    run(root, home, tools, "git", "clone", str(remote), str(writer))
    run(root, home, tools, "git", "config", "user.name", "RepHub 视觉验收", cwd=writer)
    run(root, home, tools, "git", "config", "user.email", "soft-surface@localhost", cwd=writer)

    files = {
        "src/main/java/com/rephub/net/HttpClient.java": "package com.rephub.net;\n\npublic final class HttpClient {\n    public String get(String path) { return path; }\n}\n",
        "src/main/java/com/rephub/net/RequestOptions.java": "package com.rephub.net;\n\npublic record RequestOptions(int timeoutSeconds) {}\n",
        "src/main/java/com/rephub/net/ResponseHandler.java": "package com.rephub.net;\n\npublic interface ResponseHandler {\n    void accept(int statusCode);\n}\n",
        "config/application.yml": "service:\n  name: soft-surface-fixture\n  timeout: 15\n",
        "docs/更新说明.md": "# 更新说明\n\n- 初始化本地界面验收数据。\n",
        "README.md": "# RepHub Soft Surface Fixture\n\n仅用于本地 Git/SVN 界面验收。\n",
    }
    for relative, content in files.items():
        write(root, writer / relative, content)
    base = datetime(2026, 10, 1, 9, 0, tzinfo=timezone(timedelta(hours=8)))
    git_commit(root, home, tools, writer, "chore: 初始化网络组件和说明文件", "建立用于工作区、提交历史与代码差异的本地夹具。", ("张一鸣", "zhangyiming@fixture.local"), base)
    run(root, home, tools, "git", "branch", "-M", "main", cwd=writer)

    authors = (("张一鸣", "zhangyiming@fixture.local"), ("李书文", "lishuwen@fixture.local"), ("陈晨", "chenchen@fixture.local"))
    for index in range(1, 7):
        write(root, writer / "docs" / "history" / f"第{index}次迭代.md", f"# 第 {index} 次迭代\n\n用于验证长提交说明与列表行距。\n")
        git_commit(
            root, home, tools, writer, f"feat(网络): 优化请求流程与历史阅读体验（第 {index} 次迭代）",
            "本次提交包含较长的中文说明，用于验证提交详情区域的段落层级、行高、换行和底部留白。\n\n"
            "验收时应能清楚区分标题、作者、提交时间、正文与文件列表，不让信息彼此挤压。",
            authors[index % len(authors)], base + timedelta(hours=index * 7),
        )

    run(root, home, tools, "git", "switch", "-c", "feature/soft-surface", cwd=writer)
    write(root, writer / "src/main/java/com/rephub/net/RequestOptions.java", "package com.rephub.net;\n\npublic record RequestOptions(int timeoutSeconds, boolean retryable) {}\n")
    git_commit(root, home, tools, writer, "feat: 为请求选项补充重试标记", "分支提交用于 Git 图和分支区展示。", authors[1], base + timedelta(days=3))
    write(root, writer / "docs" / "feature-notes.md", "# Soft Surface\n\n分支说明。\n")
    git_commit(root, home, tools, writer, "docs: 补充分支验收说明", "验证历史图中的分叉与合并。", authors[2], base + timedelta(days=3, hours=2))
    run(root, home, tools, "git", "switch", "main", cwd=writer)
    run(root, home, tools, "git", "merge", "--no-ff", "feature/soft-surface", "-m", "merge: 合并 soft surface 验收分支", cwd=writer)
    run(root, home, tools, "git", "switch", "-c", "hotfix/response-status", cwd=writer)
    write(root, writer / "src/main/java/com/rephub/net/ResponseHandler.java", "package com.rephub.net;\n\npublic interface ResponseHandler {\n    void accept(int statusCode);\n    default boolean successful(int code) { return code < 400; }\n}\n")
    git_commit(root, home, tools, writer, "fix: 标注响应状态判定", "第二条侧支用于验证图形连接线。", authors[0], base + timedelta(days=4))
    run(root, home, tools, "git", "switch", "main", cwd=writer)
    run(root, home, tools, "git", "merge", "--no-ff", "hotfix/response-status", "-m", "merge: 合并响应状态修复", cwd=writer)
    run(root, home, tools, "git", "push", "--all", "origin", cwd=writer)
    run(root, home, tools, "git", "--git-dir", str(remote), "symbolic-ref", "HEAD", "refs/heads/main")
    run(root, home, tools, "git", "clone", str(remote), str(workspace))
    run(root, home, tools, "git", "config", "user.name", "RepHub 本地验收", cwd=workspace)
    run(root, home, tools, "git", "config", "user.email", "workspace@fixture.local", cwd=workspace)

    changes = {
        "src/main/java/com/rephub/net/HttpClient.java": "package com.rephub.net;\n\npublic final class HttpClient {\n    public String get(String path) { return \"/api\" + path; }\n}\n",
        "src/main/java/com/rephub/net/RequestOptions.java": "package com.rephub.net;\n\npublic record RequestOptions(int timeoutSeconds, boolean retryable) {\n    public static RequestOptions standard() { return new RequestOptions(30, true); }\n}\n",
        "src/main/java/com/rephub/net/ResponseHandler.java": "package com.rephub.net;\n\npublic interface ResponseHandler {\n    void accept(int statusCode);\n    default boolean successful(int code) { return code < 300; }\n}\n",
        "config/application.yml": "service:\n  name: soft-surface-fixture\n  timeout: 30\n  retry: true\n",
        "docs/更新说明.md": "# 更新说明\n\n- 调整暖灰工作区的提交和文件详情留白。\n- 统一轻量状态色。\n",
        "README.md": "# RepHub Soft Surface Fixture\n\n仅用于本地 Git/SVN 界面验收。\n\n当前工作区含 6 个未提交修改。\n",
    }
    for relative, content in changes.items():
        write(root, workspace / relative, content)
    return workspace, remote.as_uri()


def svn_commit(root: Path, home: Path, tools: dict[str, str], cwd: Path, message: str, username: str) -> None:
    run(root, home, tools, "svn", "commit", "--username", username, "-m", message, cwd=cwd)


def create_svn(root: Path, home: Path, tools: dict[str, str]) -> tuple[Path, str, str]:
    repository = root / "remotes" / "soft-surface-svn"
    url = repository.as_uri()
    writer = root / "svn-writer"
    workspace = root / "svn-workspace"
    run(root, home, tools, "svnadmin", "create", str(repository))
    run(root, home, tools, "svn", "mkdir", "--username", "zhangyiming", "-m", "创建 trunk", f"{url}/trunk")
    run(root, home, tools, "svn", "checkout", f"{url}/trunk", str(writer))
    initial = {
        "src/main/java/com/rephub/net/HttpClient.java": "package com.rephub.net;\npublic final class HttpClient {}\n",
        "src/main/java/com/rephub/net/RequestOptions.java": "package com.rephub.net;\npublic record RequestOptions(int seconds) {}\n",
        "src/main/java/com/rephub/net/ResponseHandler.java": "package com.rephub.net;\npublic interface ResponseHandler {}\n",
        "config/application.yml": "service:\n  name: soft-surface-svn\n",
        "docs/更新说明.md": "# 更新说明\n\nSVN 初始版本。\n",
        "README.md": "# Soft Surface SVN\n",
    }
    for relative, content in initial.items():
        write(root, writer / relative, content)
    run(root, home, tools, "svn", "add", "src", "config", "docs", "README.md", cwd=writer)
    svn_commit(root, home, tools, writer, "初始化多层源码、配置和说明文件", "zhangyiming")
    for index, author in enumerate(("lianglihui", "zhangyiming", "libowen", "zhangyiming"), start=1):
        write(root, writer / "docs" / "history" / f"修订-{index}.md", f"# SVN 修订 {index}\n\n用于浏览远程目录的修订编号、作者与日期。\n")
        run(root, home, tools, "svn", "add", "--parents", f"docs/history/修订-{index}.md", cwd=writer)
        svn_commit(root, home, tools, writer, f"补充远程目录浏览说明（修订 {index}）", author)
    write(root, writer / "config" / "application.yml", "service:\n  name: soft-surface-svn\n  preview: enabled\n")
    svn_commit(root, home, tools, writer, "启用远程浏览预览配置", "zhangyiming")
    run(root, home, tools, "svn", "checkout", f"{url}/trunk", str(workspace))
    write(root, workspace / "src/main/java/com/rephub/net/HttpClient.java", "package com.rephub.net;\npublic final class HttpClient { String base = \"/api\"; }\n")
    write(root, workspace / "docs/更新说明.md", "# 更新说明\n\nSVN 工作区的未提交变更。\n")
    return workspace, f"{url}/trunk", f"{url}/trunk/src/main/java/com/rephub/net"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, help="可选，必须是 /private/tmp/RepHub-SoftSurface-<uuid> 下的新目录")
    args = parser.parse_args()
    tools = {name: tool(name) for name in ("git", "svn", "svnadmin")}
    root = (args.root or PARENT / f"{PREFIX}{uuid.uuid4()}").resolve()
    if root.parent != PARENT or not root.name.startswith(PREFIX):
        raise RuntimeError(f"测试根目录必须位于 {PARENT}/{PREFIX}<uuid>")
    if root.exists():
        raise RuntimeError(f"拒绝覆盖已有测试目录：{root}")
    root.mkdir(mode=0o700)
    home = root / "home"
    (home / ".config").mkdir(parents=True, mode=0o700)
    (home / ".subversion").mkdir(mode=0o700)
    (root / "remotes").mkdir(mode=0o700)

    git_workspace, git_remote = create_git(root, home, tools)
    svn_workspace, svn_trunk, svn_network_directory = create_svn(root, home, tools)
    manifest = {
        "root": str(root),
        "safety": "仅本机临时目录、本地 bare Git 与 file:// SVN；无网络、无业务仓库、无个人认证。",
        "git_workspace": str(git_workspace),
        "git_remote": git_remote,
        "git_expected_worktree_changes": [
            "src/main/java/com/rephub/net/HttpClient.java", "src/main/java/com/rephub/net/RequestOptions.java",
            "src/main/java/com/rephub/net/ResponseHandler.java", "config/application.yml", "docs/更新说明.md", "README.md",
        ],
        "git_graph_branches": ["main", "feature/soft-surface", "hotfix/response-status"],
        "svn_workspace": str(svn_workspace),
        "svn_trunk_url": svn_trunk,
        "svn_network_directory_url": svn_network_directory,
        "svn_checkout_suggestion": str(root / "svn-subdirectory-checkout"),
        "svn_expected_revision_at_least": 7,
        "interactions": [
            "打开 Git 工作副本：工作区应显示 6 个未提交变更，历史页应显示分支图与长中文提交说明。",
            "打开 SVN 工作副本：工作区应显示两处未提交变更；历史和文件树使用真实 file:// 修订。",
            "远程 SVN 浏览输入 svn_trunk_url，展开 src/main/java/com/rephub/net；可选择该目录检出到 svn_checkout_suggestion。",
        ],
    }
    path = root / "manifest.json"
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        print(f"fixture creation failed: {error}", file=os.sys.stderr)
        raise SystemExit(1)
