#!/usr/bin/env python3
"""创建 SVN→Git 迁移的本地原生界面验收夹具，并输出 JSON 清单。

所有仓库均创建在系统临时目录：SVN 来源是 file:// 本地仓库，Git 目标是空裸仓库。
脚本不读取业务仓库、不会访问网络，也不删除已有目录。输出的 root 可在验收结束后手动删除。
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path


def main() -> int:
    for tool in ("svn", "svnadmin", "git"):
        if shutil.which(tool) is None:
            raise RuntimeError(f"缺少本地测试工具：{tool}")

    root = Path(tempfile.gettempdir(), f"RepHub-Migration-QA-{uuid.uuid4()}").resolve()
    root.mkdir(mode=0o700)
    home = root / "home"
    (home / ".config").mkdir(parents=True, mode=0o700)
    environment = {
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"),
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/usr/bin/false",
        "LC_ALL": "en_US.UTF-8",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }

    def require_inside(path: Path) -> None:
        path.resolve().relative_to(root)

    def run(*arguments: str, cwd: Path | None = None) -> str:
        if cwd is not None:
            require_inside(cwd)
        for argument in arguments:
            if argument.startswith("/"):
                require_inside(Path(argument))
            if "://" in argument and not argument.startswith("file://"):
                raise RuntimeError(f"拒绝非本地远端：{argument}")
            if argument.startswith("file://"):
                require_inside(Path(argument.removeprefix("file://")))
        completed = subprocess.run(
            arguments, cwd=cwd or root, env=environment, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, check=False,
        )
        if completed.returncode:
            raise RuntimeError(completed.stderr.strip() or completed.stdout.strip() or "命令执行失败")
        return completed.stdout.strip()

    svn_repository = root / "source-svn"
    svn_working_copy = root / "source-svn-working-copy"
    git_remote = root / "target-empty.git"
    migration_parent = root / "migration-results"
    migration_destination = migration_parent / "migrated-from-svn"
    run("svnadmin", "create", str(svn_repository))
    svn_root = svn_repository.as_uri()
    run("svn", "mkdir", "-m", "create trunk", f"{svn_root}/trunk")
    run("svn", "checkout", f"{svn_root}/trunk", str(svn_working_copy))

    module = svn_working_copy / "迁移模块"
    documents = module / "文档"
    empty_directory = module / "空目录"
    documents.mkdir(parents=True)
    empty_directory.mkdir()
    (documents / "说明.md").write_text("第一版：中文文件。\n", encoding="utf-8")
    (module / "已删除.txt").write_text("随后会删除。\n", encoding="utf-8")
    (module / "保留但忽略.local").write_text("已受 SVN 管理，但匹配忽略规则。\n", encoding="utf-8")
    (module / ".gitignore").write_text("*.local\n", encoding="utf-8")
    (module / "二进制数据.bin").write_bytes(bytes((0, 1, 2, 0, 255, 127)))
    run("svn", "add", "迁移模块", cwd=svn_working_copy)
    run("svn", "propset", "svn:ignore", "*.local", "迁移模块", cwd=svn_working_copy)
    run("svn", "commit", "--username", "迁移作者甲", "-m", "创建迁移模块", cwd=svn_working_copy)

    (documents / "说明.md").write_text("第二版：中文文件仍可读取。\n", encoding="utf-8")
    run("svn", "delete", "已删除.txt", cwd=module)
    run("svn", "commit", "--username", "迁移作者乙", "-m", "删除旧文件并更新中文说明", cwd=svn_working_copy)

    (module / "二进制数据.bin").write_bytes(bytes((0, 9, 8, 0, 254, 126)))
    run("svn", "commit", "--username", "迁移作者甲", "-m", "更新二进制内容", cwd=svn_working_copy)
    run("git", "init", "--bare", str(git_remote))
    migration_parent.mkdir()

    manifest = {
        "root": str(root),
        "sourceSVNModuleURL": f"{svn_root}/trunk/%E8%BF%81%E7%A7%BB%E6%A8%A1%E5%9D%97",
        "sourceSVNWorkingCopy": str(svn_working_copy),
        "targetEmptyGitURL": git_remote.as_uri(),
        "migrationParent": str(migration_parent),
        "suggestedDestination": str(migration_destination),
        "mode": "history",
        "branch": "main",
        "expected": {
            "historyMessages": ["创建迁移模块", "删除旧文件并更新中文说明", "更新二进制内容"],
            "presentFiles": ["文档/说明.md", "保留但忽略.local", ".gitignore", "二进制数据.bin"],
            "deletedFile": "已删除.txt",
            "omittedGitDirectory": "空目录",
            "previewBeforePublishHasNoRemoteRefs": True,
        },
    }
    manifest_path = root / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"fixture creation failed: {error}", file=os.sys.stderr)
        raise SystemExit(1)
