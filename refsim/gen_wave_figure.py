#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
refsim/gen_wave_figure.py -- 生成 H5 的「对拍波形图」

输入：refsim/fntt_wave.vcd（由 pe1/fntt_wave_tb.v 仿真产生）
输出：report/figures/refsim_wave_fntt_compare.svg   矢量，本脚本直接画
      report/figures/refsim_wave_fntt_compare.png   GTKWave 真截图（同一窗口）

规矩（沿用 demo/gen_shots.mjs 的口径）：出图前先断言图名所声明的事实 ——
「读出窗口内 256 拍，每拍 RTL 输出 dout 与期望值 exp_now 逐位相同」。
断言不过就一张图都不写、非零退出。不靠目视。

放大窗口不是写死的，是从 VCD 里算出来的（done 脉冲前一拍起、取 200 ns），
两张图共用同一个窗口值，保证内容完全一致。

用法（从 refsim/ 目录）：
    python gen_wave_figure.py            # 断言 + 出两张图
    python gen_wave_figure.py --inspect  # 只打印 VCD 实况，不出图
    python gen_wave_figure.py --svg-only # 只出 SVG（本机没装 GTKWave 时）

本机控制台是 GBK，脚本会自己把 stdout 切到 UTF-8，否则中文输出是乱码（假红）。
"""

import bisect
import os
import re
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
VCD = os.path.join(HERE, "fntt_wave.vcd")
OUTDIR = os.path.join(REPO, "report", "figures")
STEM = "refsim_wave_fntt_compare"
TMP_TCL = os.path.join(HERE, "tmp_wave_grab.tcl")

# 图里从上到下的行序（不是 VCD 里的声明序）
ROWS = ["clk", "done", "read_a", "reading", "beat", "dout", "exp_now", "cmp_ok"]

# 色板沿用 report/figures/gen_figures.mjs 的墨色
INK, MUTED, AXIS = "#1f2933", "#6b7785", "#c3cbd4"
WAVE, MATCH, GRID = "#1f6fb2", "#2e7d32", "#e8edf2"

WINDOW_NS = 200  # 放大窗口宽度


# ----------------------------------------------------------------- VCD 解析

def parse_vcd(path):
    """返回 {信号名: {"width":.., "chg":[(t_ps, 值串), ...]}}，按时间升序"""
    sigs, by_id, t = {}, {}, 0
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            if line[0] == "$":
                if line.startswith("$var"):
                    p = line.split()
                    sigs[p[4]] = {"width": int(p[2]), "chg": []}
                    by_id[p[3]] = p[4]
                continue
            if line[0] == "#":
                t = int(line[1:])
                continue
            if line[0] in "bB":
                m = re.match(r"^[bB]([01xXzZ]+)\s+(\S+)$", line)
                if m and m.group(2) in by_id:
                    sigs[by_id[m.group(2)]]["chg"].append((t, m.group(1)))
                continue
            m = re.match(r"^([01xXzZ])(\S+)$", line)
            if m and m.group(2) in by_id:
                sigs[by_id[m.group(2)]]["chg"].append((t, m.group(1)))
    for s in sigs.values():
        s["chg"].sort(key=lambda x: x[0])
    return sigs


def value_at(sig, t):
    """t 时刻的值 = <= t 的最后一次变化"""
    i = bisect.bisect_right([c[0] for c in sig["chg"]], t) - 1
    return None if i < 0 else sig["chg"][i][1]


def hi_interval(sig):
    """信号 == '1' 的区间；多于一段或有缺就报错"""
    iv, start = [], None
    for t, v in sig["chg"]:
        if v == "1" and start is None:
            start = t
        elif v != "1" and start is not None:
            iv.append((start, t))
            start = None
    if start is not None:
        iv.append((start, None))
    return iv


def hexstr(width, bits):
    if any(c in "xXzZ" for c in bits):
        return "x" * ((width + 3) // 4)
    return "%0*X" % ((width + 3) // 4, int(bits, 2))


def is_high(v):
    return v == "1"


# ----------------------------------------------------------------- 断言

def verify(sigs):
    """核对图名声明的事实；返回 (窗口 t0/t1, 节拍时刻表)。不过就抛异常"""
    iv = hi_interval(sigs["reading"])
    if len(iv) != 1:
        raise AssertionError("reading 拉高区间有 %d 段，应恰好 1 段" % len(iv))
    r0, r1 = iv[0]
    if r1 is None:
        raise AssertionError("reading 到仿真结束都没落下")

    # 真·节拍 = beat 计数器的变化时刻（clk 边沿数会被窗口边界的假点污染）
    beats = [t for t, _ in sigs["beat"]["chg"] if r0 <= t < r1]
    if len(beats) != 256:
        raise AssertionError("读出节拍数 = %d，应为 256" % len(beats))

    bad, low = [], []
    for t in beats:
        d, e = value_at(sigs["dout"], t), value_at(sigs["exp_now"], t)
        if not d or not e or re.search(r"[^01]", d + e):
            raise AssertionError("读出或期望含未知值，不能把 X == X 当成通过")
        if d != e:
            bad.append((t, d, e))
        if not is_high(value_at(sigs["cmp_ok"], t)):
            low.append(t)
    if bad:
        for t, d, e in bad[:5]:
            print("   不符 t=%d dout=%s exp_now=%s" % (t, d, e))
        raise AssertionError("有 %d 个节拍 dout != exp_now" % len(bad))
    if low:
        raise AssertionError("有 %d 个节拍 cmp_ok 不为高" % len(low))

    # 放大窗口：done 脉冲前一拍起，取 WINDOW_NS 纳秒（done 脉冲 = 读出的开始）
    done_hits = [t for t, v in sigs["done"]["chg"] if v == "1"]
    if not done_hits:
        raise AssertionError("done 从未拉高")
    w0 = done_hits[0] - 5000
    w1 = w0 + WINDOW_NS * 1000

    print("读出窗口   : %d .. %d ps  (%.0f ns)" % (r0, r1, (r1 - r0) / 1000.0))
    print("节拍数     : %d  （逐拍核对 dout == exp_now，全部相同）" % len(beats))
    print("放大窗口   : %d .. %d ps  (%.0f ns，%d 拍)" %
          (w0, w1, (w1 - w0) / 1000.0, len([t for t in beats if w0 <= t <= w1])))
    return w0, w1, beats


# ----------------------------------------------------------------- 画 SVG

def render_svg(sigs, w0, w1, path):
    W = 1120
    LBL, X0 = 168, 186           # 标签列宽 / 波形区起点
    X1 = W - 24
    TOP = 92                     # 标题 + 副标题 + 时间轴占掉的高度
    HROW = {"clk": 26, "done": 24, "read_a": 24, "reading": 24,
            "beat": 30, "dout": 34, "exp_now": 34, "cmp_ok": 24}
    GAP = 6
    rows_h = sum(HROW[r] for r in ROWS) + GAP * (len(ROWS) - 1)
    H = TOP + rows_h + 46

    def xt(t):
        return X0 + (t - w0) * (X1 - X0) / float(w1 - w0)

    esc = lambda s: str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    o = []
    o.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
             'viewBox="0 0 %d %d" font-family="\'Microsoft YaHei\',\'PingFang SC\',sans-serif">'
             % (W, H, W, H))
    o.append('<rect width="%d" height="%d" fill="#ffffff"/>' % (W, H))
    o.append('<text x="%d" y="30" font-size="17" font-weight="700" fill="%s">'
             'FNTT 读出对拍：RTL 输出 dout 与期望值 exp_now 逐拍相同</text>'
             % (24, INK))
    o.append('<text x="24" y="52" font-size="12" fill="%s">'
             'pe1 单组向量｜done 脉冲 = 读出开始｜cmp_ok 每拍采样一次两者的比较结果，'
             '图中<b>全程为高</b>（无一次不符）</text>' % MUTED)

    # 时间轴
    ax = TOP - 16
    o.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="1"/>'
             % (X0, ax, X1, ax, AXIS))
    for i in range(0, WINDOW_NS + 1, 10):          # 每 10 ns = 一拍
        x = xt(w0 + i * 1000)
        if 10 <= i < WINDOW_NS:
            o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="1"/>'
                     % (x, ax, x, H - 40, GRID))
        if i % 20 == 0:
            o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="%s" stroke-width="1"/>'
                     % (x, ax - 5, x, ax, AXIS))
            o.append('<text x="%.1f" y="%d" text-anchor="middle" font-size="10.5" fill="%s">'
                     '%d ns</text>' % (x, ax - 9, MUTED, (w0 + i * 1000) // 1000))

    y = TOP
    for r in ROWS:
        sig, h = sigs[r], HROW[r]
        ytop, ybot = y, y + h
        hx, mx, lx = y + 5, (ytop + ybot) / 2.0, ybot - 5      # 高 / 中 / 低位
        o.append('<text x="%d" y="%.1f" text-anchor="end" font-size="12.5" fill="%s">%s</text>'
                 % (LBL, mx + 4, INK if r in ("dout", "exp_now") else MUTED, esc(r)))
        o.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="%s" stroke-width="1"/>'
                 % (X0, mx, X1, mx, AXIS))

        chg = [(t, v) for t, v in sig["chg"] if w0 < t <= w1]
        cur = value_at(sig, w0)
        color = MATCH if r == "cmp_ok" else WAVE

        if sig["width"] == 1:                                   # ---- 标量：阶梯波形
            yy = hx if is_high(cur) else lx
            pts = [(xt(w0), yy)]
            for t, v in chg:
                pts.append((xt(t), yy))
                yy = hx if is_high(v) else lx
                pts.append((xt(t), yy))
            pts.append((xt(w1), yy))
            o.append('<polyline fill="none" stroke="%s" stroke-width="1.6" points="%s"/>'
                     % (color, " ".join("%.1f,%.1f" % p for p in pts)))
            if r in ("done", "read_a"):                          # 单脉冲标个 1
                for t, v in chg:
                    if is_high(v):
                        o.append('<text x="%.1f" y="%.1f" font-size="10" fill="%s">1</text>'
                                 % (xt(t) + 3, hx - 2, MUTED))
        else:                                                    # ---- 向量：总线
            seg, cur = w0, value_at(sig, w0)
            for t, v in chg:
                _seg(o, xt(seg), xt(t), mx, color, hexstr(sig["width"], cur),
                     seg != w0, True)
                seg, cur = t, v
            _seg(o, xt(seg), xt(w1), mx, color, hexstr(sig["width"], cur),
                 seg != w0, False)
        y += h + GAP

    o.append('<text x="24" y="%d" font-size="11" fill="%s">'
             '数据：refsim/fntt_wave.vcd（由 refsim/pe1/fntt_wave_tb.v 本次仿真产生）｜'
             '由 refsim/gen_wave_figure.py 生成，出图前已断言 256 拍全部相同</text>'
             % (H - 14, MUTED))
    o.append('</svg>')
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(o) + "\n")


def _seg(o, xa, xb, mx, color, label, tick_left, tick_right):
    """总线的一段：横线 + 两端短竖线（有跳变的边才画）+ 中间的值文本（放不下就不画）"""
    if xb - xa < 0.7:
        return
    o.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="1.6"/>'
             % (xa, mx, xb, mx, color))
    for x, on in ((xa, tick_left), (xb, tick_right)):
        if on:
            o.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="1.6"/>'
                     % (x, mx - 4, x, mx + 4, color))
    if label and (xb - xa) >= len(label) * 6.6 + 6:
        cw = len(label) * 6.6 + 5
        o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="13" fill="#ffffff"/>'
                 % ((xa + xb) / 2.0 - cw / 2.0, mx - 6.5, cw))
        o.append('<text x="%.1f" y="%.1f" text-anchor="middle" font-size="11" '
                 'font-family="Consolas,\'Courier New\',monospace" fill="%s">%s</text>'
                 % ((xa + xb) / 2.0, mx + 3.6, INK, label))


# ----------------------------------------------------------------- 画 PNG

def render_png(w0, w1, path):
    import shutil
    exe = shutil.which("gtkwave")
    if not exe:
        raise RuntimeError("PATH 里找不到 gtkwave —— 先 export PATH=/c/iverilog/gtkwave/bin:$PATH")

    tcl = ["set out {%s}" % path.replace("\\", "/"),
           "array set fac {}",
           "set nfacs [gtkwave::getNumFacs]",
           "for {set i 0} {$i < $nfacs} {incr i} {",
           "    set f [gtkwave::getFacName $i]",
           "    if {[string match \"*.uut.*\" $f]} { continue }",
           "    set b [lindex [split $f .] end]",
           "    set k [string first \"\\[\" $b]",
           "    if {$k >= 0} { set b [string range $b 0 [expr {$k - 1}]] }",
           "    set fac($b) $f",
           "}",
           "set sel {}",
           "foreach w {%s} { if {[info exists fac($w)]} { lappend sel $fac($w) } }"
           % " ".join(ROWS),
           "gtkwave::addSignalsFromList $sel",
           "gtkwave::/Edit/Set_Trace_Max_Hier 0",
           "gtkwave::setZoomRangeTimes %d %d" % (w0, w1),
           "if {[catch { gtkwave::/File/Grab_To_File $out } e]} { puts \"GRAB_ERR=$e\" }",
           "puts \"GRAB_EXISTS=[file exists $out]\"",
           "catch { gtkwave::/File/Quit }",
           "catch { exit 0 }"]
    with open(TMP_TCL, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(tcl) + "\n")
    try:
        r = subprocess.run([exe, "-S", os.path.basename(TMP_TCL), os.path.basename(VCD)],
                           cwd=HERE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=120)
        out = r.stdout.decode("utf-8", "replace")
    finally:
        if os.path.exists(TMP_TCL):
            os.remove(TMP_TCL)
    if not os.path.exists(path):
        raise RuntimeError("GTKWave 没写出 PNG：\n%s" % out)


# ----------------------------------------------------------------- 入口

def main():
    if not os.path.exists(VCD):
        print("找不到 %s" % VCD)
        print("先跑仿真产生它（模块清单见 refsim/run_fntt_check.sh 的 SRC 变量）：")
        print("  iverilog -g2012 -o batch_fntt_wave.vvp <pe1 下的 .v 模块> pe1/fntt_wave_tb.v")
        print("  vvp batch_fntt_wave.vvp")
        return 2

    sigs = parse_vcd(VCD)
    if "--inspect" in sys.argv:
        for n, s in sigs.items():
            print("  %-10s width=%-3d 变化 %d 次" % (n, s["width"], len(s["chg"])))
        return 0

    try:
        w0, w1, _beats = verify(sigs)
    except AssertionError as e:
        print("✗ 断言未过，不出图：%s" % e)
        return 1

    if "--verify-only" in sys.argv:
        return 0

    os.makedirs(OUTDIR, exist_ok=True)
    svg = os.path.join(OUTDIR, STEM + ".svg")
    render_svg(sigs, w0, w1, svg)
    print("✅ 写出 %s" % os.path.relpath(svg, REPO))

    if "--svg-only" not in sys.argv:
        png = os.path.join(OUTDIR, STEM + ".png")
        render_png(w0, w1, png)
        print("✅ 写出 %s" % os.path.relpath(png, REPO))
    return 0


if __name__ == "__main__":
    sys.exit(main())
