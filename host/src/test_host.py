"""host.py 的自测 —— 事务状态机，重点是 §5.5 那五条关键规则「没接上时怎么办」。

运行
    PYTHONIOENCODING=utf-8 python host/src/test_host.py

它在验八件事
    1. **顺利路径** —— 一条事务走到底，收到的 256 行逐行等于 *_exp.txt 里那一组；
    2. **超时 → 重试成功**（规则二）—— 先发 #ABORT*69、把 #OK ABORT 读掉、整条重发；
    3. **重试有上限** —— 命令永远超时但 #ABORT 有应答时，**恰好重发 3 次**后放弃，
       不死循环、不抛异常，本事务记 FAILED；
    4. **链路真的死了就停** —— 连 #ABORT 都没人应，**一次尝试就停整轮**，
       干净退出而不是卡死（§5.5:567 那条验收要的就是这个）；
    5. **收到 #ERR 不重发**（规则三）—— 打印错误码和参数，本事务记 FAILED；
    6. **回显对不上就停整轮**（规则四）—— 而且 STOP 和 FAILED 是**两种可区分的结果**；
    7. **每次都留日志**（规则五）；
    8. **发出去的字节严格合规** —— 命令行带小写校验、数据行 3 位小写 hex 且不带校验。

关于「重试 3 次」到底算几次
    §5.5:518 写「整条事务从头重发，最多 3 次」。本文件按字面取**重发 3 次**
    → 总尝试 = 1 + 3 = 4 次。这句也能读成「总共 3 次」，所以要改就是
    `host.MAX_RETRIES` 一个数的事 —— 第 3 条就是钉住这个口径的。

关于「链路死了」算 STOP 而不是 FAILED
    §5.5 没写「发完 #ABORT 没人应」怎么办。host.py 取「停整轮」，第 4 条钉住它。
    理由写在 host.py 的模块 docstring (3)：连 #ABORT 都没人应，后面收到的字节
    全归属不明 —— 那正是规则四要停的情形。

⚠️ 覆盖范围的实话
    · 这里用的是**陪练**，不是真板子。真板子的时序抖动、CH340 的分包，
      这里一点都测不到。
    · 结果数据「算得对不对」不在这里验 —— 这里验的是「事务流程对不对」。
"""

import re
import sys

import fake_board
import host
import link
import proto
import vectors

FAILS = []
CHECKS = [0]


def check(cond, what):
    CHECKS[0] += 1
    if not cond:
        FAILS.append(what)


def eq(got, want, what):
    CHECKS[0] += 1
    if got != want:
        FAILS.append("%s\n      得到：%r\n      该是：%r" % (what, got, want))


# ---------------------------------------------------------------- 测试替身

class FlakyLink(link.Link):
    """测试替身：包一个真的 LoopbackLink，按剧本捣乱。

    ⚠️ 它在 **test_host.py** 里，**不**在 link.py 里 ——
       传输层本身不许认识协议（test_link.py 第 6 条守着这条）。

    能干的三种事（`rule(data)` 按 **写出去的字节** 决定）：
        "pass"     正常：喂给陪练，回帧照常进缓冲
        "swallow"  喂给陪练（板子状态照常推进），但**把回帧吞掉** —— 制造超时
        "dead"     连陪练都不喂 —— 制造「链路死了」
    `inject` 是排队等着顶替 read_line 的假回帧，用来制造 #ERR / 错位。
    """

    def __init__(self, board, rule=None, inject=None):
        self.inner = link.LoopbackLink(board)
        self.rule = rule or (lambda data: "pass")
        self.inject = list(inject or [])
        self.writes = []                 # 电脑写出去的每一段字节，原样记着

    def write(self, data):
        self.writes.append(data)
        verdict = self.rule(data)
        if verdict == "dead":
            return
        self.inner.write(data)
        if verdict == "swallow":
            self.inner.discard_pending()

    def read_line(self, max_wait):
        if self.inject:
            return self.inject.pop(0)
        return self.inner.read_line(max_wait)

    def discard_pending(self):
        return self.inner.discard_pending()


def fresh_board():
    return fake_board.FakeBoard()


def groups(name):
    return vectors.split_groups(vectors.read_vector(vectors.BATCH_DIR / name), name)


def aborts(writes):
    """从写出去的字节里挑出 #ABORT 那几条。"""
    return [w for w in writes if w.startswith(b"#ABORT")]


def main():
    ins = groups("ntt_batch_in.txt")
    exp = groups("ntt_batch_exp.txt")
    cmd = "#NTT 1"
    data = ins[0]

    # ------------------------------------------------------------ 1
    print("=== 1：顺利路径 ===")
    lk = link.LoopbackLink(fresh_board())
    txn = host.Host(lk).run(cmd, data)
    print("  %s" % txn.summary())
    eq(txn.outcome, host.RESULT_OK, "顺利路径没有成功")
    eq(txn.attempts, 1, "顺利路径不该重试")
    eq(len(txn.rows), 256, "收到的结果行数不对")
    eq(txn.rows, exp[0], "收到的结果和 *_exp.txt 那一组对不上")
    check(txn.error is None, "成功了却还留着错误信息：%r" % (txn.error,))

    # ------------------------------------------------------------ 2
    print("")
    print("=== 2：超时 → 发 #ABORT → 整条重发（规则二）===")
    seen = {"n": 0}

    def only_first_swallowed(d):
        if d.startswith(b"#NTT") and seen["n"] == 0:
            seen["n"] += 1
            return "swallow"
        return "pass"

    lk = FlakyLink(fresh_board(), rule=only_first_swallowed)
    txn = host.Host(lk).run(cmd, data)
    print("  %s" % txn.summary())
    eq(txn.outcome, host.RESULT_OK, "重发之后应该成功")
    eq(txn.attempts, 2, "应该是第 2 次尝试成功")
    eq(txn.rows, exp[0], "重发之后收到的结果不对")
    ab = aborts(lk.writes)
    eq(len(ab), 1, "应该恰好发过一次 #ABORT")
    eq(ab[0], b"#ABORT*69\n", "#ABORT 的字节不对（§5.5:515 要求 *69）")
    check(any("超时" in m for m in txn.log), "规则五：超时没留日志")
    check(any("重发" in m for m in txn.log), "规则五：重发没留日志")
    check(any("已读掉" in m for m in txn.log), "规则二：没记录「已读掉 #OK ABORT」")

    # ------------------------------------------------------------ 3
    print("")
    print("=== 3：重试有上限 —— 恰好重发 3 次后放弃（规则二第 3 条）===")
    lk = FlakyLink(fresh_board(),
                   rule=lambda d: "pass" if d.startswith(b"#ABORT") else "swallow")
    txn = host.Host(lk).run(cmd, data)
    print("  %s" % txn.summary())
    eq(txn.outcome, host.RESULT_FAILED, "重试耗尽应该是 FAILED（不是 STOP、不是卡死）")
    eq(txn.attempts, 4, "总尝试次数该是 1 首发 + 3 重发 = 4")
    # ⚠️ #ABORT 是 **4 次**不是 3 次：每次超时（含最后一次放弃之前）都得先喊一声，
    #    否则板子可能还赖在数据段里 —— 下一条命令的 `#` 会被它当成数据行，
    #    正是 §5.5:511 说的那种「两边都以为自己是对的」的静默错位。
    eq(len(aborts(lk.writes)), 4, "每次超时都该发一次 #ABORT（含放弃前那一次）")
    check(any("重发 3 次仍然失败" in m for m in txn.log), "放弃的理由没写清楚")
    check(any("重发" in m for m in txn.log), "规则五：重试次数没留日志")
    print("  日志：")
    for m in txn.log:
        print("    · %s" % m)

    # ------------------------------------------------------------ 4
    print("")
    print("=== 4：链路真的死了 —— 一次尝试就停整轮，不卡死 ===")
    lk = FlakyLink(fresh_board(), rule=lambda d: "dead")
    txn = host.Host(lk).run(cmd, data)
    print("  %s" % txn.summary())
    eq(txn.outcome, host.RESULT_STOP, "连 #ABORT 都没人应，该停整轮")
    eq(txn.attempts, 1, "链路死了不该傻等重试")
    check("等不到任何应答" in (txn.error or ""), "停整轮的理由没说清")

    # ------------------------------------------------------------ 5
    print("")
    print("=== 5：收到 #ERR 不重发（规则三）===")
    err_line = proto.append_checksum("#ERR 02 2 domain-word-not-TIME-NTT") + "\n"
    print("  注入的假回帧：%r" % err_line)
    lk = FlakyLink(fresh_board(), rule=lambda d: "swallow",
                   inject=[err_line.encode("ascii")])
    txn = host.Host(lk).run(cmd, data)
    print("  %s" % txn.summary())
    eq(txn.outcome, host.RESULT_FAILED, "#ERR 该记 FAILED（不是 STOP）")
    eq(txn.attempts, 1, "规则三：收到 #ERR 不许重发")
    eq(len(aborts(lk.writes)), 0, "规则三：收到 #ERR 不该发 #ABORT")
    check((txn.error or "").startswith("#ERR 02 2"),
          "错误码和它带的参数没打印出来：%r" % (txn.error,))

    # ------------------------------------------------------------ 6
    print("")
    print("=== 6：回显对不上就停整轮（规则四）===")
    wrong = proto.append_checksum("#OK INTT 1") + "\n"
    print("  发的是 #NTT 1，注入的回帧是：%r" % wrong)
    lk = FlakyLink(fresh_board(), rule=lambda d: "swallow",
                   inject=[wrong.encode("ascii")])
    txn = host.Host(lk).run(cmd, data)
    print("  %s" % txn.summary())
    eq(txn.outcome, host.RESULT_STOP, "回显对不上该停整轮（STOP），不是 FAILED")
    eq(txn.attempts, 1, "错位了不该重试")
    eq(len(aborts(lk.writes)), 0, "错位了不该发 #ABORT")
    check("回显对不上" in (txn.error or ""), "没说清是回显对不上：%r" % (txn.error,))

    print("")
    print("  6b：回帧校验值是错的 —— 也该停整轮")
    bad_ck = b"#OK NTT 1*f0\n"
    lk = FlakyLink(fresh_board(), rule=lambda d: "swallow", inject=[bad_ck])
    txn = host.Host(lk).run(cmd, data)
    print("  %s" % txn.summary())
    eq(txn.outcome, host.RESULT_STOP, "回帧校验错该停整轮")
    check("校验对不上" in (txn.error or ""), "没说清是校验错：%r" % (txn.error,))

    print("")
    print("  6c：结果行里混进一个 # 开头的行 —— 也算错位（§5.5:543）")
    lk = FlakyLink(fresh_board(),
                   rule=lambda d: "pass",
                   inject=[b"#DONE NTT 1 256*4d\n"])
    # 这条注入发生在等 #OK 的时候，所以它会先被判成「正等 #OK，收到的却是 #DONE」
    txn = host.Host(lk).run(cmd, data)
    eq(txn.outcome, host.RESULT_STOP, "等 #OK 时收到 #DONE 该停整轮")

    # ------------------------------------------------------------ 7
    print("")
    print("=== 7：规则五 —— 不做静默恢复 ===")
    lk = FlakyLink(fresh_board(),
                   rule=lambda d: "pass" if d.startswith(b"#ABORT") else "swallow")
    txn = host.Host(lk).run(cmd, data)
    retries = [m for m in txn.log if "重发" in m or "超时" in m]
    check(len(retries) >= 3, "四次尝试只留了 %d 条日志 —— 静默重试了？" % len(retries))
    print("  重试/超时相关日志 %d 条（4 次尝试至少该有 3+3 条）" % len(retries))
    for m in retries[:4]:
        print("    · %s" % m)

    # ------------------------------------------------------------ 8
    print("")
    print("=== 8：发出去的字节严格合规 ===")
    lk = link.LoopbackLink(fresh_board())
    txn = host.Host(lk).run(cmd, data)
    cmds = [b for b in txn.sent_bytes if b.startswith(b"#")]
    rows = [b for b in txn.sent_bytes if not b.startswith(b"#")]
    eq(len(cmds), 1, "一条事务只该发一条命令行")
    eq(len(rows), 256, "数据行数不对")

    for b in cmds:
        txt = b.decode("ascii")
        check(txt.endswith("\n"), "命令行不是 LF 行尾：%r" % b)
        check("\r" not in txt, "命令行里有 CR：%r" % b)
        stem, got = proto.split_checksum(txt[:-1])      # 不合规会抛 ValueError
        # ⚠️ 「小写」管的是**校验值和数据**，不是命令名 —— `#NTT` 本来就是大写
        #    （§5.3.1 说的是系数要小写、§5.4 说的是校验要 2 位小写十六进制）。
        eq(got, got.lower(), "校验值不是小写：%r" % b)
        eq(got, proto.checksum_hex(stem), "命令行的校验值不对：%r" % b)
        print("  命令行：%r  校验 %s" % (b, got))

    bad_shape = [b for b in rows if not re.fullmatch(rb"[0-9a-f]{3}\n", b)]
    check(not bad_shape, "有数据行不是「3 位小写 hex + LF」：%r" % bad_shape[:3])
    check(all(b"*" not in b for b in rows), "数据行里不该有校验（§5.4:401）")
    eq([b.decode("ascii")[:-1] for b in rows], data, "发出去的数据行和输入文件对不上")
    print("  数据行：256 行，前 3 行 %r" % [b.decode("ascii").strip() for b in rows[:3]])
    print("  检查：全是 3 位小写 hex + LF，且一个校验符都没有")

    # ------------------------------------------------------------
    print("")
    if FAILS:
        print("%d 项检查，%d 项不过：" % (CHECKS[0], len(FAILS)))
        for f in FAILS:
            print("  x " + f)
        return 1
    print("%d 项检查通过。" % CHECKS[0])
    print("")
    print("⚠️ 记住：这里用的是陪练，不是真板子。真时序抖动测不到。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
