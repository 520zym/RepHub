#!/usr/bin/env python3
"""建立 RepHub 历史与同步状态的本地隔离验收夹具。

所有 Git 远端和 SVN 仓库均为系统临时目录中的本地 bare/file:// 仓库；
不会读取业务仓库、访问网络、继承个人认证或代理配置，也不会覆盖已有目录。
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path


DEFAULT_PARENT = Path(tempfile.gettempdir()) / "RepHub-HistoryFixtures"


def ensure_inside(root: Path, target: Path) -> Path:
    resolved = target.resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as error:
        raise RuntimeError(f"测试操作越出隔离根目录：{target}") from error
    return resolved


def command(root: Path, home: Path, *args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
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
    return subprocess.run(args, cwd=cwd, env=env, check=True, stdin=subprocess.DEVNULL, text=True)


def write(root: Path, path: Path, text: str) -> None:
    ensure_inside(root, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def configure_git(root: Path, home: Path, checkout: Path) -> None:
    command(root, home, "git", "config", "user.name", "RepHub History Fixture", cwd=checkout)
    command(root, home, "git", "config", "user.email", "history-fixture@localhost", cwd=checkout)


def create_git_history(root: Path, home: Path) -> tuple[Path, Path]:
    remote = root / "remotes" / "git-history.git"
    writer = root / "git-history-writer"
    reader = root / "git-history"
    command(root, home, "git", "init", "--bare", str(remote))
    command(root, home, "git", "clone", str(remote), str(writer))
    configure_git(root, home, writer)

    original = writer / "中文 目录" / "初始 文件.txt"
    renamed = writer / "中文 目录" / "重命名 后.txt"
    write(root, original, "第一版\n")
    command(root, home, "git", "add", "--", original.relative_to(writer).as_posix(), cwd=writer)
    command(root, home, "git", "commit", "-m", "添加中文空格文件", cwd=writer)
    command(root, home, "git", "branch", "-M", "main", cwd=writer)
    command(root, home, "git", "mv", "--", original.relative_to(writer).as_posix(), renamed.relative_to(writer).as_posix(), cwd=writer)
    command(root, home, "git", "commit", "-m", "重命名中文空格文件", cwd=writer)
    write(root, renamed, "第一版\n第三版编辑\n")
    command(root, home, "git", "add", "--", renamed.relative_to(writer).as_posix(), cwd=writer)
    command(root, home, "git", "commit", "-m", "再次编辑重命名文件", cwd=writer)
    command(root, home, "git", "push", "-u", "origin", "main", cwd=writer)
    command(root, home, "git", "--git-dir", str(remote), "symbolic-ref", "HEAD", "refs/heads/main")

    command(root, home, "git", "clone", str(remote), str(reader))
    configure_git(root, home, reader)
    write(root, reader / "reader-local.txt", "仅本地提交，不能推送\n")
    command(root, home, "git", "add", "reader-local.txt", cwd=reader)
    command(root, home, "git", "commit", "-m", "reader local only", cwd=reader)

    write(root, writer / "writer-remote.txt", "远端新增，reader 已获取但未合并\n")
    command(root, home, "git", "add", "writer-remote.txt", cwd=writer)
    command(root, home, "git", "commit", "-m", "writer remote only", cwd=writer)
    command(root, home, "git", "push", cwd=writer)
    command(root, home, "git", "fetch", "origin", cwd=reader)

    command(root, home, "git", "switch", "-c", "unrelated", cwd=writer)
    write(root, writer / "unrelated-branch.txt", "此提交不应计入 main 同步徽标\n")
    command(root, home, "git", "add", "unrelated-branch.txt", cwd=writer)
    command(root, home, "git", "commit", "-m", "unrelated branch", cwd=writer)
    command(root, home, "git", "push", "-u", "origin", "unrelated", cwd=writer)
    command(root, home, "git", "fetch", "origin", cwd=reader)
    return reader, writer


def create_svn_history(root: Path, home: Path) -> tuple[Path, Path, Path, str]:
    repository = root / "remotes" / "svn-history"
    writer = root / "svn-history-writer"
    reader = root / "svn-history"
    mixed = root / "svn-mixed"
    url = repository.as_uri()
    command(root, home, "svnadmin", "create", str(repository))
    command(root, home, "svn", "mkdir", "-m", "create trunk", f"{url}/trunk")
    command(root, home, "svn", "checkout", f"{url}/trunk", str(writer))

    original = writer / "中文 空格" / "初始文件 @"
    renamed = writer / "中文 空格" / "重命名文件 @"
    write(root, original, "第一版\n")
    command(root, home, "svn", "add", "中文 空格", cwd=writer)
    # 无扩展名且含末尾 @ 的文本文件会被 Subversion 自动识别为二进制；
    # 用额外 @ 转义 peg 分隔符，确保后续移动历史与差异都是文本。
    command(root, home, "svn", "propset", "svn:mime-type", "text/plain", "中文 空格/初始文件 @@", cwd=writer)
    command(root, home, "svn", "commit", "-m", "添加中文空格@文件", cwd=writer)
    # 源路径以额外的 @ 转义其末尾的真实 @；目标路径保留真实文件名，
    # 避免对 destination 盲目追加 peg revision 分隔符。
    source_for_peg = original.relative_to(writer).as_posix() + "@"
    destination = renamed.relative_to(writer).as_posix()
    command(root, home, "svn", "move", source_for_peg, destination, cwd=writer)
    command(root, home, "svn", "commit", "-m", "移动中文空格@文件", cwd=writer)
    write(root, renamed, "第一版\n第三版编辑\n")
    command(root, home, "svn", "commit", "-m", "再次编辑移动文件", cwd=writer)

    command(root, home, "svn", "checkout", f"{url}/trunk", str(reader))
    # 当前修订依次为：mkdir r1、add r2、move r3、edit r4。旧工作副本随后只更新一个文件。
    command(root, home, "svn", "checkout", "-r", "4", f"{url}/trunk", str(mixed))
    write(root, renamed, "第一版\n第三版编辑\n远端第五版\n")
    command(root, home, "svn", "commit", "-m", "writer remote only", cwd=writer)
    # `svn update` 的单一路径参数会把末尾 @ 解释为 peg 分隔符，需要再加 @；
    # 这与上面的 `svn move` destination 语义不同。
    command(root, home, "svn", "update", destination + "@", cwd=mixed)
    return reader, writer, mixed, url


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, help="必须位于系统临时目录 RepHub-HistoryFixtures 下且不存在")
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

    git_reader, _ = create_git_history(root, home)
    svn_reader, _, mixed, svn_url = create_svn_history(root, home)
    write(root, root / "README.txt", "\n".join((
        "RepHub local history fixtures. No business repositories or network remotes are used.",
        f"git-history={git_reader}",
        "git-history expected main synchronization: ahead 1, behind 1; unrelated branch excluded.",
        f"svn-history={svn_reader}",
        "svn-history expected: reader is behind one revision after add, move, and edit history.",
        f"svn-mixed={mixed}",
        "svn-mixed expected: working copy root is r4 while one renamed file is r5.",
        f"svn-url={svn_url}/trunk",
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
