"""上位机的心脏 —— 一次事务的流程，和「没接上时怎么办」。

它在干什么（大白话）
    一次事务就是打电话的流程：
        报一条命令 → 等对方说「听到了」→ 念数据 → 等对方说「我开始报数了」
        → 听结果 → 等对方说「念完了」。
    每一步都**必须有上限**（§5.5:480）：宁可报错退出，不可静默空等。
    接不上的时候按 §5.5 的五条关键规则处理（下面每条都标了出处）。

它**不**干的事
    · 不管数据往哪来、到哪去 —— 那是调用方的事（本文件的 run() 收现成的行）；
    · 不判数据对不对 —— 那是 unpack.py 的活；
    · 不认识向量文件 —— 那是 vectors.py 的活。
    这样这个文件能用**编造的数据**单独测，不需要向量文件、不需要板子。

五条关键规则落在哪
    一（超时后板子回到等命令行）  板子端的事，这里只是**依赖**它，不实现
    二（超时→#ABORT→重发≤3）      _abort() + run() 里的重试循环
    三（收到 #ERR 不重发）         _on_err()
    四（回显对不上就停整轮）       _wait_for() 里的回显核对；run() 返回 STOP
    五（不做静默恢复）             每一次重试、每一次容错都进 txn.log

开串口后**先吃一行** `#RDY`（2026-10-07 新增，因为 A 把它落进了 RTL）
    板子复位释放后**不等命令**先自发一行 `#RDY <ver> <build> <errs>`（§5.2 那张
    应答表的最后一行）。而本文件是按「发一条、读一行」的开环写的 —— 这一行要是
    没人吃，**第一行读到的就是它而不是 `#OK`**，之后每一行错位一格，整轮被规则四
    停掉（§5.5:527），症状看起来像协议错、其实少读了一行。
    `Host.handshake()` 就是干这个的：**开串口之后调一次**，把开机那一行捡走。
    它**不是同步点** —— 收不到 `#RDY` 是完全正常的结果（§5.2 说它是「尽力而为」
    的一行，上电瞬间电脑多半还没开串口监听），那时的行为与加这个方法之前**逐字节
    相同**。

⚠️ 三处 proto.md 没写清 / 有歧义的地方（我在代码里就地标了，别当没看见）
    (1) §5.5:493 的 `T_DONE` 起算点写的是「数据行收齐之后」。可「数据行」是电脑
        **发出去**的（`T_BEGIN` 那格才是「数据行发完之后」）。按事务顺序，
        `T_DONE` 该在**结果行**收齐之后。本文件按后者实现 —— 但这是**我的解读**，
        不是文档原话。已报给 B，等 B 与 A 确认。
    (2) §5.5:518「整条事务从头重发，最多 3 次」——「3 次」是**重发**次数还是**总**
        次数？本文件按字面取「重发 3 次」= 总尝试 1 + 3 = 4 次。见 MAX_RETRIES。
    (3) 发完 `#ABORT` 之后**等不到应答**怎么办，文档没写。本文件取「停整轮」
        （理由：连 `#ABORT` 都没人应，链路状态不可知，后面收到的字节全归属不明）。
        备选是「继续重试下一条」—— 那会在一条可能已死的链路上连打很多次。
"""

import time

import proto

# ---------------------------------------------------------------- 可调参数

# 超时值全部来自 §5.5:484-493 那张表，**留成参数不写死** ——
# 第 5 步真板联调时一定会调，写死了就得改代码。
T_OK = 1.0        # 电脑端：发出命令帧之后（§5.5:490）
T_BEGIN = 5.0     # 电脑端：数据行发完之后（§5.5:491）
T_RX = 1.0        # 电脑端：收到 #BEGIN 之后，每等一行（§5.5:492）
T_DONE = 1.0      # 电脑端：结果行收齐之后（§5.5:493，措辞见模块 docstring (1)）

# §5.5:518「整条事务从头重发，最多 3 次」。
# ⚠️ 按字面取「**重发** 3 次」→ 总尝试 = 1 次首发 + 3 次重发 = 4 次。
#    这句也能读成「总共 3 次」。真要改，改这一个数就行。
MAX_RETRIES = 3

# 三种结局。**失败**和**停整轮**必须是两种可区分的结果：
#   FAILED = 这一条不行，下一条接着来（§5.5:519）
#   STOP   = 错位了，后面收到的字节全归属不明，整批都得停（§5.5:527）
RESULT_OK = "OK"
RESULT_FAILED = "FAILED"
RESULT_STOP = "STOP"

# 回帧首词。§5.2:286-290 那张表 + §5.5:529 说的四个词。
HEAD_KINDS = {"#OK", "#BEGIN", "#DONE", "#ERR"}

# ⚠️ `#RDY` **不**在 HEAD_KINDS 里 —— 它不是事务的一环（没有「正在等它」的那一步），
#    而是开机自发的通知。它由 parse_rdy() 单独认，且在 handshake() 里被捡走。
#    放进 HEAD_KINDS 会让 _wait_for() 把它当成「正等的那条不对」以外的种类，
#    把「开机那一行没被吃掉」伪装成「错位」—— 那正是我们要分辨开的两件事。
RDY_PREFIX = "#RDY "    # 含尾空格：`#RDY 1 4 0*79`（§5.2）

ABORT = "#ABORT"    # §5.2:258；校验值见 §5.5:515


def parse_rdy(text):
    """认一行 `#RDY <ver> <build> <errs>`（§5.2 应答表末行）。返回 `(ver, build, errs)`。

    **认不出来一律返回 None，不抛异常** —— 调用方要的是「这是不是 `#RDY`」这个判断，
        而不是「协议错了」。会返回 None 的情形：不是 `#RDY` 开头 / 没有合规的 `*xx` /
        校验对不上 / 字段不是正好三个十进制数。
    三个字段按 §5.2 的定义：`<ver>` = 协议版本（v1.0 写 `1`）、`<build>` = 折叠度
        `PE_NUMBER`（`1` / `4` / `16`）、`<errs>` = 本次上电以来的累计 `#ERR` 数
        （十进制、不补零、封顶 999）。**本函数不做取值范围检查** —— 「build 认不认」
        是解包层的事（`unpack.KNOWN_BUILDS`），这一层只管把三个数读出来。
    ⚠️ 别拿「校验和相同」当「两行内容相同」的证据：`#RDY 1 1 0` 的 `*7c` 与
        `#NTT 1` 撞号（`host/KNOWN_ISSUES.md` A2）。
    """
    if not text.startswith(RDY_PREFIX):
        return None
    try:
        body, got = proto.split_checksum(text)
    except ValueError:
        return None
    if proto.checksum_hex(body) != got:
        return None
    words = body.split()
    if len(words) != 4 or words[0] != "#RDY":
        return None
    try:
        return tuple(int(w) for w in words[1:])
    except ValueError:
        return None


class Transaction:
    """一次事务的全部记录 —— 失败时要能说清「第几条、失败在哪一步」（§5.5:519）。"""

    def __init__(self, command, count):
        self.command = command        # 命令正文，不带校验，如 "#NTT 1"
        self.count = count            # 这条命令该发 / 该收几行
        self.outcome = None           # RESULT_OK / FAILED / STOP
        self.attempts = 0             # 一共试了几次（含首发）
        self.rows = []                # 最后一次尝试收到的结果行
        self.error = None             # 失败原因（#ERR 原文，或超时/错位的说明）
        self.stage = ""               # 卡在哪一步
        self.sent_bytes = []          # 最后一次尝试**实际写到线上的字节**
        self.log = []                 # 规则五：每一次重试、每一次容错都留在这里
        self.raw = None               # **只有 probe() 会填**：收到的那一行原文（去掉结尾 LF）。
                                      # run() 不填它 —— 那边有 rows（结果行）和 error（错误原文）。
                                      # 探活不一样：回帧本身就是它的全部产出，所以单独留着。

    def summary(self):
        return ("%s：%s（试了 %d 次，卡在「%s」）%s"
                % (self.command, self.outcome, self.attempts, self.stage,
                   "  " + self.error if self.error else ""))


class Host:
    """把一条命令在一个插座上走完。插座可以是陪练，也可以是真串口。"""

    def __init__(self, link, t_ok=T_OK, t_begin=T_BEGIN, t_rx=T_RX, t_done=T_DONE,
                 max_retries=MAX_RETRIES, verbose=False):
        self.link = link
        self.t_ok = t_ok
        self.t_begin = t_begin
        self.t_rx = t_rx
        self.t_done = t_done
        self.max_retries = max_retries
        self.verbose = verbose
        # handshake() 捡到的开机信息。没收到 `#RDY` 时三个都是 None
        # —— 「没收到」和「收到了值 1」必须能分辨（见 handshake() 的 ⚠️）。
        self.board_version = None
        self.build = None
        self.board_errs = None
        # handshake() 读到的、但**不是** `#RDY` 的那一行，原样放回这里，
        # 让下一次 _read_line 先把它交出去 —— 等于那一行没被读过。
        self._pushback = []

    # ------------------------------------------------------------ 开机那一行

    def handshake(self, timeout=None):
        """开串口后**先吃一行**：板子上电自发的那条 `#RDY`（§5.2 应答表末行）。

        为什么要这一步：2026-10-07 A 把 `#RDY` 落进了 RTL —— 复位释放后板子
        **不等命令**先自发一行。本文件是按「发一条、读一行」的开环写的，这一行没人
        吃就会**错位一格**（见模块 docstring）。本方法专治它，**开串口之后调一次**。

        三种结局，**都不算失败**：
            · 读到 `#RDY`（校验对、字段齐）→ 记下 `<ver>` / `<build>` / `<errs>`，
              返回 True。**折叠度是电脑端唯一推不出来的信息**（FNTT 的读出序按它分档，
              而它编译进位流、命令里没有它，§5.3.4）。
            · 读到了**别的行** → **原样放回**缓冲（`_pushback`），返回 False。
              旧位流的任何回帧都走这一条 —— 等于本方法没调用过。
            · timeout 内没读到 → 返回 False。旧位流，或 `#RDY` 在串口打开前就发完了。

        ⚠️ **收不到 `#RDY` 是完全正常的结果**，不是故障：§5.2 说它是「尽力而为」的一行，
           上电瞬间电脑多半还没开串口监听，那一行就丢了。所以调用方**不许依赖**它 ——
           返回 False 时照旧用 `--build` 那份手工给的折叠度。
        ⚠️ **只该在开串口后调一次**。它不是同步点，也不是「每条事务前都清一下」——
           它是「把开机那一行捡走」。
        """
        if timeout is None:
            timeout = self.t_ok
        text = self._read_line(timeout)
        if text is None:
            return False

        rdy = parse_rdy(text)
        if rdy is None:
            # 不是 `#RDY`：放回去。**不吞** —— 吞了就把旧位流的正常回帧吃掉了。
            self._pushback.insert(0, text)
            self._note_global("开机先读到的 %r 不是 `#RDY`，原样放回缓冲（旧位流）。" % text)
            return False

        self.board_version, self.build, self.board_errs = rdy
        self._note_global("收到 %s —— 板子上电自发的一行：折叠度 pe%s。"
                          % (text, self.build))
        return True

    # ------------------------------------------------------------ 对外

    def run(self, command, data_lines):
        """把一条事务走完。返回 Transaction（看 .outcome）。

        command    —— 命令正文，不带校验，如 "#NTT 1"
        data_lines —— 要发的数据行（3 位小写 hex 的字符串），个数必须等于命令该收的行数
        """
        txn = Transaction(command, len(data_lines))
        total = self.max_retries + 1

        for attempt in range(1, total + 1):
            txn.attempts = attempt
            txn.rows = []
            txn.sent_bytes = []
            if attempt > 1:
                # 规则五：不许静默重试。
                self._note(txn, "第 %d 次重发：%s" % (attempt, command))

            verdict = self._attempt(command, data_lines, txn)

            if verdict == "ok":
                txn.outcome = RESULT_OK
                break
            if verdict == "err":
                txn.outcome = RESULT_FAILED
                break
            if verdict == "stop":
                txn.outcome = RESULT_STOP
                break

            # verdict == "timeout" —— 规则二
            self._note(txn, "第 %d 次尝试在「%s」超时。" % (attempt, txn.stage))
            if not self._abort(txn):
                txn.outcome = RESULT_STOP
                break
            if attempt == total:
                txn.outcome = RESULT_FAILED
                txn.error = "重发 %d 次仍然失败（最后卡在「%s」）" % (self.max_retries, txn.stage)
                self._note(txn, txn.error)
        return txn

    def probe(self, command):
        """发一条**不带数据**的命令（`#PING` / `#ABORT` 这类），只等一条回帧。

        为什么要单独开一个入口：`run()` 走的是**带数据的事务**（发命令 → 等 `#OK` →
        发数据 → 等 `#BEGIN` → 收结果 → 等 `#DONE`）。而 `#PING` / `#ABORT` 后面跟
        **0 行数据**，板子**不发** `#BEGIN` / `#DONE`（§5.2:286）。塞进 `run()` 会在
        「等 #BEGIN」上白等 T_BEGIN（5 s）、再重发 3 次才放弃 —— **实测如此**。
        探活要的是「此刻有没有回声」，不是「把一条事务走完」。

        返回一个 `Transaction`（`count=0`、`attempts=1`）：
            outcome == RESULT_OK       回的是 `#OK <原命令>`，而且**回显对得上**
            outcome == RESULT_FAILED   板子回了 `#ERR ...` —— 它**拒了**这条命令。
                                       这不是故障：链路活着，板子在按协议应答。
            outcome == RESULT_STOP     错位（校验错 / 首词不对 / 回显对不上）或超时
        回帧原文在 `txn.raw`；容错记录（`\r`、空行）照旧进 `txn.log`。

        ⚠️ 本条**只发一次**，不实现 §5.5 规则二的「重新发送」。
           理由：探活问的是「此刻有没有回声」，重发 3 次只会把等待从 T_OK（1 s）
           拖到 4 s；而规则二（§5.5:518）属于**事务**，探活没有数据段。
           **这处口径没有经 A 确认** —— 上板后觉得该重发，再议。
        """
        txn = Transaction(command, 0)
        txn.attempts = 1
        txn.stage = "等 #OK（T_OK=%g s）" % self.t_ok
        self._send(txn, proto.append_checksum(command))

        v, p = self._wait_for(self.t_ok, command, "OK", txn)
        if v == "OK":
            txn.raw = p
            txn.outcome = RESULT_OK
            txn.stage = "完成"
            self._note(txn, "收到 %s" % p)
        elif v == "ERR":
            txn.raw = p
            txn.outcome = RESULT_FAILED
            txn.error = p
            self._note(txn, "收到 %s —— 板子**拒**了这条命令，"
                            "但这说明链路活着、它在按协议应答。" % p)
        elif v == "DESYNC":
            txn.outcome = RESULT_STOP
            txn.error = p
            self._note(txn, "错位：%s" % p)
        else:                                  # TIMEOUT
            txn.outcome = RESULT_STOP
            txn.error = "%g s 内一个字节都没收到 —— 后面没有东西在听。" % self.t_ok
            self._note(txn, txn.error)
        return txn

    # ------------------------------------------------------------ 一次尝试

    def _attempt(self, command, data_lines, txn):
        """走一遍完整流程。返回 "ok" / "err" / "timeout" / "stop"。"""
        txn.stage = "发命令"
        self._send(txn, proto.append_checksum(command))

        txn.stage = "等 #OK（T_OK=%g s）" % self.t_ok
        v, p = self._wait_for(self.t_ok, command, "OK", txn)
        if v == "TIMEOUT":
            return "timeout"
        if v == "DESYNC":
            return self._stop(txn, p)
        if v == "ERR":
            return self._on_err(txn, p)

        txn.stage = "发 %d 行数据" % txn.count
        for line in data_lines:
            self._send(txn, line)

        txn.stage = "等 #BEGIN（T_BEGIN=%g s）" % self.t_begin
        v, p = self._wait_for(self.t_begin, command, "BEGIN", txn)
        if v == "TIMEOUT":
            return "timeout"
        if v == "DESYNC":
            return self._stop(txn, p)
        if v == "ERR":
            return self._on_err(txn, p)

        txn.stage = "收 %d 行结果（每行 T_RX=%g s）" % (txn.count, self.t_rx)
        for i in range(txn.count):
            text = self._read_line(self.t_rx)
            if text is None:
                return "timeout"
            if text.startswith("#"):
                # 结果行是 3 位十六进制，`#` 开头绝对不是结果行。
                # 数据段里不该有命令行（§5.5:543）—— 收到就说明错位了。
                return self._stop(txn, "收结果行的过程中收到了 %r —— "
                                       "数据段里不该有 `#` 开头的行（§5.5:543），"
                                       "后面的字节归属不明。" % text)
            txn.rows.append(text)

        txn.stage = "等 #DONE（T_DONE=%g s）" % self.t_done
        v, p = self._wait_for(self.t_done, command, "DONE", txn)
        if v == "TIMEOUT":
            return "timeout"
        if v == "DESYNC":
            return self._stop(txn, p)
        if v == "ERR":
            return self._on_err(txn, p)

        txn.stage = "完成"
        return "ok"

    # ------------------------------------------------------------ 收发

    def _send(self, txn, line):
        """发一行出去。命令行带校验、数据行不带 —— **由调用方保证**，这里只管发。"""
        data = (line + "\n").encode("ascii")
        txn.sent_bytes.append(data)
        self.link.write(data)

    def _read_line(self, timeout):
        """读一行，返回**去掉结尾 LF** 的正文（str）；超时返回 None。

        ⚠️ **先看 `_pushback`** —— handshake() 读到一行「不是 `#RDY`」的会放回那里。
           放回的行**不重新计时**：它读进来那一刻已经在时限内了。
        ⚠️ 空行按 §5.5:541 忽略、`\\r` 按 §5.5:542 丢掉 —— 但**都留日志**（规则五）。
        ⚠️ 忽略之后**接着等**，可**总时限不重置**：否则对方一直发空行就能把电脑
           永久挂住，正好撞上 §5.5:480「不可静默空等」。
        """
        if self._pushback:
            return self._pushback.pop(0)

        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            raw = self.link.read_line(left)
            if raw is None:
                return None
            text = raw.decode("ascii")
            if text.endswith("\n"):
                text = text[:-1]
            if "\r" in text:
                self._note_global("收到含 \\r 的回帧 %r，按 §5.5:542 丢掉这些字节。" % text)
                text = text.replace("\r", "")
            if text == "":
                self._note_global("收到空行，按 §5.5:541 忽略。")
                continue
            return text

    def _parse(self, text, txn):
        """认一行回帧。返回 (kind, words) 或 ("DESYNC", 原因)。

        kind 是 "OK" / "BEGIN" / "DONE" / "ERR"。
        ⚠️ 每个应答行都必须过校验（§5.4:401 那张表）。
        """
        try:
            body, got = proto.split_checksum(text)
        except ValueError as exc:
            return ("DESYNC", "回帧没有合规的 *xx 校验：%r（%s）" % (text, exc))
        exp = proto.checksum_hex(body)
        if exp != got:
            return ("DESYNC", "回帧校验对不上：%r —— 算出来是 %s，它写的是 %s"
                              % (text, exp, got))
        words = body.split()
        if not words:
            return ("DESYNC", "回帧正文是空的：%r" % text)
        if words[0] not in HEAD_KINDS:
            return ("DESYNC", "回帧首词不认识：%r（只认 %s）"
                              % (text, "、".join(sorted(HEAD_KINDS))))
        return (words[0][1:], words)

    def _wait_for(self, timeout, command, want, txn):
        """等一行，并且核对它是不是「我正等的那一条」。

        返回 (verdict, 内容)：
            ("OK"/"BEGIN"/"DONE", 原文)  收到了想要的那条
            ("ERR", 原文)                收到了 #ERR（规则三：本事务失败，不重发）
            ("TIMEOUT", None)            到点没等到（规则二：走 ABORT + 重发）
            ("DESYNC", 原因)             错位 / 校验错（规则四：停整轮）
        """
        text = self._read_line(timeout)
        if text is None:
            return ("TIMEOUT", None)

        kind, payload = self._parse(text, txn)
        if kind == "DESYNC":
            return ("DESYNC", payload)
        if kind == "ERR":
            return ("ERR", text)
        if kind != want:
            return ("DESYNC", "正等 #%s，收到的却是 #%s：%r —— 错位（§5.5:527）"
                              % (want, kind, text))

        # 规则四：核对回显是不是自己刚发的那条。
        #
        # ⚠️ 回显里命令名**前面那个 `#` 是没有的**：发 `#NTT 1`，回 `#OK NTT 1*58`
        #    （§5.2:286 的 `<原命令>` 指的是 `#` 后面那截；fake_board.echo_of 也这么干）。
        #    直接拿 `"#NTT 1".split()` 去比会**永远对不上**，然后整轮测试被规则四停掉 ——
        #    症状看起来像协议错，其实是这里少剥了一个 `#`。
        tokens = (command[1:] if command.startswith("#") else command).split()
        if want == "OK":
            if payload[1:] != tokens:
                return ("DESYNC", "回显对不上：发的是 %r，它回的是 %r —— 错位（§5.5:527）"
                                  % (command, text))
        else:
            # #BEGIN / #DONE 的形状：<原命令> <原参数> <count>
            if payload[1:-1] != tokens:
                return ("DESYNC", "回显对不上：发的是 %r，它回的是 %r —— 错位（§5.5:527）"
                                  % (command, text))
            tail = payload[-1]
            if not tail.isdigit():
                return ("DESYNC", "%s 的行数不是数字：%r" % (want, text))
            if int(tail) != txn.count:
                return ("DESYNC", "%s 说的行数是 %s，本事务该是 %d —— 对不上（§5.5:527）"
                                  % (want, tail, txn.count))
        return (want, text)

    # ------------------------------------------------------------ 错误路径

    def _on_err(self, txn, text):
        """规则三（§5.5:523）：收到 #ERR **不重发**。

        板子能回错误码，说明它活着、链路通、它理解了你的命令 —— 重发只会得到同一个
        错误。打印错误码和它带的参数，本事务记失败，继续下一条。
        """
        txn.error = text
        self._note(txn, "收到 %s —— 规则三：不重发，本条记失败。" % text)
        return "err"

    def _stop(self, txn, reason):
        """规则四（§5.5:527）：停整轮。"""
        txn.error = reason
        self._note(txn, "错位：%s" % reason)
        return "stop"

    def _abort(self, txn):
        """规则二（§5.5:515）：先发 #ABORT，再把它的应答读掉并校验。

        返回 True = 链路还在，可以重发；False = 停整轮。

        ⚠️ **这里是规则四唯一的例外（§5.5:531）**：`#OK ABORT` 不对应任何正在进行的
           运算，所以**不能**拿它去比对当前事务的回显 —— 那会把「重试」直接变成
           「停整轮」，规则二就废了。
        ⚠️ 等不到应答怎么办，文档没写（见模块 docstring (3)）。这里取「停整轮」。
        """
        self._send(txn, proto.append_checksum(ABORT))
        text = self._read_line(self.t_ok)
        if text is None:
            reason = ("发了 #ABORT 之后在 T_OK=%g s 内等不到任何应答 —— "
                      "链路状态不可知，停整轮。" % self.t_ok)
            txn.error = reason
            self._note(txn, reason)
            return False

        kind, payload = self._parse(text, txn)
        if kind == "DESYNC":
            txn.error = "`#ABORT` 的应答认不出来：%s" % payload
            self._note(txn, txn.error)
            return False
        if kind != "OK" or payload != ["#OK", "ABORT"]:
            txn.error = "`#ABORT` 的应答不是 `#OK ABORT`，而是 %r —— 停整轮。" % text
            self._note(txn, txn.error)
            return False

        self._note(txn, "已读掉 `%s`，链路恢复，可以重发。" % text)
        return True

    # ------------------------------------------------------------ 日志

    def _note(self, txn, msg):
        """规则五（§5.5:533）：任何一次重试都必须留一行日志。"""
        txn.log.append(msg)
        if self.verbose:
            print("    [%s] %s" % (txn.command, msg))

    def _note_global(self, msg):
        """不属于某个事务的容错记录（比如空行、`\\r`）。同样不许静默。"""
        if self.verbose:
            print("    [容错] %s" % msg)
