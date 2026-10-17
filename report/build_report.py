#!/usr/bin/env python3
"""build_report.py —— 把 report/design/*.md 合成一份 HTML（可选再出 PDF）。

为什么要有这个脚本：报告的源文件是仓库里的 Markdown（可 diff、可追溯），
但提交件定为 PDF（版式固定、离线可开）。两者之间的转换必须**可复现**，
不能靠手工复制粘贴。

依赖：
  - Python 3
  - pip install markdown==3.11.1 pymdown-extensions
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
h1:first-of-type { page-break-before: avoid; }
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
        text = path.read_text(encoding="utf-8")
        parts.append(f'<section class="chapter" data-source="{name}">\n')
        parts.append(md.convert(text))
        parts.append("\n</section>\n")
    return "\n".join(parts)


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
<title>后量子密码FPGA加速平台 · 设计报告（草稿）</title>
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
    print(f"OK  PDF : {pdf_path} ({pdf_path.stat().st_size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
