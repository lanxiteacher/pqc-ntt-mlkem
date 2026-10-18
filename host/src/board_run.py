"""在**真板子**上跑一条事务 —— H6 联调的第一个入口。

为什么要有它（`host/KNOWN_ISSUES.md` 的 C2）
    `host/src/` 里原先只有 `test_*.py`，没有一个「对真串口跑一条事务」的入口。
    联调第一天要能这样敲（口号会变，所以**脚本自己现找**，见 `host/README.md:21-23`）：

        python host/src/board_run.py --list            # 本机现在有哪些串口
        python host/src/board_run.py "#PING"           # 探活，不用板子也能看出链通没通
        python host/src/board_run.py "#INTT 1" --check # 跑一条，并和标准答案按数值对拍

    上板之前，先不碰硬件确认这个脚本本身没坏（拿**陪练**当对端，一个硬件都不要）：

        python host/src/board_run.py --loopback "#NTT 1"

两类命令走两条不同的路（都在 `host.Host` 里，本脚本只负责讲人话）
    · **带数据的**（`#NTT` / `#INTT` / `#PMUL ...`）—— `host.Host.run()`：
      它管重发、管 `#ABORT`、管每一步的超时。
    · **探活类的**（`#PING` / `#ABORT` 之类，没有标准答案向量的）—— `host.Host.probe()`：
      发一条命令、只等一条回帧，并核对「回帧合法 + 回显对得上」。
      ⚠️ 为什么不也用 `run()`：那台状态机是给**带数据的事务**写的，它发完命令会
         「等 `#BEGIN`」。而 `#PING` 只回一条 `#OK`（§5.2:286）—— 实测塞进 `run()` 会在
         「等 #BEGIN」上白等 5 s、再重发 3 次才放弃。`probe()` 就是为这条路径加的。

陪练的两种模式（只验协议，不验硬件算术）
    默认 --loopback 保留历史的文件序回放，不能据此判断物理序解包。
    加 --physical-order 后独立按 §5.3.4 重排输入匹配和输出，允许 --check。
    未识别的输入立即拒绝，不会拿第 0 组答案掩盖错误。
    例：python host/src/board_run.py --loopback --physical-order --fake-build 4 --check "#INTT 1"

⚠️ `--check` 解包按哪个折叠度 —— **开串口后会先吃一行 `#RDY` 自动认**（2026-10-07 起）
    `unpack.py` 里 FNTT 的**读出序**随折叠度分档（pe1 交织 / pe4、pe16 自然序，§5.3.4:370），
    而折叠度是编译进位流的、命令里没有它。**装载序（送进去的数据怎么摆）也随它分档**
    —— pe1 的 `#PMUL NTT` 两 bank 交织、`#PMUL TIME` 的 B bank 交织（§5.3.4:372），
    与向量文件的 pe4/pe16 布局不同。所以折叠度**在送数据之前**就得定下来；两处都由
    `unpack` 的两张表管（`load_permutation` / `permutation`），别在这里另写一份。
    A 于 2026-10-07 把 `#RDY` 落进了 RTL
    （复位释放后板子自发一行），所以本脚本**开串口后先无条件收一行**：
        · 是 `#RDY`      -> 吃掉它，拿它的 `<build>` 当折叠度（`Host.handshake()`）
        · 不是 / 没收到  -> 原样放回 / 当作没有，退回 `--build` 或默认 pe1
    ⚠️ **收不到 `#RDY` 很正常**（§5.2 说它是「尽力而为」的一行：上电瞬间电脑多半还没
   开串口监听，它就丢了）。所以**别依赖它** —— 板子烧的是 pe4 / pe16 而它又没被收到时，
   用 `--build` 手工说明。不说就用 pe1，那时 **FNTT** 会 256 个全错 ——
   那是折叠度没说对，不是 RTL 的 bug。H6 联调定的就是 pe1，所以默认这一格是对的。
    `--build` 显式给出时**优先于** `#RDY`（人不该被机器盖过）。

本脚本**不重写任何协议断言** —— 发什么、怎么判、超时多久，全在
`host.py` / `proto.py` / `unpack.py` 里。这里只负责把它们接起来、把结果打成人话。
"""

import argparse
import sys
import time

import host
import link
import unpack
import vectors


# ---------------------------------------------------------------- 取数

def vector_key(command):
    """命令 -> `vectors.VECTORS` 的键。没有向量的命令返回 None（如 `#PING`、`#ABORT`）。"""
    words = command.split()
    if not words:
        return None
    if words[0] in ("#NTT", "#INTT"):
        return (words[0],)
    if words[0] == "#PMUL" and len(words) >= 2:
        return ("#PMUL", words[1])
    return None


def group_count(command):
    """取出命令结尾的组数 `<n>`，并要求它是 1。

    §5.2:253 写着 `#NTT <n>` 的「n = 组数（**冻结为 1**）」。既然冻结了，
    本脚本就**只跑 n=1**：n>1 时「哪几组、按什么顺序」在文档里没有说死
    （§5.2:255 的 `2n×256` 只写了「前 A 后 B」），与其猜一个，不如响亮拒掉。
    """
    words = command.split()
    if not words or not words[-1].isdigit():
        raise SystemExit("!! 命令结尾要带组数，形如 `#NTT 1`（见 §5.2:253）：%r" % command)
    n = int(words[-1])
    if n != 1:
        raise SystemExit(
            "!! `<n>` 已冻结为 1（§5.2:253 原话：「n = 组数（冻结为 1）」）。\n"
            "   本脚本只跑 n=1 —— n>1 的数据顺序文档没写死，不猜。")
    return n


def build_data(command, build=unpack.DEFAULT_BUILD):
    """按命令取要发的数据行。返回 `(数据行, 期望文件名)`；没有向量的命令给 `([], None)`。

    ⚠️ 数据行**必须和命令对得上**：`#NTT` 的向量喂给 `#INTT`，陪练会「一组都对不上」，
    真板子会算出一个看着像模像样的错结果。所以这一格不留余地，认不出来就炸。

    ⚠️ `build` 管的是**装载序**（§5.3.4:372 的「输入顺序」列），**不是**解包那侧的
       读出序 —— 两者是同一张表的两列，别互相套用。向量文件存的是 pe4 / pe16 的
       布局，而 **pe1 的 `#PMUL NTT`（两 bank 交织）与 `#PMUL TIME`（B bank 交织）
       跟文件布局不一样**（`unpack._LOAD_PERM`）。不按折叠度重排就是「板子算得对、
       喂进去的布局错」，症状是稳定 252/256 全错 —— 2026-10-15 在真板子上坐实的。
    """
    key = vector_key(command)
    if key is None:
        return [], None
    try:
        in_files, exp_file = vectors.VECTORS[key]
    except KeyError:
        raise SystemExit(
            "!! %r 在 `vectors.VECTORS` 里没有向量。只认 %s。"
            % (key, " / ".join(" ".join(k) for k in vectors.VECTORS)))
    group_count(command)

    data = []
    for bank, name in enumerate(in_files):
        lines = vectors.read_vector(vectors.BATCH_DIR / name)
        groups = vectors.split_groups(lines, name)
        group = groups[0]                      # n=1 -> 每组都是第 0 组
        perm = unpack.load_permutation(key, bank, build)
        if len(group) != len(perm):
            raise SystemExit(
                "!! %s 一组 %d 行，装载序表却是 %d 项 —— 两者对不上。"
                % (name, len(group), len(perm)))
        data += [group[i] for i in perm]
    return data, exp_file


# ---------------------------------------------------------------- 列串口

def do_list():
    """打印本机串口，并指认出哪个像板载 CH340C。找到就返回它的口号，否则 None。"""
    try:
        ports = link.list_serial_ports()
    except SystemExit as e:
        print(e)
        print("  （`--list` 要装 pyserial 才能枚举本机串口。）")
        return None

    if not ports:
        print("本机一个串口都没有 —— 板子插上了吗？（要插底板上的 USB_UART 那个口）")
        return None

    print("本机串口（设备名里含 %r 的才是板子）：" % link.CH340_NAME)
    found = []
    for dev, desc in ports:
        mark = ""
        if link.CH340_NAME.lower() in (desc or "").lower():
            mark = "   <- 像板载 CH340C"
            found.append(dev)
        print("  %-8s %s%s" % (dev, desc or "(没有设备名)", mark))

    if not found:
        print("没有设备名里含 %r 的串口。"
              % link.CH340_NAME)
        print("  （板子没插 / 驱动没装 / 设备名变了 —— 三种都长这样。）")
        return None
    if len(found) > 1:
        print("有 %d 个都像板子：%s —— 不替你猜，跑的时候用 --port 指定一个。"
              % (len(found), "、".join(found)))
        return None
    return found[0]


# ---------------------------------------------------------------- 探活

def report_probe(hst, command):
    """探活类命令：交给 `host.Host.probe()`，这里只把它讲成人话。返回进程退出码。

    ⚠️ **判定逻辑一条都不在这里** —— 「回帧校验对不对、首词认不认、回显对不对得上」
       全在 `host.py` 的 `_parse` / `_wait_for` 里（那是协议的认识所在，只有一份）。
       本函数只干三件事：调它、把结果打出来、给个退出码。

    退出码：`OK` 和 `ERR` 都是 **0**。
        `#ERR` 不是故障 —— 板子能回错误码，说明链路活着、它读懂了你的命令、按协议拒了。
        拿 `#FOO 1` 去试板子，**它就该回 `#ERR 01`**，那时 0 才是对的。
        只有「错位」和「没回声」是 1。

    `hst` 是**已经调过 `handshake()`** 的 `Host`（开机那行 `#RDY` 已被捡走）——
        所以这里**不**再新建一个 Host：新建的那个还得再吃一次开机行，而那时已经没得吃了。
    """
    txn = hst.probe(command)

    for ln in txn.log:
        print("  %s" % ln)
    if txn.raw is not None:
        print("  回帧原文：%s" % txn.raw)
        print("  （错误码的含义查 `host/proto.md` §5.2 那张错误码表。）")
    print("")
    print(txn.summary())

    if txn.outcome == host.RESULT_OK:
        print("")
        print("结论：探活成功 —— 回帧合法、回显对得上，后面有东西在按协议听。")
        return 0
    if txn.outcome == host.RESULT_FAILED:
        print("")
        print("结论：板子活着并按协议应答，但它**拒了**这条命令。")
        print("      （这不是故障 —— 想看它接不接受，换一条合法命令再试。）")
        return 0
    print("")
    print("结论：**没探到**。依次查：口号对不对（`--list`）/ 板子通电没 /"
          " 底板 P5 跳线在不在 PL 档。")
    return 1


# ---------------------------------------------------------------- 对拍

def do_check(command, txn, build=unpack.DEFAULT_BUILD, build_src="默认"):
    """解包 + 按数值对拍。返回 0=全对，1=有不同。

    build     —— 折叠度（`#RDY` 的 `<build>`）。**只有 FNTT 的读出序看它**。
    build_src —— 这个值是**哪来的**（`--build` 手工给的 / 从 `#RDY` 认出的 / 退回默认的）。
                 **打出来**，免得「机器认对了」和「正好蒙对默认值」看起来一样 ——
                 那正是本仓库反复踩的「假绿」形状。见 `host/KNOWN_ISSUES.md` B4。
    """
    key = vector_key(command)
    if key is None:
        print("!! 这条命令没有标准答案向量，`--check` 用不了。")
        return 1
    _, exp_file = vectors.VECTORS[key]

    print("")
    print("--check：按 **pe%d** 口径解包（%s；板上烧的是别的折叠度时，FNTT 会全错，见 B1）"
          % (build, build_src))
    kind = unpack.kind_of(command)
    got = unpack.unpack(kind, txn.rows, build)
    exp = unpack.read_values(vectors.BATCH_DIR / exp_file)[:vectors.GROUP_LEN]
    n_bad, diffs = unpack.compare_values(got, exp)

    print("  %s：%d 个系数里 **%d** 个不同。" % (kind, len(got), n_bad))
    for i, g, e in diffs:
        print("    第 %d 个：收到 %s，该是 %s" % (i, "%03x" % g, "%03x" % e))
    if n_bad:
        print("  结论：**数值对不上**。")
        return 1
    print("  结论：全部对得上。")
    return 0


# ---------------------------------------------------------------- 主流程

def main(argv):
    ap = argparse.ArgumentParser(
        description="在真板子（或陪练）上跑一条事务。见本文件头的「怎么用」。")
    ap.add_argument("command", nargs="?", help='命令正文，形如 "#NTT 1"')
    ap.add_argument("--list", action="store_true", help="只列本机串口，不跑事务")
    ap.add_argument("--loopback", action="store_true", help="拿陪练当对端，不碰硬件")
    ap.add_argument("--physical-order", action="store_true",
                    help="配合 --loopback，按 §5.3.4 装载/读出物理序回放已知向量；只验协议与顺序，不验 RTL 算术")
    ap.add_argument("--port", default=None,
                    help="显式指定串口号（不给就按设备名现找，见 link.find_port）")
    ap.add_argument("--baud", type=int, default=link.DEFAULT_BAUD, help="波特率")
    ap.add_argument("--check", action="store_true",
                    help="跑完解包，和标准答案按数值对拍（口径按 --build）")
    ap.add_argument("--build", type=int, default=None,
                    choices=unpack.KNOWN_BUILDS,
                    help="板子烧的折叠度 PE_NUMBER（1/4/16）。"
                         "不给就靠开机那行 #RDY 自动认；#RDY 也没收到才退回 pe1。"
                         "读出序与装载序都看它：读出序只有 FNTT 看（§5.3.4:370），"
                         "装载序看 pe1 的 #PMUL NTT / #PMUL TIME（§5.3.4:372）。"
                         "说错了是 256 个全错，不是 RTL 的 bug")
    ap.add_argument("--fake-build", type=int, default=unpack.DEFAULT_BUILD,
                    choices=unpack.KNOWN_BUILDS,
                    help="**只影响 --loopback**：让陪练自称烧的是这一档（默认 1）。"
                         "用来演练上面那条「从 #RDY 自动认折叠度」的路 —— 真板子上"
                         "这取决于烧进去的位流。")
    ap.add_argument("--verbose", action="store_true", help="把每次重试 / 容错实时打出来")
    args = ap.parse_args(argv)
    if args.physical_order and not args.loopback:
        ap.error("--physical-order 必须与 --loopback 一起使用")

    if args.list:
        return 0 if do_list() else 1

    if not args.command:
        ap.print_help()
        print("")
        print("例：python host/src/board_run.py --list")
        print("    python host/src/board_run.py --loopback \"#NTT 1\"")
        print("    python host/src/board_run.py \"#PING\"")
        return 2

    # ---- 开插座 ----------------------------------------------------------
    if args.loopback:
        board = None
        if args.fake_build != unpack.DEFAULT_BUILD or args.physical_order:
            import fake_board
            board = fake_board.FakeBoard(build=args.fake_build, physical_order=args.physical_order)
        lk = link.open_link("loopback", board=board)
        where = "陪练（loopback）—— 不碰硬件"
    else:
        try:
            lk = link.open_link("serial", port=args.port, baud=args.baud)
        except SystemExit as e:            # 打不开串口 / 没装 pyserial：报人话，不是栈
            print(e)
            return 1
        where = "真串口 %s（%d-8N1）" % (lk.port, lk.baud)

    # ---- 吃掉开机那一行 `#RDY`（若在）------------------------------------
    # ⚠️ 必须在**发第一条命令之前**读掉：板子复位释放后不等命令就自发这一行，
    #    不吃它的话第一条命令读到的会是 `#RDY` 而不是 `#OK`，之后全体错位一格。
    hst = host.Host(lk, verbose=args.verbose)
    got_rdy = hst.handshake()

    print("插座：%s" % where)
    if got_rdy:
        print("开机行：收到 `#RDY` —— 板子自称 ver=%d / 折叠度 pe%d / 上电以来 %d 个 #ERR"
              % (hst.board_version, hst.build, hst.board_errs))
    else:
        print("开机行：没收到 `#RDY`（旧位流，或它在串口打开前就发完了 —— "
              "§5.2 说它是「尽力而为」的一行，这不是故障）")

    # ---- 探活类命令：一条短路，不经过事务状态机 --------------------------
    if vector_key(args.command) is None:
        print("命令：%s  （探活类：不带数据，只等一条回帧）" % args.command)
        if args.check:
            print("⚠️ 探活类命令没有标准答案向量，`--check` 用不上，已忽略。")
        print("")
        rc = report_probe(hst, args.command)
        lk.close()
        return rc

    # ---- 折叠度：人给的 > `#RDY` 认的 > 默认 ------------------------------
    # ⚠️ `--build` 的默认值是 **None**（不是 1），就是为了把「没说」和「说了 1」
    #    分开 —— 两者行为虽然一样，但「人明确说了 pe1」不该被 `#RDY` 盖掉。
    # ⚠️ 这一段**必须排在 `build_data()` 前面**：折叠度不只决定解包怎么解
    #    （读出序），也决定数据怎么送（装载序，§5.3.4:372 的「输入顺序」列）。
    if args.build is not None:
        build, build_src = args.build, "`--build` 显式给的"
    elif hst.build is not None:
        build, build_src = hst.build, "从开机行 `#RDY` 自动认出的"
    else:
        build, build_src = unpack.DEFAULT_BUILD, "没收到 `#RDY`，退回默认的"

    try:
        data, _ = build_data(args.command, build)
    except SystemExit as e:
        print(e)
        lk.close()
        return 1

    print("命令：%s   数据行：%d" % (args.command, len(data)))
    if args.loopback and args.check:
        if args.physical_order:
            print("⚠️ 物理序陪练只回放已知答案：通过证明协议/排列衔接，不证明 RTL 算术正确。")
        else:
            print("⚠️ 默认陪练回文件序；它与真板物理序不同，不能用本次对拍判断 RTL。")
            print("   测协议排列请加 --physical-order；测硬件算术请用 RTL 仿真或真板。")

    # ---- 跑一条事务 ------------------------------------------------------
    # `expect_rows`：五条带数据的命令，结果**恒为一组** = `GROUP_LEN` = 256 行
    # （§4.2 每组 256 个系数；RTL 侧 `OUT_LINES` 也是写死的 256）。
    # 传它是为了让 host 手里有一道**独立**核对 —— 见 `host.py` 的 `Transaction.expect`。
    # ⚠️ 别在这里写 `256` 字面量：`GROUP_LEN` 是「一组多少行」的**唯一**出处。
    # ⚠️ 计时口径：**只包这一条事务**（发命令 → 收齐最后一行），不含 Python 启动、
    #    不含打开串口。2026-10-18 加它是为了 921600 演示模式能给出可复现的
    #    「184 ms → 23 ms」数字；进程外 Measure-Command 会把启动的 0.4 s 也算进去。
    t0 = time.monotonic()
    txn = hst.run(args.command, data, expect_rows=vectors.GROUP_LEN)
    txn_s = time.monotonic() - t0

    print("")
    print("收到 %d 行结果：%s" % (len(txn.rows), "、".join(txn.rows[:3]) or "(无)"))
    if len(txn.rows) > 3:
        print("    …（还有 %d 行没打出来）" % (len(txn.rows) - 3))
    if txn.log:
        print("日志（规则五：每次重试 / 容错都留痕）：")
        for ln in txn.log:
            print("    - %s" % ln)
    print("")
    print(txn.summary())
    print("")
    print("事务耗时：%.3f s（发命令 → 收齐最后一行；含重试，不含 Python 启动）" % txn_s)

    rc = 0
    if txn.outcome != host.RESULT_OK:
        print("")
        print("结论：这条事务**没成功**（%s）—— `--check` 不跑。" % txn.outcome)
        rc = 1
    elif not args.check:
        print("")
        print("结论：这条事务成功。（要按数值对拍，加 `--check`。）")
    else:
        rc = do_check(args.command, txn, build, build_src)

    lk.close()
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
