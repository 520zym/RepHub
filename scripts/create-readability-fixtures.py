#!/usr/bin/env python3
"""建立 RepHub 文档预览、历史可读性和 SVN 检出隔离验收夹具。

夹具只会写入系统临时目录；Git 远端和 SVN 仓库均为本机 bare/file://
仓库。脚本不会读取业务仓库、访问网络或继承用户的认证配置。

请使用 Codex 随附 Python 运行，以生成真实的 docx/pptx/xlsx/pdf 文件：
  /Users/zhangyiming/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from docx import Document
from openpyxl import Workbook
from pptx import Presentation
from pptx.util import Inches, Pt
from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.pdfgen import canvas


SAFE_PARENT = Path(tempfile.gettempdir()).resolve()
PREFIX = "RepHub-ReadabilityFixture-"


def ensure_inside(root: Path, target: Path, *, allow_root: bool = True) -> Path:
    resolved = target.resolve()
    root_resolved = root.resolve()
    if resolved == root_resolved and allow_root:
        return resolved
    try:
        resolved.relative_to(root_resolved)
    except ValueError as error:
        raise RuntimeError(f"测试操作越出隔离根目录：{target}") from error
    return resolved


def find_tool(name: str) -> str:
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


def environment(home: Path, extra: dict[str, str] | None = None) -> dict[str, str]:
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


def command(
    root: Path,
    home: Path,
    tools: dict[str, str],
    executable: str,
    *arguments: str,
    cwd: Path | None = None,
    extra_environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    if cwd is not None:
        ensure_inside(root, cwd)
    for argument in arguments:
        if argument.startswith("/"):
            ensure_inside(root, Path(argument))
        if "://" in argument and not argument.startswith("file://"):
            raise RuntimeError(f"拒绝非本地远端：{argument}")
        if argument.startswith("file://"):
            ensure_inside(root, Path(argument.removeprefix("file://")))
    invocation = [tools[executable]]
    if executable == "svn":
        invocation.extend(("--config-dir", str(home / ".subversion")))
    invocation.extend(arguments)
    return subprocess.run(
        invocation,
        cwd=cwd,
        env=environment(home, extra_environment),
        check=True,
        stdin=subprocess.DEVNULL,
        text=True,
        capture_output=True,
    )


def write_text(root: Path, path: Path, content: str) -> None:
    ensure_inside(root, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def create_docx(root: Path, path: Path, title: str, paragraphs: list[str]) -> None:
    ensure_inside(root, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    document = Document()
    document.add_heading(title, level=0)
    for paragraph in paragraphs:
        document.add_paragraph(paragraph)
    document.save(path)


def create_pptx(root: Path, path: Path, title: str, subtitle: str) -> None:
    ensure_inside(root, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    presentation = Presentation()
    slide = presentation.slides.add_slide(presentation.slide_layouts[0])
    slide.shapes.title.text = title
    slide.placeholders[1].text = subtitle
    details = presentation.slides.add_slide(presentation.slide_layouts[1])
    details.shapes.title.text = "验收内容"
    frame = details.placeholders[1].text_frame
    frame.text = "文件内容可预览"
    for item in ("中文文件名", "多页/多对象文档", "本地隔离夹具"):
        paragraph = frame.add_paragraph()
        paragraph.text = item
        paragraph.level = 1
        paragraph.font.size = Pt(20)
    presentation.save(path)


def create_xlsx(root: Path, path: Path, title: str) -> None:
    ensure_inside(root, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    workbook = Workbook()
    sheet = workbook.active
    sheet.title = "提交统计"
    sheet.append([title, "负责人", "状态", "更新时间"])
    sheet.append(["文档预览", "张一鸣", "待评审", "2026-10-15"])
    sheet.append(["提交历史", "陈晨", "进行中", "2026-10-14"])
    sheet.column_dimensions["A"].width = 20
    sheet.column_dimensions["B"].width = 14
    sheet.column_dimensions["C"].width = 14
    sheet.column_dimensions["D"].width = 18
    workbook.save(path)


def create_pdf(root: Path, path: Path, title: str) -> None:
    ensure_inside(root, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    pdfmetrics.registerFont(UnicodeCIDFont("STSong-Light"))
    output = canvas.Canvas(str(path), pagesize=A4)
    output.setFont("STSong-Light", 18)
    output.drawString(72, 780, title)
    output.setFont("STSong-Light", 11)
    for index, text in enumerate((
        "这是用于 RepHub 本地文档预览验收的真实 PDF。",
        "文件不含业务资料，也不通过网络下载。",
        "可用于检查中文文件名、内容提取和预览入口。",
    )):
        output.drawString(72, 735 - index * 28, text)
    output.showPage()
    output.save()


def create_git_fixture(root: Path, home: Path, tools: dict[str, str]) -> tuple[Path, Path]:
    remote = root / "remotes" / "readability-history.git"
    writer = root / "git-writer"
    workspace = root / "git-workspace"
    command(root, home, tools, "git", "init", "--bare", str(remote))
    command(root, home, tools, "git", "clone", str(remote), str(writer))
    command(root, home, tools, "git", "config", "user.name", "RepHub Fixture", cwd=writer)
    command(root, home, tools, "git", "config", "user.email", "fixture@localhost", cwd=writer)

    write_text(root, writer / "Sources" / "App" / "Main.swift", "enum Demo { static let version = 0 }\n")
    write_text(root, writer / "模块 A" / "业务" / "服务说明.md", "# 初始说明\n\n用于历史列表验收。\n")
    write_text(root, writer / "配置" / "application.yml", "feature: readability\n")
    create_docx(root, writer / "文档" / "架构说明.docx", "RepHub 架构说明", ["初始版本", "支持 Git 与 SVN。"])
    create_pptx(root, writer / "演示" / "发布说明.pptx", "发布说明", "用于本地验收")
    create_xlsx(root, writer / "数据" / "提交统计.xlsx", "提交统计")
    create_pdf(root, writer / "文档" / "测试报告.pdf", "RepHub 测试报告")
    command(root, home, tools, "git", "add", "--", ".", cwd=writer)
    command(root, home, tools, "git", "commit", "-m", "chore: 初始化中文目录、源码与可预览文档", cwd=writer)
    command(root, home, tools, "git", "branch", "-M", "main", cwd=writer)

    authors = (("张一鸣", "zhangyiming@fixture.local"), ("陈晨", "chenchen@fixture.local"), ("李书文", "lishuwen@fixture.local"))
    topics = (
        "优化提交历史列表在长标题下的阅读节奏与元信息留白",
        "补充远程仓库浏览时目录的最后提交编号和提交时间展示",
        "调整工作区文件树对未跟踪 Office 文档的状态提示",
        "修正文档预览入口在窄窗口下的图标与标题对齐",
        "完善 SVN 检出向导的下载进度和即时速度说明",
        "整理多层目录中的源码说明与评审材料展示顺序",
    )
    base_time = datetime(2026, 9, 1, 9, 0, tzinfo=timezone(timedelta(hours=8)))
    for index in range(1, 31):
        source = writer / "Sources" / "Feature" / f"Feature{index % 5}.swift"
        write_text(root, source, f'// revision {index}\nstruct Feature{index} {{ let title = "提交 {index}" }}\n')
        note = writer / "模块 A" / "业务" / f"变更记录-{index:02d}.md"
        write_text(root, note, f"# 第 {index} 次变更\n\n{topics[index % len(topics)]}\n")
        command(root, home, tools, "git", "add", "--", source.relative_to(writer).as_posix(), note.relative_to(writer).as_posix(), cwd=writer)
        author_name, author_email = authors[index % len(authors)]
        subject = f"feat(可读性): {topics[index % len(topics)]}（第 {index} 次迭代）"
        body = "\n\n".join((
            "本次提交包含多层目录中的源码和说明文件，用于验证长标题不会挤压作者、时间和摘要信息。",
            "验收说明：历史详情应保持独立的信息区域，文件树可按目录折叠浏览。",
        ))
        stamp = (base_time + timedelta(hours=index * 8)).isoformat()
        command(
            root, home, tools, "git",
            "-c", f"user.name={author_name}", "-c", f"user.email={author_email}",
            "commit", "-m", subject, "-m", body,
            cwd=writer,
            extra_environment={"GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp},
        )
    command(root, home, tools, "git", "push", "-u", "origin", "main", cwd=writer)
    command(root, home, tools, "git", "--git-dir", str(remote), "symbolic-ref", "HEAD", "refs/heads/main")
    command(root, home, tools, "git", "clone", str(remote), str(workspace))
    command(root, home, tools, "git", "config", "user.name", "RepHub Workspace Fixture", cwd=workspace)
    command(root, home, tools, "git", "config", "user.email", "workspace@fixture.local", cwd=workspace)

    write_text(root, workspace / "Sources" / "App" / "Main.swift", "enum Demo { static let version = 31 }\n")
    write_text(root, workspace / "模块 A" / "业务" / "服务说明.md", "# 当前修改\n\n这是一个已跟踪但未提交的中文说明。\n")
    create_docx(root, workspace / "待评审" / "未跟踪需求说明.docx", "未跟踪需求说明", ["此文件尚未加入版本控制。", "用于文档预览和状态色验收。"])
    create_pptx(root, workspace / "待评审" / "未跟踪演示.pptx", "未跟踪演示", "当前工作区文件")
    create_xlsx(root, workspace / "待评审" / "未跟踪表格.xlsx", "未跟踪表格")
    create_pdf(root, workspace / "待评审" / "未跟踪报告.pdf", "未跟踪报告")
    return workspace, remote


def create_svn_fixture(root: Path, home: Path, tools: dict[str, str]) -> tuple[Path, str, Path]:
    repository = root / "remotes" / "readability-svn"
    url = repository.as_uri()
    writer = root / "svn-writer"
    command(root, home, tools, "svnadmin", "create", str(repository))
    command(root, home, tools, "svn", "mkdir", "-m", "创建 trunk", f"{url}/trunk")
    command(root, home, tools, "svn", "checkout", f"{url}/trunk", str(writer))

    write_text(root, writer / "服务端" / "核心" / "Bootstrap.java", "class Bootstrap { int revision = 1; }\n")
    write_text(root, writer / "服务端" / "配置" / "application.yml", "service: readability\n")
    write_text(root, writer / "资料" / "操作手册.md", "# 操作手册\n\n版本一。\n")
    write_text(root, writer / "资料" / "子模块" / "README.md", "# 子模块\n")
    command(root, home, tools, "svn", "add", "服务端", "资料", cwd=writer)
    command(root, home, tools, "svn", "commit", "-m", "添加多层源码和资料目录", cwd=writer)
    write_text(root, writer / "资料" / "操作手册.md", "# 操作手册\n\n版本二，补充检出说明。\n")
    write_text(root, writer / "资料" / "子模块" / "检出范围说明.md", "可选择该目录单独检出。\n")
    command(root, home, tools, "svn", "add", "资料/子模块/检出范围说明.md", cwd=writer)
    command(root, home, tools, "svn", "commit", "-m", "补充子目录检出范围说明", cwd=writer)
    write_text(root, writer / "服务端" / "核心" / "Bootstrap.java", "class Bootstrap { int revision = 3; }\n")
    command(root, home, tools, "svn", "commit", "-m", "更新核心启动源码的修订标记", cwd=writer)
    write_text(root, writer / "服务端" / "配置" / "application.yml", "service: readability\npreview: enabled\n")
    command(root, home, tools, "svn", "commit", "-m", "调整远程浏览预览配置", cwd=writer)
    destination_parent = root / "svn-checkout-target-parent"
    destination_parent.mkdir(mode=0o700)
    return repository, f"{url}/trunk", destination_parent


def validate_documents(root: Path, workspace: Path) -> dict[str, str]:
    checks: dict[str, str] = {}
    docx_path = workspace / "文档" / "架构说明.docx"
    checks["docx"] = "ok" if Document(docx_path).paragraphs else "empty"
    pptx_path = workspace / "演示" / "发布说明.pptx"
    checks["pptx"] = "ok" if len(Presentation(pptx_path).slides) >= 2 else "invalid"
    xlsx_path = workspace / "数据" / "提交统计.xlsx"
    checks["xlsx"] = "ok" if Workbook() and __import__("openpyxl").load_workbook(xlsx_path).active.max_row >= 3 else "invalid"
    pdf_path = workspace / "文档" / "测试报告.pdf"
    checks["pdf"] = "ok" if pdf_path.read_bytes().startswith(b"%PDF-") else "invalid"
    return checks


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, help="可选；必须是 /tmp 下的新 RepHub-ReadabilityFixture-<uuid> 目录")
    args = parser.parse_args()
    tools = {name: find_tool(name) for name in ("git", "svn", "svnadmin")}
    root = (args.root or SAFE_PARENT / f"{PREFIX}{uuid.uuid4()}").resolve()
    if root.parent != SAFE_PARENT or not root.name.startswith(PREFIX):
        raise RuntimeError(f"测试根目录必须位于 {SAFE_PARENT}/{PREFIX}<uuid>")
    if root.exists():
        raise RuntimeError(f"拒绝覆盖已有测试设施：{root}")
    root.mkdir(mode=0o700)
    home = root / "home"
    (home / ".config").mkdir(parents=True, mode=0o700)
    (home / ".subversion").mkdir(mode=0o700)
    (root / "remotes").mkdir(mode=0o700)

    workspace, git_remote = create_git_fixture(root, home, tools)
    svn_repository, svn_url, checkout_parent = create_svn_fixture(root, home, tools)
    validation = validate_documents(root, workspace)
    manifest = {
        "root": str(root),
        "git_workspace": str(workspace),
        "git_remote": git_remote.as_uri(),
        "git_expected_history_commits": 31,
        "git_worktree_state": {
            "modified": ["Sources/App/Main.swift", "模块 A/业务/服务说明.md"],
            "untracked_preview_documents": [
                "待评审/未跟踪需求说明.docx",
                "待评审/未跟踪演示.pptx",
                "待评审/未跟踪表格.xlsx",
                "待评审/未跟踪报告.pdf",
            ],
        },
        "svn_repository": str(svn_repository),
        "svn_trunk_url": svn_url,
        "svn_subdirectory_url": f"{svn_url}/资料/子模块",
        "svn_checkout_destination_parent": str(checkout_parent),
        "svn_checkout_destination_suggestion": str(checkout_parent / "子模块检出"),
        "svn_expected_revision_at_least": 5,
        "documents_validation": validation,
        "safety": "仅使用系统临时目录及本机 Git bare/file:// SVN 仓库；不访问网络或业务仓库。",
    }
    manifest_path = root / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(manifest_path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        print(f"fixture creation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
