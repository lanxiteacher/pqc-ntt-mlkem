"""解包 —— 把板子回传的「物理读出序」摆回「系数自然序」，再和标准答案对拍。

它在干什么（大白话）
    板子上那排存系数的抽屉，是**分成两半交错拼起来**的（两个 bank）。
    所以板子读抽屉的次序**不是**「编号 1、2、3、4……」：

        FNTT / PWM2：每 4 个一组，把第 2、3 个对调 → 0,2,1,3,4,6,5,7,…
                     ⚠️ FNTT 这一行**只在 pe1 成立**；pe4/pe16 上是自然序（见 §5.3.4）
                        —— 所以 FNTT 的读出序按 `#RDY` 的 `<build>` 分档，见 `permutation`
        INTT      ：前半本和后半本交叉     → 0,128,1,129,2,130,…

    §5.3.4:378 已经把这件事定死（选的是「甲」）：**板子按自己读出的物理顺序
    原样回传，电脑端按运算类型决定怎么解包**，板子端**不发**任何「序型标志」。
    所以「摆回去」这件事 100% 是电脑端（也就是本文件）的责任。

    摆错了不是「差一个」，是「**256 个全错**」—— 文档原话（§5.3.4:378）：
    「一旦电脑端解错，整组对拍会**响亮地失败**（256 个系数全错），不会静默出错。」
    所以本文件宁可报错也不猜。

它怎么知道该用哪张表
    从**命令名**推。电脑端知道自己刚发的是哪条命令（§5.3.4:378），所以：
        #NTT                   → FNTT 表
        #INTT                  → INTT 表
        #PMUL NTT              → PWM2 表（和 FNTT 是**同一张**）
        #PMUL TIME / #PMUL FULL → INTT 表
    **命令名推不出来的那一格**：FNTT 的读出序还随**折叠度**分档（pe1 交织 / pe4、pe16
    自然序），而折叠度是编译进位流的、命令里没有它（§5.3.4:378 末段）。所以这几张表之外
    多一个 `build` 参数（默认 1），值来自 `#RDY <ver> <build> <errs>` 的 `<build>`（§5.2:290）。
    ✅ 最后一行**原先不在 proto.md 的表里**（那张表只有 FNTT / INTT / PWM2 三行，
       §5.3.4:370-374）—— **2026-10-06 已按 A 的订正单补成五行**（`#PMUL TIME` /
       `#PMUL FULL` 各有独立一行）。依据是 tb 的实测：`fullmul_batch_tb.v:169-170` 和
       `halfmul_batch_tb.v:157-158` 的读出循环是 `fout[m]`、`fout[m+128]`，
       和 INTT 的 `intt_batch_tb.v:112-115` 一模一样。

⚠️ 它**不**干的事（分层，别越界）
    · 不管串口 / 插座 —— 那是 link.py；
    · 不管事务流程、重试、超时 —— 那是 host.py；
    · 不知道**发**出去的顺序该是什么 —— 2026-10-06 起 proto.md §5.3.4 的
      「输入顺序」列已给出（按 (运算, 折叠度) 分档），但**本文件仍不管发送**，
      分工不变：本文件只管**收回来**的解包。

⚠️ 一份数据两个读法，别搞混
    `vectors.read_vector` 是**严格**的（只认 3 位）——它读的是**机器生成**的定长向量。
    `read_values`（本文件）是**宽容**的（认 1~3 位）——因为仓库里有 23 个**变长**文件
    要拿来对拍（§5.3.5:389-393）。两个契约不同，都得在。
"""

import re
from pathlib import Path

import vectors

# 单一来源：组大小和「线上数据行长什么样」都在 vectors.py 里定义，
# 这里不抄第二份（抄了就会漂）。
GROUP_LEN = vectors.GROUP_LEN
DATA_LINE_RE = vectors.DATA_LINE_RE

# 对拍这一侧要更宽：仓库里有变长格式的文件，见 read_values 的说明。
ANY_HEX_RE = re.compile(r"^[0-9a-fA-F]{1,3}$")

# 三种运算类型。取值就是 proto.md §5.3.4:370-374 那张表里的三行。
FNTT = "FNTT"
INTT = "INTT"
PWM2 = "PWM2"


# ---------------------------------------------------------------- 两张表

def _perm_fntt():
    """FNTT / PWM2 的读出序：组内把第 2、3 个对调。

    §5.3.4:376 的式子：`下标 = (m & ~3) | ((m & 1) << 1) | ((m >> 1) & 1)`
    """
    return tuple((r & ~3) | ((r & 1) << 1) | ((r >> 1) & 1) for r in range(GROUP_LEN))


def _perm_intt():
    """INTT 的读出序：前半本与后半本交叉。

    §5.3.4:376 的式子：`m` 偶 → 下标 `m/2`；`m` 奇 → 下标 `128 + (m-1)/2`。
    ⚠️ 和 FNTT **不是**同一张表。文档原话：「两张表不一样，别照抄一张。」
    """
    return tuple(r // 2 if r % 2 == 0 else 128 + (r - 1) // 2
                 for r in range(GROUP_LEN))


_PERM = {
    FNTT: _perm_fntt(),
    INTT: _perm_intt(),
    PWM2: _perm_fntt(),      # 点乘和 FNTT 同序（§5.3.4:370-374 的输出列）
}

# ---------------------------------------------------------------- 折叠度档位

# `#RDY <ver> <build> <errs>` 里的 `<build>`（= `PE_NUMBER`，§5.2:290）。
# **只有 FNTT 的读出序随它分档**（§5.3.4:370）；INTT / PWM2 三档同序，不看它。
# 默认 1 = 「还没收到 #RDY」时的行为，等同加这个参数之前的**全部**行为。
DEFAULT_BUILD = 1
KNOWN_BUILDS = (1, 4, 16)


def _perm_identity():
    """自然序（恒等排列）：`perm[r] == r`。pe4 / pe16 上 FNTT 的**读出**序（§5.3.4:370）。"""
    return tuple(range(GROUP_LEN))


# FNTT 的读出序按 build 查；其余运算仍走上表那张 _PERM。
_FNTT_PERM = {
    1: _perm_fntt(),         # 默认档 —— 与 _PERM[FNTT] 是同一个值
    4: _perm_identity(),
    16: _perm_identity(),
}


# ---------------------------------------------------------------- 装载序（电脑 → 板子）

# §5.3.4:372 那张表的**「输入顺序」列** —— 与上面的**读出序是两回事**：读出看运算
# 类型，装载看 **(运算, 折叠度)**。规格原话：「装载那一列按 (运算, 折叠度) 分档，
# 没有一句话能概括……**别按装载路径外推，查表**」。
#
# ⚠️ 基准是**向量文件自己存的顺序**（`refsim/batch/*.txt`），登记的是**「要重排成
#    什么样」**，不是「文件长什么样」。所以**别按「文件一定是自然序」外推** ——
#    `intt_batch_in.txt` 就是个反例：它存的是自然序，而 §5.3.4:372 那一格
#    **三档都要求交织**，于是三档都得重排（2026-10-04 记录原话即为
#    `intt_batch_in.txt [装载 interleave]`，当时是那个临时脚本现排的）。
# ⚠️ 这张表**只管喂进去的数据**；解包（板子 → 电脑）看下面的 `permutation()`。
_LOAD_PERM = {
    # key              折叠度 -> (第 0 个 bank, 第 1 个 bank, ...)
    # INTT：三档都交织（§5.3.4:372），文件却是自然序 → 三档都要排
    ("#INTT",):        dict((b, (_perm_fntt(),)) for b in KNOWN_BUILDS),
    ("#PMUL", "NTT"):  {1: (_perm_fntt(), _perm_fntt())},      # pe1：两 bank 都交织
    ("#PMUL", "TIME"): {1: (_perm_identity(), _perm_fntt())},  # pe1：A 自然、B 交织
}


def kind_of(command):
    """从命令名推出该用哪张表。认不出来就**响亮报错**，不猜。

    command 可以是整条命令（`"#PMUL NTT 1"`），也可以只有命令名（`"#PMUL NTT"`）；
    后面的参数（条数）会被忽略。
    """
    words = command.split()
    if not words:
        raise SystemExit("!! 空命令，推不出解包序。")
    head = words[0]
    if head == "#NTT":
        return FNTT
    if head == "#INTT":
        return INTT
    if head == "#PMUL":
        if len(words) < 2:
            raise SystemExit("!! `#PMUL` 少了域参数（该是 NTT / TIME / FULL）：%r" % command)
        if words[1] == "NTT":
            return PWM2
        if words[1] in ("TIME", "FULL"):
            # ⚠️ proto.md 那张表里没有这两行，依据是 tb 实测（见模块 docstring）。
            return INTT
        raise SystemExit("!! 不认识的 `#PMUL` 域：%r（只认 NTT / TIME / FULL）" % words[1])
    raise SystemExit("!! 这条命令推不出解包序：%r" % command)


def permutation(kind, build=DEFAULT_BUILD):
    """给出该运算的读出序。

    build —— `#RDY <ver> <build> <errs>` 的 `<build>`（= 折叠度 `PE_NUMBER`，§5.2:290）。
             **只有 FNTT 用它**（§5.3.4:370：pe1 交织 / pe4、pe16 自然序）；INTT / PWM2
             三档同序，传什么都一样。默认 DEFAULT_BUILD(=1)，即「既没给 `--build`、
             也没收到 `#RDY`」时的行为 —— 等同加这个参数之前的全部行为。
             ⚠️ **A 已于 2026-10-07 把 `#RDY` 落进 RTL**，所以「自动认出折叠度」现在
             由 `board_run.py` 走通了：开串口后先收一行，是 `#RDY` 就拿它的 `<build>`
             当本参数（`host.Host.handshake()`）。`#RDY` 没收到时仍退回默认值 1
             —— 那时**显式给 `--build`** 是唯一可靠的路子（§5.2 说 `#RDY` 是
             「尽力而为」的一行，丢了是正常的）。

    返回值 `perm[r]` = **收到第 r 行**该摆到**哪个自然下标**去。
    长度 256，而且是**双射**（256 个下标互不重复、正好盖住 0..255）——
    test_unpack.py 第 1 条守着这件事。
    """
    if build not in KNOWN_BUILDS:
        raise SystemExit("!! 不认识的折叠度 <build>=%r（只认 %s，见 §5.2:290）"
                         % (build, " / ".join(str(b) for b in KNOWN_BUILDS)))
    if kind == FNTT:
        return _FNTT_PERM[build]
    try:
        return _PERM[kind]
    except KeyError:
        raise SystemExit("!! 不认识的运算类型：%r（只认 %s）"
                         % (kind, " / ".join(sorted(_PERM))))


def load_permutation(key, bank, build=DEFAULT_BUILD):
    """给出第 `bank` 个 bank **送进板子前**的重排表。

    key   —— `vectors.VECTORS` 的键，形如 `("#PMUL", "NTT")`；认不出的一律恒等。
    bank  —— 第几个 bank（0 起）：`#NTT` / `#INTT` 只有一个，`#PMUL *` 是 A、B 两个。
    build —— 折叠度（`#RDY <ver> <build> <errs>` 的 `<build>`）。

    返回值 `perm[i]` = **送出去的第 i 行**该取向量文件里的第 `perm[i]` 行。
    长度 256。没有特殊规定的 (运算, 折叠度, bank) 一律**恒等**。

    ⚠️ **与 `permutation()` 是两回事，别互相套用**：那个是**读出**序
       （板子 → 电脑，按运算类型查，只有 FNTT 看 build）；这个是**装载**序
       （电脑 → 板子，按 (运算, 折叠度) 查）。两张表都出自 §5.3.4:370-374 的同
       一张表，但是**两列**。

    ⚠️ 这一格**曾经漏掉过**（2026-10-15 在真板子上查出来的）：B1 那次只补了读出
       侧，装载侧照原样送文件，于是 pe1 上 `#PMUL NTT 1` 稳定 252/256 全错 ——
       板子算得对，是喂进去的 NTT 域布局不对。规格 §5.3.4:372 对 pe1 的
       `#PMUL NTT` / `#PMUL TIME` 另有要求，见 `_LOAD_PERM`。
    """
    banks = _LOAD_PERM.get(key, {}).get(build)
    if banks is None:
        return _perm_identity()
    if bank >= len(banks):
        raise SystemExit(
            "!! %r 在 pe%d 档下只登记了 %d 个 bank 的装载序，却问到了第 %d 个。"
            % (key, build, len(banks), bank))
    return banks[bank]


# ---------------------------------------------------------------- 解包 / 反解包

def _as_value(text, where):
    """一行文本 → 整数。形状不对就响亮报错。"""
    if not DATA_LINE_RE.match(text):
        raise SystemExit("!! %s不是 3 位十六进制：%r（线上数据行必须是 3 位，"
                         "§5.3.4 那套表也是在 3 位的前提下才成立）" % (where, text))
    return int(text, 16)


def unpack(kind, rows, build=DEFAULT_BUILD):
    """把板子回传的 256 行摆成自然序，返回 256 个整数。

    kind  —— `permutation` 认的类型（FNTT / INTT / PWM2）
    rows  —— 收到的原始行（**物理序**，3 位十六进制字符串），必须**正好 256 行**
    build —— 折叠度（`#RDY` 的 `<build>`）。**只有 FNTT 用**，见 `permutation`。

    ⚠️ 行数不对就报错。行数不对的常见成因有两个，都会静默出大错，所以宁可炸：
       命令发错了（比如拿 `#NTT` 的向量去喂 `#INTT`）；
       数据段被截断了（§5.5 的 `#ERR 05`）。
    """
    if len(rows) != GROUP_LEN:
        raise SystemExit("!! 解包要正好 %d 行，收到 %d 行 —— 要么命令发错了，"
                         "要么数据段被截断了。" % (GROUP_LEN, len(rows)))
    perm = permutation(kind, build)
    out = [0] * GROUP_LEN
    for r, text in enumerate(rows):
        out[perm[r]] = _as_value(text, "第 %d 行" % r)
    return out


def to_physical_order(kind, values, build=DEFAULT_BUILD):
    """`unpack` 的**逆**：把自然序摆成板子读出的物理序。返回 256 行字符串。

    build —— 折叠度（`#RDY` 的 `<build>`）。**只有 FNTT 用**，见 `permutation`。

    ⚠️ 现在只有一个用处：**在测试里伪造「板子该回的那 256 行」**（真板子还没有）。
       第 5 步改陪练时也会用到它 —— 陪练要改成吐物理序才算忠实。
       本函数不写文件、不发串口、不碰硬件。
    """
    if len(values) != GROUP_LEN:
        raise SystemExit("!! 摆物理序要正好 %d 个值，收到 %d 个。"
                         % (GROUP_LEN, len(values)))
    perm = permutation(kind, build)
    return ["%03x" % values[perm[r]] for r in range(GROUP_LEN)]


# ---------------------------------------------------------------- 落盘 / 读盘

def write_result(path, values):
    """按 §5.3.5:384 的铁律落盘：**二进制模式 + LF 行尾**，每行 3 位小写 hex。

    ⚠️ 必须是二进制模式。文本模式（`"w"`）在 Windows 上会把 `\\n` 翻成 `\\r\\n`，
       结果是「256 个数值全对、`diff` 却说 256 行全不同」—— 那个坑排查起来很费时间。
    ⚠️ **不许用 `diff --strip-trailing-cr` 去遮掩**行尾差异（§5.3.5:386）：
       那是把症状藏起来，不是修好。
    ⚠️ 本函数一律写 3 位。仓库里那 23 个**变长**文件（§5.3.5:389-393）和它
       字节不同 —— 所以对拍要**按数值比**（见 compare_values），别拿 `diff` 去比。
    """
    blob = bytearray()
    for v in values:
        if not (0 <= v <= 0xFFF):
            # 超出 3 位就写不出 3 位了，会静默变成 4 位、把行框撑破。
            raise SystemExit("!! 值超出 3 位十六进制能表示的范围（0..4095）：%r" % (v,))
        blob += ("%03x\n" % v).encode("ascii")
    with open(Path(path), "wb") as f:        # 二进制模式，不是 "w"
        f.write(bytes(blob))


def read_values(path):
    """读一个向量 / 结果文件，返回整数列表。**比 vectors.read_vector 宽**：认 1~3 位。

    为什么要有这么一份宽容的读法
        §5.3.5:389-393 说明仓库里有 23 个文件是**变长**的（1~3 位混排）：
        `fullmul_exp.txt` / `halfmul_exp.txt` / `halfmul_b.txt`，外加 16 个 `vref_*`。
        实测（2026-09-29）：`fullmul_exp.txt` 4096 行里有 **291** 行不是 3 位，
        `halfmul_exp.txt` **291** 行，`halfmul_b.txt` **308** 行。
        `vectors.read_vector` 对这些文件会**响亮失败**（那是它该做的 ——
        它的契约是「机器生成的定长向量」），所以对拍这一侧得用宽容的读法。
        这也正是 §5.3.5:391 的处理办法 (a)「按数值比，不按文本逐字节比」的落点。

    宽容**只针对位数**：非十六进制、超过 3 位、空行，照样**响亮报错**。
    """
    path = Path(path)
    data = path.read_bytes()
    if data and not data.endswith(b"\n"):
        raise SystemExit("!! %s 最后一行没有换行符结尾 —— 文件可能被截断了。" % path)
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()                      # 文件以 LF 结尾，切出来末尾多个空段，正常
    out = []
    for i, raw in enumerate(lines):
        text = raw.decode("ascii", "replace")
        if not ANY_HEX_RE.match(text):
            # ⚠️ 这里**不跳过**空行。中间冒出空行说明文件形状不对，
            #    静默跳过就等于把「少了一行」藏起来 —— 对拍会错位。
            raise SystemExit("!! %s 第 %d 行不是 1~3 位十六进制：%r" % (path, i + 1, text))
        out.append(int(text, 16))
    return out


# ---------------------------------------------------------------- 对拍

def compare_values(got, exp, limit=10):
    """**按数值比，不按文本逐字节比**（§5.3.5:391 的处理办法 (a)）。

    返回 `(n_bad, diffs)`：
        n_bad —— 不同的个数；
        diffs —— 最多 `limit` 条 `(下标, 收到的, 该是的)`，用来指出「第一个不同在哪」。

    为什么不能按文本比：`write_result` 一律写 3 位，而 `fullmul_exp.txt` 那批
    是变长的。按文本比会得到「**数值全对、文本不匹配**」——症状和行尾 CRLF
    那个坑一模一样，成因却完全不同（§5.3.5:389 原话），排查时最容易认错。
    """
    if len(got) != len(exp):
        raise SystemExit("!! 对拍的两边长度不同：收到 %d 个，期望 %d 个。"
                         % (len(got), len(exp)))
    diffs = []
    n_bad = 0
    for i in range(len(got)):
        if got[i] != exp[i]:
            n_bad += 1
            if len(diffs) < limit:
                diffs.append((i, got[i], exp[i]))
    return n_bad, diffs
