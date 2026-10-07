"""假串口对端（陪练机器人）。

它是什么 / 不是什么
    它是**上位机的对手方**，分两层：
      · 第 1 层 —— `handle_line()`：收一行命令、验校验、回 `#OK` 或 `#ERR`。
      · 第 2 层 —— `FakeBoard`：收数据行，回 `#BEGIN` + 结果 + `#DONE`。

    **它不是会算数的板子** —— 结果不是算出来的，是**从 `refsim/batch/*_exp.txt` 查出来的**：
    收到的 256 行先在各个向量组里**逐行精确**找是哪一组，再回传对应的那一组。
    ⚠️ **必须是精确匹配，不许模糊** —— 改坏一个字符就应当匹配不上。

    它也不是最终交付的那个 Verilog 测试台（那个要等 A 的模块出来）。

⚠️ 它**永远只会回正确答案** —— 你发对数据，它就回对答案。
    所以它**测不出上位机「判错」的能力**（上位机就算把结果全判成通过，陪练也发现不了）。
    这是「回放标准答案」的固有缺陷，得靠**故意使坏的开关**来补，
    见 host/proto.md §5.5:561-569 的三条注错自测（那是协议冻结的验收条件）。

依据
    host/proto.md  §5.2 命令字表（:246-304）
                   §5.4 校验（:395-476）
                   §5.5 行的处理（:539-546）

⚠️ 上面的行号会**随 proto.md 的编辑整体漂移**（在文档中间插一行，后面的全体 +2）。
    改完 proto.md，重跑 `grep -n "§" host/src/*.py` 逐条对一遍。本文件已核到 2026-09-29。

命令字表**运行时从 proto.md 现读**，不在本文件里抄一份。
    （理由见 memory: proto-md-single-source —— 抄一份会各自漂移，
      改文档的人忘了改代码时，代码还会照旧「报平安」。）

⚠️ 不发明规则
    proto.md 有若干处**没写**的路径。本层的做法是**显式 raise NotImplementedError**，
    把草案的洞变成代码里看得见的路标，而不是替草案编一套规则。
    每一处 raise 的注释里都写了「缺口在哪一段」。

第④步（错误路径）做了什么 / 还有什么在 raise
    ✅ 已实现（协议文本写得死的那些）：
        · 数据行不合规        -> `#ERR 04`，位置 = 第一个非法字符的列号
        · 数据段里的 `#` 行    -> `#ERR 04`（`#ABORT` 除外，见下）
        · 数据段里 `#ABORT`    -> `#OK ABORT`，丢弃本事务、回等命令行
        · 等一行等超时了      -> `#ERR 05`，位置 = 已收到的行数（由 timeout() 触发）
        · 命令行超过 64 字节   -> `#ERR 04`（§5.5:544）
    ⏳ 仍在 raise（**草案真没写**，不是本层偷懒）：
        · 等命令行状态收到**不是 `#` 开头**的行
        · 命令行缺 `*xx`、或 `*` 后面不是 2 位小写十六进制
        · `n ≠ 1`
        · `#LAYERS`
    每处 raise 的注释都写明了缺的是哪一段。
"""

import re
from pathlib import Path

import proto
from vectors import (BATCH_DIR, DATA_LINE_RE, GROUP_LEN, VECTORS,
                     read_vector, split_groups)

PROTO_MD = Path(__file__).resolve().parent.parent / "proto.md"

# §5.2「电脑 → 板子」那张表的锚点
CMD_ANCHOR = "**电脑 → 板子**"
# 表格前三格：命令 / 参数 / 后面要跟的数据行数
ROW_RE = re.compile(r"^\|\s*`([^`]+)`\s*\|([^|]*)\|([^|]*)\|")
SEP_RE = re.compile(r"^\|[\s:\-|]+\|\s*$")

# `<n>` 是「一个十进制数」的占位符，出现在命令字表的原文里
N = "<n>"

# 命令行长度上限（§5.5:544）
MAX_CMD_LEN = 64

# §5.2:259 —— `#LAYERS` 在表里，但参数和语义都「预留，未定」（受 C 的 H7 影响，§六第10条）。
# 这一条不是从 proto.md 抄来的数据，是**本层实现状态的声明**。
NOT_IMPLEMENTED = {"#LAYERS"}

# 数据行的形状（DATA_LINE_RE）在 vectors.py，和向量文件用同一套。
# 命令表「后面要跟的数据行数」那一格的形状：`0` / `n×256` / `2n×256`
COUNT_RE = re.compile(r"^(\d*)\s*n\s*[×x*]\s*(\d+)$")

# 向量文件在哪（BATCH_DIR）、一组多少个（GROUP_LEN）、命令 ↔ 文件怎么对应（VECTORS），
# 都在 vectors.py —— **上位机要用同一套**。抄两份必然漂移：一边改了、另一边没改，
# 对拍就会在「送的」和「该收的」之间对不上，症状却长得像协议 bug。


# ---------------------------------------------------------------- 读 proto.md

def _load_rows():
    """从 proto.md §5.2 读出命令字表，返回 [(词元元组, 数据行数原文), ...]。

    第二个元素是那一格的**原文**（`0` / `n×256` / `2n×256` / 未定），
    由 eval_line_count() 在知道 n 之后再算 —— 本文件不预先把数字抄下来。

    spec 是词元元组，例如：
        ('#PING',)                  -> #PING
        ('#NTT', '<n>')             -> #NTT 1
        ('#PMUL', 'TIME', '<n>')    -> #PMUL TIME 1
    """
    lines = PROTO_MD.read_text(encoding="utf-8").splitlines()

    start = next((i for i, ln in enumerate(lines) if CMD_ANCHOR in ln), None)
    if start is None:
        raise SystemExit(
            "!! 在 %s 里找不到锚点「%s」。\n"
            "   proto.md 的 §5.2 大概被改动过了，这个读法要跟着改。" % (PROTO_MD, CMD_ANCHOR))

    i = start + 1
    while i < len(lines) and not lines[i].strip():
        i += 1

    rows = []
    while i < len(lines) and lines[i].startswith("|"):
        rows.append(lines[i])
        i += 1
    if not rows:
        raise SystemExit("!! 锚点「%s」后面没找到表格。检查 %s 的 §5.2。" % (CMD_ANCHOR, PROTO_MD))

    # 第一条是表头就跳过；万一没有表头，整块都用
    data_rows = rows if ROW_RE.match(rows[0]) else rows[1:]

    rows_out = []
    for ln in data_rows:
        if SEP_RE.match(ln):
            continue
        m = ROW_RE.match(ln)
        if not m:
            raise SystemExit(
                "!! 命令表里有一行没读懂：\n   %r\n"
                "   这里不静默跳过 —— 读不懂就是错。" % ln)
        rows_out.append((tuple(m.group(1).split()), m.group(3).strip()))

    if not rows_out:
        raise SystemExit("!! 没解析出任何命令，检查 %s 的 §5.2 表格格式。" % PROTO_MD)
    return rows_out


def load_commands():
    """只要命令词元（[spec, ...]）。数据行数请用 _load_rows()。"""
    return [tokens for tokens, _ in _load_rows()]


# ---------------------------------------------------------------- 拼应答帧

def echo_of(body):
    """回显用的命令原文 —— **去掉开头的 `#`**。理由见 ok_frame。"""
    return body[1:]


def ok_frame(body):
    """`#OK <原命令> <原参数>` —— §5.2:286，**必须回显**。

    ⚠️ 回显时**不带原来的 `#`**。`body` 传进来是 `#PMUL TIME 1` 这样（带 `#`），
    出去要是 `#OK PMUL TIME 1`（不带 `#`）。
    依据是 §5.2 里的**实例**：`#OK PMUL TIME 1`（:286 那张表）、`#OK NTT 1`（:447）、
    `#OK ABORT`（§5.5:516）—— 全都是 `#OK ` + 去掉 `#` 的命令原文。

    §5.2:286 那个记号 `<原命令>` 本身有歧义（命令字表里每条命令都是**带** `#` 写的），
    照字面实现就会多一个 `#`。实例是权威。这处记号的歧义已记入待修清单。
    """
    return proto.append_checksum("#OK " + echo_of(body))


def rdy_frame(ver=1, build=1):
    """`#RDY <ver> <build> <errs>` —— §5.2 应答表末行；**复位释放后板子自发的一行**。

    2026-10-07 A 把这一帧落进了 RTL（`rtl/board/proto_fsm.v` 的 `S_RDY` /
    `RK_RDY`，复位落点由 `S_IDLE` 改成 `S_RDY`）。陪练跟上，否则
    `board_run.py --loopback` **测不到「上位机吃掉这一行」那条路** ——
    而那正是本次要防的坑（第一行读成 `#RDY` 而不是 `#OK`，之后全体错位一格）。

    `<errs>` 恒填 `0`：陪练只在**上电那一刻**发这一行，那时它还没回过任何 `#ERR`。
    （真板子是「本次上电以来累计发过的 `#ERR` 条数、封顶 999」，见 §5.2。）

    ⚠️ 三档的校验和：`#RDY 1 1 0*7c` / `#RDY 1 4 0*79` / `#RDY 1 16 0*4a`。
        与 `#NTT 1` 撞号的正是第一个 `7c`（`host/KNOWN_ISSUES.md` A2）——
        别拿校验和去区分这两行。
    """
    return proto.append_checksum("#RDY %d %d 0" % (ver, build))


def err_frame(code, position):
    """`#ERR <code> <位置>` —— §5.2:289。

    ⚠️ 草案里这条写作「`#ERR <code> <位置> <详情>`」三段，但**唯一的实例**
    （§5.2:304 的 `#ERR 03 got=3f exp=a2*52`）**没有独立的「详情」段** ——
    详情被并进了「位置」（`got=.. exp=..`）。
    两种写法只能选一种，这里**照唯一的实例走**：只有 code + 位置。
    这处草案内部不一致已记入待修清单。
    """
    return proto.append_checksum("#ERR %s %s" % (code, position))


def pos_of_bad_data_line(text):
    """数据行不合规时，`#ERR 04` 的「位置」填几。

    ⚠️ **草案只说了「第一个非法字符的位置」（§5.2:299），没说从 0 还是从 1 数。**
    本层的取法（**同类问题只在这一处定义，要改就改这一处**）：

        · 有非法字符   -> 该字符的**列号，从 1 数**        （`0g4` -> 2）
        · 长度超过 3   -> 第 4 列，即第一个越界的位置      （`0123` -> 4）
        · 长度不足 3   -> len+1，即**本该有字符的那一位**  （`04` -> 3）

    **为什么从 1 数**：`#ERR 01` 的位置填 `0`（§5.2:296），说明 `0` 在这个协议里
    被当作「不适用」的哨兵值；真实字符位从 1 起才不和它撞。而且人读列号天然从 1 数。

    ⚠️ 这是**草案文本没写死的一处**，不是本文件偷偷替协议定的规矩 ——
    已列入给 A 的待确认清单。
    """
    for i, ch in enumerate(text):
        if ch not in "0123456789abcdefABCDEF":
            return i + 1
    return min(len(text) + 1, 4)


# ---------------------------------------------------------------- 认命令

def match_command(tokens, commands):
    """在命令表里找与 tokens 匹配的一条。找不到返回 None。

    `<n>` 匹配任意十进制数字串；其余词元必须逐字相等。
    """
    for spec in commands:
        if len(spec) != len(tokens):
            continue
        if all((s == N and t.isdigit()) or (s == t) for s, t in zip(spec, tokens)):
            return spec
    return None


def pmul_domains(commands):
    """从命令表里**读出** `#PMUL` 允许哪些域词（而不是在本文件里写死）。

    现在读到的是 NTT / TIME / FULL。§5.2:297 的「参数非法」只提了 TIME / NTT，
    漏了 FULL —— 那是草案的笔误，记在待修清单里；这里以表格为准。
    """
    return {spec[1] for spec in commands if len(spec) == 3 and spec[0] == "#PMUL"}


# ---------------------------------------------------------------- 主入口

def handle_line(line, commands=None):
    """处理板子收到的**一行**，返回应答行；不该回时返回 None。

    line 末尾的 LF 由调用方切掉；本函数自己会把 CR / LF 都去掉。
    """
    if commands is None:
        commands = load_commands()

    # §5.5:548 —— \r 在计数之前就丢掉
    text = line.replace("\r", "").replace("\n", "")

    # §5.5:541 —— 空行忽略，不计入行数
    if text == "":
        return None

    # 超长命令行（§5.5:544）
    if len(text) > MAX_CMD_LEN:
        # 「第一个非法字符」= 第 MAX_CMD_LEN+1 个 —— 前 64 个都还在限内。
        # 位置从 1 数，与 pos_of_bad_data_line() 同一套约定。
        return err_frame("04", str(MAX_CMD_LEN + 1))

    # 非 # 开头的行（等命令行状态）
    if not text.startswith("#"):
        raise NotImplementedError(
            "草案未定义：处在「等命令行」状态时收到**不是 # 开头**的行该怎么回。\n"
            "  §5.2:296 的 01（未知命令）只覆盖「# 开头但不是表里任何一个」。")

    # 命令行必须带 *xx（§5.4:401）
    try:
        body, got = proto.split_checksum(text)
    except ValueError:
        raise NotImplementedError(
            "草案未定义：命令行缺少 *xx、或 * 后面不是 2 位小写十六进制时，\n"
            "  该归 03（校验错）还是 04（格式错）。\n"
            "  §5.4:401 只说命令行**必须**有校验，§5.2 没给这两种情况的归类。")

    exp = proto.checksum_hex(body)
    if got != exp:
        # §5.2:298 / :304 —— 两个值都回
        return err_frame("03", "got=%s exp=%s" % (got, exp))

    # ---- 认命令字 ----
    tokens = body.split()
    spec = match_command(tokens, commands)
    if spec is None:
        # §5.2:296 未知命令，位置填 0
        return err_frame("01", "0")

    name = spec[0]
    if name in NOT_IMPLEMENTED:
        raise NotImplementedError(
            "命令 %s 在 §5.2 的表里，但参数与语义「预留，未定」（§5.2:259，受 C 的 H7 影响，\n"
            "  见 §六 第 10 条）。本层不替它编行为。" % name)

    # 无参数命令：#PING / #ABORT -> #OK（回显）
    if spec == ("#PING",) or spec == ("#ABORT",):
        # §5.2:252 / :258；#ABORT 的应答见 §5.5:516-517（收 #ABORT 后回显 #OK ABORT）
        return ok_frame(body)

    # 带 <n> 的命令
    if N in spec:
        n = tokens[spec.index(N)]
        if n != "1":
            raise NotImplementedError(
                "草案未定义：n ≠ 1 时 #ERR 02 的「位置」该填什么。\n"
                "  §5.2:297 说 02 的位置是「出错字段的序号」，但没写序号从 0 起还是从 1 起。\n"
                "  （§5.2:253 已把 n 冻结为 1，所以正常流程走不到这里。）")
        return ok_frame(body)

    raise NotImplementedError(
        "命令 %s 在 §5.2 的表里，但本层还没有对应的处理分支。\n"
        "  这是本层实现不全，不是草案的问题 —— 不要在这里随手编行为。" % name)


# ---------------------------------------------------------------- 第 2 层：数据段

def eval_line_count(expr, n):
    """把命令表那一格按 n 算成整数行数。

    那一格可能是 `2n×256`（**前 A 后 B**） 这种**带注解**的，
    所以先取**第一对反引号里的内容**；没有反引号就整格当表达式。
    读不懂就响亮报错 —— 不猜。
    """
    m = re.search(r"`([^`]+)`", expr)
    e = (m.group(1) if m else expr).strip()
    if e.isdigit():
        return int(e)
    m2 = COUNT_RE.match(e)
    if m2:
        a = int(m2.group(1)) if m2.group(1) else 1
        return a * n * int(m2.group(2))
    raise SystemExit(
        "!! 命令表里「后面要跟的数据行数」这一格读不懂：%r\n"
        "   只认 `0` / `n×256` / `2n×256` 这几种形状。\n"
        "   proto.md 的 §5.2 大概改了，这个读法要跟着改。" % expr)


# read_vector() / split_groups() 也搬到 vectors.py 了（本文件从那里 import）。
# 上位机要用同一份读法，不能各写一版。


class FakeBoard:
    """陪练的状态机。

    第②步只有「等命令行」一个状态。这里加上「数据段」——
    §5.2:310-311 规定的顺序义务：
        电脑发命令 → 必须等到 `#OK` 才发数据行；数据行发完 → 必须等到 `#DONE`。
        板子发出 `#OK` 之后只认数据行；发出 `#DONE` 之前不接受新命令。

    ⚠️ 它有**两顶帽子**，本类把两顶分开放：
        · 演板子 —— feed() 的返回值就是「板子会回的行」
        · 当裁判 —— self.mismatches / self.notes 是「这一轮对不对」
    为什么要分：**真板子手上没有任何参考向量**，它判不了「你发的数据对不对」。
    把裁判结论混进应答帧，陪练就不像板子了，测出来的东西也不作数。

    ⚠️ **本类不自己看时钟**（T_LINE）。它按「来一行处理一行」工作，没有时间概念。
    「等一行等超时了」这件事实由**调用方**判定，然后调 `timeout()` 把它变成
    板子该回的那一行 `#ERR 05`。这样这一层在真电脑、仿真 tb、单元测试里都同样能用。
    """

    def __init__(self, batch_dir=None, rows=None, build=1, ver=1):
        self.rows = rows if rows is not None else _load_rows()
        self.commands = [t for t, _ in self.rows]
        self.batch_dir = Path(batch_dir) if batch_dir else BATCH_DIR
        # 陪练自称的折叠度 / 协议版本 —— 就是 `#RDY` 里那两个字段（§5.2）。
        # 让调用方能造一台「烧的是 pe4」的陪练，用来验「上位机从 #RDY 自动认折叠度」。
        self.build = build
        self.ver = ver
        self.reset()

    def boot_lines(self):
        """复位释放后板子**不等命令**自发的那一行（`#RDY`，§5.2），并清掉「待发」。

        真板子（2026-10-07 起）在复位落点 `S_RDY` 上先发这一行、再进 `S_IDLE`。
        本方法给**插座**用：`LoopbackLink` 一建好就调它，把这一行预先塞进收缓冲 ——
        精确模拟「板子早上电了、你才开串口」这个**最危险**的次序（`#RDY` 已在线路上
        等着，电脑第一行读到的就是它）。不预先塞的话，陪练要等到被喂字节才回话，
        而 `handshake()` 是**发命令之前**读的 —— 那条路就一段都测不到。

        已经取过一次就返回空（对应 §5.2「只在复位释放后发**一次**」）。
        """
        if not self.rdy_pending:
            return []
        self.rdy_pending = False
        return [rdy_frame(self.ver, self.build)]

    def reset(self):
        self.state = "CMD"       # "CMD" = 等命令行；"DATA" = 数据段
        self.rdy_pending = True  # 复位释放后要先自发一行 `#RDY`（见 boot_lines）
        self.cmd_body = None     # 正在执行的那条命令原文（不带校验）
        self.in_groups = []      # 每个输入文件切好的组；in_groups[f][i] = 第 i 组
        self.out_groups = []     # 输出文件切好的组；out_groups[i] = 第 i 组结果
        self.n_groups = 0        # 一共几组
        self.count = 0           # 本条事务该收几行数据
        self.received = []       # 实际收到的数据行
        self.group = None        # 匹配到的组号；None = 一组都对不上
        self.nearest = None      # 没匹配上时最接近的是第几组（**只用于报信，不参与判定**）
        self.mismatches = []     # [(第几行, 收到, 期望), ...]，序号从 1 起
        self.notes = []

    # ---- 主入口
    def feed(self, line):
        """喂**一行**给板子，返回板子要回的行（list，可能为空、可能是 258 行）。

        line 末尾带不带 LF / CR 都行 —— 本函数自己会去掉。
        """
        text = line.replace("\r", "").replace("\n", "")
        # 复位后还没发过 `#RDY` 的话，排在这一行的应答**前面** ——
        # 真板子那时正忙着发自发的那一行，你这一刻发的命令排在它后面。
        pre = self.boot_lines()
        if text == "":
            return pre                     # §5.5:541 空行忽略，不计入行数
        if self.state == "CMD":
            return pre + self._feed_cmd(text)
        return pre + self._feed_data(text)

    # ---- 等命令行
    def _feed_cmd(self, text):
        reply = handle_line(text, self.commands)
        if reply is None:
            return []
        if not reply.startswith("#OK "):
            return [reply]                 # #ERR …：不进数据段

        tokens = text.rsplit("*", 1)[0].split()
        spec = match_command(tokens, self.commands)
        if spec is None:
            return [reply]                 # 到不了：handle_line 已经拦过
        count = self._line_count(spec)
        if count:
            self._begin(tokens, spec, count)
        return [reply]

    def _line_count(self, spec):
        for row_tokens, expr in self.rows:
            if row_tokens == spec:
                return eval_line_count(expr, n=1)
        raise SystemExit("!! 命令表里找不到 %r 这一行 —— 内部不一致。" % (spec,))

    def _begin(self, tokens, spec, count):
        key = tuple(t for t in spec if t != N)
        if key not in VECTORS:
            raise NotImplementedError(
                "命令 %s 要跟 %d 行数据，但本文件没有它的向量对应表。\n"
                "  已知的五条在 VECTORS 里（依据是各 *_batch_tb.v 的 $readmemh）。\n"
                "  这是陪练实现不全，不是草案的问题 —— 不要在这里随手编。"
                % (" ".join(tokens), count))

        ins, out_name = VECTORS[key]
        self.in_groups = [
            split_groups(read_vector(self.batch_dir / name), name) for name in ins
        ]
        self.out_groups = split_groups(
            read_vector(self.batch_dir / out_name), out_name)

        group_counts = {len(g) for f in self.in_groups for g in f} | \
                       {len(g) for g in self.out_groups}
        if group_counts != {GROUP_LEN}:
            raise SystemExit(
                "!! 向量切出来的组大小不齐：%s\n"
                "   每个输入文件、输出文件都必须是 %d 行的整数倍，而且组大小一致。"
                % (sorted(group_counts), GROUP_LEN))

        nsets = {len(f) for f in self.in_groups} | {len(self.out_groups)}
        if len(nsets) != 1:
            raise SystemExit(
                "!! 各向量文件的**组数**不一致：%s\n"
                "   输入和输出的组必须一一对应，否则没法按组配对。"
                % sorted(nsets))
        self.n_groups = nsets.pop()

        per_tx = len(ins) * GROUP_LEN        # 一次事务该收几行
        if per_tx != count:
            raise SystemExit(
                "!! 一次事务的数据行数和协议对不上：\n"
                "   命令 %s 按 §5.2 要跟 %d 行，但按向量切法应是 %d 个文件 x %d = %d 行。\n"
                "   不许偷偷截断或补齐 —— 先查是文件错了还是协议改了。"
                % (" ".join(tokens), count, len(ins), GROUP_LEN, per_tx))

        self.state = "DATA"
        self.cmd_body = " ".join(tokens)
        self.count = count
        self.received = []
        self.group = None
        self.nearest = None
        self.mismatches = []

    # ---- 数据段
    def _feed_data(self, text):
        # 数据段里出现 `#` 开头的行 —— 只认 `#ABORT`，其余归 04
        # （§5.2:299「数据段里出现了 # 开头的行（`#ABORT` 除外）」、§5.5:543）
        if text.startswith("#"):
            return self._abort_or_err(text)

        if not DATA_LINE_RE.match(text):
            return self._err("04", pos_of_bad_data_line(text),
                             "数据行不是恰好 3 位十六进制：%r" % (text,))

        self.received.append(text)
        if len(self.received) < self.count:
            return []
        return self._finish()

    # ---- 错误路径（第④步）
    def _discard(self):
        """丢弃本事务、清空行缓冲、回到「等命令行」。

        依据 §5.5:509 关键规则一：板子**不能赖在数据段里不走** ——
        否则电脑后续发的命令行的 `#` 会被当成数据行判 04，
        再发的数据行又成了上一条命令的尾巴，**从此全线错位而且两边都以为自己是对的**。
        `notes`（裁判那顶帽子）不清空，它是日志。
        """
        self.state = "CMD"
        self.cmd_body = None
        self.count = 0
        self.received = []
        self.group = None
        self.nearest = None
        self.mismatches = []

    def _err(self, code, position, why):
        """回一帧 `#ERR`，并丢弃本事务。

        §5.2:289：`#ERR` = 「出错，**放弃本条事务**」。
        """
        self.notes.append("回 #ERR %s %s —— %s" % (code, position, why))
        self._discard()
        return [err_frame(code, str(position))]

    def _abort_or_err(self, text):
        """数据段里收到 `#` 开头的行。

        `#ABORT` 是**唯一合法**的那一个（§5.2:312 允许它出现、§5.5:516 定了它的应答）。
        它本身是一条命令行，所以**照样要过校验**（§5.4:401）—— 校验对不上就不算数。

        校验对不上的 `#ABORT`、以及别的任何命令字，**都归 04**：
        §5.2:299 把「数据段里 `#` 开头的行」的默认归宿就定成了 04，
        所以这里不需要再去分辨 03 / 01 —— 那是**等命令行状态**才分的家。
        """
        try:
            body, got = proto.split_checksum(text)
        except ValueError:
            body, got = text, None

        if body == "#ABORT" and got == proto.checksum_hex(body):
            self._discard()
            self.notes.append(
                "事务进行中收到 #ABORT —— 按 §5.5:516 回 #OK ABORT，本事务作废")
            return [ok_frame("#ABORT")]

        return self._err("04", pos_of_bad_data_line(text),
                         "数据段里不允许出现命令（`#ABORT` 除外）：%r" % (text,))

    def timeout(self):
        """**行超时**（`T_LINE` 到点）—— 回 `#ERR 05`，位置 = 已收到的行数。

        依据 §5.2:300「`05` 数据行数不足 / 行超时 …… 位置填**已收到的行数**」，
        以及 §5.5:509 关键规则一（超时后必须立刻丢弃本事务、回到等命令行）。

        ⚠️ **本层没有时钟。**「等一行等超时了」这件事实由**调用方**判定：
        真电脑上用真实时间，仿真里由 testbench 计时，测试里直接调这个函数。
        本函数只负责把「超时了」变成**板子该回的那一行**。

        不在数据段里（没有事务在进行）时调用它，返回空 —— 没有事务可超时。
        """
        if self.state != "DATA":
            return []
        recv = len(self.received)
        self.notes.append("T_LINE 超时：已收 %d / %d 行" % (recv, self.count))
        self._discard()
        return [err_frame("05", str(recv))]

    def _match_group(self):
        """在 n_groups 组里找**逐行精确**匹配的那一组（大小写不计，§5.3.1:323）。

        ⚠️ **精确匹配是红线，不许模糊。** 改坏一个字符就应当匹配不上 ——
        一旦「最像的那组也算」，电脑发一组改错一个字符的数据也会被认下来、
        回它一个正确答案，**那才是真正的过度配合**。

        一组都对不上时，把「最接近的那一组」的差异记进 mismatches ——
        **只为报信，不参与判定**（回传哪一组由 _finish 另定）。
        """
        recv = [ln.lower() for ln in self.received]
        best_i, best_diff = None, None
        for i in range(self.n_groups):
            exp = [ln for f in self.in_groups for ln in f[i]]
            exp_l = [ln.lower() for ln in exp]
            if exp_l == recv:
                self.group = i
                self.mismatches = []
                return
            diff = [(k + 1, self.received[k], exp[k])
                    for k in range(len(exp)) if exp_l[k] != recv[k]]
            if best_diff is None or len(diff) < len(best_diff):
                best_i, best_diff = i, diff
        self.group = None
        self.nearest = best_i
        self.mismatches = best_diff or []

    def _finish(self):
        """数据行收齐 —— 回 `#BEGIN` + 结果 + `#DONE`，回到等命令行。"""
        self._match_group()

        if self.group is not None:
            results = self.out_groups[self.group]
        else:
            # ⚠️ 一组都对不上。真板子会「照收到的数据算一个」—— 回放式陪练算不了。
            #    回退到**固定的第 0 组**，**不用「最接近的那一组」**：
            #    若用最接近的，把改坏一个字符的第 5 组数据回成第 5 组的正确答案，
            #    电脑反而看不出问题 —— 那是把信号抹掉。
            results = self.out_groups[0]
            self.notes.append(
                "收到的数据**一组都对不上**（最接近的是第 %s 组，差 %d 行）—— "
                "回传的是第 0 组的答案，**这一轮的结果不作数**。"
                % (self.nearest, len(self.mismatches)))

        inner = echo_of(self.cmd_body)     # 例如 `PMUL TIME 1`（不带 #）
        count = len(results)
        out = [proto.append_checksum("#BEGIN %s %d" % (inner, count))]
        out += results
        out += [proto.append_checksum("#DONE %s %d" % (inner, count))]

        self.state = "CMD"
        self.cmd_body = None
        return out
