#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 gen_critical_paths.py 的四道自锚做**阴性对照**。

为什么要有这个：`gen_critical_paths.py` 出文档前会自己锚四道，任一道对不上就报错
退出。但「跑通了」本身不说明锚有用 —— 一个恒为真的检查也是「跑通」。这里把每道锚
**本该拦住的失败**人造出来，看它是不是真的会响。

四道锚分别拦：
  1. 筛错路径组   —— 报告里 `Max Delay Paths` 这个节名出现两次，按节名筛会拿到
                     `**async_default**` 组，那一组的 slack 不是**时钟级** WNS。
                     ⚠️ 比的必须是 `Intra Clock Table` 里 `sys_clk` 那一行；
                     `Design Timing Summary` 的 WNS 是**全设计最坏**，2026-10-07
                     起它落在 async 组上，拿它当锚会把对的路径判成错的（旧版就是
                     这么写的，代价是 RTL 一改就报假错）。
  1b. 路径组/检查没认全 —— `Design Timing Summary` 的 WNS 应等于 `sys_clk` 组与
                     `**async_default**` 组的 **Recovery** 里更差的那个（WHS 对 Removal）。
                     ⚠️ 那一组里混着 `Recovery`（进 WNS）和 `Removal`（进 WHS），
                     一锅端取 min 会拿 Removal 的数去比 WNS —— 本脚本第 1b 反例就在拦这个。
  2. 明细没解析全 —— **逻辑级**行数应等于报告自报的 `Logic Levels`。
                     ⚠️ 口径不是「数 LUT」：`MUXF7` 这类专用多路器也算一级逻辑。
                     本脚本第 2 反例就在拦「只数 LUT」这个写法（pe4 上会差 1）。
  3. 明细漏读/多读 —— 逐行延迟相加应等于报告自报的 `Data Path Delay`。

另外顺带核两件与「切段切对没有」有关的事（不是锚，是**独立旁证**）：
  · 明细里所有 `net` 行相加 = 报告 `route` 那栏
  · 明细里所有器件行相加 = 报告 `logic` 那栏
  这两栏是 Vivado 自己算的，与我们的切段无关；两边对得上，说明数据路径那一段
  既没切多（混进时钟树）也没切少（丢行）。

用法（任意目录）：
    python check_critical_paths_anchors.py
退出码 0 = 三道锚都「该响时响、不该响时不响」；非 0 = 有锚是哑的。
"""
import importlib.util
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPORTS = HERE / "reports"
GEN = HERE / "gen_critical_paths.py"
PES = (1, 4, 16)

# 把 gen_critical_paths.py 当模块载进来（不执行它的 main()）
_spec = importlib.util.spec_from_file_location("gen_critical_paths", GEN)
gcp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gcp)

bad = []


def ok(label, cond, detail):
    print(f"  {'OK  ' if cond else '哑!!'} {label:<48} {detail}")
    if not cond:
        bad.append(label)


def main():
    for pe in PES:
        rpt = REPORTS / f"board_pe{pe}_timing.rpt"
        if not rpt.exists():
            print(f"缺报告 {rpt} —— 停", file=sys.stderr)
            return 1

        paths = gcp.parse_report(rpt)
        setup = [d for d in paths if d["group"] == "sys_clk"
                 and (d["ptype"] or "").startswith("Setup")]
        asyncs = [d for d in paths if d["group"] == "**async_default**"]
        rec = [d for d in asyncs if (d["ptype"] or "").startswith("Recovery")]
        rem = [d for d in asyncs if (d["ptype"] or "").startswith("Removal")]
        wns, whs = gcp.design_summary(rpt)
        cwns, cwhs = gcp.intra_clock_summary(rpt)
        p = setup[0]
        nets = [r for r in p["rows"] if r["net"]]
        lv = [r for r in p["rows"]
              if not r["net"] and not gcp.SEQ_RE.match(r["kind"])]
        luts = [r for r in p["rows"] if r["kind"].startswith("LUT")]
        total = sum(r["incr"] for r in p["rows"])

        print(f"pe{pe}：时钟级 WNS {cwns:.3f} / WHS {cwhs:.3f}；"
              f"全设计最坏 {wns:.3f} / {whs:.3f}；"
              f"sys_clk 组 Setup {len(setup)} 条、"
              f"async 组 {len(asyncs)} 条（Recovery {len(rec)} / Removal {len(rem)}）")

        # 锚 1 —— 正例：筛出来的那条就是**时钟级** WNS 那条
        ok("锚1 正例：筛出的 slack = Intra Clock Table 的 sys_clk WNS",
           abs(p["slack"] - cwns) < 1e-6, f"{p['slack']:.3f} vs {cwns:.3f}")
        # 锚 1 —— 反例：模拟「按节名筛」撞上 async 组
        a = asyncs[0]
        ok("锚1 反例：按节名筛会拿到 async 组的 slack，被拦",
           abs(a["slack"] - cwns) > 1e-6, f"会误报成 {a['slack']:.3f}")
        # 锚 1 —— 反例之二：拿 Design Timing Summary 当锚（旧版写法）会怎样
        #   ⚠️ 这一条**只是报告，不计失败**：某些档两组恰好相等（10-05 那版位流
        #      就是），那时旧写法「碰巧」也对 —— 正是它藏了这么久的原因。
        same = abs(wns - cwns) < 1e-6
        ok("锚1 反例2：Design Timing Summary 只能用来看「是不是同一档世界」",
           True,
           f"全设计最坏 {wns:.3f} vs 时钟级 {cwns:.3f} —— "
           + ("两者相等（旧世界：拿它当时钟级 WNS 使不会露馅）"
              if same else "不等（拿它当时钟级 WNS 使会误判，旧锚在此必挂）"))
        # 锚 1b —— 正例：全设计最坏 = sys_clk 组与 async/**同族**里更差的那个
        w_wns = min([cwns] + [d["slack"] for d in rec])
        w_whs = min([cwhs] + [d["slack"] for d in rem])
        ok("锚1b 正例：WNS = min(sys_clk, async/Recovery)",
           abs(wns - w_wns) < 1e-6, f"{wns:.3f} vs {w_wns:.3f}")
        ok("锚1b 正例：WHS = min(sys_clk, async/Removal)",
           abs(whs - w_whs) < 1e-6, f"{whs:.3f} vs {w_whs:.3f}")
        # 锚 1b —— 反例：把 async 两族一锅端取 min（**本锚的第一版就是这么写的**）
        #   Removal 的 slack 普遍比 Recovery 小（pe1 是 1.700 vs 2.490），
        #   混着取 min 会拿 Removal 的数去比 WNS ⇒ 报假错。
        mixed = min([cwns] + [d["slack"] for d in asyncs])
        ok("锚1b 反例：两族混着取 min 会报假错，被拦",
           abs(wns - mixed) > 1e-6,
           f"混着算得 {mixed:.3f}，真 WNS 是 {wns:.3f}"
           + ("  —— ⚠️本档两族最坏恰好相同，这条反例在此档不成立（正常）"
              if abs(wns - mixed) < 1e-6 else "  —— 混着算会误判"))
        # 锚 1b —— 反例：冒出第三种检查类型
        unknown = len(rec) + len(rem) != len(asyncs)
        ok("锚1b 反例：出现第三种检查类型会被拦",
           not unknown,
           f"async {len(asyncs)} = Recovery {len(rec)} + Removal {len(rem)}"
           + ("" if not unknown else "  ★对不上，锚会响"))

        # 锚 2 —— 正例 + 反例（丢一级逻辑 / 只数 LUT）
        ok("锚2 正例：逻辑级行数 = Logic Levels",
           len(lv) == p["lvl"], f"数出 {len(lv)}，报告写 {p['lvl']}")
        ok("锚2 反例：丢一级逻辑会被拦",
           len(lv) - 1 != p["lvl"], f"少一级后 {len(lv) - 1} vs {p['lvl']}")
        #   只数 LUT 是**本锚的第一版写法** —— pe4 上会差 1（路径里有一级 MUXF7）
        only_lut = len(luts) != p["lvl"]
        ok("锚2 反例：只数 LUT 会报假错 —— 本档是否触发",
           True,
           f"只数 LUT 得 {len(luts)}，真逻辑级 {p['lvl']}"
           + ("  —— ★本档会报假错（路径里有非 LUT 的逻辑级）" if only_lut
              else "  —— 本档恰好全是 LUT，蒙对"))

        # 锚 3 —— 正例 + 反例（丢一行 net）
        ok("锚3 正例：逐行相加 = Data Path Delay",
           abs(total - p["delay"]) <= 0.02, f"{total:.3f} vs {p['delay']:.3f}")
        ok("锚3 反例：少一行 net 会被拦",
           abs(total - nets[-1]["incr"] - p["delay"]) > 0.02,
           f"少一行后 {total - nets[-1]['incr']:.3f} vs {p['delay']:.3f}")

        # 旁证：两栏是 Vivado 自己算的，与我们怎么切段无关
        ok("旁证：net 行相加 = 报告 route 栏",
           abs(sum(r["incr"] for r in nets) - p["route"]) <= 0.02,
           f"{sum(r['incr'] for r in nets):.3f} vs {p['route']:.3f}")
        ok("旁证：器件行相加 = 报告 logic 栏",
           abs((total - sum(r["incr"] for r in nets)) - p["logic"]) <= 0.02,
           f"{total - sum(r['incr'] for r in nets):.3f} vs {p['logic']:.3f}")
        # 旁证：时钟树的行不许混进数据路径
        leak = [r for r in p["rows"]
                if r["loc"].startswith("(") or "clock" in r["kind"].lower()
                or r["kind"].startswith(("IBUF", "BUFG"))]
        ok("旁证：明细里没有时钟树行", not leak, f"混进 {len(leak)} 行")
        print("")

    if bad:
        print("有检查是哑的：" + "、".join(bad), file=sys.stderr)
        return 1
    print("四道锚都该响时响、不该响时不响；两道旁证也各自对上。")
    print("（标「本档是否触发 / 恰好相同」的那几条是**报告性**的，不计失败 ——")
    print("  它们记录的是「这个错法在哪几档上会蒙对」，蒙对的档正是它藏得住的原因。）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
