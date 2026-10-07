#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 board_pe<N>_timing.rpt 抽出关键路径，生成 critical_paths.md。

为什么要有这个脚本：H4 欠 C 的「关键路径素材」。手抄三份报告里的数字容易抄错、
且报告一重跑就对不上。这里把 .rpt 当**唯一真相**，文档是派生物 —— 报告换了
重跑一遍即可，不需要人工核。

用法（在 rtl/vivado/ 下，或从别处跑都行）：
    python gen_critical_paths.py

输出：同目录 critical_paths.md（LF 行尾 —— CLAUDE.md 约定 1）。
⚠️ 只读 reports/ 下的 .rpt，不碰 Vivado 工程；**不需要板子、不需要开 Vivado**。
"""
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPORTS = HERE / "reports"
OUT = HERE / "critical_paths.md"
PES = (1, 4, 16)

# ----------------------------------------------------------------- 解析
# 一份 report_timing_summary 里有两组路径组：
#   · sys_clk        —— 真正的时序关键路径（Design Timing Summary 的 WNS 就取自它）
#   · **async_default** —— 复位的 recovery / removal（异步控制端）
# 两组各有 Max / Min 两节。关键路径要的是第一组的 Max 那节。
SLACK_RE = re.compile(r"^Slack \((MET|VIOLATED)\)\s*:\s*([\d.]+)ns", re.M)
# 明细表的三条分隔线，依次收「源时钟路径 / 数据路径 / 目的时钟路径」。
SEP_RE = re.compile(r"^\s*-{10,}")
NET_RE = re.compile(r"^\(fo=(\d+)(?:,\s*routed)?\)$")
# 时序单元（触发器 / 锁存器 / 块 RAM / 移位寄存器）—— 它们**不算**「一级逻辑」。
# 判 `Logic Levels` 那栏时用来排除，见 main() 里锚 2 的说明。
SEQ_RE = re.compile(r"^(?:FD|LD|RAMB|SRL)")


def design_summary(path):
    """`Design Timing Summary` 那行的 (WNS, WHS) —— **全设计最坏**那条。

    ⚠️ **2026-10-07 订正：这一行不恒等于时钟级 WNS。** 它是全设计最坏；板级三档
    时序全 MET 时，最坏的那条可能落在 `**async_default**` 组（复位同步器 → 异步
    控制端的 recovery），那时它比时钟组更**差**。

      · 10-05 那版位流：async_default 是 8.338，比时钟组 6.538 **好**
        ⇒ 这一行**碰巧**就是时钟级 WNS —— 旧锚（拿它锚「筛对组没有」）因此
        一直没露馅，直到 RTL 改了才暴露。
      · 10-07 加了 `#RDY` 重建后反过来：pe1 这一行给 **2.490**（async_default），
        而时钟组是 **7.339**。**同一个字段，含义变了，且不报错。**

    ⇒ 「筛对路径组了没有」要用 `intra_clock_summary()` 的**时钟级** WNS 来锚，
      不要用本函数。本函数留着给 1b 锚当「全设计最坏」那一侧用。
    """
    txt = path.read_text(encoding="utf-8", errors="replace")
    i = txt.find("Design Timing Summary")
    if i < 0:
        return None
    for ln in txt[i:].split("\n"):
        m = re.match(r"^\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)", ln)
        if m:
            return float(m.group(1)), float(m.group(5))
    return None


def intra_clock_summary(path, clock="sys_clk"):
    """`Intra Clock Table` 里 `clock` 那一行的 (WNS, WHS) —— **时钟级** WNS。

    这才是「`Path Group` 筛出来的 Setup 首条」应当相等的那个数，也是锚 1 用的数。
    表长这样（表头下先一行破折号，再是每个时钟一行）：

        Clock             WNS(ns)      TNS(ns)  ...      WHS(ns)      THS(ns)  ...
        -----             -------      -------  ...      -------      -------  ...
        sys_clk             7.339        0.000  ...        0.020        0.000  ...

    ⚠️ 同名的表还有 `Inter Clock Table`（首词 `From`）与 `Path Group Table`
       （首词 `Path Group`）—— 表头**首词是 `Clock`** 的只有这一张，按这个认。
    """
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for i, ln in enumerate(lines):
        if not re.match(r"^\s*Clock\s+WNS\(ns\)", ln):
            continue
        j = i + 1
        while j < len(lines) and lines[j].strip() and set(lines[j].strip()) <= set("-"):
            j += 1                       # 跳过破折号行
        while j < len(lines) and lines[j].strip():
            parts = lines[j].split()
            if parts and parts[0] == clock:
                try:
                    return float(parts[1]), float(parts[5])
                except (ValueError, IndexError):
                    return None
            j += 1
        return None
    return None


def field(block, pat, cast=str, default=None):
    m = re.search(pat, block)
    return cast(m.group(1)) if m else default


def parse_report(path):
    """返回 (报告头信息 dict, [路径 dict, ...])，按报告里的先后顺序。"""
    txt = path.read_text(encoding="utf-8", errors="replace")
    starts = [m.start() for m in SLACK_RE.finditer(txt)]
    blocks = [txt[a:b] for a, b in zip(starts, starts[1:] + [len(txt)])]

    paths = []
    for b in blocks:
        d = dict(
            slack=field(b, r"Slack \((?:MET|VIOLATED)\)\s*:\s*([\d.]+)ns", float),
            status=field(b, r"Slack \((MET|VIOLATED)\)"),
            src=field(b, r"Source:\s+(\S+)"),
            dst=field(b, r"Destination:\s+(\S+)"),
            group=field(b, r"Path Group:\s+(\S+)"),
            ptype=field(b, r"Path Type:\s+(\S+)"),
            req=field(b, r"Requirement:\s+([\d.]+)ns", float),
            delay=field(b, r"Data Path Delay:\s+([\d.]+)ns", float),
            logic=field(b, r"logic ([\d.]+)ns \(([\d.]+)%\)", float),
            route=field(b, r"route ([\d.]+)ns \(([\d.]+)%\)", float),
            lvl=field(b, r"Logic Levels:\s+(\d+)", int),
            lvlbrk=field(b, r"Logic Levels:\s+\d+\s+\(([^)]*)\)", default=""),
        )
        m = re.search(r"route [\d.]+ns \(([\d.]+)%\)", b)
        d["route_pct"] = float(m.group(1)) if m else None
        m = re.search(r"logic [\d.]+ns \(([\d.]+)%\)", b)
        d["logic_pct"] = float(m.group(1)) if m else None
        # 明细行：<位置> <类型> <增量> <累计> [r|f] <资源>
        # 只在**数据路径**那一段里取。段的边界是三条分隔线：
        #   第 1 条收「源时钟路径」（时钟树 → 起点 FF 的 C 端）
        #   第 2 条收**数据路径**（起点 FF 的 Q → … → 终点 FF 的 D）—— 要的就是这段
        #   第 3 条收「目的时钟路径」（+ pessimism/uncertainty/setup）
        # 不切段的话时钟树那几行也会进来，其中 `(clock sys_clk rise edge)` 行还会被
        # 拆成 loc="(clock" / kind="sys_clk rise edge"，表就花了。
        lines = b.split("\n")
        seps = [i for i, l in enumerate(lines) if SEP_RE.match(l)]
        detail = lines[seps[1] + 1:seps[2]] if len(seps) >= 3 else []
        rows = []
        for ln in detail:
            m = re.match(r"^\s{2,}(\S*)\s+(\S.*?)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)"
                         r"(?:\s+[rf])?\s+(\S+)\s*$", ln)
            if not m:
                continue
            loc, kind, incr, cum, res = m.groups()
            # 走线行没有位置列，`net` 落进了 loc，扇出号落进了 kind
            is_net = loc == "net"
            nf = NET_RE.match(kind) if is_net else None
            rows.append(dict(loc=loc, kind=kind, incr=float(incr),
                             cum=float(cum), res=res, net=is_net,
                             fo=int(nf.group(1)) if nf else None))
        d["rows"] = rows
        paths.append(d)
    return paths


def short(cell):
    """把 `u_fsm/tx_len_reg[6]/D` 剥成 `u_fsm/tx_len_reg[6]`（端点方向由列名表达）。

    时钟端 `/C`、使能端 `/CE`、异步端 `/CLR` `/PRE` 一并剥掉 —— 否则终点列会出现
    `r_echo_reg[314]/CE`，读起来像「路径终点是使能口」，而它其实还是那个寄存器。
    """
    return re.sub(r"/(?:D|C|CE|CLR|PRE|RAMA/WADR\d+)$", "", cell or "")


# ----------------------------------------------------------------- 生成
def main():
    missing = [p for p in PES if not (REPORTS / f"board_pe{p}_timing.rpt").exists()]
    if missing:
        print("缺报告：", missing, file=sys.stderr)
        return 1

    data = {}
    for pe in PES:
        rpt = REPORTS / f"board_pe{pe}_timing.rpt"
        allp = parse_report(rpt)
        # 只取 sys_clk 组的 Setup（= 真正的 WNS 那一组）
        setup = [d for d in allp if d["group"] == "sys_clk"
                 and (d["ptype"] or "").startswith("Setup")]
        asyncs = [d for d in allp if d["group"] == "**async_default**"]
        if not setup:
            print(f"pe{pe}: 报告里没有 sys_clk 组的 Setup 路径 —— 停", file=sys.stderr)
            return 1
        # 锚 1：筛出来的那条 = **该时钟组**的 WNS（时钟级，取自 Intra Clock Table）
        #   ⚠️ 别拿 `Design Timing Summary` 的 WNS 来锚这一条 —— 那是全设计最坏，
        #      2026-10-07 起它落在 async_default 组上，会把对的路径判成错的。
        #      详见上面 design_summary() 的说明。
        clk = intra_clock_summary(rpt)
        if not clk:
            print(f"pe{pe}: 读不到 Intra Clock Table 里 sys_clk 那一行 —— 停",
                  file=sys.stderr)
            return 1
        cwns, cwhs = clk
        if abs(setup[0]["slack"] - cwns) > 1e-6:
            print(f"pe{pe}: 筛出的 slack {setup[0]['slack']:.3f} ≠ Intra Clock Table "
                  f"里 sys_clk 的 WNS {cwns:.3f} —— 筛错组了，停", file=sys.stderr)
            return 1
        # 锚 1b：全设计最坏 = 已知两组里更差的那个 —— 但**必须按检查族分开比**。
        #   ⚠️ 2026-10-07 撞见：`**async_default**` 这一个组里混着**两种**检查，
        #      `Recovery`（异步控制端的建立检查，Setup 族，进 WNS）与
        #      `Removal`（属 Hold 族，进 WHS）。pe1 实测：组内 Recovery 最坏
        #      2.490、Removal 最坏 1.700 —— 若把 20 条一锅端取 min，会拿 1.700
        #      去比 `Design Timing Summary` 的 WNS 2.490，**把对的数判成错的**
        #      （这正是本锚自己第一次跑时就哑掉的原因）。
        #   ⇒ Recovery 只跟 WNS 比、Removal 只跟 WHS 比；两族相加必须等于该组
        #      全部条数，冒出第三种类型就是本脚本没认出来的检查，停。
        summ = design_summary(rpt)
        if not summ:
            print(f"pe{pe}: 读不到 Design Timing Summary —— 停", file=sys.stderr)
            return 1
        wns, whs = summ
        fam = {"Setup": [], "Hold": []}
        for a in asyncs:
            t = a["ptype"] or ""
            if t.startswith("Recovery"):
                fam["Setup"].append(a)
            elif t.startswith("Removal"):
                fam["Hold"].append(a)
            else:
                print(f"pe{pe}: async 组里出现没认出来的检查类型 {t!r} "
                      f"（slack {a['slack']:.3f}）—— 停", file=sys.stderr)
                return 1
        for name, key, clk_v, rep_v in (("WNS", "Setup", cwns, wns),
                                        ("WHS", "Hold", cwhs, whs)):
            pool = [clk_v] + [d["slack"] for d in fam[key]]
            if abs(rep_v - min(pool)) > 1e-6:
                detail = "、".join(f"{n:.3f}" for n in pool)
                print(f"pe{pe}: Design Timing Summary 的 {name} {rep_v:.3f} ≠ "
                      f"sys_clk 组与 async/{key} 族里更差的那个 {min(pool):.3f}"
                      f"（{detail}）—— 报告里有本脚本没认出来的路径组/检查，停",
                      file=sys.stderr)
                return 1
        # 锚 2：明细里「逻辑级」的条数 = 报告自报的逻辑级数
        #   ⚠️ 2026-10-07 撞见：**不能只数 `LUT*`**。pe4 那条关键路径中间有一级
        #      `MUXF7`（专用多路器）—— 它**算一级逻辑但不叫 LUT**，只数 LUT 得
        #      14、报告写 15，把解析完全正确的数据判成「没解析全」。
        #      ⇒ 口径取「非走线、且非时序单元（见 SEQ_RE）」。三档现数据：
        #        pe1 11 LUT = 11；pe4 14 LUT + 1 MUXF7 = 15；pe16 12 LUT = 12。
        lv = [r for r in setup[0]["rows"]
              if not r["net"] and not SEQ_RE.match(r["kind"])]
        if len(lv) != setup[0]["lvl"]:
            kinds = "、".join(sorted({r["kind"].split()[0] for r in lv}))
            print(f"pe{pe}: 明细里数出 {len(lv)} 级逻辑（{kinds}），"
                  f"报告写 {setup[0]['lvl']} 级 —— 明细行没解析全，停",
                  file=sys.stderr)
            return 1
        # 锚 3：明细逐行相加 = 报告自报的数据路径延迟（0.02 留给三处三位小数的舍入）
        got, want = sum(r["incr"] for r in setup[0]["rows"]), setup[0]["delay"]
        if abs(got - want) > 0.02:
            print(f"pe{pe}: 明细逐行相加 {got:.3f} ≠ Data Path Delay {want:.3f} "
                  f"—— 明细行有漏读或多读，停", file=sys.stderr)
            return 1
        # wns/whs = 全设计最坏（可能落在 async_default）；cwns/cwhs = 时钟级。
        # wns/whs = 全设计最坏（可能落在 async_default）；cwns/cwhs = 时钟级；
        # fam = async 组按检查族拆开（Setup 族=Recovery、Hold 族=Removal）。
        data[pe] = dict(setup=setup, asyncs=asyncs, all=allp, fam=fam,
                        wns=wns, whs=whs, cwns=cwns, cwhs=cwhs)

    L = []
    A = L.append
    A("# 关键路径（板级三档）—— 从 Vivado 报告机械抽取")
    A("")
    A("> **本文件是派生物，不是手写的。** 由 `python gen_critical_paths.py` 从")
    A("> `reports/board_pe{1,4,16}_timing.rpt` 抽取生成 —— 报告重跑后重跑本脚本即可，")
    A("> 不要直接编辑本文。")
    A("")
    A("对应 H4：C 要的「关键路径素材」。⚠️ **本文是数据，不是截图** ——")
    A("Vivado GUI 里那张 Schematic 图要人在机器前开 GUI 才截得到，本文替代不了它；")
    A("但报告里能引用的一切数字都在这里，且可复跑。")
    A("")
    A("## 一、判据与口径")
    A("")
    A("`report_timing_summary -max_paths 10` 的输出里路径分**两组**，先分清再读数：")
    A("")
    A("| 组 | `Path Group` | 是什么 | 报告里的节 |")
    A("|---|---|---|---|")
    A("| 1 | `sys_clk` | 真正的时序关键路径；**「时钟级 WNS」指的就是这一组的**"
      "（取自 `Intra Clock Table` 里 `sys_clk` 那一行） | `Max Delay Paths`（前） / `Min Delay Paths`（前） |")
    A("| 2 | `**async_default**` | 复位同步器到异步控制端的 recovery / removal "
      "| 后面那两组同名节 |")
    A("")
    A("⚠️ **两组的 `Max Delay Paths` 都叫这个名字** —— 只按节名找会拿到第二组，")
    A(f"而第二组的 slack（pe1 的 recovery 最坏一条是 "
      f"{min(d['slack'] for d in data[1]['fam']['Setup']):.3f} ns）**不是时钟级 WNS**。")
    A("本文按 `Path Group` 字段筛，不按节名；筛完拿 `Intra Clock Table` 里 `sys_clk`")
    A("那一行对一遍（见 §六），对不上直接报错、不出文档。")
    A("")
    A("⚠️⚠️ **`Design Timing Summary` 的 WNS 从 2026-10-07 起也不再等于时钟级 WNS 了。**")
    A("它给的是**全设计最坏**：板级三档时序全 MET 时，最坏那条可能落在")
    A("`**async_default**` 组（复位同步器的 recovery），而不是时钟组。")
    A("10-05 那版位流里 async 是 8.338、比时钟组 6.538 **好**，两个数**碰巧相等**，")
    A("所以拿它当锚一直没露馅；10-07 加了 `#RDY` 重建后反过来 —— pe1 那一行给 "
      f"{data[1]['wns']:.3f}，时钟组却是 {data[1]['cwns']:.3f}。")
    A("**同一个字段，含义变了，且不报错。**（`rtl/vivado/synth_board.tcl` 里同源的那条")
    A("2026-10-07 已拆成 `WNS_WORST_ANY_NS` / `WNS_CLOCK_NS` 两行；§六 的 1b 锚是它的机器版。）")
    A("")
    A("⚠️ **而且这个坑是逐档的、不是「三档都错」** —— 同一批重建里：")
    A(f"pe1 全设计最坏 {data[1]['wns']:.3f} / 时钟级 {data[1]['cwns']:.3f}（不等）、"
      f"pe4 {data[4]['wns']:.3f} / {data[4]['cwns']:.3f}（不等）、")
    A(f"pe16 {data[16]['wns']:.3f} / {data[16]['cwns']:.3f}（**相等**）。")
    A("pe16 恰好落在「相等」那一侧，所以只看 pe16 是看不出问题的 —— 这也是为什么")
    A("§六 的锚要在**三档上逐档跑**，不能挑一档抽样。")
    A("")
    A("⚠️ 另有一处同源口径要记住：`**async_default**` **这一个组里混着两种检查** ——")
    A("`Recovery`（异步控制端的建立检查，进 **WNS**）与 `Removal`（进 **WHS**）。")
    A(f"pe1 组内：Recovery 最坏 "
      f"{min(d['slack'] for d in data[1]['fam']['Setup']):.3f}、Removal 最坏 "
      f"{min(d['slack'] for d in data[1]['fam']['Hold']):.3f}。")
    A("**取最坏时必须按族分开** —— 一锅端会把 Removal 的数当成 WNS 用。")
    A("")
    A("另一条同类的坑（`project_state.md` §二 已记）：**板级 WNS 不能反推 Fmax** ——")
    A("20 ns 目标是故意放松的，布线器没被逼；核的 Fmax 推算在 `folding_comparison.md` §9.1，")
    A("那是**另一个边界 + 另一个约束**，别把两个数放一格里比。")
    A("")
    A("## 二、三档 WNS 与关键路径（`sys_clk` 组，Setup）")
    A("")
    A("| 档 | WNS (ns) | 数据路径 (ns) | 其中逻辑 / 布线 | 逻辑级数 | 起点 → 终点 |")
    A("|---|---|---|---|---|---|")
    for pe in PES:
        p = data[pe]["setup"][0]
        A(f"| pe{pe} | **+{p['slack']:.3f}** | {p['delay']:.3f} "
          f"| {p['logic']:.3f} ({p['logic_pct']:.1f}%) / {p['route']:.3f} ({p['route_pct']:.1f}%) "
          f"| {p['lvl']} | `{short(p['src'])}` → `{short(p['dst'])}` |")
    A("")
    A("⚠️ **三档的关键路径都不在蝶形里。** 起点都在 `u_line`（行组装）这一侧，")
    A("终点都在 `u_fsm` 的宽寄存器使能译码上 —— 也就是说，**卡时序的是协议状态机那一层，")
    A("不是 NTT 核**。这条对「折叠度是否值得做」是个旁证：收紧时钟时先动的是状态机，")
    A("不是蝶形阵列。")
    A("")
    A("## 三、三档各自的前 10 条（`sys_clk` 组，Setup）")
    A("")
    for pe in PES:
        rows = data[pe]["setup"]
        A(f"### pe{pe}")
        A("")
        A("| # | Slack (ns) | 数据路径 (ns) | 逻辑级数 | 起点 → 终点 |")
        A("|---|---|---|---|---|")
        for i, p in enumerate(rows, 1):
            A(f"| {i} | {p['slack']:.3f} | {p['delay']:.3f} | {p['lvl']} "
              f"| `{short(p['src'])}` → `{short(p['dst'])}` |")
        A("")
        if len(rows) < 10:
            A(f"（报告里 `sys_clk` 组的 Setup 段只给了 {len(rows)} 条，不是 10 条 —— "
              f"`-max_paths 10` 是**上限**，报告按各路径组分别截断。）")
            A("")

    p = data[1]["setup"][0]
    nets = [r for r in p["rows"] if r["net"]]
    luts = [r for r in p["rows"] if r["kind"].startswith("LUT")]
    hop = max(nets, key=lambda r: r["incr"])
    avg_lut = sum(r["incr"] for r in luts) / len(luts)
    avg_net = sum(r["incr"] for r in nets) / len(nets)

    A(f"## 四、pe1 最坏那条的完整网表（{p['lvl']} 级逻辑）")
    A("")
    A(f"`{short(p['src'])}` → `{short(p['dst'])}`，slack **+{p['slack']:.3f} ns**，")
    A(f"数据路径 {p['delay']:.3f} ns，逻辑级数 {p['lvl']}（{p['lvlbrk']}）。")
    A("")
    A("下表是报告里**数据路径那一段**逐行照抄 —— 源时钟路径、目的时钟路径两段已切掉")
    A("（它们不是数据路径）。走线单列成 `net` 行：布线在这张表里是**显式的**，")
    A("和逻辑各占一行，谁也不折进谁。")
    A("")
    A("| # | 位置 | 类型 | 增量 (ns) | 累计 (ns) | 资源 |")
    A("|---|---|---|---|---|---|")
    for i, r in enumerate(p["rows"], 1):
        if r["net"]:
            A(f"| {i} | — | net (fo={r['fo']}, routed) | {r['incr']:.3f} "
              f"| {r['cum']:.3f} | `{r['res']}` |")
        else:
            A(f"| {i} | {r['loc']} | {r['kind']} | {r['incr']:.3f} "
              f"| {r['cum']:.3f} | `{r['res']}` |")
    A("")
    q_launch = sum(r["incr"] for r in p["rows"] if not r["net"]) - sum(
        r["incr"] for r in luts)
    A(f"读法：第 1 行是起点 FF 的 clk-to-Q，之后每「一跳 LUT + 一跳走线」成对出现，"
      f"第 {len(p['rows'])} 行（终点 FF 的 D 端之前那跳走线）收尾。")
    A("")
    A(f"⚠️ 这条路的**布线占 {p['route_pct']:.1f}%**、逻辑只占 {p['logic_pct']:.1f}%：")
    A(f"{len(nets)} 跳走线合计 {sum(r['incr'] for r in nets):.3f} ns，"
      f"{len(luts)} 个 LUT 合计 {sum(r['incr'] for r in luts):.3f} ns，"
      f"再加起点 FF 的 clk-to-Q {q_launch:.3f} ns")
    A(f"—— 三项相加正是 `Data Path Delay` 的 {p['delay']:.3f} ns"
      f"（⚠️ Vivado 把**起点 FF 也算进「逻辑」**里，所以 12 个 LUT 的和比 `logic` 那栏小）。")
    A(f"平摊下来一个 LUT {avg_lut:.3f} ns、一跳走线 {avg_net:.3f} ns"
      f"（**{avg_net / avg_lut:.1f} 倍**）—— 所以优化该往「压扇出」走。")
    A("")
    A(f"根因是控制信号的高扇出：起点 `{short(p['src'])}/Q` 一条网线扇出 "
      f"{nets[0]['fo']}；")
    A(f"单跳最贵的是 `{hop['res']}`，扇出 {hop['fo']}、一跳 {hop['incr']:.3f} ns —— "
      f"比任何一个 LUT 都慢一个量级。")
    A("")
    A("## 五、`**async_default**` 组（复位的 recovery / removal）")
    A("")
    A("⚠️ **这一个组里混着两种检查，必须分开看** —— `Recovery` 属 Setup 族、进 **WNS**；")
    A("`Removal` 属 Hold 族、进 **WHS**。下面的表按族分两列，别把两列放一起比大小。")
    A("")
    A("| 档 | Recovery 最坏 (ns) → 进 WNS | Removal 最坏 (ns) → 进 WHS | 起点 → 终点 |")
    A("|---|---|---|---|")
    for pe in PES:
        a = data[pe]["asyncs"]
        if not a:
            A(f"| pe{pe} | — | — | （报告里没给这一组） |")
            continue
        rec = min(data[pe]["fam"]["Setup"], key=lambda d: d["slack"])
        rem = min(data[pe]["fam"]["Hold"], key=lambda d: d["slack"])
        A(f"| pe{pe} | {rec['slack']:.3f} | {rem['slack']:.3f} "
          f"| `{short(rec['src'])}` → `{short(rec['dst'])}` |")
    A("")
    A("三档这一组的起点都是 `rst_sync_reg[1]/C` —— 就是 `ntt_board_top.v` 里那级")
    A("「异步置位、同步释放」复位同步器（比例程多这一步，拦按键毛刺）。终点分两类：")
    A("pe1 / pe4 落在 **NTT 核内部**（`u_core/.../btfu/w5r0_reg`），pe16 落在 `u_fsm`。")
    A("原因直白 —— 复位网的扇出：核内 `w5r0` 那一排寄存器离 `rst_sync_reg[1]` 的布线更远。")
    A("⚠️ **这仍然不是「核有时序问题」**：recovery 量的是「异步复位释放沿离时钟沿够不够远」，")
    A("与核的组合逻辑深度无关 —— 别把它读成 §二 那条「卡时序的不是蝶形」的反例。")
    A("")
    A("⚠️ **2026-10-07 起，Recovery 那一列就是「全设计最坏」的所在地**（见 §一 那段）。")
    A("注意它的性质：这条路径**不 gate 时钟** —— recovery 检查的是「异步控制端别在")
    A("时钟沿附近动」，它 slack 小**不等于** 50 MHz 跑不动。`Design Timing Summary`")
    A("的 WNS 现在被它占着，所以**别拿那一格反推板级余量**，要用 §二 的时钟级数。")
    A("")
    A("## 六、怎么复跑")
    A("")
    A("```sh")
    A("cd rtl/vivado && python gen_critical_paths.py      # 只读 reports/*.rpt，不碰 Vivado")
    A("```")
    A("")
    A("报告本身怎么来的：`sh rtl/vivado/run_board_synth.sh`（需 Vivado，**不需要板子**）。")
    A("⚠️ 从**仓库外目录**启动 Vivado —— 仓库路径含撇号会把综合引擎咬死。")
    A("")
    A("脚本出文档前会自己锚四道，任一道对不上就报错退出、不生成文件：")
    A("")
    A("1. 筛出来的那条路径的 slack，等于同份报告 `Intra Clock Table` 里 `sys_clk`")
    A("   那一行的 WNS（**时钟级**）—— 防「按节名筛、筛到 `**async_default**` 那组」")
    A("   （§一 那个坑）。")
    A("1b. `Design Timing Summary` 的 **WNS** ＝ `sys_clk` 组与 `**async_default**` 组里的")
    A("   **Recovery** 里更差的那个；**WHS** 同理，对 `**async_default**` 组的")
    A("   **Removal** —— 防报告里出现本脚本没认出来的第三组路径 / 第三种检查。")
    A("   ⚠️ **这条 2026-10-07 才加**：它反过来暴露了旧的")
    A("   第 1 道锚本身在用错数（拿全设计最坏当时钟级 WNS 使，RTL 一改就误判）。")
    A("2. 明细里数出的**逻辑级**条数，等于报告自报的 `Logic Levels` —— 防明细行没解析全。")
    A("   ⚠️ 口径是「非走线、且非时序单元（`FD*`/`LD*`/`RAMB*`/`SRL*`）」，**不是只数**")
    A("   `LUT*`**：pe4 那条路径中间有一级 `MUXF7`（专用多路器），它算一级逻辑但不叫 LUT。")
    A("3. 明细逐行延迟相加，等于报告自报的 `Data Path Delay` —— 防漏读或多读行。")
    A("")
    A("这四道锚本身也有人验：**`python check_critical_paths_anchors.py`** 把每道锚本该")
    A("拦住的失败人造出来（按节名筛、把 async 两族混着取最坏、只数 LUT、丢一行 net），")
    A("看它响不响；")
    A("顺带拿报告自己的 `route` / `logic` 两栏当**独立旁证** —— 那两栏是 Vivado 算的，")
    A("与我们怎么切段无关，对得上才说明数据路径那一段既没切多也没切少。")
    A("")
    A("⚠️ **锚 1b 和锚 2 的第一版都是错的，是这套阴性对照当场抓出来的**（2026-10-07）：")
    A("1b 把 async 组 20 条一锅端取 min，拿 Removal 的 1.700 去比 WNS 2.490；")
    A("2 只数 LUT，在 pe4 上得 14 而报告写 15。两道都**报假错**（把对的数判成错的）——")
    A("跟它们本来要防的「报假对」是一对。**没有阴性对照，这两条会一直错下去**，")
    A("因为三档里 pe1/pe16 恰好都能蒙对。")
    A("")

    OUT.write_bytes("\n".join(L).encode("utf-8"))   # "wb" = 保持 LF
    print(f"已生成 {OUT}（{len(L)} 行）")
    for pe in PES:
        p = data[pe]["setup"][0]
        rec = min(data[pe]["fam"]["Setup"], key=lambda d: d["slack"])
        rem = min(data[pe]["fam"]["Hold"], key=lambda d: d["slack"])
        extra = (f"，async 组 Recovery {rec['slack']:.3f} / Removal {rem['slack']:.3f}"
                 if data[pe]["asyncs"] else "，无 async 组")
        print(f"  pe{pe}: 时钟级 WNS +{p['slack']:.3f} ns"
              f"（全设计最坏 {data[pe]['wns']:.3f}{extra}）  "
              f"{short(p['src'])} -> {short(p['dst'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
