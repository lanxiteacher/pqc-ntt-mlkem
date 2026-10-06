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

⚠️ `--check` 在 `--loopback` 下**必然全错**，那不是 bug
    陪练 `fake_board.py` 回吐的是 `*_exp.txt` 的**文件序**，而真板子回的是**物理序**
    （§5.3.4:378「板子按自己读出的物理顺序原样回传」）。`unpack()` 要的正是物理序 ——
    所以拿陪练的输出解包，256 个系数会全错。这条是**已知**的（KNOWN_ISSUES B4 那个
    假绿陷阱的反面）：陪练只用来验「脚本跑不跑得起来」，**数值对拍请在真板子上做**。

⚠️ `--check` 解包按哪个折叠度，用 `--build` 说明（默认 1）
    `unpack.py` 里 FNTT 的**读出序**随折叠度分档（pe1 交织 / pe4、pe16 自然序，§5.3.4:370），
    而折叠度是编译进位流的、命令里没有它 —— 所以**必须由你告诉它**。不给就按 pe1。
    ⚠️ 板子若烧的是 pe4 / pe16 而这里没给 `--build`，**FNTT** 会 256 个全错 ——
    那是折叠度没说对，不是 RTL 的 bug。H6 联调定的就是 pe1，所以默认这一格是对的。
    ⚠️ **板子端还没实现 `#RDY`**（A 侧零命中），所以「自动认出折叠度」暂时做不到，
    只能手工传；`unpack.py` 的 `build` 参数已经留好，A 一发得出 `#RDY` 就能接上。

本脚本**不重写任何协议断言** —— 发什么、怎么判、超时多久，全在
`host.py` / `proto.py` / `unpack.py` 里。这里只负责把它们接起来、把结果打成人话。
"""

import argparse
import sys

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


def build_data(command):
    """按命令取要发的数据行。返回 `(数据行, 期望文件名)`；没有向量的命令给 `([], None)`。

    ⚠️ 数据行**必须和命令对得上**：`#NTT` 的向量喂给 `#INTT`，陪练会「一组都对不上」，
    真板子会算出一个看着像模像样的错结果。所以这一格不留余地，认不出来就炸。
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
    for name in in_files:
        lines = vectors.read_vector(vectors.BATCH_DIR / name)
        groups = vectors.split_groups(lines, name)
        data += groups[0]                      # n=1 -> 每组都是第 0 组
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

def report_probe(lk, command, verbose):
    """探活类命令：交给 `host.Host.probe()`，这里只把它讲成人话。返回进程退出码。

    ⚠️ **判定逻辑一条都不在这里** —— 「回帧校验对不对、首词认不认、回显对不对得上」
       全在 `host.py` 的 `_parse` / `_wait_for` 里（那是协议的认识所在，只有一份）。
       本函数只干三件事：调它、把结果打出来、给个退出码。

    退出码：`OK` 和 `ERR` 都是 **0**。
        `#ERR` 不是故障 —— 板子能回错误码，说明链路活着、它读懂了你的命令、按协议拒了。
        拿 `#FOO 1` 去试板子，**它就该回 `#ERR 01`**，那时 0 才是对的。
        只有「错位」和「没回声」是 1。
    """
    txn = host.Host(lk, verbose=verbose).probe(command)

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

def do_check(command, txn, build=unpack.DEFAULT_BUILD):
    """解包 + 按数值对拍。返回 0=全对，1=有不同。

    build —— 折叠度（`#RDY` 的 `<build>`）。**只有 FNTT 的读出序看它**，
             命令行由 `--build` 给，默认 pe1（见文件头的说明）。
    """
    key = vector_key(command)
    if key is None:
        print("!! 这条命令没有标准答案向量，`--check` 用不了。")
        return 1
    _, exp_file = vectors.VECTORS[key]

    print("")
    print("--check：按 **pe%d** 口径解包（板上烧的是别的折叠度时，FNTT 会全错，见 B1）"
          % build)
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
    ap.add_argument("--port", default=None,
                    help="显式指定串口号（不给就按设备名现找，见 link.find_port）")
    ap.add_argument("--baud", type=int, default=link.DEFAULT_BAUD, help="波特率")
    ap.add_argument("--check", action="store_true",
                    help="跑完解包，和标准答案按数值对拍（口径按 --build）")
    ap.add_argument("--build", type=int, default=unpack.DEFAULT_BUILD,
                    choices=unpack.KNOWN_BUILDS,
                    help="板子烧的折叠度 PE_NUMBER（1/4/16，默认 1）。"
                         "只有 FNTT 的读出序看它 —— 烧了 pe4/pe16 却不给，FNTT 会全错")
    ap.add_argument("--verbose", action="store_true", help="把每次重试 / 容错实时打出来")
    args = ap.parse_args(argv)

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
        lk = link.open_link("loopback")
        where = "陪练（loopback）—— 不碰硬件"
    else:
        try:
            lk = link.open_link("serial", port=args.port, baud=args.baud)
        except SystemExit as e:            # 打不开串口 / 没装 pyserial：报人话，不是栈
            print(e)
            return 1
        where = "真串口 %s（%d-8N1）" % (lk.port, lk.baud)

    # ---- 探活类命令：一条短路，不经过事务状态机 --------------------------
    if vector_key(args.command) is None:
        print("插座：%s" % where)
        print("命令：%s  （探活类：不带数据，只等一条回帧）" % args.command)
        if args.check:
            print("⚠️ 探活类命令没有标准答案向量，`--check` 用不上，已忽略。")
        print("")
        rc = report_probe(lk, args.command, args.verbose)
        lk.close()
        return rc

    try:
        data, _ = build_data(args.command)
    except SystemExit as e:
        print(e)
        lk.close()
        return 1

    print("插座：%s" % where)
    print("命令：%s   数据行：%d" % (args.command, len(data)))
    if args.loopback and args.check:
        print("⚠️ `--loopback` + `--check`：陪练回的是**文件序**，解包必然全错。")
        print("   那不是 bug（KNOWN_ISSUES B4）—— 数值对拍要在真板子上做。")

    # ---- 跑一条事务 ------------------------------------------------------
    txn = host.Host(lk, verbose=args.verbose).run(args.command, data)

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

    rc = 0
    if txn.outcome != host.RESULT_OK:
        print("")
        print("结论：这条事务**没成功**（%s）—— `--check` 不跑。" % txn.outcome)
        rc = 1
    elif not args.check:
        print("")
        print("结论：这条事务成功。（要按数值对拍，加 `--check`。）")
    else:
        rc = do_check(args.command, txn, args.build)

    lk.close()
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
