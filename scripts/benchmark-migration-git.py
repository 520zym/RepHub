#!/usr/bin/env python3
"""比较迁移对象读写的进程开销；仅使用自动清理的独立临时目录，不连接远端。"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    with tempfile.TemporaryDirectory(prefix="RepHub-Migration-Benchmark-") as folder:
        root = Path(folder)
        home = root / "home"
        home.mkdir()
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home),
               "XDG_CONFIG_HOME": str(home), "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"}

        def git(repo, *args, data=None):
            return subprocess.check_output(["git", "-C", str(repo), *args], env=env, input=data,
                                           stderr=subprocess.PIPE)

        source = root / "source"
        source.mkdir()
        paths = []
        payloads = []
        for index in range(320):
            path = source / f"file {index:04}.bin"
            payload = index.to_bytes(4, "big") + bytes(range(255)) * 4
            path.write_bytes(payload)
            paths.append(str(path))
            payloads.append(payload)
        old, new = root / "old", root / "new"
        for repo in (old, new):
            repo.mkdir()
            git(repo, "init", "--template=", "--quiet")

        result = {"files": len(paths), "bytes_per_file": len(payloads[0]),
                  "scope": "Git hash/cat processes only; excludes SVN, full-tree copies and verification"}

        started = time.perf_counter()
        old_ids = [git(old, "hash-object", "-w", "--no-filters", "--", path).strip() for path in paths]
        result["hash_per_file_ms"] = round((time.perf_counter() - started) * 1000, 1)
        started = time.perf_counter()
        new_ids = []
        for offset in range(0, len(paths), 256):
            new_ids.extend(git(new, "hash-object", "-w", "--no-filters", "--", *paths[offset:offset + 256]).splitlines())
        result["hash_batch_ms"] = round((time.perf_counter() - started) * 1000, 1)
        assert old_ids == new_ids

        started = time.perf_counter()
        for oid, expected in zip(new_ids, payloads):
            assert git(new, "cat-file", "blob", oid.decode()) == expected
        result["cat_per_file_ms"] = round((time.perf_counter() - started) * 1000, 1)
        started = time.perf_counter()
        for offset in range(0, len(new_ids), 256):
            chunk = new_ids[offset:offset + 256]
            data = git(new, "cat-file", "--batch", data=b"\n".join(chunk) + b"\n")
            position = 0
            for index, oid in enumerate(chunk):
                end = data.index(b"\n", position)
                identifier, kind, size = data[position:end].split(b" ")
                assert identifier == oid and kind == b"blob"
                position = end + 1
                size = int(size)
                assert data[position:position + size] == payloads[offset + index]
                position += size
                assert data[position:position + 1] == b"\n"
                position += 1
            assert position == len(data)
        result["cat_batch_ms"] = round((time.perf_counter() - started) * 1000, 1)
        result["hash_processes"] = {"before": 320, "after": 2}
        result["cat_processes"] = {"before": 320, "after": 2}
        result["content_identical"] = True
        print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
