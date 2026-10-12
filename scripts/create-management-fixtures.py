#!/usr/bin/env python3
"""创建初始化、推送、分支、暂存、冲突与关联目录的全本地验收样本。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    root = Path(tempfile.mkdtemp(prefix="RepHub-Management-QA-"))
    home = root / "home"
    home.mkdir()
    env = {**os.environ, "HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"),
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"),
           "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false", "LC_ALL": "en_US.UTF-8"}
    svn = shutil.which("svn") or "/opt/homebrew/bin/svn"
    svnadmin = shutil.which("svnadmin") or "/opt/homebrew/bin/svnadmin"

    def run(tool, *args, cwd=None, expect_failure=False):
        cwd = cwd or root
        assert cwd.resolve().is_relative_to(root.resolve())
        result = subprocess.run([tool, *map(str, args)], cwd=cwd, env=env, capture_output=True, text=True)
        if result.returncode and not expect_failure:
            raise RuntimeError(result.stderr or result.stdout)
        return result.stdout.strip()

    def git(*args, cwd=None, **kwargs):
        return run("git", "-c", "core.hooksPath=/dev/null", *args, cwd=cwd, **kwargs)

    def identity(directory):
        git("config", "user.name", "RepHub QA", cwd=directory)
        git("config", "user.email", "rephub-qa@example.invalid", cwd=directory)

    for name in ["unmanaged-git", "unmanaged-svn"]:
        directory = root / name
        (directory / "Sources").mkdir(parents=True)
        (directory / "Sources" / "Demo.swift").write_text("struct Demo { let version = 1 }\n")
        (directory / "README.md").write_text("# RepHub isolated management fixture\n")

    bare = root / "remote.git"
    git("init", "--bare", "--initial-branch=main", bare)
    actions = root / "git-actions"
    git("clone", bare, actions)
    identity(actions)
    (actions / "Sources").mkdir()
    (actions / "Sources" / "Demo.swift").write_text("struct Demo { let version = 1 }\n")
    git("add", "--", "Sources/Demo.swift", cwd=actions)
    git("commit", "-m", "initial management fixture", cwd=actions)
    git("push", "-u", "origin", "main", cwd=actions)
    git("switch", "-c", "feature/demo", cwd=actions)
    (actions / "Sources" / "Demo.swift").write_text("struct Demo { let version = 2 }\n")
    git("commit", "-am", "feature comparison fixture", cwd=actions)
    git("push", "origin", "feature/demo", cwd=actions)
    git("switch", "main", cwd=actions)
    branches = root / "git-branches"
    git("clone", bare, branches)
    identity(branches)
    (actions / "Sources" / "Demo.swift").write_text("struct Demo { let version = 3 }\n")
    (actions / "literal[1].txt").write_text("literal pathspec fixture\n")

    conflict = root / "git-conflict"
    git("clone", bare, conflict)
    identity(conflict)
    (conflict / "Sources" / "Demo.swift").write_text("struct Demo { let version = 9 }\n")
    git("commit", "-am", "conflicting local fixture", cwd=conflict)
    git("merge", "--no-commit", "--no-ff", "origin/feature/demo", cwd=conflict, expect_failure=True)

    repository = root / "svn-repository"
    run(svnadmin, "create", repository)
    url = repository.as_uri()
    run(svn, "--non-interactive", "--config-dir", home / "svn", "mkdir", url + "/trunk", "-m", "fixture trunk")
    svn_copy = root / "svn-linked"
    run(svn, "--non-interactive", "--config-dir", home / "svn", "checkout", url + "/trunk", svn_copy)
    (svn_copy / "Guide.txt").write_text("initial SVN fixture\n")
    run(svn, "--non-interactive", "--config-dir", home / "svn", "add", "Guide.txt", cwd=svn_copy)
    run(svn, "--non-interactive", "--config-dir", home / "svn", "commit", "-m", "add guide", cwd=svn_copy)
    (svn_copy / "Guide.txt").write_text("updated SVN fixture\n")
    manifest = {"root": str(root), "git": str(actions), "branches": str(branches),
                "conflict": str(conflict), "svn": str(svn_copy), "gitInit": str(root / "unmanaged-git"),
                "svnInit": str(root / "unmanaged-svn"), "svnImportURL": url + "/imported-project",
                "gitRemote": str(bare)}
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
