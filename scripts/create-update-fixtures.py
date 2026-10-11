#!/usr/bin/env python3
"""建立 RepHub 更新功能的本地隔离 Git/SVN 验收夹具。

不访问网络，不读取业务仓库；所有远端、工作副本和 HOME 都位于
build/update-fixtures/<uuid>。脚本不会删除任何已有目录。
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_PARENT = PROJECT / "build" / "update-fixtures"


def ensure_inside(root: Path, target: Path) -> Path:
    resolved = target.resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as error:
        raise RuntimeError(f"测试操作越出隔离根目录：{target}") from error
    return resolved


def command(root: Path, home: Path, *args: str, cwd: Path | None = None) -> None:
    for arg in args:
        if arg.startswith("/"):
            ensure_inside(root, Path(arg))
        if "://" in arg and not arg.startswith("file://"):
            raise RuntimeError(f"拒绝非本地远端：{arg}")
        if arg.startswith("file://"):
            ensure_inside(root, Path(arg.removeprefix("file://")))
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
    path.write_text(text, encoding="utf-8")


def git_config(root: Path, home: Path, checkout: Path) -> None:
    command(root, home, "git", "config", "user.name", "RepHub Fixture", cwd=checkout)
    command(root, home, "git", "config", "user.email", "fixture@localhost", cwd=checkout)


def git_pair(root: Path, home: Path, name: str) -> tuple[Path, Path]:
    remote = root / "remotes" / f"{name}.git"
    source = root / f"{name}-source"
    target = root / name
    command(root, home, "git", "init", "--bare", str(remote))
    command(root, home, "git", "clone", str(remote), str(source))
    git_config(root, home, source)
    write(root, source / "README.md", f"{name} fixture initial\n")
    command(root, home, "git", "add", "README.md", cwd=source)
    command(root, home, "git", "commit", "-m", "fixture initial", cwd=source)
    command(root, home, "git", "branch", "-M", "main", cwd=source)
    command(root, home, "git", "push", "-u", "origin", "main", cwd=source)
    command(root, home, "git", "clone", str(remote), str(target))
    command(root, home, "git", "checkout", "main", cwd=target)
    git_config(root, home, target)
    return source, target


def svn_pair(root: Path, home: Path, name: str) -> tuple[Path, Path, str]:
    repository = root / "remotes" / name
    source = root / f"{name}-source"
    target = root / name
    url = repository.as_uri()
    command(root, home, "svnadmin", "create", str(repository))
    command(root, home, "svn", "mkdir", "-m", "fixture create trunk", f"{url}/trunk")
    command(root, home, "svn", "checkout", f"{url}/trunk", str(source))
    write(root, source / "README.md", f"{name} fixture initial\n")
    command(root, home, "svn", "add", "README.md", cwd=source)
    command(root, home, "svn", "commit", "-m", "fixture initial", cwd=source)
    command(root, home, "svn", "checkout", f"{url}/trunk", str(target))
    return source, target, url


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, help="必须位于 build/update-fixtures 下且不存在")
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

    git_source, git_target = git_pair(root, home, "git-update")
    write(root, git_source / "remote-change.txt", "remote update only\n")
    command(root, home, "git", "add", "remote-change.txt", cwd=git_source)
    command(root, home, "git", "commit", "-m", "fixture remote update", cwd=git_source)
    command(root, home, "git", "push", cwd=git_source)

    dirty_source, dirty_target = git_pair(root, home, "git-dirty")
    write(root, dirty_source / "remote-change.txt", "remote update while target is dirty\n")
    command(root, home, "git", "add", "remote-change.txt", cwd=dirty_source)
    command(root, home, "git", "commit", "-m", "fixture remote update", cwd=dirty_source)
    command(root, home, "git", "push", cwd=dirty_source)
    write(root, dirty_target / "README.md", "local uncommitted change\n")

    diverged_source, diverged_target = git_pair(root, home, "git-diverged")
    write(root, diverged_source / "remote-change.txt", "remote branch change\n")
    command(root, home, "git", "add", "remote-change.txt", cwd=diverged_source)
    command(root, home, "git", "commit", "-m", "fixture remote branch", cwd=diverged_source)
    command(root, home, "git", "push", cwd=diverged_source)
    write(root, diverged_target / "local-change.txt", "local branch change\n")
    command(root, home, "git", "add", "local-change.txt", cwd=diverged_target)
    command(root, home, "git", "commit", "-m", "fixture local branch", cwd=diverged_target)

    svn_source, svn_target, _ = svn_pair(root, home, "svn-update")
    write(root, svn_source / "remote-change.txt", "remote svn update only\n")
    command(root, home, "svn", "add", "remote-change.txt", cwd=svn_source)
    command(root, home, "svn", "commit", "-m", "fixture remote update", cwd=svn_source)

    conflict_source, conflict_target, _ = svn_pair(root, home, "svn-conflict")
    write(root, conflict_source / "README.md", "remote change\n")
    command(root, home, "svn", "commit", "-m", "fixture remote conflict", cwd=conflict_source)
    write(root, conflict_target / "README.md", "local conflicting change\n")

    dual_source, dual_target, dual_svn_url = svn_pair(root, home, "dual")
    dual_remote = root / "remotes" / "dual-git.git"
    command(root, home, "git", "init", "--bare", str(dual_remote))
    command(root, home, "git", "init", cwd=dual_target)
    git_config(root, home, dual_target)
    command(root, home, "git", "add", "README.md", cwd=dual_target)
    command(root, home, "git", "commit", "-m", "fixture initial", cwd=dual_target)
    command(root, home, "git", "branch", "-M", "main", cwd=dual_target)
    command(root, home, "git", "remote", "add", "origin", str(dual_remote), cwd=dual_target)
    command(root, home, "git", "push", "-u", "origin", "main", cwd=dual_target)
    dual_git_source = root / "dual-git-source"
    command(root, home, "git", "clone", str(dual_remote), str(dual_git_source))
    command(root, home, "git", "checkout", "main", cwd=dual_git_source)
    git_config(root, home, dual_git_source)
    write(root, dual_git_source / "git-only.txt", "git remote update\n")
    command(root, home, "git", "add", "git-only.txt", cwd=dual_git_source)
    command(root, home, "git", "commit", "-m", "fixture git update", cwd=dual_git_source)
    command(root, home, "git", "push", cwd=dual_git_source)
    write(root, dual_source / "svn-only.txt", "svn remote update\n")
    command(root, home, "svn", "add", "svn-only.txt", cwd=dual_source)
    command(root, home, "svn", "commit", "-m", "fixture svn update", cwd=dual_source)

    write(root, root / "README.txt", "\n".join((
        "RepHub local update fixtures. No business repositories or network remotes are used.",
        f"git-update={git_target}",
        f"git-dirty={dirty_target}",
        f"git-diverged={diverged_target}",
        f"svn-update={svn_target}",
        f"svn-conflict={conflict_target}",
        f"dual={dual_target}",
        f"dual-svn={dual_svn_url}",
        "",
    )))
    print(root)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"fixture creation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
