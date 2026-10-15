#!/usr/bin/env python3
"""在隔离的本机 svnserve 上比较两种 SVN 历史快照策略。

旧策略：每个修订都从远端 `svn export -r` 一个完整快照。
新策略：首次 checkout，随后固定 URL 按修订 `svn switch -r`，再本地 export。

脚本只创建自动清理的临时 svnadmin 仓库；svnserve 和 TCP 统计代理都只监听
127.0.0.1。统计值是代理观察到的服务端 -> 客户端字节数，初始化夹具的提交不计入。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
from typing import Iterable


class ByteCounter:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._value = 0

    def add(self, size: int) -> None:
        with self._lock:
            self._value += size

    def reset(self) -> None:
        with self._lock:
            self._value = 0

    def value(self) -> int:
        with self._lock:
            return self._value


class CountingProxy(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, target: tuple[str, int], counter: ByteCounter) -> None:
        self.target = target
        self.counter = counter
        super().__init__(("127.0.0.1", 0), CountingProxyHandler)


class CountingProxyHandler(socketserver.BaseRequestHandler):
    """透明转发 svn:// TCP，并只累计服务端到客户端方向的字节。"""

    def handle(self) -> None:
        server = self.server
        assert isinstance(server, CountingProxy)
        try:
            upstream = socket.create_connection(server.target, timeout=10)
        except OSError:
            return
        # 代理本身不应因 Nagle / Delayed ACK 合并小型 SVN 协议包而改变两种策略的耗时。
        for connection in (self.request, upstream):
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        upstream.settimeout(None)
        self.request.settimeout(None)

        def relay(source: socket.socket, destination: socket.socket, count: bool) -> None:
            try:
                while True:
                    data = source.recv(64 * 1024)
                    if not data:
                        break
                    if count:
                        server.counter.add(len(data))
                    destination.sendall(data)
            except OSError:
                pass
            finally:
                try:
                    destination.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

        upstream_to_client = threading.Thread(target=relay, args=(upstream, self.request, True), daemon=True)
        upstream_to_client.start()
        relay(self.request, upstream, False)
        upstream_to_client.join(timeout=5)
        upstream.close()


def find_tool(name: str) -> str:
    candidates = [shutil.which(name), f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}", f"/usr/bin/{name}"]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise RuntimeError(f"缺少本机工具 {name}（已检查 PATH、/opt/homebrew/bin、/usr/local/bin、/usr/bin）。")


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def wait_for_port(port: int, process: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if process.poll() is not None:
            stderr = process.stderr.read().decode("utf-8", "replace") if process.stderr else ""
            raise RuntimeError(f"svnserve 启动失败：{stderr.strip() or process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("等待本机 svnserve 监听超时。")


def stop_process(process: subprocess.Popen[bytes] | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def make_environment(root: Path) -> tuple[dict[str, str], Path]:
    home = root / "home"
    config = home / "svn-config"
    config.mkdir(parents=True, mode=0o700)
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "LC_ALL": "C",
        "LANG": "C",
        "SVN_SSH": "/usr/bin/false",
    }
    return env, config


def run(command: list[str], *, env: dict[str, str], cwd: Path, timeout: float, config: Path | None = None) -> subprocess.CompletedProcess[str]:
    if config is not None and Path(command[0]).name == "svn":
        command = [*command, "--config-dir", str(config), "--no-auth-cache", "--non-interactive"]
    completed = subprocess.run(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL, capture_output=True,
                               text=True, timeout=timeout, check=False)
    if completed.returncode:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"exit {completed.returncode}"
        raise RuntimeError(f"命令失败：{' '.join(command[:3])} …\n{detail}")
    return completed


def write_fixture(working_copy: Path, files: int, binary_bytes: int, revisions: int,
                  svn: str, env: dict[str, str], config: Path, timeout: float) -> list[int]:
    payload_dir = working_copy / "payload"
    payload_dir.mkdir(parents=True)
    seen: set[bytes] = set()
    for index in range(files):
        payload = os.urandom(binary_bytes)
        digest = hashlib.sha256(payload).digest()
        while digest in seen:
            payload = os.urandom(binary_bytes)
            digest = hashlib.sha256(payload).digest()
        seen.add(digest)
        (payload_dir / f"asset-{index:03d}.bin").write_bytes(payload)
    text = working_copy / "changes.txt"
    text.write_text("revision 0\n", encoding="utf-8")
    run([svn, "add", "payload", "changes.txt"], env=env, cwd=working_copy, timeout=timeout, config=config)
    initial = run([svn, "commit", "-m", "initial binary fixture"], env=env, cwd=working_copy, timeout=timeout, config=config)
    revision_numbers = [int(initial.stdout.strip().rsplit(" ", 1)[-1].rstrip("."))]
    for index in range(1, revisions + 1):
        text.write_text(f"revision {index}\n" + ("x" * (index * 17)) + "\n", encoding="utf-8")
        result = run([svn, "commit", "changes.txt", "-m", f"small text change {index}"], env=env, cwd=working_copy,
                     timeout=timeout, config=config)
        revision_numbers.append(int(result.stdout.strip().rsplit(" ", 1)[-1].rstrip(".")))
    return revision_numbers


def tree_digest(root: Path) -> str:
    lines: list[bytes] = []
    for item in sorted((entry for entry in root.rglob("*") if entry.is_file()), key=lambda path: path.relative_to(root).as_posix()):
        relative = item.relative_to(root).as_posix().encode("utf-8")
        content = item.read_bytes()
        lines.append(relative + b"\0" + str(len(content)).encode() + b"\0" + hashlib.sha256(content).digest())
    return hashlib.sha256(b"\n".join(lines)).hexdigest()


def benchmark_old(revisions: Iterable[int], url: str, output: Path, *, svn: str, env: dict[str, str], config: Path,
                  timeout: float) -> tuple[dict[int, str], float]:
    output.mkdir(parents=True, exist_ok=False)
    started = time.perf_counter()
    snapshots: dict[int, str] = {}
    for revision in revisions:
        target = output / f"r{revision}"
        run([svn, "export", "--force", "-r", str(revision), url, str(target)], env=env, cwd=output, timeout=timeout, config=config)
        snapshots[revision] = tree_digest(target)
    return snapshots, time.perf_counter() - started


def benchmark_incremental(revisions: list[int], url: str, output: Path, *, svn: str, env: dict[str, str], config: Path,
                          timeout: float) -> tuple[dict[int, str], float]:
    output.mkdir(parents=True, exist_ok=False)
    started = time.perf_counter()
    working_copy = output / "working-copy"
    snapshots: dict[int, str] = {}
    run([svn, "checkout", "-r", str(revisions[0]), url, str(working_copy)], env=env, cwd=output, timeout=timeout, config=config)
    for index, revision in enumerate(revisions):
        if index:
            run([svn, "switch", "-r", str(revision), url, str(working_copy)], env=env, cwd=output, timeout=timeout, config=config)
        target = output / f"r{revision}"
        run([svn, "export", "--force", str(working_copy), str(target)], env=env, cwd=output, timeout=timeout, config=config)
        snapshots[revision] = tree_digest(target)
    return snapshots, time.perf_counter() - started


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--files", type=int, default=120, help="初始提交中的随机二进制文件数（默认：120）")
    parser.add_argument("--binary-bytes", type=int, default=32 * 1024, help="每个随机二进制文件的字节数（默认：32768）")
    parser.add_argument("--revisions", type=int, default=10, help="初始提交后的仅文本小改动次数（默认：10）")
    parser.add_argument("--timeout", type=float, default=45, help="单个 SVN 命令的超时秒数（默认：45）")
    arguments = parser.parse_args()
    if arguments.files <= 0 or arguments.binary_bytes <= 0 or not 1 <= arguments.revisions <= 100 or arguments.timeout <= 0:
        parser.error("files、binary-bytes、timeout 必须大于 0，revisions 必须在 1 到 100 之间。")
    return arguments


def main() -> int:
    arguments = parse_arguments()
    svn, svnadmin, svnserve = (find_tool(name) for name in ("svn", "svnadmin", "svnserve"))
    server: subprocess.Popen[bytes] | None = None
    proxy: CountingProxy | None = None
    proxy_thread: threading.Thread | None = None
    with tempfile.TemporaryDirectory(prefix="RepHub-SVN-Migration-Benchmark-") as folder:
        root = Path(folder).resolve()
        env, config = make_environment(root)
        repository_parent = root / "repositories"
        repository_parent.mkdir()
        repository = repository_parent / "source"
        run([svnadmin, "create", str(repository)], env=env, cwd=root, timeout=arguments.timeout)
        (repository / "conf" / "svnserve.conf").write_text("[general]\nanon-access = write\nauth-access = write\n", encoding="utf-8")
        server_port = free_port()
        server = subprocess.Popen([svnserve, "--daemon", "--foreground", "--root", str(repository_parent), "--listen-host", "127.0.0.1",
                                   "--listen-port", str(server_port)], env=env, cwd=root, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            wait_for_port(server_port, server)
            counter = ByteCounter()
            proxy = CountingProxy(("127.0.0.1", server_port), counter)
            proxy_thread = threading.Thread(target=proxy.serve_forever, daemon=True)
            proxy_thread.start()
            direct_url = f"svn://127.0.0.1:{server_port}/source/trunk"
            measured_url = f"svn://127.0.0.1:{proxy.server_address[1]}/source/trunk"
            run([svn, "mkdir", direct_url, "-m", "create trunk"], env=env, cwd=root, timeout=arguments.timeout, config=config)
            writer = root / "writer"
            run([svn, "checkout", direct_url, str(writer)], env=env, cwd=root, timeout=arguments.timeout, config=config)
            revisions = write_fixture(writer, arguments.files, arguments.binary_bytes, arguments.revisions,
                                      svn, env, config, arguments.timeout)

            counter.reset()
            old_snapshots, old_seconds = benchmark_old(revisions, measured_url, root / "old", svn=svn, env=env,
                                                       config=config, timeout=arguments.timeout)
            old_bytes = counter.value()

            counter.reset()
            new_snapshots, new_seconds = benchmark_incremental(revisions, measured_url, root / "new", svn=svn, env=env,
                                                                config=config, timeout=arguments.timeout)
            new_bytes = counter.value()
            if old_snapshots != new_snapshots:
                differing = [f"r{revision}" for revision in revisions if old_snapshots.get(revision) != new_snapshots.get(revision)]
                raise RuntimeError(f"两种策略的快照内容不一致：{', '.join(differing)}")

            result = {
                "scope": "临时 svnadmin 仓库 + 仅127.0.0.1 svnserve/proxy；统计服务端到客户端字节，不含夹具创建。",
                "fixture": {"binaryFiles": arguments.files, "bytesPerBinaryFile": arguments.binary_bytes,
                            "smallTextRevisions": arguments.revisions, "snapshots": len(revisions), "revisions": revisions},
                "oldRemoteExport": {"remoteExports": len(revisions), "checkouts": 0, "switches": 0,
                                    "localExports": 0, "serverToClientBytes": old_bytes, "elapsedSeconds": round(old_seconds, 3)},
                "incrementalSwitch": {"remoteExports": 0, "checkouts": 1, "switches": len(revisions) - 1,
                                      "localExports": len(revisions), "serverToClientBytes": new_bytes,
                                      "elapsedSeconds": round(new_seconds, 3)},
                "snapshotsIdentical": True,
                "networkByteReduction": old_bytes - new_bytes,
                "networkReductionRatio": round(1 - (new_bytes / old_bytes), 4) if old_bytes else None,
                "limitation": "本机零延迟、随机二进制不可压缩；这是新目录迁移的无 seed 场景，首次 checkout 计入新策略。当前工作副本首次迁移可复用干净 BASE 缓存而进一步减少该步骤，但不由本脚本测量。本结果仅验证重复全量传输的字节差异，不代表完整迁移（本地快照、Git 写入和核对均另计）的耗时或所有 SVN 服务端实现。",
            }
            print(json.dumps(result, ensure_ascii=False, indent=2))
        finally:
            if proxy is not None:
                proxy.shutdown()
                proxy.server_close()
            if proxy_thread is not None:
                proxy_thread.join(timeout=5)
            stop_process(server)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"benchmark failed: {error}", file=os.sys.stderr)
        raise SystemExit(1)
