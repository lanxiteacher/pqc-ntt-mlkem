"""
核对旧 rtl/zetas_tables.v，并生成完整、已验证的 Verilog twiddle 表。

运行：python gen_tables.py
"""
import sys, os, re
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ntt_golden as G

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OLD = os.path.join(ROOT, "rtl", "zetas_tables.v")

# ---------- 1. 核对旧文件 ----------
print("=" * 70)
print("1. 核对旧 rtl/zetas_tables.v")
print("=" * 70)

def parse_verilog_array(text, name):
    m = re.search(rf"\b{name}\s*\[0:\d+\]\s*=\s*\{{(.*?)\}}\s*;", text, re.S)
    if not m:
        return None
    return [int(x) for x in re.findall(r"-?\d+", m.group(1))]

if os.path.exists(OLD):
    text = open(OLD, encoding="utf-8").read()
    old_z = parse_verilog_array(text, "ZETAS")
    old_zi = parse_verilog_array(text, "ZETAS_INV")
    print(f"  解析到 ZETAS {len(old_z)} 项, ZETAS_INV {len(old_zi)} 项")
    bad = [i for i in range(128) if old_z[i] != G.ZETAS[i]]
    print(f"  ZETAS 错误项: {len(bad)}/128")
    if bad:
        print(f"    错误索引区间: {bad[0]}..{bad[-1]}")
        print(f"    前 3 个: " + ", ".join(f"[{i}] 旧={old_z[i]} 应为={G.ZETAS[i]}" for i in bad[:3]))
        # 统计是不是占位符
        placeholders = {old_z[i] for i in bad}
        print(f"    这些错误项用到的值集合: {sorted(placeholders)}  (共 {len(placeholders)} 种 -> 疑似占位符)")
    # zetas_inv 前提检查
    inv_ok = all((old_zi[i] * G.ZETAS[i]) % G.Q == 1 for i in range(128))
    print(f"  ZETAS_INV 是否满足 z*zinv=1 (mod q): {inv_ok}")
    for i in range(128):
        if (old_zi[i] * G.ZETAS[i]) % G.Q != 1:
            print(f"    [{i}] 首个不满足: zetas[{i}]={G.ZETAS[i]} zetas_inv[{i}]={old_zi[i]}")
            break
    print("  注: 当前 ref 实现根本不存在 zetas_inv 表 —— 逆变换复用 zetas 反向遍历")
else:
    print("  旧文件不存在，跳过")

# ---------- 2. 生成新表 ----------
print()
print("=" * 70)
print("2. 生成完整表")
print("=" * 70)

assert G.zetas_formula() == G.ZETAS, "公式重算与硬编码表不符！"
print("  生成前自检: zetas_formula() == ZETAS  OK")

def fmt(vals, per_line=8, indent="  "):
    lines = []
    for i in range(0, len(vals), per_line):
        lines.append(indent + ", ".join(f"{v:6d}" for v in vals[i:i + per_line]))
    return ",\n".join(lines)

FWD_SCHED = [s for s in G.layer_schedule() if s[0] == "fwd"]
INV_SCHED = [s for s in G.layer_schedule() if s[0] == "inv"]

out = f"""// ============================================================================
// ML-KEM / CRYSTALS-Kyber NTT twiddle 表   (q=3329, n=256, zeta=17, R=2^16)
//
// 本文件由 gen_tables.py 生成，全部 128 项均已与 pq-crystals/kyber ref/ntt.c
// 的硬编码 zetas[128] 逐项比对通过，并可用公式独立重算：
//     zetas[i] = centered( R * 17^bitrev7(i) mod q )
//
// 【重要】不存在 zetas_inv 表。逆向 NTT 复用本表，只是索引从 127 递减到 1。
//         旧版 rtl/zetas_tables.v 里的 ZETAS_INV 基于错误前提，已废弃。
// 【重要】zetas[0] 正向和逆向都从不使用。
// 【重要】表中是 int16 有符号中心化代表 [-q/2, q/2]，不是 [0, q-1]。
// ============================================================================

// ---- 完整 twiddle 表：正逆共用 ----------------------------------------------
localparam signed [15:0] ZETAS [0:127] = {{
{fmt(G.ZETAS)}
}};

// ---- 逐层索引调度（写地址生成逻辑直接照抄） ---------------------------------
// 正向 NTT (Cooley-Tukey / DIT)，k 从 1 升到 127，7 层：
"""
for _, layer, ln, nb, idx in FWD_SCHED:
    rng = f"zetas[{idx[0]}..{idx[-1]}]" if nb > 1 else f"zetas[{idx[0]}]"
    out += f"//   层{layer}  len={ln:<4} 块数={nb:<3} {rng}\n"

out += """//
// 逆向 NTT (Gentleman-Sande / DIF)，k 从 127 降到 1，7 层：
"""
for _, layer, ln, nb, idx in INV_SCHED:
    rng = f"zetas[{idx[0]}..{idx[-1]}]" if nb > 1 else f"zetas[{idx[0]}]"
    out += f"//   层{layer}  len={ln:<4} 块数={nb:<3} {rng}\n"

out += f"""
// ---- 逐层展开版：层 0..6 各自独立的 zeta 列表 -------------------------------
"""
for _, layer, ln, nb, idx in FWD_SCHED:
    out += f"// fwd 层{layer} (len={ln}, {nb} 块)\n"
    out += f"localparam signed [15:0] ZETAS_FWD_L{layer} [0:{nb-1}] = {{\n"
    out += fmt([G.ZETAS[i] for i in idx], per_line=nb if nb <= 8 else 8) + "\n};\n\n"
for _, layer, ln, nb, idx in INV_SCHED:
    out += f"// inv 层{layer} (len={ln}, {nb} 块)\n"
    out += f"localparam signed [15:0] ZETAS_INV_L{layer} [0:{nb-1}] = {{\n"
    out += fmt([G.ZETAS[i] for i in idx], per_line=nb if nb <= 8 else 8) + "\n};\n\n"

out += f"""
// ---- 常数 ----------------------------------------------------------------
localparam [15:0] KYBER_Q   = 16'd3329;
localparam [15:0] KYBER_QINV= 16'd62209;   // q^-1 mod 2^16  (有符号代表 -3327)
localparam signed [15:0] KYBER_MONT = -16'sd1044;  // R mod q (== 2285)
localparam signed [15:0] KYBER_F    = 16'sd1441;   // R^2/128 mod q, 配 fqmul 用在 invntt 末尾
localparam [15:0] BARRETT_V = 16'd20159;   // ((1<<26) + q/2)/q
localparam signed [15:0] R2_MOD_Q   = 16'sd1353;   // R^2 mod q, poly_tomont 用
"""

NEW = os.path.join(ROOT, "rtl", "zetas_tables_verified.v")
with open(NEW, "w", encoding="utf-8") as f:
    f.write(out)
print(f"  已写出: {NEW}  ({len(out)} 字节)")

# ---------- 3. 回读校验 ----------
print()
print("=" * 70)
print("3. 回读新文件校验")
print("=" * 70)
rt = open(NEW, encoding="utf-8").read()
rz = parse_verilog_array(rt, "ZETAS")
print(f"  解析 ZETAS: {len(rz)} 项, 与黄金表一致 ? {rz == G.ZETAS}")
for _, layer, ln, nb, idx in FWD_SCHED:
    got = parse_verilog_array(rt, f"ZETAS_FWD_L{layer}")
    want = [G.ZETAS[i] for i in idx]
    print(f"  fwd 层{layer}: {'OK' if got == want else 'FAIL'}  ({nb} 项)")
for _, layer, ln, nb, idx in INV_SCHED:
    got = parse_verilog_array(rt, f"ZETAS_INV_L{layer}")
    want = [G.ZETAS[i] for i in idx]
    print(f"  inv 层{layer}: {'OK' if got == want else 'FAIL'}  ({nb} 项)")
print("\n注意: 层表是 FILTER 成 7 个独立数组的，解析器按第一个匹配取，")
print("      上面每个层名只出现一次，故结果可信。")
