"""host.py 的自测 —— 事务状态机，重点是 §5.5 那五条关键规则「没接上时怎么办」。

运行
    PYTHONIOENCODING=utf-8 python host/src/test_host.py

它在验十一件事
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
    9. **`probe()` 那条单独的路**（不带数据的命令 `#PING` / `#ABORT`）——
       探活成功 / 板子回 `#ERR`（拒，不是故障）/ 静默超时 / 回显对不上 / 校验错 /
       首词不认识 / 回帧夹 `\r` 与空行，各归哪一类；并且钉住两条约定：
       **只发一次、不发 `#ABORT`**（那是事务重试的路子）。
   10. **开串口先吃掉开机那行 `#RDY`**（`Host.handshake`，2026-10-07 A 落进 RTL）——
       吃掉并记下折叠度 / 旧位流没有它时原样返回 False / 第一行不是 `#RDY` 时
       **原样放回不吞**（这条保证它对旧位流无害）/ 校验错或字段数不对的不认。
   11. **「发几行」和「收几行」是两个数**（2026-10-07 `#PMUL` 错位）——
       `#PMUL NTT 1` 下行 512、板子只回 256，走到底；
       `#DONE` 的行数必须和 `#BEGIN` 自洽；调用方给的 `expect_rows` 也要和
       `#BEGIN` 自洽（给对了不碍事，给错了停整轮）。
       ⚠️ **本条是唯一能把改前/改后分开的证据**：其余各条只用 `#NTT 1`，
          那个命令 256 进 256 出，两个数碰巧相等，分辨不出来。

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
    `rewrite` 是**逐行过一道**的改写钩子（`bytes -> bytes`），陪练**照常正常回**，
                 只把回来的某一行换掉 —— 用来造「回帧本身合法、但内容不对」的错位
                 （第 11b 条：`#BEGIN` 说 256、`#DONE` 说 100）。
                 ⚠️ 与 `inject` 的分工：inject 是**凭空**喂一行（板子没发），
                    rewrite 是**改**板子真发的那一行 —— 后者才不会把帧序搞乱。
    """

    def __init__(self, board, rule=None, inject=None, rewrite=None):
        # 陪练是**已上电**的：它开机自发的那一行 `#RDY` 已经在线路上了。
        # 本文件验的是**事务状态机**，不是「吃掉 `#RDY`」那一条（那是第 10 条），
        # 所以这里按测试需要先把它取走 —— 否则每条用例的第一行都会读到 `#RDY`。
        # ⚠️ 取走 ≠ 丢掉：`Host.handshake()` 在生产路径里读它（见 host.py）。
        drain_boot(board)
        self.inner = link.LoopbackLink(board)
        self.rule = rule or (lambda data: "pass")
        self.inject = list(inject or [])
        self.rewrite = rewrite
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
            text = self.inject.pop(0)
        else:
            text = self.inner.read_line(max_wait)
        if self.rewrite is not None and text is not None:
            text = self.rewrite(text)
        return text

    def discard_pending(self):
        return self.inner.discard_pending()


def fresh_board():
    return fake_board.FakeBoard()


def drain_boot(board):
    """把陪练**开机自发的那一行 `#RDY`** 从它手里取走（有就取，没有就跳过）。

    ⚠️ 这是**测试**的方便法门，**不是**生产路径。生产上这一行由
       `Host.handshake()` 在读第一条回帧**之前**读掉，而且**内容要留着**
       （`<build>` 是解包 FNTT 的唯一依据）。本文件验的不是那件事，所以直接取走 ——
       取走之后本文件的每一条断言说的都还是「事务状态机」那件事。
       第 10 条专门验 handshake 本身。
    """
    boot = getattr(board, "boot_lines", None)
    return boot() if boot is not None else []


def fresh_link(board=None):
    """开一个「陪练当对端」的插座，**开机那一行已取走**（见 drain_boot）。"""
    board = board if board is not None else fresh_board()
    drain_boot(board)
    return link.LoopbackLink(board)


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
    lk = fresh_link()
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
    lk = fresh_link()
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

    # ------------------------------------------------------------ 9
    print("")
    print("=== 9：probe() —— 不带数据的命令（#PING / #ABORT）走单独一条路 ===")
    print("  为什么要有这条路：probe 塞进 run() 会在「等 #BEGIN」白等 5 s、再重发 3 次")

    # 9a 探活成功
    lk = FlakyLink(fresh_board())
    t = host.Host(lk).probe("#PING")
    eq(t.outcome, host.RESULT_OK, "探活 #PING 没成功")
    eq(t.raw, proto.append_checksum("#OK PING"), "回帧原文不对")
    eq(t.attempts, 1, "探活只该试 1 次")
    eq(t.rows, [], "探活没有结果行，rows 该是空的")
    check(t.error is None, "探活成功了却还留着错误信息：%r" % (t.error,))
    print("  %s" % t.summary())

    # 9b 不带数据、不重试、不发 #ABORT —— 这三条是 probe 与 run 的分界
    eq(len(lk.writes), 1, "探活只该往线上写一条命令，实测写了 %d 条" % len(lk.writes))
    check(not aborts(lk.writes), "探活竟然发了 #ABORT —— 那条路是给事务重试用的")

    # 9c #ABORT 本身也走 probe
    t = host.Host(FlakyLink(fresh_board())).probe("#ABORT")
    eq(t.outcome, host.RESULT_OK, "探活 #ABORT 没成功")
    eq(t.raw, proto.append_checksum("#OK ABORT"), "#ABORT 的回帧原文不对")

    # 9d 板子**拒**了这条命令：不是故障，是应答
    t = host.Host(FlakyLink(fresh_board())).probe("#FOO 1")
    eq(t.outcome, host.RESULT_FAILED, "#FOO 1 该记 FAILED（板子拒了它）")
    check(t.raw is not None and t.raw.startswith("#ERR 01"),
          "未知命令该回 #ERR 01，实收：%r" % (t.raw,))
    print("  %s" % t.summary())

    # 9e 链路静默 -> STOP + 超时，而且**不重发**
    lk = FlakyLink(fresh_board(), rule=lambda d: "dead")
    t = host.Host(lk).probe("#PING")
    eq(t.outcome, host.RESULT_STOP, "静默链路该记 STOP")
    check(t.raw is None, "一个字节都没收到，raw 该是 None")
    check("没收到" in (t.error or ""), "超时的说明里没讲清「没收到」：%r" % (t.error,))
    eq(len(lk.writes), 1, "链路静默时探活也**不许**重发（约定：探活只发一次）")

    # 9f 回显对不上 -> STOP（拿 `#OK WRONG` 冒充应答）
    #    ⚠️ inject 喂的是**字节** —— `link.read_line` 交出来的就是字节，
    #       传字符串会在 host.py 的 decode 那一步炸（这一条我写错过一次）。
    t = host.Host(FlakyLink(fresh_board(),
                            inject=[(proto.append_checksum("#OK WRONG")
                                     + "\n").encode("ascii")]
                            )).probe("#PING")
    eq(t.outcome, host.RESULT_STOP, "回显对不上该记 STOP")
    check("回显对不上" in (t.error or ""), "没报出「回显对不上」：%r" % (t.error,))

    # 9g 校验值错 -> STOP
    t = host.Host(FlakyLink(fresh_board(),
                            inject=[b"#OK PING*00\n"])).probe("#PING")
    eq(t.outcome, host.RESULT_STOP, "回帧校验错该记 STOP")
    check("校验" in (t.error or ""), "没报出校验问题：%r" % (t.error,))

    # 9h 首词不认识 -> STOP
    t = host.Host(FlakyLink(fresh_board(),
                            inject=[(proto.append_checksum("#WAT PING")
                                     + "\n").encode("ascii")]
                            )).probe("#PING")
    eq(t.outcome, host.RESULT_STOP, "回帧首词不认识该记 STOP")

    # 9i 回帧里夹 CR / 空行 -> 按 §5.5:541-542 丢掉，仍然认得出
    #    （要是 CR 没被丢掉，校验值就会变成 "17\r"，这一步必然红 —— 所以这条
    #      同时钉住了「CR 真的被处理了」）
    t = host.Host(FlakyLink(fresh_board(),
                            inject=[b"\n", b"#OK PING*17\r\n"])).probe("#PING")
    eq(t.outcome, host.RESULT_OK, "回帧夹了 CR/空行就认不出来了")
    eq(t.raw, proto.append_checksum("#OK PING"), "夹 CR 之后回帧原文不对")

    # ------------------------------------------------------------ 10
    print("")
    print("=== 10：开串口后先吃掉开机那行 #RDY（Host.handshake）===")
    # 2026-10-07 A 把 `#RDY` 落进了 RTL：复位释放后板子**不等命令**先自发一行。
    # 上位机是「发一条、读一行」的开环，这一行没人吃就会错位一格 ——
    # 症状是整轮在规则四上被停掉，看起来像协议错。本条钉住 handshake 的四种情形。

    # 10a 新位流：插座里躺着 `#RDY` -> 吃掉、记下折叠度、**且不影响紧随其后的事务**
    bd = fake_board.FakeBoard(build=4)
    lk = link.LoopbackLink(bd)                      # 注意：**不**调 drain_boot
    hst = host.Host(lk)
    check(hst.handshake(), "handshake 没认出插座里那行 #RDY")
    eq(hst.build, 4, "handshake 没记下 #RDY 的 <build>")
    eq(hst.board_version, 1, "handshake 没记下 #RDY 的 <ver>")
    eq(hst.board_errs, 0, "handshake 没记下 #RDY 的 <errs>")
    t = hst.probe("#PING")
    eq(t.outcome, host.RESULT_OK,
       "吃掉 #RDY 之后探活该照常成功 —— 没成功说明 handshake 多吃/少吃了一行")
    eq(t.raw, proto.append_checksum("#OK PING"), "吃掉 #RDY 之后回帧原文不对")

    # 10b 旧位流：插座里没有 `#RDY` -> 返回 False，**行为与加这个方法之前完全相同**
    lk = fresh_link()
    hst = host.Host(lk)
    check(not hst.handshake(), "旧位流（没有 #RDY）handshake 竟然报成功")
    check(hst.build is None, "没收到 #RDY 时 build 该是 None，不是别的值")
    eq(hst.probe("#PING").outcome, host.RESULT_OK, "旧位流上探活该照常成功")

    # 10c 第一行**不是** `#RDY` -> **原样放回**，不许吞掉
    #     （这一条是本方法最关键的一条：它保证 handshake 对旧位流是**无害**的。
    #       要是吞了，旧位流的第一条回帧就没了 —— 那是把「兼容」说成了「兼容」。）
    lk = fresh_link()
    lk.write((proto.append_checksum("#PING") + "\n").encode("ascii"))   # 回帧已在缓冲里
    hst = host.Host(lk)
    check(not hst.handshake(), "第一行是普通回帧时 handshake 不该报成功")
    eq(hst._read_line(1.0), proto.append_checksum("#OK PING"),
       "handshake 把那条不是 #RDY 的回帧**吞掉了** —— 旧位流上会丢一条帧")

    # 10d 校验对不上的 `#RDY` -> 当它不是 #RDY（放回），不抛异常
    #     （§5.2 说这一行是「尽力而为」，所以认不出只能当没有，不能当故障）
    #     ⚠️ 这里必须用 inject 直接喂**字节**，不能 `lk.write` —— write 是**发给板子**的
    #        命令行，板子会按校验错回 `#ERR 03`，那测的就变成了「#ERR 也算非 #RDY」。
    hst = host.Host(FlakyLink(fresh_board(), inject=[b"#RDY 1 4 0*00\n"]))
    check(not hst.handshake(), "校验错的 #RDY 竟然被认下了 —— 那会把错的折叠度当真")
    check(hst.build is None, "校验错的 #RDY 不该写进 build")

    # 10e 字段数不对的 `#RDY`（少了 <errs>）-> 同样不认
    hst = host.Host(FlakyLink(fresh_board(),
                              inject=[(proto.append_checksum("#RDY 1 4")
                                       + "\n").encode("ascii")]))
    check(not hst.handshake(), "只有两个字段的 #RDY 竟然被认下了")

    print("  10a 新位流吃掉 + 记下 build=4 ✓ ｜ 10b 旧位流无 #RDY ✓")
    print("  10c 非 #RDY 原样放回（不吞）✓ ｜ 10d 校验错的不认 ✓ ｜ 10e 字段数不对的不认 ✓")

    # ------------------------------------------------------------ 11
    print("")
    print("=== 11：#PMUL「发 512 行、只回 256 行」—— 收几行听板子的，不听自己的 ===")
    # 2026-10-07 真板子撞出来的
    # （logs/letter_2026-10-07_A_to_B_pmul_desync.txt，症状是整轮在 #BEGIN 上被判错位停掉）。
    # 根因：host.py 原来只有一个 `count`，既当「我要发几行」又当「我要收几行」。
    #   `#NTT 1` 恰好 256 进 256 出 —— 两个意思碰巧相等，所以这个 bug 一直没露头；
    #   `#PMUL NTT 1` 是 512 进 256 出，板子回 `#BEGIN PMUL NTT 1 256`，
    #   老代码拿它跟「我发了 512 行」比，对不上 → 规则四停整轮。
    # §5.2:287 定死了：`#BEGIN <count>` 的 count = **板子即将发出的（结果）行数**。
    # ⚠️ 这条用例是**唯一**能把改前和改后分开的证据 —— 别的模块只用 `#NTT 1`，
    #    那个数两版都对，分辨不出来。
    data_pmul = groups("pwm2_batch_a.txt")[0] + groups("pwm2_batch_b.txt")[0]   # 下行 A 256 + B 256
    exp_pmul = groups("pwm2_batch_exp.txt")[0]

    lk = FlakyLink(fresh_board())          # 用 FlakyLink 是为了能查 `.writes`（发了哪些字节）
    t = host.Host(lk).run("#PMUL NTT 1", data_pmul)
    print("  %s" % t.summary())
    eq(len(data_pmul), 512, "本条用例的前提不成立：下行该是 512 行（A 256 + B 256）")
    eq(t.sent, 512, "`Transaction.sent` 没记对「我发了几行」")
    eq(t.recv, 256, "`Transaction.recv` 没记对「板子说回几行」")
    eq(t.outcome, host.RESULT_OK, "#PMUL NTT 1 没成功 —— 就是 2026-10-07 那个错位")
    eq(t.attempts, 1, "#PMUL 顺利路径不该重试")
    eq(len(t.rows), 256, "收到的结果行数不对（该是 256 行结果，不是 512）")
    eq(t.rows, exp_pmul, "收到的结果和 pwm2_batch_exp.txt 对不上")
    eq(len(aborts(lk.writes)), 0, "顺利路径竟然发了 #ABORT")
    eq(sum(1 for w in lk.writes if not w.startswith(b"#")), 512,
       "往线上写的数据行不是 512 条（发送行数这一半老代码本来是对的，别改坏）")

    # 11b `#DONE` 必须和 `#BEGIN` 自洽
    #     造法：陪练**照常正常回**，只把 `#DONE` 那一行改掉，校验值重算成合法的 ——
    #     这样考的就是「前后两个数自洽」，不是校验。
    def bad_done(text):
        if text.startswith(b"#DONE"):
            return (proto.append_checksum("#DONE NTT 1 100") + "\n").encode("ascii")
        return text

    t = host.Host(FlakyLink(fresh_board(), rewrite=bad_done)).run(cmd, data)
    eq(t.outcome, host.RESULT_STOP, "#BEGIN 说 256、#DONE 说 100，竟然没停整轮")
    check("DONE 说的行数" in (t.error or ""),
          "没报出「DONE 行数对不上」：%r" % (t.error,))
    print("  11b 伪造 `#DONE NTT 1 100`（#BEGIN 说的是 256）→ STOP ✓")

    # 11c `expect_rows` —— 拆开了「发/收」之后，`#BEGIN` 成了唯一权威，
    #     板子若报一个「自己前后自洽（BEGIN==DONE）但整体是错的」数，就没第二个人核对。
    #     `expect_rows` 就是补回来的那一道。先钉「它不许把正常路径搞坏」：
    lk = FlakyLink(fresh_board())
    t = host.Host(lk).run("#PMUL NTT 1", data_pmul, expect_rows=256)
    eq(t.outcome, host.RESULT_OK, "给了**对的** expect_rows，反而把 #PMUL 弄失败了")
    eq(t.expect, 256, "Transaction.expect 没记住调用方给的数")
    eq(len(t.rows), 256, "给了 expect_rows 之后收到的行数不对")

    # 11d 再钉「板子自报的数和它不一样 → STOP」，且要说清是哪两个数对不上。
    #     ⚠️ 这里是拿一个**故意说错的 `expect_rows`** 去触发那道闸门（陪练只会按
    #        proto.md 回 256，改不动它自己的 OUT_LINES）。所以本条验的是
    #        「这道闸门会响、响的时候说的话对」，**不是**「真板子会这么干」。
    lk = FlakyLink(fresh_board())
    t = host.Host(lk).run("#PMUL NTT 1", data_pmul, expect_rows=512)
    eq(t.outcome, host.RESULT_STOP, "板子报 256、调用方说该是 512，竟然没停整轮")
    check("该是 512" in (t.error or ""),
          "陈述里没写明「该是 512」：%r" % (t.error,))
    check("256" in (t.error or ""),
          "陈述里没写明板子报的是 256：%r" % (t.error,))
    eq(len(t.rows), 0, "停整轮之前不该已经收了结果行")
    eq(len(aborts(lk.writes)), 0, "停整轮不是重发 —— 不该发 #ABORT")
    print("  11c 给对的 expect_rows（256）→ 照常 OK ✓")
    print("  11d 给错的 expect_rows（512，板子报 256）→ STOP，且两个数都写进陈述 ✓")

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
