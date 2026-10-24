#!/usr/bin/env python3
"""build_report.py —— 把 report/design/*.md 合成一份 HTML（可选再出 PDF）。

为什么要有这个脚本：报告的源文件是仓库里的 Markdown（可 diff、可追溯），
但提交件定为 PDF（版式固定、离线可开）。两者之间的转换必须**可复现**，
不能靠手工复制粘贴。

依赖：
  - Python 3
  - pip install markdown==3.11.1 pymdown-extensions pypdf
  - 出 PDF 时：Microsoft Edge（Windows 11 自带），无头模式打印

用法：
  python report/build_report.py                 # -> report/build/report.html + report.pdf
  python report/build_report.py --html-only     # 只出 HTML
  python report/build_report.py --out-dir D:/tmp/report
  EDGE=<msedge.exe 路径> python report/build_report.py

⚠️ 生成的 HTML/PDF 是**产物**，不进仓库（report/build/ 已在 .gitignore）。
⚠️ 源文件改了要重跑，不要直接改产物。
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

# Windows 控制台默认 GBK，Git Bash 按 UTF-8 读；统一成 UTF-8 免得中文输出变乱码
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

try:
    import markdown
except ImportError:
    sys.exit("缺少 markdown：先运行  python -m pip install markdown==3.11.1 pymdown-extensions")

HERE = Path(__file__).resolve().parent
DESIGN = HERE / "design"

# 报告顺序：前置件 -> 正文五章 -> 附录 -> 参考文献
SOURCES = [
    "00_front_matter.md",
    "01_background_and_related_work.md",
    "02_design_and_innovation.md",
    "03_performance_and_resources.md",
    "04_functional_correctness.md",
    "05_reproducibility.md",
    "06_appendix.md",
    "07_references.md",
]

EDGE_CANDIDATES = [
    Path(r"C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"),
    Path(r"C:/Program Files/Microsoft/Edge/Application/msedge.exe"),
    Path(r"C:/Program Files/Google/Chrome/Application/chrome.exe"),
]

CSS = """
@page { size: A4; margin: 18mm 16mm; }
body {
  font-family: "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", sans-serif;
  font-size: 10.5pt; line-height: 1.65; color: #111;
}
h1 {
  font-size: 20pt; border-bottom: 2px solid #333; padding-bottom: 4px;
  page-break-before: always;
}
section.chapter:first-of-type h1 { page-break-before: avoid; }
h2 { font-size: 15pt; margin-top: 1.2em; page-break-after: avoid; }
h3 { font-size: 12.5pt; page-break-after: avoid; }
table {
  border-collapse: collapse; width: 100%; margin: 0.8em 0; font-size: 9pt;
  table-layout: auto;
}
th, td { border: 1px solid #888; padding: 3px 5px; vertical-align: top; }
th { background: #eee; }
tr { page-break-inside: avoid; }
code {
  font-family: Consolas, "Courier New", monospace; background: #f4f4f4;
  padding: 0 2px; font-size: 9pt;
}
pre {
  background: #f6f8fa; padding: 8px; white-space: pre-wrap;
  word-break: break-all; page-break-inside: avoid;
}
blockquote {
  border-left: 3px solid #bbb; margin-left: 0; padding-left: 10px;
  color: #333; background: #fafafa;
}
img { max-width: 100%; }
a { color: #0645ad; text-decoration: none; }
.generated-note {
  font-size: 9pt; color: #666; border-bottom: 1px solid #ddd;
  padding-bottom: 6px; margin-bottom: 18px;
}
@media print { .generated-note { display: none; } }
"""


def find_edge():
    env = os.environ.get("EDGE")
    if env:
        p = Path(env)
        if p.exists():
            return p
    for p in EDGE_CANDIDATES:
        if p.exists():
            return p
    return None


def strip_build_meta(text):
    """去掉每章标题下那段写给队友的「状态 / 原料 / 评分项」元信息。

    这些块以 `>` 开头、以 `---` 结束，留在源文件里给协作用；PDF 是提交件，
    不能把「初稿」「骨架」「C 不代改」这类内部状态印给评委。
    """
    lines = text.splitlines()
    i = next((k for k, line in enumerate(lines) if line.startswith("# ")), None)
    if i is None:
        return text
    j = i + 1
    while j < len(lines) and not lines[j].strip():
        j += 1
    if j >= len(lines) or not lines[j].startswith(">"):
        return text
    k = j
    while k < len(lines) and lines[k].startswith(">"):
        k += 1
    m = k
    while m < len(lines) and not lines[m].strip():
        m += 1
    if m < len(lines) and lines[m].strip() == "---":
        return "\n".join(lines[:j] + lines[m + 1:])
    return text


def convert(sources):
    md = markdown.Markdown(
        extensions=["tables", "fenced_code", "sane_lists", "attr_list", "pymdownx.tilde"],
        output_format="html5",
    )
    parts = []
    for name in sources:
        path = DESIGN / name
        if not path.exists():
            sys.exit(f"缺少源文件：{path}")
        text = strip_build_meta(path.read_text(encoding="utf-8"))
        parts.append(f'<section class="chapter" data-source="{name}">\n')
        parts.append(md.convert(text))
        parts.append("\n</section>\n")
    return "\n".join(parts)


CHAPTERS = [
    "封面与摘要", "一、选题背景与相关工作", "二、设计与创新点", "三、性能与资源",
    "四、功能正确性", "五、可复现性", "附录", "参考文献",
]

OVERLAY_CSS = """
@page { size: A4; margin: 0; }
html, body { margin: 0; padding: 0; }
.page {
  position: relative; width: 210mm; height: 296.8mm;
  page-break-after: always; break-after: page;
}
.page:last-child { page-break-after: auto; break-after: auto; }
.hd {
  position: absolute; top: 7mm; left: 16mm; right: 16mm;
  font: 8.5pt "Microsoft YaHei", sans-serif; color: #666;
  border-bottom: 0.4pt solid #ccc; padding-bottom: 1.5mm;
}
.ft {
  position: absolute; bottom: 6mm; left: 16mm; right: 16mm;
  font: 8.5pt "Microsoft YaHei", sans-serif; color: #666; text-align: center;
}
"""


def add_page_furniture(pdf_path, edge, out_dir, title="后量子密码FPGA加速平台 · 设计报告"):
    """给 PDF 逐页叠加页眉与页码（封面页不加）。

    Chrome 无头打印不支持 CSS `@page` 的 margin box（`@bottom-center` / `counter(page)`），
    所以用同一条 Edge 生成一份与正文等页数的空白叠层（每页只写页眉/页码），再用 pypdf 逐页合并。
    不引入第二种渲染器，页码位置与正文版心同一次渲染确定。
    """
    try:
        from pypdf import PdfReader, PdfWriter
    except ImportError:
        sys.exit("缺少 pypdf：先运行  python -m pip install pypdf（叠加页码用）")

    n = len(PdfReader(str(pdf_path)).pages)
    if n < 2:
        return

    pages = []
    for i in range(1, n + 1):
        head = "" if i == 1 else f'<div class="hd">{title}</div>'
        foot = "" if i == 1 else f'<div class="ft">第 {i} 页 / 共 {n} 页</div>'
        pages.append(f'<div class="page">{head}{foot}</div>')
    overlay_html = out_dir / "overlay.html"
    overlay_pdf = out_dir / "overlay.pdf"
    overlay_html.write_text(
        '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
        f"<style>{OVERLAY_CSS}</style></head><body>{''.join(pages)}</body></html>",
        encoding="utf-8", newline="\n")

    cmd = [str(edge), "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
           f"--print-to-pdf={overlay_pdf}", overlay_html.as_uri()]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if proc.returncode != 0 or not overlay_pdf.exists():
        sys.stdout.write(proc.stdout.decode("utf-8", "replace"))
        sys.exit("ERROR: 页码叠层生成失败（Edge 打印 overlay.html）")

    reader = PdfReader(str(pdf_path))
    over = PdfReader(str(overlay_pdf))
    if len(over.pages) != n:
        sys.exit(f"ERROR: 叠层页数 {len(over.pages)} ≠ 正文页数 {n}，"
                 "页码会错位；拒绝合并（检查 overlay.html 的分页样式）")

    # 先按正文（未叠页眉）找章节起始页：每个 h1 都从新页开始，页首即标题
    starts = {}
    for i in range(n):
        head = (reader.pages[i].extract_text() or "").strip()
        for ch in CHAPTERS:
            if ch not in starts and head.startswith(ch):
                starts[ch] = i
    if "封面与摘要" not in starts and "封面与摘要" in (reader.pages[0].extract_text() or ""):
        starts["封面与摘要"] = 0       # 第 1 页顶上是构建说明，标题不在行首

    writer = PdfWriter()
    for i, page in enumerate(reader.pages):
        page.merge_page(over.pages[i])
        writer.add_page(page)
    for ch in CHAPTERS:                      # 书签：评委可点目录跳章
        if ch in starts:
            writer.add_outline_item(ch, starts[ch])
    numbered = out_dir / "report_numbered.pdf"
    with numbered.open("wb") as f:
        writer.write(f)
    numbered.replace(pdf_path)


def main():
    ap = argparse.ArgumentParser(description="把 report/design/*.md 合成 HTML/PDF")
    ap.add_argument("--out-dir", default=str(HERE / "build"))
    ap.add_argument("--html-only", action="store_true")
    args = ap.parse_args()

    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    body = convert(SOURCES)
    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<base href="{DESIGN.as_uri()}/">
<title>后量子密码FPGA加速平台 · 设计报告</title>
<style>{CSS}</style>
</head>
<body>
<div class="generated-note">本文件由 <code>report/build_report.py</code> 从
<code>report/design/*.md</code> 生成，请勿直接编辑。源文件改动后重跑脚本。</div>
{body}
</body>
</html>
"""
    html_path = out_dir / "report.html"
    html_path.write_text(html, encoding="utf-8", newline="\n")
    print(f"OK  HTML: {html_path}")

    if args.html_only:
        return

    edge = find_edge()
    if not edge:
        sys.exit("找不到 Edge/Chrome。用 EDGE=<msedge.exe 路径> 指定，或用 --html-only。")

    pdf_path = out_dir / "report.pdf"
    cmd = [
        str(edge),
        "--headless=new",
        "--disable-gpu",
        "--no-pdf-header-footer",
        f"--print-to-pdf={pdf_path}",
        html_path.as_uri(),
    ]
    print("   调用：", " ".join(cmd))
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    if proc.returncode != 0 or not pdf_path.exists():
        sys.stdout.write(proc.stdout.decode("utf-8", "replace"))
        sys.exit(f"ERROR: PDF generation failed (edge rc={proc.returncode}). HTML kept: {html_path}")
    add_page_furniture(pdf_path, edge, out_dir)
    print(f"OK  PDF : {pdf_path} ({pdf_path.stat().st_size / 1024:.0f} KB，已加页眉/页码)")


if __name__ == "__main__":
    main()
