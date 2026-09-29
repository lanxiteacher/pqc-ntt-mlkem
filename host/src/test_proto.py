"""proto.py 的自测 —— 直接读 proto.md §5.4 那张对照表，逐条复算。

运行
    PYTHONIOENCODING=utf-8 python host/src/test_proto.py

它在验什么
    验一件事：proto.md §5.4 里那张「本协议用到的全部校验值」，
    和 proto.py 的算法算出来的是不是一致。

为什么直接从 proto.md 读，而不在脚本里抄一份
    proto.md 是草案，W2 冻结前还会改（§六 有 12 条待拍板）。要是脚本里抄一份，
    两份就会各自漂移 —— 改文档的人忘了改脚本，脚本还会照旧打印「全部通过」，
    那就成了「在报平安的方向上撒谎」。
    直接从 proto.md 读，全仓库只剩一份表，想对不上都对不上。

    附带好处：跑一次这个脚本，就等于回答了「proto.md 改了之后，
    proto.py 那 4 个函数要不要跟着改」—— **通过就是不用改**。

读法（锚点 + 严格行匹配，任何一处不对劲都大声报错）
    1. 找到含「本协议用到的全部校验值」的那一行；
    2. 取它后面连续的表格行；
    3. 每一行必须长成  | `正文` | `*xx` |   （xx 为 2 位小写十六进制）。
       读不懂的行直接报错退出，**绝不静默跳过**。

不写死条数
    proto.md 那张表目前 14 条，但已知它漏了 3 条（`#OK ABORT` / `#PMUL FULL 1` /
    `#OK PING`，待补）。所以脚本只报「N/N 通过」，不断言 N 等于几。
    表补到 17 条时，这个脚本不用改。
"""

import re
import sys
from pathlib import Path

import proto

PROTO_MD = Path(__file__).resolve().parent.parent / "proto.md"
ANCHOR = "本协议用到的全部校验值"
ROW_RE = re.compile(r"^\|\s*`([^`]+)`\s*\|\s*`\*([0-9a-f]{2})`\s*\|\s*$")
SEP_RE = re.compile(r"^\|[\s:\-|]+\|\s*$")


def load_table():
    """从 proto.md 里把那张对照表读出来，返回 [(正文, 校验), ...]。"""
    lines = PROTO_MD.read_text(encoding="utf-8").splitlines()

    start = next((i for i, ln in enumerate(lines) if ANCHOR in ln), None)
    if start is None:
        raise SystemExit(
            "!! 在 %s 里找不到锚点「%s」。\n"
            "   proto.md 的 §5.4 大概被改动过了，这个脚本的读法要跟着改。" % (PROTO_MD, ANCHOR))

    # 锚点行和表格之间可能隔着空行，先跳过去
    i = start + 1
    while i < len(lines) and not lines[i].strip():
        i += 1

    rows = []
    while i < len(lines) and lines[i].startswith("|"):
        rows.append(lines[i])
        i += 1

    if not rows:
        raise SystemExit(
            "!! 锚点「%s」后面没找到表格。检查 %s 的 §5.4 是不是被改过。"
            % (ANCHOR, PROTO_MD))

    # 第 1 行是表头「| 行 | 校验 |」就跳过；万一没有表头，则整块都用
    data_rows = rows if ROW_RE.match(rows[0]) else rows[1:]

    table = []
    for ln in data_rows:
        if SEP_RE.match(ln):     # |---|---| 这样的分隔行
            continue
        m = ROW_RE.match(ln)
        if not m:
            raise SystemExit(
                "!! 表格里有一行没读懂：\n   %r\n"
                "   要么格式被改过，要么校验不是「2 位小写十六进制」。\n"
                "   这里不静默跳过 —— 读不懂就是错。" % ln)
        table.append((m.group(1), m.group(2)))

    if not table:
        raise SystemExit("!! 锚点后面没解析出任何数据行，检查 %s 的表格格式。" % PROTO_MD)
    return table


def main():
    table = load_table()
    print("表来源：%s" % PROTO_MD)
    print("读到 %d 条。" % len(table))
    print("")

    failures = []
    for body, expected in table:
        # 1) 算法算出来的校验，和表里写的是否一致
        got = proto.checksum_hex(body)
        if got != expected:
            failures.append("checksum_hex(%r) = %s，proto.md 表里写的是 %s" % (body, got, expected))
            continue

        # 2) 拼出来的整行
        line = proto.append_checksum(body)
        want = body + "*" + expected
        if line != want:
            failures.append("append_checksum(%r) = %r，期望 %r" % (body, line, want))
            continue

        # 3) 再拆回去（末尾不带换行、带 LF 两种）
        if proto.split_checksum(line) != (body, expected):
            failures.append("split_checksum(%r) 没能还原出 (%r, %r)" % (line, body, expected))
        elif proto.split_checksum(line + "\n") != (body, expected):
            failures.append("split_checksum(%r) 没能还原出 (%r, %r)"
                            % (line + "\\n", body, expected))

    if failures:
        print("%d 条里有 %d 条对不上：" % (len(table), len(failures)))
        for f in failures:
            print("  x", f)
        print("")
        print("结论：proto.py 的算法和 proto.md 当下的表**不一致**。")
        print("      要么表错了，要么校验规则改了而代码没跟着改。别猜，去和 A 对。")
        return 1

    print("%d/%d 通过" % (len(table), len(table)))
    print("")
    print("=> proto.py 的算法适配 proto.md 当下的表。")
    print("   以后 proto.md 改了，重跑本脚本：仍然通过，就说明那 4 个函数不用动。")

    # 顺带把两条已知的特殊值报出来（只报数，不做判定）
    by_name = dict(table)
    print("")
    print("顺带看一眼两条已知的特殊值（只报数，不做判定）：")
    if "#PMUL TIME 2" in by_name:
        print("  #PMUL TIME 2  ->  *%s   （proto.md:452：0 也是正常校验值）"
              % by_name["#PMUL TIME 2"])
    else:
        print("  #PMUL TIME 2 不在表里，跳过。")

    a, b = by_name.get("#PMUL NTT 1"), by_name.get("#OK NTT 1")
    if a is None or b is None:
        print("  #PMUL NTT 1 / #OK NTT 1 有缺，跳过。")
    else:
        print("  #PMUL NTT 1 = *%s， #OK NTT 1 = *%s  ->  %s"
              % (a, b, "相同（即 proto.md:453 的说法）" if a == b else "不同"))

    return 0


if __name__ == "__main__":
    sys.exit(main())
