"""代码注释里的行号引用，核对它指得对不对。

运行
    PYTHONIOENCODING=utf-8 python host/src/test_citations.py

为什么要这个脚本
    host/src/*.py 的注释里到处写着「见 host/proto.md §5.2:252」这种指路牌。
    这种指路牌的**内容一个字都不会错，但行号会漂** —— 只要有人在 proto.md
    中间插一行，后面所有行号全体 +1，指路牌就全偏了。
    而且**任何测试都不会因此报错**：测试跑的是代码，不是注释。
    （2026-09-29 真漂过一次：文件头插了 2 行，约 40 处引用全偏 2 格，
      当时是人工一行行 grep 出来的。这个脚本就是那次事故的产物。）

它查的四件事（任何一条不满足就非零退出）
    1. 行号落在 proto.md 的行数范围内；
    2. 带小节号的引用，那一行必须真的**落在那一节里**（不能指到别节去）；
    3. **单行**引用不许指到空行 —— 这是上次漂移最常见的翻车方式；
    4. **单行**引用不许指到表头或表格分隔线（`| 命令 | 参数 |` / `|---|---|`）——
       那是**路标**不是**内容**，指到它等于没指。

    区间引用（写成 `395-476` 的）只查第 1、2 条，外加「区间里至少有一行是正文」。
    理由：区间端点落在表头或空行上是常见且合理的写法（比如要指整张表）。

它还打一张对照表
    「代码里的原话 ↔ proto.md 那一行的原文」并排打出来，给**人**看。
    脚本能自动判的只是**形状**（空行 / 表头 / 越界 / 串节）；
    「这一行讲的是不是那回事」是**语义**，脚本判不了，得靠人扫一眼。
    所以这个脚本的输出不是「通过/失败」，而是**一份可复核的清单**。

⚠️ 本脚本不检查自己
    上面「举例」的说明里就写着真的引用（如 §5.2:252）。不改写就自我指涉，
    改写得不像人话又读不懂。所以按文件名跳过自己，见 SKIP。
"""

import re
import sys
from pathlib import Path

PROTO_MD = Path(__file__).resolve().parent.parent / "proto.md"
SRC_DIR = Path(__file__).resolve().parent

# 见模块 docstring 末尾「本脚本不检查自己」。
SKIP = {Path(__file__).name}

# ---------------------------------------------------------------- 引用长什么样

# 甲、带小节号的写法：
#     §5.2:252            §5.3.1:323
#     §5.4 校验（:395-476）   ← 小节名夹在中间，冒号前最多 12 个非冒号字符
#     §5.2:298 / :304      ← 后面 ` / :304` 是省略了小节号的简写，归同一节
SEC_CITE_RE = re.compile(
    r"§(?P<sec>\d+(?:\.\d+)*)"
    r"[^:：\n]{0,12}?:"
    r"(?P<a>\d+)(?:\s*-\s*(?P<b>\d+))?"
    r"(?P<more>(?:\s*/\s*:\d+(?:\s*-\s*\d+)?)*)"
)
# 乙、只写文件名的写法：proto.md:433-450
MD_CITE_RE = re.compile(r"proto\.md:(?P<a>\d+)(?:\s*-\s*(?P<b>\d+))?")
# 甲里那串追加的简写。
MORE_RE = re.compile(r":\s*(\d+)(?:\s*-\s*(\d+))?")

# ---------------------------------------------------------------- proto.md 的结构

# 有编号的标题才算「小节」：`### 5.2 命令字表`、`#### 5.3.1 一个系数怎么写`。
# `## 六、` / `### 第 1 条` / `#### 关键规则一` 这些**没有**编号，不是小节 ——
# 它们都算在所属的编号小节里（例如四条「关键规则」全算 §5.5）。
HEAD_RE = re.compile(r"^(#{1,6})\s+(\d+(?:\.\d+)*)\s")
# 定边界要用**所有**标题，包括没编号的 —— 否则 §5.5 会一路"漏"到文件末尾，
# 把 §六 的地界也算进自己家，那样指到 §六 的错引用就查不出来了。
ANY_HEAD_RE = re.compile(r"^(#{1,6})\s+")
# 表格分隔线：| --- | :---: |
SEP_RE = re.compile(r"^\|[\s:\-|]+\|\s*$")


def load_sections(lines):
    """proto.md 的行 -> {小节号: (起行号, 止行号)}，行号从 1 起、闭区间。

    一节的结尾 = 它后面第一个**层级不比自己深**的标题的前一行。
    ⚠️ 判边界时「标题」指**所有**标题（含 `## 六、` 这种没编号的），
       只有小节号才要求标题带编号。用错这一条，§5.5 会一路漏到文件末尾。
    """
    all_heads = []      # (层级, 行号)  —— 所有标题，只用来定边界
    numbered = []       # (小节号, 层级, 行号)
    for i, ln in enumerate(lines, 1):
        m = ANY_HEAD_RE.match(ln)
        if not m:
            continue
        all_heads.append((len(m.group(1)), i))
        m2 = HEAD_RE.match(ln)
        if m2:
            numbered.append((m2.group(2), len(m2.group(1)), i))

    out = {}
    for sec, lvl, start in numbered:
        end = len(lines)
        for lvl2, start2 in all_heads:
            if start2 > start and lvl2 <= lvl:
                end = start2 - 1
                break
        out[sec] = (start, end)
    return out


def is_table_header(lines, i):
    """第 i 行（1 起）是不是表头 —— 判据：它下一行是分隔线。"""
    if not lines[i - 1].startswith("|"):
        return False
    return i < len(lines) and bool(SEP_RE.match(lines[i]))


def is_content(lines, i):
    """第 i 行（1 起）是不是「正文」—— 非空、不是分隔线、不是表头。"""
    s = lines[i - 1]
    return bool(s.strip()) and not SEP_RE.match(s) and not is_table_header(lines, i)


def find_cites(text):
    """一行代码文本 -> [(小节号 or None, 起行号, 止行号 or None), ...]，按出现位置排序。"""
    found = []
    for m in SEC_CITE_RE.finditer(text):
        found.append((m.start(), m.group("sec"), int(m.group("a")),
                      int(m.group("b")) if m.group("b") else None))
        for ma, mb in MORE_RE.findall(m.group("more")):
            found.append((m.start(), m.group("sec"), int(ma), int(mb) if mb else None))
    for m in MD_CITE_RE.finditer(text):
        found.append((m.start(), None, int(m.group("a")),
                      int(m.group("b")) if m.group("b") else None))
    found.sort(key=lambda t: t[0])
    return [(sec, a, b) for _, sec, a, b in found]


# ---------------------------------------------------------------- 主流程

def check_one(lines, sections, sec, a, b):
    """查一条引用，返回 [问题, ...]（空 = 合格）。"""
    bad = []

    ends = (a,) if b is None else (a, b)
    for x in ends:
        if not 1 <= x <= len(lines):
            bad.append("第 %d 行超出 proto.md 的范围（共 %d 行）" % (x, len(lines)))
    if bad:
        return bad                       # 越界了，后面的检查没意义

    if sec is not None:
        if sec not in sections:
            bad.append("proto.md 里找不到 §%s 这一节" % sec)
        else:
            lo, hi = sections[sec]
            for x in ends:
                if not lo <= x <= hi:
                    bad.append("第 %d 行不在 §%s（%d-%d）里" % (x, sec, lo, hi))

    if b is None:
        # 单行：那行必须是正文
        if not lines[a - 1].strip():
            bad.append("指到空行")
        elif SEP_RE.match(lines[a - 1]):
            bad.append("指到表格分隔线")
        elif is_table_header(lines, a):
            bad.append("指到表头（路标不是内容）")
    else:
        # 区间：只要区间里有正文就放过（端点落在表头/空行上是常见写法）
        if not any(is_content(lines, x) for x in range(a, b + 1)):
            bad.append("%d-%d 这一整段里没有正文" % (a, b))

    return bad


def main():
    lines = PROTO_MD.read_text(encoding="utf-8").splitlines()
    sections = load_sections(lines)
    files = sorted(p for p in SRC_DIR.glob("*.py") if p.name not in SKIP)

    print("被引文件 ：%s（%d 行）" % (PROTO_MD, len(lines)))
    print("识别到的小节：%s"
          % "  ".join("§%s=%d-%d" % (k, v[0], v[1]) for k, v in sorted(sections.items())))
    print("扫的文件 ：%s" % "  ".join(p.name for p in files))
    if SKIP:
        print("跳过     ：%s（见模块 docstring 末尾）" % "  ".join(sorted(SKIP)))
    print("")

    rows = []
    for path in files:
        for lineno, text in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for sec, a, b in find_cites(text):
                rows.append((path.name, lineno, sec, a, b,
                             check_one(lines, sections, sec, a, b)))

    print("=== 逐条对照（代码里的引用 -> proto.md 那一行的原文）===")
    print("")
    for name, lineno, sec, a, b, bad in rows:
        cite = ("§%s:" % sec if sec is not None else "proto.md:") + \
               (str(a) if b is None else "%d-%d" % (a, b))
        raw = lines[a - 1].strip()
        cut = raw[:58] + ("…" if len(raw) > 58 else "")
        mark = "   <<< " + "；".join(bad) if bad else ""
        print("  %-30s %-14s | %s%s" % ("%s:%d" % (name, lineno), cite, cut, mark))

    n_bad = sum(1 for r in rows if r[5])
    print("")
    print("共 %d 处引用，%d 处形状不合格。" % (len(rows), n_bad))

    if not rows:
        # 防呆：一处都没扫到，最可能是**匹配规则坏了**（改了引用写法忘了改正则）。
        # 那种情况下这个脚本会"全部合格"地退出 0 —— 正好是最坏的一种假通过。
        print("")
        print("!! 一处引用都没扫到。多半是引用写法变了、下面的正则没跟着改，")
        print("   而不是代码里真的没有引用。先查本脚本的 SEC_CITE_RE / MD_CITE_RE。")
        return 1

    if n_bad:
        print("")
        print("形状只是下限。**语义**还得人看上面那张表：那一行讲的是不是那回事。")
        return 1
    print("形状全部合格。")
    print("")
    print("⚠️ 但形状对 ≠ 指得对。上面那张表要人再过一眼 ——")
    print("   脚本判不了「§5.2:297 那一行讲的是不是参数非法」。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
