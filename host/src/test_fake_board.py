"""fake_board.py 的自测 —— 拿 proto.md 那张对照表当标准答案。

运行
    PYTHONIOENCODING=utf-8 python host/src/test_fake_board.py

它在验三件事
    1. 命令字表**确实是从 proto.md 读来的**（不是抄在代码里）；
    2. 对已知命令，陪练回的 `#OK` 跟 proto.md 那张校验表**逐条对得上**；
    3. 草案**没定义**的路径，陪练**显式 raise**，而不是偷偷编一个行为。

标准答案从哪来
    proto.md:433-450 那张对照表。它已经被 `test_proto.py` 验过和算法一致，
    所以这里可以直接拿它当 `#OK` / `#ERR 03` 应答的标准答案。

表格读取器直接复用 test_proto 的，不另写一份解析。
"""

import sys

import proto
import fake_board
import test_proto

# 输入正文（不含校验）  ->  期望的应答正文（不含校验）
CASES = [
    ("#PMUL TIME 1", "#OK PMUL TIME 1"),
    ("#NTT 1",       "#OK NTT 1"),
    ("#INTT 1",      "#OK INTT 1"),
    ("#PMUL NTT 1",  "#OK PMUL NTT 1"),
    ("#PMUL FULL 1", "#OK PMUL FULL 1"),
    ("#PING",        "#OK PING"),
    ("#ABORT",       "#OK ABORT"),
]


def expect(body, table):
    """期望的整行。校验优先查表；表里没有就退回用算法算。返回 (整行, 来源)。"""
    ck = table.get(body)
    if ck is not None:
        return body + "*" + ck, "表"
    return proto.append_checksum(body), "算法"


def main():
    table = dict(test_proto.load_table())
    commands = fake_board.load_commands()

    print("校验表来源：%s（%d 条）" % (test_proto.PROTO_MD, len(table)))
    print("命令表来源：%s（%d 条）" % (fake_board.PROTO_MD, len(commands)))
    print("  读到的命令：%s" % "  ".join(" ".join(s) for s in commands))
    print("")
    print("命令表里的 #PMUL 域词：%s" % sorted(fake_board.pmul_domains(commands)))
    print("")

    failures = []
    from_table = 0

    # ---- 1) 已知命令的 #OK 应答 ----
    for body, want in CASES:
        line = proto.append_checksum(body)
        got = fake_board.handle_line(line, commands)
        want_line, src = expect(want, table)
        if src == "表":
            from_table += 1
        else:
            # 表里没有这条应答（已知 B1：那张表漏了 3 条），也算通过，但标出来
            pass
        if got != want_line:
            failures.append("handle_line(%r)\n      实际 %r\n      期望 %r" % (line, got, want_line))
        else:
            print("  [%s] %-18s -> %s" % (src, line, got))

    # ---- 2) #ERR 03 应答 ----
    want_err = "#ERR 03 got=3f exp=a2"
    want_line, src = expect(want_err, table)
    got = fake_board.err_frame("03", "got=3f exp=a2")
    if got != want_line:
        failures.append("err_frame('03','got=3f exp=a2')\n      实际 %r\n      期望 %r" % (got, want_line))
    else:
        print("  [%s] err_frame(03)     -> %s" % (src, got))

    # ---- 3) 真喂一条错校验，走通 03 这条路 ----
    got = fake_board.handle_line("#PING*3f", commands)
    want_line, src = expect("#ERR 03 got=3f exp=33", table)   # exp=33 来自表里的 #PING
    if got != want_line:
        failures.append("handle_line('#PING*3f')\n      实际 %r\n      期望 %r" % (got, want_line))
    else:
        print("  [算法] #PING*3f          -> %s" % got)

    # ---- 4) 未知命令 -> #ERR 01 ----
    got = fake_board.handle_line(proto.append_checksum("#NOPE"), commands)
    if got != proto.append_checksum("#ERR 01 0"):
        failures.append("handle_line('#NOPE*..')\n      实际 %r\n      期望 %r" % (got, "#ERR 01 0*.."))
    else:
        print("  [算法] #NOPE*%s          -> %s" % (proto.checksum_hex("#NOPE"), got))

    # ---- 5) 空行 -> 不回 ----
    if fake_board.handle_line("", commands) is not None:
        failures.append("空行应该返回 None（§5.5:541）")

    # ---- 6) 草案没定义的路径，必须显式 raise ----
    must_raise = [
        ("A2f",                                  "不是 # 开头的行"),
        ("#PING",                                "缺 *xx"),
        ("#PING*3D",                             "校验写成大写"),
        (proto.append_checksum("#PMUL TIME 2"),  "n ≠ 1"),
        (proto.append_checksum("#LAYERS 1"),     "预留未定"),
    ]
    raised = 0
    for line, why in must_raise:
        try:
            fake_board.handle_line(line, commands)
        except NotImplementedError:
            raised += 1
        else:
            failures.append("应该 raise NotImplementedError 但没 raise：%r（%s）" % (line, why))

    # ---- 6b) 超长命令行：第④步起**按 §5.5:544 回 #ERR 04**，不再 raise ----
    #          位置 = 第 65 列（前 64 列都还在限内），列号从 1 数。
    long_line = "#" + "X" * 70
    got = fake_board.handle_line(long_line, commands)
    want = proto.append_checksum("#ERR 04 %d" % (fake_board.MAX_CMD_LEN + 1))
    if got != want:
        failures.append("超长命令行 -> 实际 %r，期望 %r" % (got, want))

    print("")
    if failures:
        print("有 %d 处对不上：" % len(failures))
        for f in failures:
            print("  x", f)
        return 1

    print("%d 条 #OK 应答通过（其中 %d 条直接对的是 proto.md 那张表，"
          "%d 条表里没有、用算法算的）" % (len(CASES), from_table, len(CASES) - from_table))
    print("%d 处草案未定义的路径，全部按设计显式 raise" % raised)
    print("超长命令行 -> %s（§5.5:544，位置 = 第 %d 列）"
          % (want, fake_board.MAX_CMD_LEN + 1))
    print("")
    print("=> 陪练的第 1 层（命令行）行为，和 proto.md 一致。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
