#!/usr/bin/env python3
"""创建当前 SVN 工作副本迁移的隔离 UI 样本，不访问业务仓库或网络。"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    script = Path(__file__).with_name("create-migration-fixtures.py")
    manifest = json.loads(subprocess.check_output([sys.executable, str(script)], text=True))
    root = Path(manifest["root"]).resolve()
    assert root.name.startswith("RepHub-Migration-QA-")
    home = root / "home"
    environment = {
        "HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"),
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"),
        "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "en_US.UTF-8",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }
    working_copy = root / "existing-svn-project"
    subprocess.run(["svn", "checkout", manifest["sourceSVNModuleURL"], str(working_copy)],
                   env=environment, cwd=root, check=True, capture_output=True)
    (working_copy / "keep-untracked.local").write_text("本地额外文件，不能迁移或覆盖。\n", encoding="utf-8")
    manifest["workingCopy"] = str(working_copy)
    manifest["svnWriter"] = str(Path(manifest["sourceSVNWorkingCopy"]) / "迁移模块")
    manifest["initialFiles"] = {
        str(path.relative_to(working_copy)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in working_copy.rglob("*") if path.is_file() and ".svn" not in path.parts
    }
    manifest["expectedCutoverRevision"] = "r4"
    (root / "working-copy-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
