#!/bin/sh
# ===========================================================================
# run_probes.sh —— 跑出 H1_port_spec.md 里的全部周期数与顺序表
#
# 用法：sh run_probes.sh      （在 rtl/probes/ 下跑，或从别处跑都行）
# 依赖：iverilog（/c/iverilog/bin）、python
# 中间文件全部落在 _work/，不进仓库。
# ===========================================================================
set -e
export PATH="/c/iverilog/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
BATCH="../../refsim/batch"
W="_work"
mkdir -p "$W"

# ------------------------------------------------------------------ 向量
# 取 FNTT 黄金向量的第 0 组（前 256 行）。refsim/batch 是 B 的目录，只读。
head -256 "$BATCH/ntt_batch_in.txt"  > "$W/in.txt"
head -256 "$BATCH/ntt_batch_exp.txt" > "$W/exp.txt"

PE1=$(ls ../pe1/*.v | tr '\n' ' ')
PE4=$(ls ../pe4/*.v | tr '\n' ' ')
PE16=$(ls ../pe16/*.v | tr '\n' ' ')
CORE="../ntt_core"          # 参数化后的新树（本段只用到叶子 BRAM/BROM）

# vvp 的工作目录决定 $readmemh 的相对路径，所以统一在 _work 里跑
run_tb () {   # run_tb <可执行名> <plusargs...>
    vvp "../_work/$1" ${2:+$2} > "../_work/$1.log" 2>&1 || true
}

echo "═══ ⓪ ntt_core 叶子：BRAM/BROM 三档实例化 + 内容抽查 ═══"
# TW_ADDR_W 是手工选的 9/8/7，推不出公式（设计文档 §3.3）—— 所以三档的搭配写死在下面
for cfg in 1:9 4:8 16:7; do
    pe="${cfg%%:*}"; tw="${cfg##*:}"
    iverilog -g2005 -DCFG_PE_NUM=$pe -DCFG_TW=$tw \
        -o "$W/leaf$pe.vvp" leaf_elab_tb.v "$CORE/BRAM.v" "$CORE/BROM.v"
    ( cd "$W" && vvp "leaf$pe.vvp" ) > "$W/leaf$pe.log" 2>&1 || true
    grep -E '^(PE=|抽查)' "$W/leaf$pe.log" | sed 's/^/  /'
    grep -E '^(PASS|FAIL|FATAL)' "$W/leaf$pe.log" | sed 's/^/  /'
done

echo "═══ ① pe1 接口时序（核） ═══"
iverilog -g2012 -o "$W/pe1_core.vvp" $PE1 pe1_timing_tb.v
( cd "$W" && vvp pe1_core.vvp ) > "$W/pe1_core.log" 2>&1
grep '^TIMELINE' "$W/pe1_core.log" | sed 's/^/  /'

echo "═══ ② pe1 接口时序（KyberHPM1PE_top，带输入/输出寄存） ═══"
iverilog -g2012 -DUSE_TOP -o "$W/pe1_top.vvp" $PE1 pe1_timing_tb.v
( cd "$W" && vvp pe1_top.vvp ) > "$W/pe1_top.log" 2>&1
grep '^TIMELINE' "$W/pe1_top.log" | sed 's/^/  /'

echo "═══ ③ pe4 装载顺序 / 读出顺序 ═══"
iverilog -g2012 -o "$W/pe4.vvp" $PE4 order_tb.v
( cd "$W" && vvp pe4.vvp ) > "$W/pe4.log" 2>&1
grep '^ORDER' "$W/pe4.log" | sed 's/^/  /'

echo "═══ ④ pe16 装载顺序 / 读出顺序 ═══"
iverilog -g2012 -DPE16 -o "$W/pe16.vvp" $PE16 order_tb.v
( cd "$W" && vvp pe16.vvp ) > "$W/pe16.log" 2>&1
grep '^ORDER' "$W/pe16.log" | sed 's/^/  /'

echo
echo "═══ ⑤ 反推顺序表 ═══"
python - "$W" <<'PY'
# -*- coding: utf-8 -*-
import sys, os
from collections import defaultdict
sys.stdout.reconfigure(encoding="utf-8")

W = sys.argv[1]
exp = [int(l.strip(), 16) for l in open(os.path.join(W, "exp.txt")) if l.strip()]
idx = defaultdict(list)
for j, v in enumerate(exp):
    idx[v].append(j)

def load(name):
    return [int(l.split()[2], 16)
            for l in open(os.path.join(W, name)) if l.startswith("RAW")]

def beat_lines(name):
    return [l.split()[2].strip()
            for l in open(os.path.join(W, name)) if l.startswith("BEAT")]

def report(tag, raw, pe):
    pi, amb = [], 0
    for v in raw:
        c = idx[v]
        if len(c) == 1:
            pi.append(c[0])
        else:
            pi.append(-1); amb += 1
    print(f"  {tag}: 256 个值里可唯一定位的 {256-amb} 个")
    bad = []
    for b in range(256 // pe):
        want = [pe*b + (pe-1-j) for j in range(pe)]
        got  = pi[pe*b:pe*b+pe]
        for j in range(pe):
            if got[j] != -1 and got[j] != want[j]:
                bad.append((b, j, got[j], want[j]))
    if not bad:
        print(f"  {tag}: ✅ 全部可唯一定位的值都符合「dout 最高切片 = 本拍最低下标，拍间自然顺序」")
    else:
        print(f"  {tag}: ❌ {len(bad)} 处不符，前 8 条：")
        for b, j, g, w in bad[:8]:
            print(f"      beat {b} 切片 {j}: 实测下标 {g}，规则预测 {w}")

report("pe4 ", load("pe4.log") , 4)
report("pe16", load("pe16.log"), 16)

# ---- pe1 的读出顺序（FNTT，结果在 bank1）---------------------------------
# 时间线显示 first_dout_cc 在 read_pulse 之后第 3 拍，而 OUT 数组从 read 之后
# 第 1 拍就开始记，所以要跳过前 2 条。
out = [int(l.split()[2], 16)
       for l in open(os.path.join(W, "pe1_core.log")) if l.startswith("OUT ")]
pi = []
for v in out:
    c = idx[v]
    pi.append(c[0] if len(c) == 1 else -1)
beats = pi[2:258]                      # 第 3 拍起的 256 拍
assert len(beats) == 256, f"OUT 条数不够：{len(pi)}"
want = [4*(m//4) + [0,2,1,3][m % 4] for m in range(256)]
mis = [(m, beats[m], want[m]) for m in range(256)
       if beats[m] != -1 and beats[m] != want[m]]
if not mis:
    print("  pe1 : ✅ 读出顺序符合组内 0,2,1,3 循环（0,2,1,3,4,6,5,7,...）")
else:
    print(f"  pe1 : ❌ {len(mis)} 处不符，前 8 条：{mis[:8]}")
print(f"  pe1  非零读数拍数: 见 ① 的 nonzero_beats（含末尾 1 拍越界回卷）")

for tag, f in (("pe4 ", "pe4.log"), ("pe16", "pe16.log")):
    bl = beat_lines(f)
    print(f"  {tag} 读出拍数（含多打的 4 拍）: {len(bl)}，其中第 {len(bl)-4} 拍之后是越界拍")
PY

echo
echo "═══ ⑥ ntt_core/ntt_addressgenerator 与上游逐拍等价 ═══"
# L=7→pe1（多两个输出，要 -DHAS_PE1_PORTS）｜L=5→pe4｜L=3→pe16（都不能带那个宏）
for cfg in 7:pe1:-DHAS_PE1_PORTS 5:pe4: 3:pe16:; do
    L="${cfg%%:*}"; rest="${cfg#*:}"; dir="${rest%%:*}"; extra="${rest#*:}"
    iverilog -g2005 -DCFG_L=$L $extra \
        -o "$W/ag$L.vvp" ag_equiv_tb.v "../$dir/addressgenerator.v" "../$dir/shiftreg.v" \
        "$CORE/addressgenerator.v" "$CORE/shiftreg.v"
    ( cd "$W" && vvp "ag$L.vvp" ) > "$W/ag$L.log" 2>&1 || true
    grep -E '^(CFG|PHASE)' "$W/ag$L.log" | sed 's/^/  /'
    grep -E '^(PASS|FAIL|FATAL)' "$W/ag$L.log" | sed 's/^/  /'
done

echo
echo "═══ ⑦ ntt_core/KyberHPMNTT 与上游逐拍等价（三档） ═══"
# 新核的参数化写法：共享骨架 + 只在「结构真的不同」的地方开 generate 分支。
# 所以这条探针要证明的是「参数化没改行为」，比的是每拍的全部端口与内部状态。
COREV="$(ls $CORE/*.v | grep -v _top | tr '\n' ' ')"    # 新核（不含 _top）

core_run () {   # $1=PE_NUMBER $2=上游源码 $3=上游模块名 $4=新核源码 $5=标签
    iverilog -g2005 -DCFG_PE_NUM="$1" -DCFG_PE_MOD="$3" \
        -o "$W/core$5.vvp" core_equiv_tb.v $2 $4 2>"$W/core$5.err" || true
    ( cd "$W" && vvp "core$5.vvp" ) > "$W/core$5.log" 2>&1 || true
    grep -E '^(CFG|CYCLES|PASS|FAIL|FATAL|WARN)' "$W/core$5.log" | sed 's/^/  /'
    if ! grep -qE '^(PASS|FAIL|FATAL)' "$W/core$5.log"; then
        echo "  ❌ $5 没有产出 PASS/FAIL/FATAL —— 编译或仿真挂了，看 $W/core$5.log 与 $W/core$5.err"
    fi
}

for cfg in 1:pe1:KyberHPM1PE 4:pe4:KyberHPM4PE 16:pe16:KyberHPM16PE; do
    pe="${cfg%%:*}"; rest="${cfg#*:}"; dir="${rest%%:*}"; mod="${rest##*:}"
    core_run "$pe" "$(ls ../$dir/*.v | tr '\n' ' ')" "$mod" "$COREV" "$pe"
done

echo "  --- 非法 PE_NUMBER=3：应当响亮地失败（不是静默给出错电路）---"
core_run 3 "$PE16" KyberHPM16PE "$COREV" 3
echo "  （上面那行 FATAL 来自两个地方：核自己的 initial 守卫 + 探针的守卫）"
echo "  （编译期另有 $(grep -c 'out of bounds' "$W/core3.err" || true) 条 out-of-bounds 警告 —— 正是「落进 pe16 支」的证据）"

echo "  --- 阴性对照：改一处必须 FAIL，否则探针没有分辨力 ---"
neg_prep () {   # $1=目标目录：拷一份新核进去
    rm -rf "$1"; mkdir -p "$1"; cp $CORE/*.v "$1/"
}

# 对照 A —— 只动 pe16 分支：装载时 pe16 的写地址高位取反
neg_prep "$W/negA"
python - "$W/negA/KyberHPMNTT.v" <<'PY'
# -*- coding: utf-8 -*-
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8")
old, new = "{32{1'b0,di_cntr[L-1:0]}}", "{32{1'b1,di_cntr[L-1:0]}}"
assert s.count(old) == 1, "对照 A 的锚点不再是唯一一处，脚本要跟着改"
p.write_bytes(s.replace(old, new).encode("utf-8"))
PY
for cfg in 1:pe1:KyberHPM1PE 4:pe4:KyberHPM4PE 16:pe16:KyberHPM16PE; do
    pe="${cfg%%:*}"; rest="${cfg#*:}"; dir="${rest%%:*}"; mod="${rest##*:}"
    core_run "$pe" "$(ls ../$dir/*.v | tr '\n' ' ')" "$mod" \
             "$(ls "$W/negA"/*.v | grep -v _top | tr '\n' ' ')" "A$pe"
done
echo "  → 预期：只有 PE=16 FAIL，PE=1/PE=4 仍 PASS（证明探针能定位到配置）"

# 对照 B —— 动共享骨架：dout 的低半改成读低半（原本读高半）
neg_prep "$W/negB"
python - "$W/negB/KyberHPMNTT.v" <<'PY'
# -*- coding: utf-8 -*-
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8")
old = "assign do0_lo[12*(PE_NUMBER-1-dg) +: 12] = do0[PE_NUMBER+dg];"
new = "assign do0_lo[12*(PE_NUMBER-1-dg) +: 12] = do0[dg];"
assert s.count(old) == 1, "对照 B 的锚点不再是唯一一处，脚本要跟着改"
p.write_bytes(s.replace(old, new).encode("utf-8"))
PY
for cfg in 1:pe1:KyberHPM1PE 4:pe4:KyberHPM4PE 16:pe16:KyberHPM16PE; do
    pe="${cfg%%:*}"; rest="${cfg#*:}"; dir="${rest%%:*}"; mod="${rest##*:}"
    core_run "$pe" "$(ls ../$dir/*.v | tr '\n' ' ')" "$mod" \
             "$(ls "$W/negB"/*.v | grep -v _top | tr '\n' ' ')" "B$pe"
done
echo "  → 预期：三档全 FAIL（证明共享骨架也在被逐拍比对，不是只比了分支）"

echo
echo "═══ 完成 —— 中间文件在 rtl/probes/_work/ ═══"
