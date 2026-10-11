#!/usr/bin/env python3
"""创建 RepHub 提交功能的本地隔离 Git + SVN 共管验收夹具。

所有工作副本、Git bare 远端、SVN file:// 仓库和工具配置都在 /tmp 下的新目录中。
脚本不读取业务仓库、不访问网络，也不会覆盖已有目录。
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path


SAFE_PARENT = Path("/tmp").resolve()


def ensure_inside(root: Path, target: Path, *, including_root: bool = False) -> Path:
    resolved = target.resolve()
    root_resolved = root.resolve()
    if resolved != root_resolved or not including_root:
        try:
            resolved.relative_to(root_resolved)
        except ValueError as error:
            raise RuntimeError(f"测试操作越出隔离根目录：{target}") from error
    return resolved


def find_tool(name: str) -> str:
    """优先选 Homebrew 安装的 Subversion，再回退 PATH 中的可用工具。"""
    candidates: list[Path] = []
    if name in {"svn", "svnadmin"}:
        candidates.extend((Path("/opt/homebrew/bin") / name, Path("/usr/local/bin") / name))
    found = shutil.which(name)
    if found:
        candidates.append(Path(found))
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    raise RuntimeError(f"缺少本地测试工具：{name}")


def isolated_environment(home: Path) -> dict[str, str]:
    return {
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


def command(
    root: Path,
    home: Path,
    tools: dict[str, str],
    executable: str,
    *arguments: str,
    cwd: Path | None = None,
) -> None:
    if cwd is not None:
        ensure_inside(root, cwd, including_root=True)
    for argument in arguments:
        if argument.startswith("/"):
            ensure_inside(root, Path(argument), including_root=True)
        if "://" in argument and not argument.startswith("file://"):
            raise RuntimeError(f"拒绝非本地远端：{argument}")
        if argument.startswith("file://"):
            ensure_inside(root, Path(argument.removeprefix("file://")), including_root=True)

    invocation = [tools[executable]]
    # 显式隔离 SVN 的认证/服务器配置，避免意外读取用户的 ~/.subversion。
    if executable == "svn":
        invocation.extend(("--config-dir", str(home / ".subversion")))
    invocation.extend(arguments)
    subprocess.run(
        invocation,
        cwd=cwd,
        env=isolated_environment(home),
        check=True,
        stdin=subprocess.DEVNULL,
    )


def write(root: Path, path: Path, content: str) -> None:
    ensure_inside(root, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def configure_git(root: Path, home: Path, tools: dict[str, str], workspace: Path) -> None:
    command(root, home, tools, "git", "config", "user.name", "RepHub Commit Fixture", cwd=workspace)
    command(root, home, tools, "git", "config", "user.email", "fixture@localhost", cwd=workspace)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        help="可选；必须是 /tmp 直属、名称以 RepHub-CommitFixture- 开头且尚不存在的目录",
    )
    args = parser.parse_args()

    tools = {name: find_tool(name) for name in ("git", "svn", "svnadmin")}
    root = (args.root or SAFE_PARENT / f"RepHub-CommitFixture-{uuid.uuid4()}").resolve()
    if root.parent != SAFE_PARENT or not root.name.startswith("RepHub-CommitFixture-"):
        raise RuntimeError(f"测试根目录必须是 {SAFE_PARENT}/RepHub-CommitFixture-<uuid>")
    if root.exists():
        raise RuntimeError(f"拒绝覆盖已有测试设施：{root}")

    root.mkdir(mode=0o700)
    home = root / "home"
    (home / ".config").mkdir(parents=True, mode=0o700)
    (home / ".subversion").mkdir(mode=0o700)
    remotes = root / "remotes"
    remotes.mkdir(mode=0o700)

    svn_repository = remotes / "commit-svn"
    svn_url = svn_repository.as_uri()
    svn_writer = root / "svn-writer"
    workspace = root / "workspace"
    git_remote = remotes / "commit-git.git"

    # SVN 先形成两段历史；随后 checkout 的 workspace 是 Git/SVN 同一工作树。
    command(root, home, tools, "svnadmin", "create", str(svn_repository))
    command(root, home, tools, "svn", "mkdir", "-m", "fixture create trunk", f"{svn_url}/trunk")
    command(root, home, tools, "svn", "checkout", f"{svn_url}/trunk", str(svn_writer))
    write(root, svn_writer / "README.md", "RepHub commit fixture baseline\n")
    write(root, svn_writer / "Sources" / "Main.swift", "enum Fixture { static let version = 1 }\n")
    write(root, svn_writer / "docs" / "Guide.md", "# Guide\n\nBaseline guide.\n")
    write(root, svn_writer / "StagedKeep.md", "This tracked file must remain staged in Git.\n")
    # 让双管理目录的两个元数据目录不污染另一侧的状态列表。
    write(root, svn_writer / ".gitignore", ".svn/\n")
    command(root, home, tools, "svn", "propset", "svn:ignore", ".git", ".", cwd=svn_writer)
    command(root, home, tools, "svn", "add", "README.md", "Sources", "docs", "StagedKeep.md", ".gitignore", cwd=svn_writer)
    command(root, home, tools, "svn", "commit", "-m", "fixture svn baseline", cwd=svn_writer)
    write(root, svn_writer / "docs" / "Guide.md", "# Guide\n\nBaseline guide, SVN revision two.\n")
    command(root, home, tools, "svn", "commit", "-m", "fixture svn guide history", "docs/Guide.md", cwd=svn_writer)
    command(root, home, tools, "svn", "checkout", f"{svn_url}/trunk", str(workspace))

    # 以同一目录建立独立 Git 远端，并形成第二段 Git 历史。
    command(root, home, tools, "git", "init", "--bare", str(git_remote))
    command(root, home, tools, "git", "init", cwd=workspace)
    configure_git(root, home, tools, workspace)
    command(root, home, tools, "git", "add", "--", ".gitignore", "README.md", "Sources/Main.swift", "docs/Guide.md", "StagedKeep.md", cwd=workspace)
    command(root, home, tools, "git", "commit", "-m", "fixture git baseline", cwd=workspace)
    command(root, home, tools, "git", "branch", "-M", "main", cwd=workspace)
    command(root, home, tools, "git", "remote", "add", "origin", str(git_remote), cwd=workspace)
    command(root, home, tools, "git", "push", "-u", "origin", "main", cwd=workspace)
    write(root, workspace / "README.md", "RepHub commit fixture Git second history.\n")
    command(root, home, tools, "git", "add", "--", "README.md", cwd=workspace)
    command(root, home, tools, "git", "commit", "-m", "fixture git second history", cwd=workspace)
    command(root, home, tools, "git", "push", cwd=workspace)

    # 待提交的公共改动；StagedKeep 预先仅 Git 暂存，用来验收未选择文件不会被带入提交。
    write(root, workspace / "README.md", "RepHub commit fixture: selected shared change.\n")
    write(root, workspace / "Sources" / "Main.swift", "enum Fixture { static let version = 2 }\n")
    write(root, workspace / "docs" / "Guide.md", "# Guide\n\nWorking tree change for Git and SVN.\n")
    write(root, workspace / "docs" / "NewDraft.md", "Untracked draft selected only when the user chooses it.\n")
    write(root, workspace / "StagedKeep.md", "This tracked file must remain staged in Git after committing README.md.\n")
    command(root, home, tools, "git", "add", "--", "StagedKeep.md", cwd=workspace)

    readme = root / "README.txt"
    write(root, readme, "\n".join((
        "RepHub isolated commit fixture. It uses only local Git bare and SVN file:// repositories.",
        f"root={root}",
        f"workspace={workspace}",
        f"git-remote={git_remote}",
        f"svn-url={svn_url}/trunk",
        "",
        "Suggested verification (run from workspace):",
        "git status --short",
        "svn status",
        "git log --oneline -2",
        "svn log -l 2",
        "# After selecting and committing only README.md in Git, this must still show StagedKeep.md:",
        "git diff --cached --name-only -- StagedKeep.md",
        "# Confirm the selected Git commit has no unselected file:",
        "git show --format= --name-only HEAD",
        "# Confirm an SVN commit by the client reached only this local fixture:",
        f"svn log -l 1 {svn_url}/trunk",
        "",
    )))
    print(f"root={root}")
    print(f"workspace={workspace}")
    print(f"git-remote={git_remote}")
    print(f"svn-url={svn_url}/trunk")
    print(f"verification={readme}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"fixture creation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
