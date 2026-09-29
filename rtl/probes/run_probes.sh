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
# ⚠️ Windows 的 python 默认按系统码页（cp936）编码 stdout，脚本里的 ✅/❌ 一打就
# UnicodeEncodeError 崩掉 —— 崩在最后一段读起来像"跑完了"，其实后面的判据一条没出。
# 段 ⑤ 里那句 sys.stdout.reconfigure 只救它自己，这里统一兜住。
export PYTHONIOENCODING=utf-8

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

echo "  --- 阴性对照（Task 1 Step 7）：两条都必须炸，否则断言没有分辨力 ---"
# 对照 1（F1）：PE=4 配 TW_ADDR_W=9 —— 这套搭配**能编能跑**，只是 c_tw/raddr_tw/BROM
#   会静默读飞。正是「能跑但错」才需要 elaboration 期的断言。预期 FAIL。
if iverilog -g2005 -DCFG_PE_NUM=4 -DCFG_TW=9 -o "$W/leafbad.vvp" \
        leaf_elab_tb.v "$CORE/BRAM.v" "$CORE/BROM.v" 2>"$W/leafbad.err"; then
    ( cd "$W" && vvp leafbad.vvp ) 2>&1 | grep -E '^(FAIL|PASS)' | sed 's/^/  /'
else
    echo "  ℹ️ 对照 1 在编译期就被拦住（也可接受）"
fi
# 对照 2：PE_NUMBER=3 —— BROM 的 generate 没有 default，不守就会得到一个
#   dout 恒为 X 的「能跑的」设计。预期 FATAL。
if iverilog -g2005 -DCFG_PE_NUM=3 -DCFG_TW=9 -o "$W/leafbad3.vvp" \
        leaf_elab_tb.v "$CORE/BRAM.v" "$CORE/BROM.v" 2>"$W/leafbad3.err"; then
    ( cd "$W" && vvp leafbad3.vvp ) 2>&1 | grep -E '^(FAIL|PASS|FATAL)' | sed 's/^/  /'
else
    echo "  ℹ️ 对照 2 在编译期就被拦住（也可接受）"
fi

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

TOPV="$CORE/KyberHPMNTT_top.v"

echo
echo "═══ ⑧ KyberHPMNTT_top：固定 12 位接口的三档对外行为 ═══"
# 这条是「接口一致」的判据：三档喂**同一串** 12 位激励，
#   ① 装载相位收尾后再脉冲 start_* 能收到 done
#   ② 有效 dout 从 read 之后第 2*PE_NUMBER+3 拍起（**三档不同**，见探针文件头）
#   ③ 连续 256 拍有效值（非零、且不同值个数不退化）
#   ④ done 在 start_* 之后第 CC+3 拍
# 然后打印这 256 个值，下面横向 diff。
#
# ⚠️ 这条走的是 **PWM2 之后** 读 bank A 那条路。那个 ✅ **不能**读成
#    「固定 12 位接口成立」—— 它只说明三档在**这条路上**一致。
#    FNTT 之后直接读的那条路，段 ⑨ 实测三档**不一致**（有黄金锚），
#    原因与归属见 ⑨ 的说明，别把这里的 ✅ 外推。

for pe in 1 4 16; do
    iverilog -g2005 -DCFG_PE_NUM=$pe -o "$W/top$pe.vvp" \
        top_behavior_tb.v $COREV "$TOPV" 2>"$W/top$pe.err" || true
    ( cd "$W" && vvp "top$pe.vvp" ) > "$W/top$pe.log" 2>&1 || true
    grep -E '^(LOAD_|OP_|READ_A|FAIL|WARN)' "$W/top$pe.log" | sed 's/^/  /'
done
for pe in 1 4 16; do
    grep '^DOUT' "$W/top$pe.log" | awk '{print $3}' > "$W/top_seq$pe.txt"
    printf "  pe%-3s 读出 %s 个值\n" "$pe" "$(wc -l < "$W/top_seq$pe.txt" | tr -d ' ')"
done
if diff -q "$W/top_seq1.txt" "$W/top_seq4.txt" >/dev/null 2>&1 &&
   diff -q "$W/top_seq1.txt" "$W/top_seq16.txt" >/dev/null 2>&1; then
    echo "  ✅ 三档 dout 序列**逐位相同**（256/256）"
else
    echo "  ❌ 三档 dout 序列不同："
    diff "$W/top_seq1.txt" "$W/top_seq4.txt"  | head -6 | sed 's/^/    1vs4  /'
    diff "$W/top_seq1.txt" "$W/top_seq16.txt" | head -6 | sed 's/^/    1vs16 /'
fi

# pe1 另外和上游 KyberHPM1PE_top 逐拍对拍（接口同名同位宽，直连）
# ⚠️ pe4/pe16 没有可比的 _top —— 上游那两档的 _top 是**宽**接口，不是同一个东西。
iverilog -g2005 -DCFG_PE_NUM=1 -DREF_PE1 -o "$W/top1ref.vvp" \
    top_behavior_tb.v $PE1 $COREV "$TOPV" 2>"$W/top1ref.err" || true
( cd "$W" && vvp top1ref.vvp ) > "$W/top1ref.log" 2>&1 || true
grep -E '^(PASS|FAIL)' "$W/top1ref.log" | sed 's/^/  /'

echo "  --- 阴性对照：反序列化的切片号写成正着数，必须只见于 pe>1 ---"
# 改成「rsub=0 取切片 0，否则取切片 PE_NUMBER-rsub」——
#   组内顺序变成 0,3,2,1（pe4），而 H1_port_spec.md §五 要求最高切片 = 最低下标。
#   预期：pe1 仍 PASS（PE=1 时 rsub 恒 0，两式同值），pe4/pe16 FAIL。
#   ⚠️ 这条同时也是「三档逐位相同」这条判据**有分辨力**的证明：
#      没有它，上面那个 ✅ 只说明三档跑得一样，不说明跑对了。
rm -rf "$W/negT"; mkdir -p "$W/negT"; cp "$TOPV" "$W/negT/"
python - "$W/negT/KyberHPMNTT_top.v" <<'PY'
# -*- coding: utf-8 -*-
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8")
old = "wire [3:0]  dsel     = PE_NUMBER - 1 - rsub;"
new = "wire [3:0]  dsel     = (rsub == 4'd0) ? 4'd0 : (PE_NUMBER - rsub);"
assert s.count(old) == 1, "对照 T 的锚点不再是唯一一处，脚本要跟着改"
p.write_bytes(s.replace(old, new).encode("utf-8"))
PY
for pe in 1 4 16; do
    iverilog -g2005 -DCFG_PE_NUM=$pe -o "$W/negT$pe.vvp" \
        top_behavior_tb.v $COREV "$W/negT/KyberHPMNTT_top.v" 2>/dev/null || true
    ( cd "$W" && vvp "negT$pe.vvp" ) > "$W/negT$pe.log" 2>&1 || true
    grep '^DOUT' "$W/negT$pe.log" | awk '{print $3}' > "$W/negT_seq$pe.txt"
done
if diff -q "$W/negT_seq1.txt" "$W/negT_seq16.txt" >/dev/null 2>&1; then
    echo "  ❌ pe1 与 pe16 竟然还相同 —— 对照没生效，检查锚点"
else
    echo "  ✅ pe1 与 pe16 已不同（$(diff "$W/negT_seq1.txt" "$W/negT_seq16.txt" | grep -c '^<' || true) 处）—— 判据有分辨力"
fi
if diff -q "$W/negT_seq1.txt" "$W/top_seq1.txt" >/dev/null 2>&1; then
    echo "  ✅ pe1 不受影响（PE=1 时 rsub 恒 0，两式同值）—— 与预期一致"
else
    echo "  ❌ pe1 也被改动了 —— 与「只影响 pe>1」的预期不符，要查"
fi

echo
echo "═══ ⑨ KyberHPMNTT_top 对着黄金向量（有外部锚）═══"
# ⑧ 只证明三档**互相一致**（自洽）；这条把 `$BATCH/ntt_batch_exp.txt` 第 0 组
# （FIPS 203 KAT 校验过的参考实现算出来的 FNTT 结果）当锚，问的是「都对不对」。
#
# 两趟：
#   A) 装载 A → FNTT A → 读 A（不做 PWM2，直接对纯 FNTT 黄金向量）
#   B) 再走一遍 ⑧ 那条路（装载 B → FNTT B → PWM2 A → 读 A），
#      B 装的是**同一串 vin**，顺带把 FNTT B / PWM2 A 的 CC+3 也在顶层量一遍
#      —— 这一趟的读出值不是 exp 的简单函数（bank 的存取关系没弄清），
#      所以只拿它比三档**互相**是否一致，不当作对黄金向量的判据。
for mode in "" "-DWITH_PWM2"; do
    tag="fntt"; [ -n "$mode" ] && tag="pwm2"
    for pe in 1 4 16; do
        iverilog -g2005 -DCFG_PE_NUM=$pe $mode -o "$W/gold_${tag}_$pe.vvp" \
            top_golden_tb.v $COREV "$TOPV" 2>"$W/gold_${tag}_$pe.err" || true
        ( cd "$W" && vvp "gold_${tag}_$pe.vvp" ) > "$W/gold_${tag}_$pe.log" 2>&1 || true
        grep '^DOUT' "$W/gold_${tag}_$pe.log" | awk '{print $3}' > "$W/gold_${tag}_$pe.txt"
    done
done
for pe in 1 4 16; do
    grep -E '^(FAIL|PASS)' "$W/gold_fntt_$pe.log" | sed "s/^/  FNTT pe$pe /"
    grep -E '^(OP_|FAIL|PASS)' "$W/gold_pwm2_$pe.log" | sed "s/^/  PWM2 pe$pe /"
done
python - <<'PY'
# -*- coding: utf-8 -*-
import pathlib
from collections import defaultdict
d = pathlib.Path("_work")
def vals(p): return [int(x, 16) for x in p.read_text().split()]
exp = vals(d/"exp.txt")
# 上游的「交织」约定 σ(m) = 4*(m//4) + [0,2,1,3][m%4]
sig = lambda m: 4*(m//4) + [0,2,1,3][m % 4]

def name_of(mp):
    """把 m→黄金下标 的映射表认出来是哪一种约定"""
    known = {"自然序": lambda m: m, "交织 0,2,1,3": sig}
    for nm, f in known.items():
        if all(x == "?" or int(x) == f(m) for m, x in enumerate(mp)):
            return nm
    return "既不是自然序也不是 0,2,1,3 交织"

print("  --- A) 装载 A → FNTT A → 读 A（锚 = 纯 FNTT 黄金向量）---")
maps = {}
for pe in (1, 4, 16):
    got = vals(d/f"gold_fntt_{pe}.txt")
    if sorted(got) != sorted(exp):
        print(f"  pe{pe}: ❌ 多重集 != 黄金向量 —— 装载或变换就是错的，先别管顺序")
        continue
    b = defaultdict(list)
    for i, v in enumerate(exp): b[v].append(i)
    mp = [str(b[v][0]) if len(b[v]) == 1 else "?" for v in got]
    nat = sum(1 for m in range(256) if got[m] == exp[m])
    print(f"  pe{pe}: 多重集 == 黄金向量 ✅；逐位==自然序 {nat}/256；"
          f"值有重复记 ? 的 {mp.count('?')} 处")
    print(f"        outset 约定 = {name_of(mp)}     m→idx 前 12: {','.join(mp[:12])}")
    maps[pe] = mp
if len(maps) == 3:
    if maps[1] == maps[4] == maps[16]:
        print("  ✅ 三档的读出约定相同 —— 固定 12 位接口在 FNTT 读数路上成立")
    else:
        print("  ❌ 三档的读出约定**不同** —— 「三档 dout 逐位相同」在 FNTT 读数路上**不成立**")
        print(f"        pe1 / pe4 / pe16 分别 = {[name_of(maps[p]) for p in (1,4,16)]}")
print("  --- B) 装载 B → FNTT B → PWM2 A → 读 A（⑧ 那条路，只比三档互相）---")
p = {pe: vals(d/f"gold_pwm2_{pe}.txt") for pe in (1, 4, 16)}
if p[1] == p[4] == p[16]:
    print("  ✅ 三档在这条路上逐位相同（与 ⑧ 一致）")
    # 顺带说一说这条路是什么约定（用 pe1 的流去套 σ 的逆）
    inv = [0]*256
    for m in range(256): inv[sig(m)] = m
    print(f"        （这条路只说明三档**一致**，没有外部锚，不能说明对）")
else:
    print("  ❌ 三档在这条路上也不同，与 ⑧ 的结论矛盾，要查")
PY

echo
echo "═══ 完成 —— 中间文件在 rtl/probes/_work/ ═══"
