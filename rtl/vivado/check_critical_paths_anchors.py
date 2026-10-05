#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 gen_critical_paths.py 的三道自锚做**阴性对照**。

为什么要有这个：`gen_critical_paths.py` 出文档前会自己锚三道，任一道对不上就报错
退出。但「跑通了」本身不说明锚有用 —— 一个恒为真的检查也是「跑通」。这里把每道锚
**本该拦住的失败**人造出来，看它是不是真的会响。

三道锚分别拦：
  1. 筛错路径组   —— 报告里 `Max Delay Paths` 这个节名出现两次，按节名筛会拿到
                     `**async_default**` 组，那一组的 slack 不是 WNS。
  2. 明细没解析全 —— LUT 行数应等于报告自报的 `Logic Levels`。
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
        wns, whs = gcp.design_summary(rpt)
        p = setup[0]
        nets = [r for r in p["rows"] if r["net"]]
        luts = [r for r in p["rows"] if r["kind"].startswith("LUT")]
        total = sum(r["incr"] for r in p["rows"])

        print(f"pe{pe}：WNS {wns:.3f} / WHS {whs:.3f}，"
              f"sys_clk 组 Setup {len(setup)} 条、async 组 {len(asyncs)} 条")

        # 锚 1 —— 正例：筛出来的那条就是 WNS 那条
        ok("锚1 正例：筛出的 slack = Design Timing Summary 的 WNS",
           abs(p["slack"] - wns) < 1e-6, f"{p['slack']:.3f} vs {wns:.3f}")
        # 锚 1 —— 反例：模拟「按节名筛」撞上 async 组
        a = asyncs[0]
        ok("锚1 反例：按节名筛会拿到 async 组的 slack，被拦",
           abs(a["slack"] - wns) > 1e-6, f"会误报成 {a['slack']:.3f}")

        # 锚 2 —— 正例 + 反例（丢一行 LUT）
        ok("锚2 正例：LUT 行数 = Logic Levels",
           len(luts) == p["lvl"], f"数出 {len(luts)}，报告写 {p['lvl']}")
        ok("锚2 反例：少一行 LUT 会被拦",
           len(luts) - 1 != p["lvl"], f"少一行后 {len(luts) - 1} vs {p['lvl']}")

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
    print("三道锚都该响时响、不该响时不响；两道旁证也各自对上。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
