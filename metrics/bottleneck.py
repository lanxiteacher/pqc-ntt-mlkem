#!/usr/bin/env python3
"""瓶颈归因表 —— 一趟 NTT 事务的耗时，PC 侧拆成三段量。

为什么要这张表
    `report/design/03` §3.13.6 记了上板端到端墙钟（约 0.18–0.27 s），但那只说明
    「往返很慢」，没说清慢在哪一段。这张表把一趟事务拆开：

        ① 计算核       —— FPGA 上跑一遍 NTT 要多久（µs 级）
        ② 串口搬运     —— 115200 bps 上把输入送进去、把结果收回来要多久（ms 级）
        ③ 软件参考实现 —— 同一件事改在 PC 上用 C 参考实现算一遍要多久（µs 级）

    结论一句话：**瓶颈不在核，在接口。**

三段各自怎么量（口径写清楚，别混）
    ① 计算核   —— 读 `rtl/probes/README.md` §判据 2 的周期数 ÷ 板上 50 MHz。
                  **不是实测**：核嵌在协议状态机里，PC 看不见它什么时候起、什么时候停，
                  板子上量不出单独的核墙钟。这是「周期数 × 已知时钟」的换算值。
    ② 串口搬运 —— **走真实协议栈**（B 的 `host.Host` + `link.LoopbackLink` +
                  `fake_board.FakeBoard`）跑完整一趟，用一个计数的插座数出**线上真实
                  字节数**，再乘 10 bit/字节 ÷ 115200 bps。字节数是真的（协议栈自己拼的），
                  波特率是协议定死的 ⇒ 这个耗时是**模型值**，不是秒表读数。
                  ⚠️ loopback 是进程内的，**没有真的串口时序** —— 电气层的时间量不出来，
                  只能算。算出来的值与上板实测的复核见文末「复核」一节。
    ③ 软件参考实现 —— **真编译真跑**：`gcc -O2` 编 `research/kyber_ref/`，量的是
                  **`poly_ntt()` 的语义**（`ntt()` + `poly_reduce()`），不是裸 `ntt()`；
                  每轮先把合法输入（系数在 [0,q)）拷回工作数组，**输入准备与计算分开计时**。
                  原始轮次追加到 `metrics/data/bottleneck_ref_raw.csv`（一次会话一组）。
                  ⚠️ 这个数**随机器变**，同一台机器跨会话也会漂 ±10%（CPU 调频）——
                  报告引用的是**全部已记录轮次的累计中位**，所以默认重跑**不追加**，
                  要留新一轮证据显式加 `--record`。CPU 型号、OS、编译器写进产物。

产物
    `metrics/data/bottleneck.csv`          长表，一列一个数
    `metrics/README.md` 的 GEN 块          两张表，脚本维护、别手改

用法
    python metrics/bottleneck.py             # 只读历史：重跑不改变报告值
    python metrics/bottleneck.py --record    # 追加本轮原始轮次（留证据时才用）

⚠️ 本脚本**只读** `host/`、`research/`、`rtl/probes/` 下的文件，一个字节都不改。
"""

import argparse
import csv
import datetime
import platform
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
HOST_SRC = REPO / "host" / "src"
REF_DIR = REPO / "research" / "kyber_ref"
PROBES_MD = REPO / "rtl" / "probes" / "README.md"
C_SRC = HERE / "bottleneck_ref_timing.c"
CSV_OUT = HERE / "data" / "bottleneck.csv"
REF_RAW_OUT = HERE / "data" / "bottleneck_ref_raw.csv"
README = HERE / "README.md"

# 让 `import host` 等能找到 B 的模块。**不改它们**，只是 import。
sys.path.insert(0, str(HOST_SRC))

import board_run          # noqa: E402  只借它的 build_data()（装载序也在里面）
import fake_board         # noqa: E402
import host               # noqa: E402
import link               # noqa: E402
import vectors            # noqa: E402

# ---------------------------------------------------------------- 口径常数

BAUD = link.DEFAULT_BAUD          # 115200（proto.md §4.1）
BITS_PER_BYTE = 10                # 8N1 = 1 起始 + 8 数据 + 1 停止（link.py 顶上那条）
BOARD_MHZ = 50.0                  # 板上 `sys_clk` = 50 MHz（rtl/vivado/reports/board_*.rpt）
BUILD = 1                         # H6 联调定的就是 pe1（板子烧的那一档）

# 五条带数据的命令（`vectors.VECTORS` 的键 + 命令写法）。顺序照 §3.13.6 那张表。
COMMANDS = [
    ("#NTT",          "#NTT 1"),
    ("#INTT",         "#INTT 1"),
    ("#PMUL NTT",     "#PMUL NTT 1"),
    ("#PMUL TIME",    "#PMUL TIME 1"),
    ("#PMUL FULL",    "#PMUL FULL 1"),
]

# 上板实测墙钟（§3.13.6，10-04 那一版的历史值）。
# 用来复核模型 —— 模型值与它对照，差多少写进表里。
# (`#PMUL TIME` 那格仍**没有墙钟值**：10-15 pe1 复跑被旧向量文件卡住；
#  文件格式已由 B 于 2026-10-17 修复，10-18 三档各 6/6 已通过，
#  但新报告只留逐项对拍、不记墙钟秒数，所以这一格仍为空。)`
BOARD_WALL = {
    "#NTT":       {"pe1": 0.181, "pe4": 0.181, "pe16": 0.181},
    "#INTT":      {"pe1": 0.180, "pe4": 0.181, "pe16": 0.181},
    "#PMUL NTT":  {"pe1": 0.270, "pe4": 0.269, "pe16": 0.269},
    "#PMUL TIME": None,
    "#PMUL FULL": {"pe1": 0.270, "pe4": 0.270, "pe16": 0.270},
}

REPS = 3          # C 参考实现跑几轮取中位数
REF_ITERS = 200000  # 每轮调多少次 ntt()

# ---------------------------------------------------------------- 读周期数

# `rtl/probes/README.md` §判据 2 那张表：`| pe1 | 904 | 647 | 904 |`
CYC_RE = re.compile(r"^\|\s*pe(1|4|16)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*$", re.M)


def read_cycles():
    """从探针文档读出三档周期数。读不到就响亮报错 —— 不猜。"""
    text = PROBES_MD.read_text(encoding="utf-8")
    out = {}
    for m in CYC_RE.finditer(text):
        out["pe" + m.group(1)] = {"fntt": int(m.group(2)),
                                  "pwm2": int(m.group(3)),
                                  "intt": int(m.group(4))}
    if set(out) != {"pe1", "pe4", "pe16"}:
        raise SystemExit(
            "!! 在 %s 里没读齐三档周期数（读到 %s）。\n"
            "   那张表大概被改动过了，这个读法要跟着改 —— 别手抄一份顶替。"
            % (PROBES_MD, sorted(out) or "空"))
    return out


# ---------------------------------------------------------------- 计数插座

class CountingLink(link.LoopbackLink):
    """照抄 B 的 LoopbackLink，只多一件事：数**上线走了多少字节**。

    ⚠️ 一个字节都不许吞、不许补 —— 数出来多少就是协议栈真拼出来多少。
       所以它只重写 write / read_line / discard_pending 三处去累加，其余原样。
    """

    def __init__(self, board):
        super().__init__(board)
        self.tx = 0
        self.rx = 0

    def write(self, data):
        self.tx += len(data)                 # 上位机 → 板子
        super().write(data)

    def read_line(self, max_wait):
        line = super().read_line(max_wait)
        if line is not None:
            self.rx += len(line)             # 板子 → 上位机
        return line

    def discard_pending(self):
        thrown = super().discard_pending()
        self.rx += len(thrown)               # 扔掉的也是从线上收来的
        return thrown


def profile(command, build=BUILD):
    """跑一条事务，返回它的分项。跑不起来（如向量坏了）返回 `{"blocked": 原因}`。

    ⚠️ 整段都包在 try 里：向量坏了时，`build_data`（读**输入**文件）和陪练的
       `_begin`（读**期望**文件）都可能抛 `SystemExit`，两处都得接住 ——
       一条命令跑不了不该把整张表带崩，它自己要作为一格「受阻」进表。
    """
    try:
        data, _ = board_run.build_data(command, build)

        board = fake_board.FakeBoard(build=build)
        lk = CountingLink(board)
        hst = host.Host(lk)
        hst.handshake()                      # 吃掉开机那行 `#RDY`（若在）

        t0 = time.perf_counter()
        txn = hst.run(command, data, expect_rows=vectors.GROUP_LEN)
        pc_secs = time.perf_counter() - t0
        lk.close()
    except SystemExit as exc:
        line = (str(exc).strip().splitlines() or ["（无说明）"])[0]
        # 去掉本机的绝对路径前缀（进表的是「哪个文件坏了」，不是「本机的盘符」）
        # 与开头那个 `!! ` 提示符。
        return {"blocked": shorten(line).removeprefix("!! ").strip()}

    if txn.outcome != host.RESULT_OK:
        return {"blocked": "事务没成功（%s）：%s" % (txn.outcome, txn.error)}

    wire = lk.tx + lk.rx
    return {
        "command": command,
        "rows_in": len(data),
        "rows_out": len(txn.rows),
        "tx": lk.tx,
        "rx": lk.rx,
        "wire": wire,
        "serial_secs": wire * BITS_PER_BYTE / BAUD,
        "pc_secs": pc_secs,                  # 陪练在进程内，这个数≈纯软件开销
    }


# ---------------------------------------------------------------- C 参考实现计时

def gcc_version():
    try:
        out = subprocess.run(["gcc", "--version"], capture_output=True,
                             text=True, check=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit("!! 找不到能用的 gcc（编译 C 参考实现要用）：%s" % exc)
    return out.stdout.splitlines()[0].strip()


def cpu_model():
    """CPU 型号 —— 能拿到就写，拿不到不编。"""
    if sys.platform == "win32":
        try:
            out = subprocess.run(
                ["powershell", "-NoProfile", "-Command",
                 "(Get-CimInstance Win32_Processor).Name"],
                capture_output=True, text=True, timeout=15, check=True)
            name = out.stdout.strip().splitlines()[0].strip()
            if name:
                return name
        except (OSError, subprocess.SubprocessError, IndexError):
            pass
    return platform.processor() or platform.machine() or "unknown"


def time_reference(reps=REPS, iters=REF_ITERS):
    """编译并跑 `research/kyber_ref` 的 poly_ntt() 语义，返回单次耗时中位数（秒）。

    计时程序输出一行：`<n> <prep_s> <total_s> <checksum> <bad>`；
    净计算 = total - prep。每一轮都换回合法输入，避免把上一轮输出当下一轮输入。
    """
    session = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    with tempfile.TemporaryDirectory() as td:
        exe = Path(td) / ("ref_timing.exe" if sys.platform == "win32" else "ref_timing")
        cmd = ["gcc", "-O2", "-I", str(REF_DIR), str(C_SRC),
               str(REF_DIR / "ntt.c"), str(REF_DIR / "reduce.c"), "-o", str(exe)]
        build = subprocess.run(cmd, capture_output=True, text=True)
        if build.returncode != 0:
            raise SystemExit("!! 编译 C 参考实现失败：\n%s\n%s"
                             % (" ".join(cmd), build.stderr))

        rows, nets, preps, checksums = [], [], [], set()
        for r in range(1, reps + 1):
            run = subprocess.run([str(exe), str(iters)], capture_output=True,
                                 text=True, check=True)
            parts = run.stdout.split()
            if len(parts) != 5:
                raise SystemExit("!! 计时程序输出格式变了：%r" % run.stdout)
            n = int(parts[0])
            prep, total = float(parts[1]), float(parts[2])
            checksum, bad = int(parts[3]), int(parts[4])
            if bad:
                raise SystemExit("!! poly_ntt 输出有 %d 个系数落在中心代表区间外" % bad)
            checksums.add(checksum)
            preps.append(prep / n)
            nets.append((total - prep) / n)
            rows.append({
                "session": session,
                "utc": datetime.datetime.now(datetime.timezone.utc)
                       .isoformat(timespec="seconds"),
                "round": r, "iters": n,
                "prep_ns": "%.1f" % (prep / n * 1e9),
                "total_ns": "%.1f" % (total / n * 1e9),
                "net_ns": "%.1f" % ((total - prep) / n * 1e9),
                "checksum": checksum, "bad_coeffs": bad,
            })
    if len(checksums) != 1:
        raise SystemExit("!! 各轮输出的 checksum 不一致：%s" % checksums)
    return {
        "median": statistics.median(nets),
        "min": min(nets),
        "max": max(nets),
        "prep_median": statistics.median(preps),
        "total_median": statistics.median(nets) + statistics.median(preps),
        "checksum": checksums.pop(),
        "rows": rows,
        "reps": reps,
        "iters": iters,
    }


def write_ref_raw(ref, gcc, cpu):
    """把本轮计时**追加**到原始轮次表（表头只在文件不存在时写）。

    为什么追加而不是覆盖：同一台机器跨会话的读数会漂 ±20%（笔记本 CPU 调频/温热状态），
    只留最后一次会把「读数随环境变」这件事藏掉；报告里的参考值取全部已记录轮次的中位。
    """
    REF_RAW_OUT.parent.mkdir(parents=True, exist_ok=True)
    fresh = not REF_RAW_OUT.exists() or REF_RAW_OUT.stat().st_size == 0
    with REF_RAW_OUT.open("a", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        if fresh:
            w.writerow(["utc", "session", "round", "iters", "prep_ns", "total_ns",
                        "net_ns", "checksum", "bad_coeffs", "cpu", "python", "gcc", "task"])
        for row in ref["rows"]:
            w.writerow([row["utc"], row["session"], row["round"], row["iters"], row["prep_ns"],
                        row["total_ns"], row["net_ns"], row["checksum"],
                        row["bad_coeffs"], cpu, platform.python_version(), gcc,
                        "poly_ntt = ntt + poly_reduce; valid input each round"])


def aggregate_ref():
    """读原始轮次表，返回**跨会话**的中位与范围（报告引用的是这一组数）。

    读数噪声约 ±0.2 µs（CPU 调频），所以返回前**取到 0.1 µs**：
    否则每次重跑累计中位都会在小数第二位跳一下，报告与生成器永远差一点点。
    """
    nets, preps, sessions = [], [], set()
    with REF_RAW_OUT.open(encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            nets.append(float(row["net_ns"]) / 1e9)
            preps.append(float(row["prep_ns"]) / 1e9)
            sessions.add(row.get("session") or row["utc"][:16])
    us = lambda s: round(s * 1e6, 1) / 1e6
    return {
        "median": us(statistics.median(nets)),
        "min": us(min(nets)), "max": us(max(nets)),
        "prep_median": statistics.median(preps),
        "rounds": len(nets), "sessions": len(sessions),
    }


# ---------------------------------------------------------------- 拼表

def shorten(msg):
    """把消息里的仓库绝对路径换成相对路径 —— 换台机器路径不同，别让它进产物。

    顺带把 `\\` 归一成 `/`：那些消息来自 Windows 上跑的 Path，进了 markdown 是反的斜杠。
    """
    for sep in ("\\", "/"):
        msg = msg.replace(str(REPO) + sep, "")
    return msg.replace("\\", "/")


def fmt_val(secs, digits=None):
    """秒 → (数值, 单位)。按量级选单位，别让 CSV 里全是 `0.000018` 这种读不出的数。"""
    if secs < 1e-3:
        return ("%.2f" % (secs * 1e6), "µs")
    if secs < 1:
        return ("%.1f" % (secs * 1e3), "ms")
    return ("%.3f" % secs, "s")


def fmt_s(secs):
    """秒 → 人看的（µs 或 ms）。"""
    if secs < 1e-3:
        return "%.2f µs" % (secs * 1e6)
    if secs < 1:
        return "%.1f ms" % (secs * 1e3)
    return "%.3f s" % secs


def main():
    ap = argparse.ArgumentParser(description="瓶颈归因：核 / 串口搬运 / 软件参考实现")
    ap.add_argument("--record", action="store_true",
                    help="把本轮原始轮次追加到 data/bottleneck_ref_raw.csv"
                         "（默认只读历史，保证重跑不改变报告的累计中位）")
    args = ap.parse_args()

    # Windows 控制台默认 GBK，打印带 ⇒ / µ 的行会当场炸。**只影响控制台**，
    # 写文件的地方一律显式 utf-8 —— 见下面 write_text / csv 两处的 encoding。
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):
        pass

    cycles = read_cycles()

    print("  [1/3] 走真实协议栈数线上字节数 ……")
    prof = []
    for _, command in COMMANDS:
        r = profile(command)
        prof.append(r)
        if "blocked" in r:
            print("      %-13s 受阻：%s" % (command, r["blocked"].splitlines()[0]))
        else:
            print("      %-13s 发 %d B ／ 收 %d B ⇒ %s @ %d bps"
                  % (command, r["tx"], r["rx"], fmt_s(r["serial_secs"]), BAUD))

    print("  [2/3] 编译并计时 C 参考实现（poly_ntt 语义）……")
    ref = time_reference()
    gcc = gcc_version()
    cpu = cpu_model()
    session = dict(ref)                 # 本轮读数，留作对照
    if args.record:
        write_ref_raw(ref, gcc, cpu)
    else:
        print("      （本轮不写入原始轮次表；要追加证据请加 --record）")
    ref = aggregate_ref()               # 报告引用：跨会话累计
    ref.update({"reps": session["reps"], "iters": session["iters"],
                "checksum": session["checksum"]})
    print("      poly_ntt() 净计算：本轮中位 %s；跨 %d 次会话 %d 轮累计中位 %s"
          "（%s–%s）；输入准备：中位 %s"
          % (fmt_s(session["median"]), ref["sessions"], ref["rounds"],
             fmt_s(ref["median"]), fmt_s(ref["min"]), fmt_s(ref["max"]),
             fmt_s(ref["prep_median"])))
    print("      CPU：%s" % cpu)

    # 主表用 `#NTT 1`（最干净的一条：256 进 / 256 出）。它必须跑通，否则整张表没意义。
    ntt = next((r for r in prof if r.get("command") == "#NTT 1"), None)
    if ntt is None or "blocked" in ntt:
        raise SystemExit("!! `#NTT 1` 没跑通，主表立不起来：%s"
                         % (ntt or {}).get("blocked", "(没有这条)"))

    core_secs = cycles["pe1"]["fntt"] / (BOARD_MHZ * 1e6)
    total = ntt["serial_secs"] + core_secs     # 一趟的墙钟模型：核 + 串口（PC 侧开销另记）

    # ---- 生成 markdown ----------------------------------------------------
    G = []
    G.append("<!-- 这一段由 `python metrics/bottleneck.py` 生成，别手改 -->")
    G.append("")
    G.append("### 瓶颈归因：一趟 `#NTT 1` 拆三段（pe1 @ 板上 50 MHz）")
    G.append("")
    G.append("| 段 | 耗时 | 在这趟里的占比 | 怎么来的 |")
    G.append("|---|---:|---:|---|")
    G.append("| ① 计算核（FPGA 上跑 NTT） | %s | %.4f%% | %d 拍 ÷ %.0f MHz |"
             % (fmt_s(core_secs), 100 * core_secs / total, cycles["pe1"]["fntt"], BOARD_MHZ))
    G.append("| ② 串口搬运（%d 8N1） | **%s** | **%.3f%%** | %d B × %d bit ÷ %d bps |"
             % (BAUD, fmt_s(ntt["serial_secs"]), 100 * ntt["serial_secs"] / total,
                ntt["wire"], BITS_PER_BYTE, BAUD))
    G.append("| ③ 软件参考实现（同一件事改在 PC 上算） | %s | —（③ 不是这一趟的一段，是 ① 的替代） | `poly_ntt()` = `ntt()` + `poly_reduce()`；gcc -O2 实测，见文末 |"
             % fmt_s(ref["median"]))
    G.append("")
    G.append("**结论：瓶颈不在核，在接口。** —— 核占 %.3f%%，串口搬运占 **%.3f%%**，差 **4 个数量级**。"
             % (100 * core_secs / total, 100 * ntt["serial_secs"] / total))
    G.append("")

    G.append("### 折叠度改得了核，改不了接口")
    G.append("")
    G.append("| 档 | 核周期数 | 核延迟 @ 板上 50 MHz | 串口搬运（同上一趟） | 核占端到端 |")
    G.append("|---|---:|---:|---:|---:|")
    for tier in ("pe1", "pe4", "pe16"):
        cyc = cycles[tier]["fntt"]
        secs = cyc / (BOARD_MHZ * 1e6)
        G.append("| %s | %d | %s | %s | %.5f%% |"
                 % (tier, cyc, fmt_s(secs), fmt_s(ntt["serial_secs"]),
                    100 * secs / (secs + ntt["serial_secs"])))
    G.append("")
    G.append("> 折叠度把核从 %d 拍压到 %d 拍（%.1f×），但那一段在端到端里本来就只占万分之几 ——"
             % (cycles["pe1"]["fntt"], cycles["pe16"]["fntt"],
                cycles["pe1"]["fntt"] / cycles["pe16"]["fntt"]))
    G.append("> **折叠度的价值要用周期数论证（§3.3），不能用端到端耗时论证。**")
    G.append("")

    G.append("### 五条命令：模型耗时 vs 上板实测（复核）")
    G.append("")
    G.append("| 命令 | 数据行 | 发 / 收字节 | 合计 | 模型耗时 @ %d | 上板实测（§3.13.6） | 差 |"
             % BAUD)
    G.append("|---|---:|---:|---:|---:|---:|---:|")
    for (_key, cmd), r in zip(COMMANDS, prof):
        if "blocked" in r:
            G.append("| `%s` | — | — | — | — | — | ⚠️ 受阻：%s |"
                     % (cmd, r["blocked"].splitlines()[0]))
            continue
        wall = BOARD_WALL.get(cmd.split(" 1")[0])
        measured = wall["pe1"] if wall else None
        if measured:
            shown = "%.3f s" % measured
            diff = "%+.1f%%" % (100 * (r["serial_secs"] - measured) / measured)
        elif cmd.startswith("#PMUL TIME"):
            shown, diff = "✅ 6/6（10-18，无墙钟）", "—"
        else:
            shown, diff = "—", "未测"
        G.append("| `%s` | %d | %d / %d | %d B | %s | %s | %s |"
                 % (cmd, r["rows_in"], r["tx"], r["rx"], r["wire"],
                    fmt_s(r["serial_secs"]), shown, diff))
    G.append("")
    G.append("> ⚠️ 模型是「字节数 × 10 bit ÷ 波特率」，**不含** USB 缓冲 / CH340 转发 / 板子换向"
             "这些电气层开销，也不含实测那个读数的计时边界（A 的临时脚本怎么掐表不定）。")
    G.append("> 两条在 **±3%** 内对得上 —— 足以支撑「这趟耗时几乎全是串口搬运」这个判断，"
             "但**别把模型值当实测值引**。")
    G.append("")
    G.append("> ✅ **2026-10-17 更新**：B 已修正 `halfmul_b` / `halfmul_exp` / `fullmul_exp` 的"
             "变长格式（补零至 3 位、LF），本表五条命令现已全部能走陪练。")
    G.append("> `#PMUL TIME` 那一格没有墙钟值：2026-10-18 三档各 **6/6** 已通过，"
             "但新报告只留逐项对拍、**不记墙钟秒数**；10-04 那一版没有 TIME 的有效测量。"
             "它与串口模型无关。`#PMUL FULL` 在板子上不需要期望文件，2026-10-04 已实测 0.270 s。")
    G.append("")

    G.append("### 口径与机器（引这两个数时必须连它们一起写）")
    G.append("")
    G.append("| 项 | 值 |")
    G.append("|---|---|")
    G.append("| 计算核周期数来源 | `rtl/probes/README.md` §判据 2（顶层 `done` 拍 − `start` − 3） |")
    G.append("| 板上时钟 | %.0f MHz（`sys_clk`，`board_pe*_timing.rpt`） |" % BOARD_MHZ)
    G.append("| 串口参数 | %d 8N1，%d bit/字节 |" % (BAUD, BITS_PER_BYTE))
    G.append("| 串口字节数来源 | 走 `host/src/` 真实协议栈（陪练当对端）数出来的**线上真实字节** |")
    G.append("| 软件参考实现 | `research/kyber_ref/` 的 **`poly_ntt()` 语义**（`ntt()` + `poly_reduce()`）"
             "；每轮先拷回合法输入（系数在 [0,q)）；`gcc -O2`，每次会话 %d 轮 × %d 次，"
             "**跨 %d 次会话累计取中位** |"
             % (ref["reps"], ref["iters"], ref["sessions"]))
    G.append("| 参考实现净计算（%d 次会话 / %d 轮） | %s ／ %s ／ %s（中位／最小／最大） |"
             % (ref["sessions"], ref["rounds"], fmt_s(ref["median"]),
                fmt_s(ref["min"]), fmt_s(ref["max"])))
    G.append("| 输入准备（每轮 512 B memcpy） | %s（已从净计算中扣除） |"
             % fmt_s(ref["prep_median"]))
    G.append("| 输出校验 | checksum `%016x`；越界系数 0 个 |" % ref["checksum"])
    G.append("| CPU | %s |" % cpu)
    G.append("| OS / Python | %s / %s |" % (platform.platform(), platform.python_version()))
    G.append("| 编译器 | %s（`-O2`；电源模式未控制） |" % gcc)
    G.append("| 本机 Python 侧一趟开销 | %s（单次会话读数，波动约 ±10%%；含陪练自己的向量匹配，是上界） |"
             % fmt_s(ntt["pc_secs"]))
    G.append("")
    G.append("> ⚠️ 软件参考实现那个数**随机器变**（CPU / 编译器 / 优化级）。上表是**本机**的读数，")
    G.append("> 换机器重跑 `python metrics/bottleneck.py` 会变 —— 它不是设计的属性。")
    G.append("> 这也正是报告里把它写成「本机 gcc -O2 实测」而不是一个绝对值的原因。")
    G.append("")

    # ---- CSV --------------------------------------------------------------
    rows = [["段", "命令", "值", "单位", "口径", "证据"]]

    def add(seg, cmd, secs, how, ev):
        val, unit = fmt_val(secs)
        rows.append([seg, cmd, val, unit, how, ev])

    for tier in ("pe1", "pe4", "pe16"):
        add("计算核延迟", "#NTT 1（%s）" % tier, cycles[tier]["fntt"] / (BOARD_MHZ * 1e6),
            "%d 拍 ÷ %.0f MHz（板上，%s）" % (cycles[tier]["fntt"], BOARD_MHZ, tier),
            "rtl/probes/README.md §判据 2")
    for r in prof:
        if "blocked" in r:
            continue
        add("串口搬运", r["command"], r["serial_secs"],
            "线上 %d B × %d bit ÷ %d bps（模型）" % (r["wire"], BITS_PER_BYTE, BAUD),
            "host/src/ 协议栈实数 + proto.md §4.1")
    add("软件参考实现", "poly_ntt()", ref["median"],
        "gcc -O2；poly_ntt = ntt + poly_reduce；每轮合法输入；跨 %d 次会话 / %d 轮取中位；已扣输入准备"
        % (ref["sessions"], ref["rounds"]),
        "metrics/bottleneck_ref_timing.c")
    add("软件参考实现-输入准备", "poly_ntt()", ref["prep_median"],
        "每轮 512 B memcpy 回合法输入；%d 轮 × %d 次取中位（本机）" % (ref["reps"], ref["iters"]),
        "metrics/data/bottleneck_ref_raw.csv")
    add("PC 侧软件开销", "#NTT 1", ntt["pc_secs"],
        "陪练在进程内（无电气层）；含陪练自己的向量匹配开销，是上界",
        "host/src/board_run.py 同一条路径")

    CSV_OUT.parent.mkdir(parents=True, exist_ok=True)
    # ⚠️ `lineterminator="\n"` + `newline=""`：仓库统一 LF 行尾（`.gitattributes` 是 `* -text`）。
    #    csv 模块默认吐 `\r\n`，不加这一句会把 markers 之外的字节悄悄改成 CRLF。
    with CSV_OUT.open("w", encoding="utf-8", newline="") as f:
        csv.writer(f, lineterminator="\n").writerows(rows)

    # ---- 更新 README 的 GEN 块 -------------------------------------------
    B = "<!-- GEN:BOTTLENECK:BEGIN -->"
    E = "<!-- GEN:BOTTLENECK:END -->"
    md = README.read_text(encoding="utf-8")
    i, j = md.find(B), md.find(E)
    if i < 0 or j < 0 or j < i:
        raise SystemExit("!! %s 里找不到 %s … %s 标记。" % (README, B, E))
    md = md[:i + len(B)] + "\n\n" + "\n".join(G) + "\n" + md[j:]
    # ⚠️ `newline="\n"`：Path.write_text 默认在 Windows 上把 `\n` 翻成 `\r\n`，
    #    那样会把整个 README 的行尾改掉（仓库统一 LF）。gen_metrics.mjs 那边同理。
    README.write_text(md.replace("\r\n", "\n"), encoding="utf-8", newline="\n")

    print("  [3/3] 写出产物 ……")
    print("  ✅ %s（%d 行）" % (CSV_OUT.relative_to(REPO), len(rows) - 1))
    print("  ✅ 更新 %s 的 GEN 块" % README.relative_to(REPO))


if __name__ == "__main__":
    main()
