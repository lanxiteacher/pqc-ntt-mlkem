"""fake_board.py 数据段（第 2 层）的自测 —— 第③步。

运行
    PYTHONIOENCODING=utf-8 python host/src/test_fake_board_data.py

它在验五件事
    1. 一条事务能走到底：喂够数据行 → `#BEGIN` + 结果 + `#DONE`，回到等命令行；
    2. 回传的结果**逐行等于**那一组的 `*_exp.txt`（顺序、字节都不许动）；
    3. **每一组都认**：16 组数据分别发进去，回的必须是各回各的答案 ——
       尤其不能「不管发哪组，永远回第 0 组」；
    4. 陪练**真的在核对**：改坏一个字符就认不出是哪一组，
       而且**不许回那一组的正确答案**（那就成了过度配合）；
    5. **错误路径（第④步）**：数据行格式错回 `#ERR 04`（位置 = 第一个非法字符的
       列号，从 1 数）、行超时回 `#ERR 05`（位置 = 已收行数）、数据段里的 `#ABORT`
       回 `#OK ABORT` 并作废本事务；**每条错误回帧之后都必须回到等命令行**。
    6. **草案真没写**的那几条路径仍然显式 raise（不替协议编规矩）。

⚠️ 本层**不验**「开机那一行 `#RDY`」
    2026-10-07 A 把 `#RDY <ver> <build> <errs>` 落进了 RTL，陪练跟着学：复位后
    第一次 `feed()` 会多吐一行。本文件每条用例都用 `fresh()` 开陪练，**先把它取走** ——
    那条路径专归 `test_host.py` 第 10 条（`Host.handshake()`）验。理由见 `fresh()`。

⚠️ 覆盖范围：5 条命令里**只覆盖 3 条**。
   `#PMUL TIME` / `#PMUL FULL` 被**外部问题**挡住 —— 向量文件没补零，见 BLOCKED。
   本脚本装了一条**绊线**：向量一修好，它会主动报错，逼着把这两条接回来。

标准答案从哪来
    · `#OK` / `#BEGIN` / `#DONE` 的校验值 —— proto.md:444-449 那六行（经 test_proto 验过）；
    · 结果正文 —— `refsim/batch/*_exp.txt` 本身。
      ⚠️ 这一条对「数值算得对不对」是**循环的**（同一个文件既是答案又是被检对象）。
      它验的是「陪练有没有**原样、按组**把文件吐出来」这件机械属性，
      **不**验那些数算得对不对 —— 那是 A 的 RTL 和 refsim 的事。
"""

import re
import sys

import proto
import fake_board
import test_proto

BATCH = fake_board.BATCH_DIR
GL = fake_board.GROUP_LEN

# 协议规定的数据行形状（§5.3.1:322，板子端宽容大写 §5.3.1:323）
HEX_RE = re.compile(r"^[0-9a-fA-F]{3}$")

# ⚠️ 被**外部问题**挡住的两条命令。
#    不是陪练的问题，也不是上位机的问题 —— 是**向量文件没补零**：
#    halfmul_b.txt / halfmul_exp.txt / fullmul_exp.txt 里有 `27` 这样的 2 位值，
#    按 §5.3.1:322「长度必须正好 3」它们不是合法的数据行。
#    挡的不只是陪练：上位机拿 `*_exp.txt` 当对拍基准，一样会撞同一面墙。
#    修它是**改动已冻结的 H2 黄金向量**，要通知 A / C，所以不在这里顺手做。
BLOCKED = {
    "#PMUL TIME 1": ["halfmul_a.txt", "halfmul_b.txt", "halfmul_exp.txt"],
    "#PMUL FULL 1": ["fullmul_a.txt", "fullmul_b.txt", "fullmul_exp.txt"],
}


def lines_of(name):
    """测试自己读向量文件，**不借 fake_board.read_vector** ——
    免得那边有个 bug，两边一起错还照样打印「通过」。"""
    txt = (BATCH / name).read_text(encoding="utf-8")
    return [ln.strip() for ln in txt.splitlines() if ln.strip()]


def group_of(name, i):
    return lines_of(name)[i * GL:(i + 1) * GL]


def bad_lines(name):
    """该文件里不是「恰好 3 位十六进制」的 (行号, 内容)。行号按**文件实际行**算，从 1 起。"""
    txt = (BATCH / name).read_text(encoding="utf-8")
    out = []
    for i, raw in enumerate(txt.split("\n"), 1):
        ln = raw.rstrip("\r")
        if ln and not HEX_RE.match(ln):
            out.append((i, ln))
    return out


def fresh(build=1):
    """开一台陪练，并**先把它开机自发的那行 `#RDY` 取走**。

    2026-10-07 A 把 `#RDY <ver> <build> <errs>` 落进了 RTL（`proto_fsm.v` 的
    `S_RDY`，复位落点由 `S_IDLE` 改成 `S_RDY`），陪练跟着学：复位之后**第一次**
    `feed()` 会在这条应答**前面**多吐一行 `#RDY`（`fake_board.boot_lines()`）。
    不取走的话，本文件每条用例读到的第一行都是它，后面全体错位一格。

    ⚠️ 本层验的是**数据段**行为，**不是**「吃掉 `#RDY`」那一条 —— 那一条在
       `test_host.py` 第 10 条（`Host.handshake()`），生产路径上也由它读掉，
       而且**内容要留着**（`<build>` 是解包 FNTT 读出序的唯一依据）。
       这里按测试的方便先取走；取走之后本文件每条断言说的还是「数据段」那件事。
       （同样的做法：`test_host.py` 的 `drain_boot()`、`test_link.py` 的 `fresh_link()`。）
    """
    b = fake_board.FakeBoard(build=build)
    b.boot_lines()
    return b


def cmd(body):
    return proto.append_checksum(body)


def frame(body, table):
    """期望的整行 + 校验的来源（「表」或「算法」）。"""
    ck = table.get(body)
    if ck is not None:
        return body + "*" + ck, "表"
    return proto.append_checksum(body), "算法"


def run(board, cmd_body, data_lines):
    """走一条事务：发命令 + 逐行喂数据，返回收到的所有行。"""
    out = list(board.feed(cmd(cmd_body)))
    for ln in data_lines:
        out += board.feed(ln)
    return out


def main():
    table = dict(test_proto.load_table())
    failures = []
    checks = [0]

    def check(cond, what):
        checks[0] += 1
        if not cond:
            failures.append(what)

    print("校验表来源：%s（%d 条）" % (test_proto.PROTO_MD, len(table)))
    print("向量目录　：%s" % BATCH)
    print("")

    # ---- 0) 五条命令的向量对应关系 ----
    print("命令 -> 输入文件 -> 输出文件（依据各 *_batch_tb.v 的 $readmemh）")
    plan = [
        ("#NTT 1",       ["ntt_batch_in.txt"],                     "ntt_batch_exp.txt"),
        ("#INTT 1",      ["intt_batch_in.txt"],                    "intt_batch_exp.txt"),
        ("#PMUL NTT 1",  ["pwm2_batch_a.txt", "pwm2_batch_b.txt"], "pwm2_batch_exp.txt"),
        ("#PMUL TIME 1", ["halfmul_a.txt", "halfmul_b.txt"],       "halfmul_exp.txt"),
        ("#PMUL FULL 1", ["fullmul_a.txt", "fullmul_b.txt"],       "fullmul_exp.txt"),
    ]
    for cmd_body, ins, out_name in plan:
        mark = "  ⚠️ 未测" if cmd_body in BLOCKED else ""
        print("  %-14s <- %-40s -> %s%s" % (cmd_body, " + ".join(ins), out_name, mark))
    n_groups = len(lines_of("ntt_batch_in.txt")) // GL
    print("  每组 %d 个系数；向量文件共 %d 组。" % (GL, n_groups))
    print("")

    # ---- 1) #PING 不该开数据段 ----
    b = fresh()
    got = b.feed(cmd("#PING"))
    want, _ = frame("#OK PING", table)
    check(got == [want], "#PING 的应答：实际 %r，期望 %r" % (got, [want]))
    check(b.state == "CMD", "#PING 之后不该进数据段，实际状态 %r" % b.state)
    print("1) #PING      -> %s   状态=%s" % (got[0], b.state))

    # ---- 2) 能跑的命令 x 每一组 ----
    print("")
    print("2) 能跑的命令 x %d 组，每组各走一遍完整事务" % n_groups)
    covered = 0
    for cmd_body, ins, out_name in plan:
        if cmd_body in BLOCKED:
            continue                       # 被外部问题挡住，见下面 2b
        covered += 1
        b = fresh()
        firsts = {}
        for i in range(n_groups):
            data = []
            for name in ins:
                data += group_of(name, i)
            out = run(b, cmd_body, data)
            exp = group_of(out_name, i)

            want_ok, _ = frame("#OK " + cmd_body[1:], table)
            want_beg, s2 = frame("#BEGIN %s %d" % (cmd_body[1:], GL), table)
            want_don, s3 = frame("#DONE %s %d" % (cmd_body[1:], GL), table)

            check(len(out) == GL + 3,
                  "%s 第 %d 组：应答应 %d 行，实际 %d 行" % (cmd_body, i, GL + 3, len(out)))
            check(out[0] == want_ok, "%s 第 %d 组首帧：%r" % (cmd_body, i, out[0]))
            check(out[1] == want_beg, "%s 第 %d 组 BEGIN：%r != %r" % (cmd_body, i, out[1], want_beg))
            check(out[-1] == want_don, "%s 第 %d 组 DONE：%r != %r" % (cmd_body, i, out[-1], want_don))
            check(out[2:-1] == exp,
                  "%s 第 %d 组的结果正文和 %s 对不上" % (cmd_body, i, out_name))
            check(b.state == "CMD", "%s 第 %d 组结束后该回到等命令行" % (cmd_body, i))
            check(b.group == i, "%s 第 %d 组：陪练认成了第 %r 组" % (cmd_body, i, b.group))
            check(b.mismatches == [], "%s 第 %d 组不该有 mismatch" % (cmd_body, i))
            firsts[i] = out[2]
        # 各回各的答案：不能「不管发哪组，永远回第 0 组」
        check(len(set(firsts.values())) > 1,
              "%s：16 组回的首个系数全都一样，疑似永远回第 0 组" % cmd_body)
        print("   %-14s %d 组全过；结果首系数 第0组=%s 第1组=%s 第%d组=%s"
              % (cmd_body, n_groups, firsts[0], firsts[1], n_groups - 1, firsts[n_groups - 1]))

    # ---- 2b) 被外部问题挡住的两条 ----
    print("")
    if BLOCKED:
        print("2b) ⚠️ 这两条**没测** —— 被外部问题挡住，不是陪练的问题")
    for cmd_body, names in BLOCKED.items():
        hit = {n: bad_lines(n) for n in names}
        hit = {n: v for n, v in hit.items() if v}
        if not hit:
            # 绊线：向量修好了，这个「跳过」就必须失效，否则会变成永久的遗忘
            failures.append(
                "%s 的向量已经补齐了！请把 BLOCKED 里这一条移到上面的正常用例里，"
                "别再跳过它。" % cmd_body)
            print("   !! %s 的向量已经没有不合规行了 —— 请解除跳过。" % cmd_body)
            continue
        print("   %-14s 未测。原因：%d 个向量文件共 %d 行没补零 ——"
              % (cmd_body, len(hit), sum(len(v) for v in hit.values())))
        for n, v in hit.items():
            print("       %-20s 首个不合规是第 %d 行 %r（该文件共 %d 行不合规）"
                  % (n, v[0][0], v[0][1], len(v)))
        print("       备选走法：#NTT 1 + #PMUL NTT 1 + #INTT 1 三步分开走，结果逐比特相同。")

    # ---- 3) 改坏一个字符：必须认不出组，且不许回那一组的正确答案 ----
    print("")
    print("3) 精确匹配红线（改坏一个字符）  —— 用 #PMUL NTT 1（向量干净）")
    i = 3
    good_a = group_of("pwm2_batch_a.txt", i)
    good_b = group_of("pwm2_batch_b.txt", i)
    bad_a = list(good_a)
    bad_a[2] = "000" if good_a[2] != "000" else "001"

    b_bad = fresh()
    out_bad = run(b_bad, "#PMUL NTT 1", bad_a + good_b)
    exp_i = group_of("pwm2_batch_exp.txt", i)
    exp_0 = group_of("pwm2_batch_exp.txt", 0)

    check(b_bad.group is None,
          "改坏一个字符后不该认得出组，实际认成第 %r 组" % b_bad.group)
    check(b_bad.nearest == i,
          "最接近的应该是第 %d 组（只为报信），实际 %r" % (i, b_bad.nearest))
    check(b_bad.mismatches == [(3, bad_a[2], good_a[2])],
          "差异记录应指向第 3 行，实际 %r" % (b_bad.mismatches,))
    check(out_bad[2:-1] != exp_i,
          "!! 不该回第 %d 组的正确答案 —— 那等于把错误认了下来（过度配合）" % i)
    check(out_bad[2:-1] == exp_0, "一组都对不上时应回退到第 0 组的答案")
    check(bool(b_bad.notes), "认不出组时应留一条 notes 说明「这轮不作数」")
    print("   发对第 %d 组 : group=%d，mismatch=0" % (i, i))
    print("   改坏第 3 行  : group=%r，nearest=%r，mismatch=%r"
          % (b_bad.group, b_bad.nearest, b_bad.mismatches))
    print("                  -> 回的**不是**第 %d 组的正确答案 ✅" % i)
    if b_bad.notes:
        print("                  notes: %s" % b_bad.notes[0])

    # ---- 4) 大写等价（§5.3.1:323 板子端宽容接收） ----
    # 必须挑一个**真的含字母**的系数来改，否则 .upper() 是空操作，这一条等于没测
    k = next((j for j, v in enumerate(good_a) if any(c in "abcdef" for c in v)), None)
    check(k is not None, "第 %d 组 A 里找不到含字母的系数，大写这条测不了" % i)
    upper = list(good_a)
    upper[k] = upper[k].upper()
    b_up = fresh()
    out_up = run(b_up, "#PMUL NTT 1", upper + good_b)
    check(upper[k] != good_a[k], "被改的那一行大小写没变，这条没测到东西")
    check(b_up.group == i, "大写应当等价，应认成第 %d 组，实际 %r" % (i, b_up.group))
    check(out_up[2:-1] == exp_i, "大写时回的结果应当就是第 %d 组的答案" % i)
    print("")
    print("4) 大写宽容    : 第 %d 行 %r -> %r，认成第 %r 组，mismatch=%d"
          % (k + 1, good_a[k], upper[k], b_up.group, len(b_up.mismatches)))

    # ---- 5) 空行忽略、不计入行数（§5.5:541） ----
    b_blank = fresh()
    out_blank = run(b_blank, "#PMUL NTT 1",
                    good_a[:10] + ["", "", "\r\n"] + good_a[10:] + good_b)
    check(b_blank.group == i, "夹空行后应仍认成第 %d 组，实际 %r" % (i, b_blank.group))
    check(out_blank[2:-1] == exp_i, "夹空行后应答帧变了")
    print("5) 夹 3 个空行 : 认成第 %r 组，mismatch=%d"
          % (b_blank.group, len(b_blank.mismatches)))

    # ---- 6) 错误路径（第④步） ----
    print("")
    print("6) 错误路径：数据行格式错 -> #ERR 04；行超时 -> #ERR 05；#ABORT -> #OK ABORT")

    # 6a) 数据行格式错 —— 位置 = 第一个非法字符的列号（从 1 数）
    #     ⚠️ 「从 1 数」是**草案没写死的一处**，本层在 pos_of_bad_data_line() 里定的，
    #        已列入给 A 的待确认清单。这里锁住它，免得将来悄悄变。
    print("")
    print("6a) 数据行格式错：位置字段的取值（列号从 1 数）")
    bad_cases = [
        ("0g4",   2, "'g' 在第 2 列"),
        ("#FOO",  1, "数据段里的命令，'#' 在第 1 列"),
        ("0",     2, "只有 1 位：位置 = 本该有字符的第 2 位"),
        ("04",    3, "只有 2 位：位置 = 本该有字符的第 3 位"),
        ("0123",  4, "4 位：第 4 列是第一个越界的"),
    ]
    for line, want_pos, why in bad_cases:
        b = fresh()
        b.feed(cmd("#PMUL NTT 1"))
        got = b.feed(line)
        want = proto.append_checksum("#ERR 04 %d" % want_pos)
        check(got == [want], "数据行 %r -> 实际 %r，期望 %r" % (line, got, [want]))
        check(b.state == "CMD",
              "回 #ERR 后必须回到等命令行（§5.5:509），%r 之后是 %r" % (line, b.state))
        check(b.received == [], "回 #ERR 后行缓冲该清空，实际 %r" % (b.received,))
        check(len(b.notes) > 0, "回 #ERR 时该在 notes 里留一句为什么")
        print("   %-8r -> %-24s 位置=%d  (%s)" % (line, got[0], want_pos, why))

    # 6b) 行超时（T_LINE）-> #ERR 05，位置 = 已收到的行数
    print("")
    b_to = fresh()
    b_to.feed(cmd("#PMUL NTT 1"))
    for ln in good_a[:7]:
        b_to.feed(ln)
    got = b_to.timeout()
    want = proto.append_checksum("#ERR 05 7")
    check(got == [want], "行超时 -> 实际 %r，期望 %r" % (got, [want]))
    check(b_to.state == "CMD", "超时后必须回到等命令行，实际 %r" % b_to.state)
    check(b_to.received == [], "超时后行缓冲该清空，实际 %r" % (b_to.received,))
    print("6b) 收 7 行后 T_LINE 超时 -> %s" % got[0])

    b_idle = fresh()
    check(b_idle.timeout() == [], "不在数据段里调 timeout() 不该回行（没有事务可超时）")

    # 6c) 数据段里收到 #ABORT -> #OK ABORT，本事务作废，能立刻接新命令
    print("")
    b_ab = fresh()
    b_ab.feed(cmd("#PMUL NTT 1"))
    for ln in good_a[:5]:
        b_ab.feed(ln)
    got = b_ab.feed(cmd("#ABORT"))
    want = proto.append_checksum("#OK ABORT")
    check(got == [want], "数据段里 #ABORT -> 实际 %r，期望 %r" % (got, [want]))
    check(b_ab.state == "CMD", "#ABORT 后必须回到等命令行，实际 %r" % b_ab.state)
    check(b_ab.received == [], "#ABORT 后行缓冲该清空，实际 %r" % (b_ab.received,))

    want_ping, _ = frame("#OK PING", table)
    after = run(b_ab, "#PING", [])
    check(after == [want_ping],
          "#ABORT 作废后应能立刻接新命令，实际 %r" % (after,))
    print("6c) 收 5 行后发 #ABORT -> %s" % got[0])
    print("    随后 #PING -> %s（说明真的回到了等命令行）" % after[0])

    # 校验对不上的 #ABORT 不算数 —— §5.2:299 把数据段里 # 开头的行默认判 04
    b_ab2 = fresh()
    b_ab2.feed(cmd("#PMUL NTT 1"))
    got = b_ab2.feed("#ABORT*00")
    check(bool(got) and got[0].startswith("#ERR 04"),
          "校验错的 #ABORT 该判 04，实际 %r" % (got,))
    print("    #ABORT 校验错 -> %s" % got[0])

    # 6d) 超长命令行（§5.5:544）-> #ERR 04，位置 = 第 65 列
    b_long = fresh()
    got = b_long.feed("#" + "0" * 64)
    want = proto.append_checksum("#ERR 04 %d" % (fake_board.MAX_CMD_LEN + 1))
    check(got == [want], "65 字节命令行 -> 实际 %r，期望 %r" % (got, [want]))
    print("")
    print("6d) 65 字节命令行（上限 %d）-> %s" % (fake_board.MAX_CMD_LEN, got[0]))

    # 6e) 草案**真没写**的路径，仍然必须显式 raise
    print("")
    print("6e) 草案真没写的路径，仍然必须显式 raise（不许在这里替协议编规矩）")
    still_undefined = [
        ("abc",                        "等命令行状态收到**不是 # 开头**的行"),
        ("#PING",                      "命令行缺 *xx"),
        ("#PING*ZZ",                   "校验位是大写、不是 2 位小写十六进制"),
        (proto.append_checksum("#NTT 2"), "n ≠ 1（§5.2:253 已冻结为 1，走不到）"),
    ]
    raised = 0
    for line, why in still_undefined:
        b = fresh()
        try:
            b.feed(line)
        except NotImplementedError:
            raised += 1
            print("   正确 raise : %-22r (%s)" % (line, why))
        else:
            failures.append("%r 应该 raise 但没 raise（%s）" % (line, why))
    check(raised == len(still_undefined),
          "仍应 raise 的数量不对：%d/%d" % (raised, len(still_undefined)))

    # ---- 收尾 ----
    print("")
    if failures:
        print("有 %d 处对不上（共 %d 项检查）：" % (len(failures), checks[0]))
        for f in failures:
            print("  x", f)
        return 1

    print("全部 %d 项检查通过。" % checks[0])
    print("")
    print("=> 陪练的第 2 层（数据段）行为，和 proto.md 一致：")
    print("   一个完整事务 = #OK -> (数据行) -> #BEGIN + 结果 + #DONE，")
    print("   并且 %d 组向量**各认各的**，不总是回第 0 组。" % n_groups)
    print("")
    print("⚠️ 覆盖范围：%d 条命令覆盖 %d 条，未覆盖 %d 条（被向量文件挡住，见 2b）。"
          % (len(plan), covered, len(BLOCKED)))
    print("   向量一修好，本脚本会**主动报错**提醒你把它们接回来 ——")
    print("   这个跳过不会悄悄变成遗忘。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
