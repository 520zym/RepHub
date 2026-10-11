#!/usr/bin/env python3
"""建立 RepHub 文件树和大工作区差异的本地隔离验收夹具。"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path


DEFAULT_PARENT = Path(tempfile.gettempdir()) / "RepHub-TreeFixtures"


def ensure_inside(root: Path, target: Path) -> None:
    try:
        target.resolve().relative_to(root.resolve())
    except ValueError as error:
        raise RuntimeError(f"测试操作越出隔离根目录：{target}") from error


def command(root: Path, home: Path, *args: str, cwd: Path | None = None) -> None:
    for argument in args:
        if argument.startswith("/"):
            ensure_inside(root, Path(argument))
        if "://" in argument and not argument.startswith("file://"):
            raise RuntimeError(f"拒绝非本地远端：{argument}")
        if argument.startswith("file://"):
            ensure_inside(root, Path(argument.removeprefix("file://")))
    if cwd is not None:
        ensure_inside(root, cwd)
    env = {
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
    subprocess.run(args, cwd=cwd, env=env, check=True, stdin=subprocess.DEVNULL)


def write(root: Path, path: Path, text: str) -> None:
    ensure_inside(root, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def configure_git(root: Path, home: Path, checkout: Path) -> None:
    command(root, home, "git", "config", "user.name", "RepHub Tree Fixture", cwd=checkout)
    command(root, home, "git", "config", "user.email", "tree-fixture@localhost", cwd=checkout)


def create_git_tree(root: Path, home: Path) -> Path:
    remote = root / "remotes" / "tree.git"
    writer = root / "git-tree-writer"
    reader = root / "git-tree"
    command(root, home, "git", "init", "--bare", str(remote))
    command(root, home, "git", "clone", str(remote), str(writer))
    configure_git(root, home, writer)
    write(root, writer / "LICENSE", "RepHub tree fixture license\n")
    write(root, writer / ".hidden", "隐藏文件仍应显示\n")
    write(root, writer / "长行UTF8.txt", "温润的文件树预览。" * 1800)
    write(root, writer / "Sources" / "App" / "Main.swift", "enum Main { static let version = 1 }\n")
    write(root, writer / "Sources" / "Core" / "Rules.swift", "enum Rules { static let enabled = true }\n")
    write(root, writer / "docs" / "manual" / "Guide.md", "# Guide\n")
    write(root, writer / "large-change.txt", "")
    command(root, home, "git", "add", "--all", cwd=writer)
    command(root, home, "git", "commit", "-m", "tree fixture initial", cwd=writer)
    command(root, home, "git", "branch", "-M", "main", cwd=writer)

    write(root, writer / "Sources" / "App" / "Main.swift", "enum Main { static let version = 2 }\n")
    write(root, writer / "Sources" / "Core" / "Rules.swift", "enum Rules { static let enabled = false }\n")
    write(root, writer / "docs" / "manual" / "Guide.md", "# Guide\n\n跨目录提交。\n")
    command(root, home, "git", "add", "Sources/App/Main.swift", "Sources/Core/Rules.swift", "docs/manual/Guide.md", cwd=writer)
    command(root, home, "git", "commit", "-m", "cross path fixture change", cwd=writer)
    command(root, home, "git", "push", "-u", "origin", "main", cwd=writer)
    command(root, home, "git", "--git-dir", str(remote), "symbolic-ref", "HEAD", "refs/heads/main")

    for branch in ("feature/flight/one", "feature/flight/two", "fix/api/login", "fix/api/payment", "release/2026.10"):
        command(root, home, "git", "switch", "main", cwd=writer)
        command(root, home, "git", "switch", "-c", branch, cwd=writer)
        command(root, home, "git", "push", "-u", "origin", branch, cwd=writer)
    command(root, home, "git", "switch", "main", cwd=writer)

    command(root, home, "git", "clone", str(remote), str(reader))
    configure_git(root, home, reader)
    (reader / "empty-directory").mkdir()
    write(root, reader / "Sources" / "App" / "Main.swift", "enum Main { static let version = 2; static let local = true }\n")
    write(root, reader / "local-untracked.txt", "未跟踪文件\n")
    write(root, reader / "large-change.txt", "".join(f"新增差异行 {line:05d}\n" for line in range(1, 10_001)))
    return reader


def create_svn_tree(root: Path, home: Path) -> Path:
    repository = root / "remotes" / "tree-svn"
    seed = root / "svn-tree-seed"
    checkout = root / "svn-tree"
    url = repository.as_uri()
    command(root, home, "svnadmin", "create", str(repository))
    command(root, home, "svn", "mkdir", "-m", "tree fixture trunk", f"{url}/trunk")
    command(root, home, "svn", "checkout", f"{url}/trunk", str(seed))
    write(root, seed / "Sources" / "App" / "Main.swift", "final class Main {}\n")
    write(root, seed / "docs" / "manual" / "Guide.md", "# SVN Guide\n")
    write(root, seed / ".hidden", "SVN 隐藏文件\n")
    (seed / "empty-directory").mkdir()
    command(root, home, "svn", "add", "Sources", "docs", ".hidden", "empty-directory", cwd=seed)
    command(root, home, "svn", "commit", "-m", "tree fixture initial", cwd=seed)
    command(root, home, "svn", "checkout", f"{url}/trunk", str(checkout))
    return checkout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, help="必须位于系统临时目录 RepHub-TreeFixtures 下且不存在")
    args = parser.parse_args()
    for tool in ("git", "svn", "svnadmin"):
        if shutil.which(tool) is None:
            raise RuntimeError(f"缺少本地测试工具：{tool}")
    root = (args.root or DEFAULT_PARENT / str(uuid.uuid4())).resolve()
    parent = DEFAULT_PARENT.resolve()
    try:
        root.relative_to(parent)
    except ValueError as error:
        raise RuntimeError(f"测试根目录必须位于 {parent}") from error
    if root.exists():
        raise RuntimeError(f"拒绝覆盖已有测试设施：{root}")
    root.mkdir(parents=True, mode=0o700)
    home = root / "home"
    (home / ".config").mkdir(parents=True, mode=0o700)
    (root / "remotes").mkdir(mode=0o700)
    git_tree = create_git_tree(root, home)
    svn_tree = create_svn_tree(root, home)
    write(root, root / "README.txt", "\n".join((
        "RepHub local tree fixtures. No business repositories or network remotes are used.",
        f"git-tree={git_tree}",
        "git-tree contains nested local/remote branches, hidden files, an empty directory, and a 10000-line worktree diff.",
        f"svn-tree={svn_tree}",
        "",
    )))
    print(root)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"fixture creation failed: {error}", file=os.sys.stderr)
        raise SystemExit(1)
