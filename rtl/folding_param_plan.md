# 参数化折叠度 NTT 核 · 实施计划

> **给执行者：** 逐任务执行，每个 Task 末尾有独立的验证与提交，**不要跳步**。
> 步骤用 `- [ ]` 勾选跟踪。

**目标：** 把上游三份手工复制的 RTL（`rtl/pe1|pe4|pe16/`）合并成**一份**以 `PE_NUMBER`
为参数的 RTL（`rtl/ntt_core/`），三档都综合进 `xc7z020clg400-2`，且行为与上游**逐拍一致**。

**做法：** 叶子上游三档本来就逐字节相同，直接取一份；`addressgenerator.v` / `BRAM.v` /
`BROM.v` 的参数化常数已全部推导成折叠参数 `L = $clog2(128/PE_NUMBER)` 的表达式；
核保持宽接口不动，**固定 12 位接口与序列化器放在核外**。

**技术栈：** Verilog-2001 ｜ iverilog 12.0（`C:\iverilog\bin`，不在 PATH）｜
Vivado ML Standard 2020.2（`E:\xilinx\Vivado\2020.2`）｜ python 3

**设计文档（spec）：** `rtl/folding_param_design.md` —— **本计划从它展开，两个一起读**。

**进度（2026-09-29）：** Task 1~8 已完成，**三条判据全过**。
`sh rtl/probes/run_probes.sh` 段 ⓪⑥⑦⑧⑨⑩ 全 PASS
（含各自的阴性对照，逐拍等价 pe1 7005 拍 / pe4 1919 拍 / pe16 669 拍）。
**判据 1（Vivado 综合 + 引脚预算）已通过**：三档 Bonded IOB 都是 37，三档都布完线。
**判据 2（三档周期数）已通过**：三档 × {FNTT, PWM2, INTT} 共 12 格全部等于上游实测值。
**判据 3（三档功能对拍）已通过**：3 个运算 × 3 档 × 4096 系数全部多重集相等，
pe1 三处读出顺序与 B 的 bench 逐字一致。见下方 Task 5 / Task 6 / Task 7。
**Task 8 已完成**（文档与跨队同步）—— 至此本计划全部走完。

⚠️ **Task 4 有一条判据没达标，已改由 Task 6 承接：** 新增的段 ⑨ 拿
`refsim/batch/ntt_batch_exp.txt` 第 0 组当外部锚，量出 **FNTT 读数路上三档的读出顺序并不一致**
（pe1 = 交织 `0,2,1,3`；pe4/pe16 = 自然序）。段 ⑧ 那个「三档逐位相同」只覆盖
**PWM2 之后的读数路**，不能外推。交织是**上游 pe1 自带的约定**（`refsim/pe1/fntt_batch_tb.v`
第 113-117 行靠反交织才对得上 FIPS 203 黄金向量），核与上游逐拍等价所以被原样继承，
不是本次参数化引入的。详细结论见 `rtl/probes/README.md` 的 `top_golden_tb.v` 一节。

⚠️ **判据 1 已核对，但「核 / 顶层」是两个边界，对比时要标清。**
上游那三份已提交的报告量的是**核**（`KyberHPMNPE`）；本轮 `rtl/ntt_core/` 量的是**顶层**
（含 12 位串行化的外壳）。两者的 IOB 数一样（上游 `_top` 不改端口位宽），但 LUT/FF
差一级寄存器的量。所以扫描脚本加了 `TREE=upstream_top` 专门量上游顶层，
对比表里必须写清哪一行是哪个边界。见下方 Task 7 的「实施记录」。

---

## Global Constraints

以下每条都是硬约束，**每个 Task 都隐含包含**：

1. **目录名与文件名一律纯英文**（小写字母、数字、下划线或连字符）——
   《选题指南》§3.3.5.4 用的是「**须**」，不是「推荐」。
2. **跨平台数据文件统一 LF 行尾**；python 写文件用 `"wb"`，**不要用 `"w"`**。
   （仓库层 `.gitattributes` 是 `* -text` 兜底，但不要依赖它。）
3. **testbench 里禁止无界 `while (done == 0)`** —— 必须加计数护栏，否则挂死而不是报错。
4. **「验证通过」必须配「非退化」** —— 先统计向量里有多少个不同值，再谈全中。
5. **`research/ref_rtl/` 是只读原件**；**`rtl/pe1|pe4|pe16/` 本轮只读**，是等价性对照基准。
6. **不动 `refsim/`**（B 的主责）；探针需要黄金向量时**只读**引用。
7. **只改 `rtl/` 及其子目录**。
8. **一个能跑通的小步 = 一个提交**；不 push 到远端不算完。
9. **文件操作复制而不是移动**；损坏的文件移到 `_broken/`，**不要删除**。
10. **禁止杀 `claude.exe` / `node.exe`**。
11. iverilog 每次先 `export PATH="/c/iverilog/bin:$PATH"`。
12. **Vivado 必须从仓库外目录启动**（仓库路径 `C:\Users\l'x\Desktop\FPGA` 含撇号，
    会把 ABC 引擎的 shell 引号咬死）—— 用 `C:\fpga_work\`。
13. ⚠️ **新树里凡是与上游重名的模块，一律加 `ntt_` 前缀。**
    Verilog 没有命名空间 —— 新旧两棵树同名的话，**想做逐拍对拍时根本编译不过**
    （`module already declared`）。这是 Task 2 / Task 3 的核心手段能不能用的前提。

    重名清单（**新树一律改**）：`addressgenerator` → `ntt_addressgenerator`、
    `BRAM` → `ntt_BRAM`、`BROM` → `ntt_BROM`、`butterfly` → `ntt_butterfly`、
    `modadd` / `modsub` / `modred` / `modmul` / `intmul` → 各加 `ntt_` 前缀、
    `dt0`–`dt3` / `FA` / `HA` / `div2` / `shiftreg` → 各加 `ntt_` 前缀。

    **`KyberHPMNTT` 与 `KyberHPMNTT_top` 不重名**（上游叫 `KyberHPM1PE` 等），保持原名。

    **文件名不变**（仍是 `addressgenerator.v` 等）—— 只改 `module` 关键字后面的标识符。
    批量改法：

    ```bash
    cd "C:/Users/l'x/Desktop/FPGA/rtl/ntt_core"
    for m in addressgenerator BRAM BROM butterfly modadd modsub modred modmul \
             intmul dt0 dt1 dt2 dt3 FA HA div2 shiftreg; do
      sed -i "s/\bmodule ${m}\b/module ntt_${m}/" $m.v
    done
    grep -n "^module" *.v        # 逐条核对，必须全部带 ntt_ 前缀
    ```

    ⚠️ **同时要改这棵树里的例化**（叶子之间可能有互相例化）：
    ```bash
    grep -n "^\s*\(butterfly\|modadd\|modsub\|modred\|modmul\|intmul\|dt[0-3]\|FA\|HA\|div2\|shiftreg\|BRAM\|BROM\|addressgenerator\)\b" *.v
    ```
    每一条命中都要加 `ntt_` 前缀。**改完必须重新跑一遍 elaboration 才算数。**

---

## Review Focus

以下是设计文档隐含、但**单个 Task 的测试不一定覆盖**的五类失效，最可能咬人。
每条都必须在下面指定的 Task 里有对应测试。

| # | 失效模式 | 期望行为 | 测试落在 |
|---|---|---|---|
| F1 | `c_tw` / `raddr_tw` / `BROM` 地址**位宽三处不一致**（9/8/7 是手工选的，不是 L 的函数） | 三者恒等；读地址不越界 | Task 1 的位宽断言 |
| F2 | pe16 **INTT 与 FNTT 的 stall 条件不对称**被「顺手统一」掉 | 逐拍保持上游行为 | Task 2 的逐拍等价探针 |
| F3 | FNTT 在 `S = L-1` 处**读口恒等、写口仍置换**这一故意的不一致被抹平 | 逐拍保持 | Task 2 的逐拍等价探针 |
| F4 | `PE_NUMBER=1` 时序列化器**不是直通**，破坏 pe1 已验证的时序 | pe1 外部行为与上游 `KyberHPM1PE_top` 完全一致 | Task 4 的直通与非直通两组用例 |
| F5 | `128 / PE_NUMBER` 不是 2 的幂时 `$clog2` 给出错误 L | 非法 `PE_NUMBER` 在 elaboration 期报错，而非静默算错 | Task 3 的非法参数用例 |

---

## 文件结构

### 新建

```
rtl/ntt_core/               文件名        模块名（⚠️ 一律加 ntt_ 前缀，见约束 13）
├── KyberHPMNTT_top.v       KyberHPMNTT_top   固定 12 位接口 + 序列化（**唯一对外的模块**）
├── KyberHPMNTT.v           KyberHPMNTT       核，#(parameter PE_NUMBER)，宽接口 din[12*PE-1:0]
├── addressgenerator.v      ntt_addressgenerator   #(parameter L, TW_ADDR_W)（**最高风险**）
├── BRAM.v                  ntt_BRAM              #(parameter ADDR_W)
├── BROM.v                  ntt_BROM              #(parameter TW_ADDR_W)
├── butterfly.v  modadd.v  modsub.v  modred.v  modmul.v  intmul.v      各加 ntt_ 前缀
└── dt0.v  dt1.v  dt2.v  dt3.v  FA.v  HA.v  div2.v  shiftreg.v         各加 ntt_ 前缀
```

```
rtl/probes/
├── ag_equiv_tb.v         新：addressgenerator 逐拍等价（旧 vs 新）
├── core_equiv_tb.v       新：核逐拍等价（旧 vs 新）
├── top_behavior_tb.v     新：三档对外行为 + 周期数
├── run_probes.sh         改：接入三条新探针
└── README.md             改：写清新探针验什么、怎么复跑
```

### 只读（对照基准，本轮**不改不删**）

```
rtl/pe1/  rtl/pe4/  rtl/pe16/
rtl/folding_param_design.md      ← spec
rtl/H1_port_spec.md              ← Task 8 要改其中 §五
refsim/batch/                    ← 黄金向量，只读
```

---

## Task 1: 归并叶子模块 + 参数化 `BRAM` / `BROM`

**Files:**
- Create: `rtl/ntt_core/`（整个目录）
- Modify: 无
- Test: `rtl/probes/ag_equiv_tb.v` **不涉及**；本任务用 elaboration + 读写往返自检

**Interfaces:**
- Produces（后续 Task 依赖的确切名字）：
  - `ntt_BRAM #(parameter ADDR_W = 8) (clk, wen, waddr, din, raddr, dout)`
    —— **单读口**（`rtl/pe1/BRAM.v` 原文就是 6 个端口，**没有** `brsel/brselen/raddr0/raddr1`；
    银行选择与多读口是**核**在例化处铺的，不是 BRAM 自己的端口）。
    只把写死的 `[7:0]` 换成 `[ADDR_W-1:0]`、深度 `[255:0]` 换成 `[0:2**ADDR_W-1]`。
    数据位宽恒 **12**（三档都是 `reg [11:0] blockram`）。
  - `ntt_BROM #(parameter PE_NUMBER = 1, TW_ADDR_W = 9) (clk, raddr, dout)`
    —— `dout` 位宽 = **`12*PE_NUMBER`**（12/48/192，一拍读出一整组蝶形的 twiddle）；
    **三张表内容互不相同**，走 `generate` 逐档放原表（见 Step 5）。
  - **端口名一律不改；模块名一律加 `ntt_` 前缀**（约束 13）

- [x] **Step 1: 先确认三档叶子模块真的逐字节相同**

```bash
cd "C:/Users/l'x/Desktop/FPGA"
for f in butterfly modadd modsub modred modmul intmul dt0 dt1 dt2 dt3 FA HA div2 shiftreg; do
  a=rtl/pe1/$f.v; b=rtl/pe4/$f.v; c=rtl/pe16/$f.v
  s14=$(cmp -s "$a" "$b" && echo same || echo DIFF)
  s416=$(cmp -s "$b" "$c" && echo same || echo DIFF)
  echo "$f.v  pe1-pe4=$s14  pe4-pe16=$s416"
done
```

预期（设计文档 §4.1 已记录，此处复核 —— 2026-09-29 实跑结果已回填）：
大部分 `same/same`；`modred.v` 是 `DIFF/same`、`modsub.v` 是 `same/DIFF`
（都只差 CC0 版权注释头）；`dt0`–`dt3` 四个是 `DIFF/DIFF`（只差**一个空行**，pe1 与 pe16 相同）。

> 实跑确认：**没有任何一处是逻辑差异**。取 pe1 那份即可；
> 注释头不齐的两个（`modred.v` 取 pe4、`modsub.v` 取 pe1）见 Step 3。

**若出现预期外的 DIFF，停下来，先 `diff` 看清差异再决定取哪一份** —— 不要默认取 pe1。

- [x] **Step 2: 建目录，从 pe1 复制一份叶子**

```bash
cd "C:/Users/l'x/Desktop/FPGA"
mkdir -p rtl/ntt_core
for f in butterfly modadd modsub modred modmul intmul dt0 dt1 dt2 dt3 FA HA div2 shiftreg; do
  cp rtl/pe1/$f.v rtl/ntt_core/$f.v
done
ls rtl/ntt_core/

# ⚠️ 立刻改模块名（约束 13）—— 否则新旧同名，后面几步的逐拍对拍根本编不过
cd rtl/ntt_core
for m in butterfly modadd modsub modred modmul intmul dt0 dt1 dt2 dt3 FA HA div2 shiftreg; do
  sed -i "s/\bmodule ${m}\b/module ntt_${m}/" $m.v
done
# 叶子之间若有互相例化，也要一并改
grep -n "^\s*\(butterfly\|modadd\|modsub\|modred\|modmul\|intmul\|dt[0-3]\|FA\|HA\|div2\|shiftreg\)\b" *.v
cd "C:/Users/l'x/Desktop/FPGA"
grep -n "^module" rtl/ntt_core/*.v      # 逐条核对，必须全部带 ntt_ 前缀
```

- [x] **Step 3: 把 `modred.v` 的 CC0 版权头补上**

pe1 的 `modred.v` 缺上游 CC0 注释头，pe4/pe16 有。取 pe4 那份（注释头在），
但**先用 `diff` 确认除了注释头没有别的差异**：

```bash
cd "C:/Users/l'x/Desktop/FPGA"
diff rtl/pe1/modred.v rtl/pe4/modred.v
cp rtl/pe4/modred.v rtl/ntt_core/modred.v
```

预期 `diff` 只输出注释行差异。**若 diff 里出现任何非注释行，停下来报告。**

- [x] **Step 4: 参数化 `BRAM.v`**

先看清三档的差异：

```bash
cd "C:/Users/l'x/Desktop/FPGA"
diff rtl/pe1/BRAM.v rtl/pe4/BRAM.v
diff rtl/pe4/BRAM.v rtl/pe16/BRAM.v
```

已知差异（设计文档 §3.1a）：地址位宽 `[7:0]` / `[5:0]` / `[3:0]`（= `L+1`），
存储深度 `[255:0]` / `[63:0]` / `[15:0]`。**数据位宽三档都是 12，端口三档都是 6 个**
（实核：`rtl/pe1/BRAM.v` 只有 `clk/wen/waddr/din/raddr/dout`）。

改法：以 pe1 那份为底，把模块头改成

```verilog
module ntt_BRAM #(                // ⚠️ 模块名加 ntt_ 前缀（约束 13）
    parameter ADDR_W = 8          // = L+1：pe1→8, pe4→6, pe16→4
)(
    input  wire              clk,
    input  wire              wen,
    input  wire [ADDR_W-1:0] waddr,
    input  wire [11:0]       din,
    input  wire [ADDR_W-1:0] raddr,
    output reg  [11:0]       dout
);
(* ram_style="block" *) reg [11:0] blockram [0:2**ADDR_W-1];
```

**改完确认没有漏网的写死常数**（⚠️ 用 python 查，别用 `grep -c $'\r'` 那类判据）：

```bash
cd "C:/Users/l'x/Desktop/FPGA"
grep -n "\[7:0\]\|\[255:0\]\|\[5:0\]\|\[3:0\]" rtl/ntt_core/BRAM.v
```

预期：无输出。**有裸常数就继续改。**

- [x] **Step 5: 参数化 `BROM.v`**

```bash
cd "C:/Users/l'x/Desktop/FPGA"
diff rtl/pe1/BROM.v rtl/pe4/BROM.v
diff rtl/pe4/BROM.v rtl/pe16/BROM.v
```

⚠️ **`TW_ADDR_W` 三档取 9 / 8 / 7**，这个参数**不接受** `L` 推导 ——
上游是手工挑的 2 的幂（源码注释 "222 is enough" / "86 is enough"）。

⚠️⚠️ **但更重要的是：三张表的「内容」也不同**，而且**不是彼此的打包或连续切片**
（设计文档 §3.3c）。所以不能用「以 pe1 为底」的做法 —— pe1 那张 12 位表**喂不了 pe4/pe16**。

**做法：`generate` 按 `PE_NUMBER` 分三支，各放一份上游原表，逐字提取、不做任何改写。**
表是静态数据，逐字保留即 bit-exact。

**不要手抄**（pe1 388 行 + pe4 228 行 + pe16 92 行 case，手抄必错）。用脚本从上游文件抠：

```bash
cd "C:/Users/l'x/Desktop/FPGA"
PY=$(command -v python3 || command -v python)
"$PY" "C:/Users/l'x/AppData/Local/Temp/gen_brom.py"        # 生成 rtl/ntt_core/BROM.v
"$PY" "C:/Users/l'x/AppData/Local/Temp/verify_brom.py"     # 逐行比对三个分支 vs 上游
```

生成的模块头：

```verilog
module ntt_BROM #(                // ⚠️ 模块名加 ntt_ 前缀（约束 13）
    parameter PE_NUMBER = 1,          // 1 / 4 / 16：决定数据位宽 12*PE_NUMBER 与表内容
    parameter TW_ADDR_W = 9           // ⚠️ 手工选 9/8/7，**不是** L 的函数（设计文档 §3.3）
)(
    input  wire                    clk,
    input  wire [TW_ADDR_W-1:0]    raddr,
    output reg  [12*PE_NUMBER-1:0] dout
);
generate
if (PE_NUMBER == 1) begin : G_TW1
    always @(posedge clk) begin
        case(raddr)   // ← 上游 rtl/pe1/BROM.v 的表，逐字
        ...
        endcase
    end
end else if (PE_NUMBER == 4) begin : G_TW4
    ...上游 rtl/pe4/BROM.v 的表...
end else begin : G_TW16
    ...上游 rtl/pe16/BROM.v 的表...
end
endgenerate
```

⚠️ **`generate` 里没有 `default` 分支** —— 传别的 `PE_NUMBER` 时 `dout` 会悬空且**不报错**。
所以 Step 6 的探针里必须有一条非法 `PE_NUMBER` 的守卫（已写进 `leaf_elab_tb.v`）。

顺手删掉三份里那条挂在死数组上、无任何引用的
`(* rom_style="block" *) reg ... blockrom [...];`（三档都只出现在声明行，已核）——
这是 `logs/` §二 B 里挂着的遗留清理项。生成的 BROM.v 里不再保留它。

- [x] **Step 6: 写叶子探针，三档各跑一次**

> ⚠️ **偏离原计划（已与用户确认按此办）**：原计划写的是一个跑完就删的临时顶
> `rtl/ntt_core/_elab_check.v`。改成**常驻探针** `rtl/probes/leaf_elab_tb.v` ——
> 因为 BROM 的表内容是 Task 1 才发现的第三处真结构分歧，
> 三张表一旦被谁改错、或 generate 分支接错，**编译和综合都不会报错**，
> 只有真的读一次表才知道。这个风险值得一个常驻回归。

探针验四件事（`rtl/probes/leaf_elab_tb.v`，期望值全部手工抄自上游三份 `BROM.v`）：

1. `TW_ADDR_W` 与 `PE_NUMBER` 的搭配（F1，查表断言，**不是**公式）
2. **BROM 三张表的内容** —— 每档抽查 5 个地址（首条 / 3 个中间 / 末条），
   覆盖「全同条 / 部分同 / 全不同」三种形态
3. BRAM 读写往返 + 地址间不串扰
4. **非退化**（约定 4）：统计抽查到的不同 12 位系数值个数，少于 8 个就判失败

```bash
cd "C:/Users/l'x/Desktop/FPGA"
export PATH="/c/iverilog/bin:$PATH"
L=rtl/probes/leaf_elab_tb.v
for cfg in "1 9" "4 8" "16 7"; do
  set -- $cfg
  iverilog -g2005 -DCFG_PE_NUM=$1 -DCFG_TW=$2 -o /tmp/leaf$1.vvp \
    $L rtl/ntt_core/BRAM.v rtl/ntt_core/BROM.v && vvp /tmp/leaf$1.vvp
done
```

预期（2026-09-29 实跑）：

```
PE=1  L=7  TW_ADDR_W=9  BRAM 深度=256  BROM 表宽=12 位   → 抽查到 8 个不同值   PASS
PE=4  L=5  TW_ADDR_W=8  BRAM 深度=64   BROM 表宽=48 位   → 抽查到 15 个不同值  PASS
PE=16 L=3  TW_ADDR_W=7  BRAM 深度=16   BROM 表宽=192 位  → 抽查到 46 个不同值  PASS
```

- [x] **Step 7: 阴性对照 —— 确认断言与守卫真的有分辨力（Review Focus）**

**两条都要跑，缺一条这一步不算完成：**

```bash
cd "C:/Users/l'x/Desktop/FPGA"; export PATH="/c/iverilog/bin:$PATH"

# 对照 1（F1）：PE=4 但 TW_ADDR_W 故意传 9 —— 必须 FAIL
iverilog -g2005 -DCFG_PE_NUM=4 -DCFG_TW=9 -o /tmp/leafbad.vvp \
  rtl/probes/leaf_elab_tb.v rtl/ntt_core/BRAM.v rtl/ntt_core/BROM.v && vvp /tmp/leafbad.vvp

# 对照 2：PE_NUMBER=3（128/3 非整数，且 BROM 的 generate 没有 default）—— 必须 FATAL
iverilog -g2005 -DCFG_PE_NUM=3 -DCFG_TW=9 -o /tmp/leafbad3.vvp \
  rtl/probes/leaf_elab_tb.v rtl/ntt_core/BRAM.v rtl/ntt_core/BROM.v && vvp /tmp/leafbad3.vvp
```

预期（2026-09-29 实跑）：

```
对照 1 → FAIL: PE_NUMBER=4 时 TW_ADDR_W 应为 8，实为 9 —— c_tw/raddr_tw/BROM 会读飞
对照 2 → FATAL: CFG_PE_NUM=3 不是 1/4/16 —— BROM 的 generate 没有 default，dout 会悬空
```

> 对照 1 是 F1 的兜底：`TW_ADDR_W` 手工选，写错会**静默读飞**，
> 所以让它在 **elaboration 期**就炸，而不是等跑波形才发现。
> 注意 `ntt_BROM #(.TW_ADDR_W(9))` 配 PE=4 本身**能编译能跑** —— 这正是需要断言的原因。
>
> 对照 2 是那条 `generate` 没有 `default` 的兜底：不守的话，
> 非法 `PE_NUMBER` 会得到一个 `dout` 恒为 X 的「能跑的」设计。

- [x] **Step 8: 提交**

```bash
cd "C:/Users/l'x/Desktop/FPGA"
git add rtl/ntt_core/ rtl/probes/leaf_elab_tb.v
git commit -m "ntt_core：叶子模块归并 + BRAM/BROM 参数化

叶子模块三档只差空白/注释（14 个文件逐对 cmp 实核，无一处逻辑差异）；
modred.v 取 pe4 那份（pe1 缺 CC0 头）。
BRAM 单读口、数据位宽恒 12、深度 2**ADDR_W。
BROM 数据位宽 = 12*PE_NUMBER；三张表内容互不相同（第三处真结构分歧），
用 generate 逐档放原表，由脚本从上游文件逐字提取 + 逐行比对。
新树模块一律加 ntt_ 前缀（约束 13）—— 否则新旧同名，等价探针编不过。
顺带删掉 BROM.v 里挂在死数组上的 rom_style 属性（三档均无引用）。"
git push
```

---

## Task 2: 参数化 `addressgenerator.v` + 逐拍等价探针

> **这是整份计划里最高风险的一步。** 上游三份是逐档手工调的，
> 参数化的正确性判据不是「看起来对」，而是「和旧的逐拍一模一样」。

**Files:**
- Create: `rtl/ntt_core/addressgenerator.v`
- Create: `rtl/probes/ag_equiv_tb.v`
- Modify: `rtl/probes/run_probes.sh`, `rtl/probes/README.md`

**Interfaces:**
- Consumes: Task 1 的 `ntt_BRAM` / `ntt_BROM` 参数名（本任务不用它们，但要保持端口名一致）
- Produces: `ntt_addressgenerator #(parameter L = 7, TW_ADDR_W = 9)`，
  端口名**与 `rtl/pe1/addressgenerator.v` 完全一致**（**模块名不同**，见约束 13），
  **含** pe1 独有的两个输出 `c_loop_pwm[L-1:0]` 与 `raddr_b[L-1:0]`。
  pe4/pe16 档这两个输出接不出线也无所谓 —— **端口一律保留，不要按档裁掉**，
  这样顶层的例化不用写分支。

- [x] **Step 1: 先写失败的等价探针**

新建 `rtl/probes/ag_equiv_tb.v`。**核心手法：把旧的与新的例化在同一个 testbench 里，
接同一组激励，逐拍比对全部输出。**

```verilog
`timescale 1ns/1ps
// 三档各跑一次（旧文件按档换；pe1 那份多两个输出，要额外 -DHAS_PE1_PORTS）：
//   iverilog -g2005 -DCFG_L=7 -DHAS_PE1_PORTS -o ag7.vvp rtl/probes/ag_equiv_tb.v rtl/pe1/addressgenerator.v  rtl/ntt_core/addressgenerator.v && vvp ag7.vvp
//   iverilog -g2005 -DCFG_L=5                 -o ag5.vvp rtl/probes/ag_equiv_tb.v rtl/pe4/addressgenerator.v  rtl/ntt_core/addressgenerator.v && vvp ag5.vvp
//   iverilog -g2005 -DCFG_L=3                 -o ag3.vvp rtl/probes/ag_equiv_tb.v rtl/pe16/addressgenerator.v rtl/ntt_core/addressgenerator.v && vvp ag3.vvp
//
// ⚠️ 这条能成立的前提是约束 13：新树模块改名为 ntt_addressgenerator。
//    否则两个同名模块会 "module already declared"，根本编不过。
module ag_equiv_tb;
    localparam integer LL    = `CFG_L;    // 折叠参数 L = 7/5/3（**不是** PE_NUMBER）
    localparam integer PW    = LL;        // c_loop 位宽 = L；raddr/waddr 位宽 = L+1
    localparam integer TW    = (LL==7) ? 9 : (LL==5) ? 8 : 7;   // 手工选，见设计文档 §3.3
    localparam integer MAXCC = 20000;     // 护栏（约束 3）

    reg clk = 0, reset = 1;
    always #5 clk = ~clk;

    reg start_fntt = 0, start_pwm2 = 0, start_intt = 0;
    wire [PW:0]   o_raddr0, o_raddr1, o_waddr0, o_waddr1;
    wire [PW:0]   n_raddr0, n_raddr1, n_waddr0, n_waddr1;
    wire [TW-1:0] o_tw, n_tw;
    wire [2:0]    o_stage, o_stage_pwm, n_stage, n_stage_pwm;
    wire          o_wen0,o_wen1,o_bs0,o_bs1,o_bse0,o_bse1;
    wire          n_wen0,n_wen1,n_bs0,n_bs1,n_bse0,n_bse1;
    wire [PW-1:0] o_loop_pwm, o_raddr_b, n_loop_pwm, n_raddr_b;   // pe1 独有；其余档悬空

    addressgenerator u_old (                    // ← 上游那份（只读）
        .clk(clk), .reset(reset),
        .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
        .ct(3'd0), .pwm(3'd0),
        .raddr0(o_raddr0), .raddr1(o_raddr1), .waddr0(o_waddr0), .waddr1(o_waddr1),
        .wen0(o_wen0), .wen1(o_wen1),
        .brsel0(o_bs0), .brsel1(o_bs1), .brselen0(o_bse0), .brselen1(o_bse1),
        .stage_count(o_stage), .stage_count_pwm(o_stage_pwm),
`ifdef HAS_PE1_PORTS
        .c_loop_pwm(o_loop_pwm), .raddr_b(o_raddr_b),
`endif
        .raddr_tw(o_tw)
    );

    ntt_addressgenerator #(.L(PW), .TW_ADDR_W(TW)) u_new (   // ← 新写的参数化版
        .clk(clk), .reset(reset),
        .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
        .ct(3'd0), .pwm(3'd0),
        .raddr0(n_raddr0), .raddr1(n_raddr1), .waddr0(n_waddr0), .waddr1(n_waddr1),
        .wen0(n_wen0), .wen1(n_wen1),
        .brsel0(n_bs0), .brsel1(n_bs1), .brselen0(n_bse0), .brselen1(n_bse1),
        .stage_count(n_stage), .stage_count_pwm(n_stage_pwm),
        .c_loop_pwm(n_loop_pwm), .raddr_b(n_raddr_b),
        .raddr_tw(n_tw)
    );

    integer cc = 0, errors = 0;
    reg [8*8-1:0] seg = "reset";

    task chk; input [8*8-1:0] what; input [31:0] ov; input [31:0] nv;
        begin
            if (ov !== nv) begin
                if (errors < 20)
                    $display("  x [%0s] cc=%0d %0s: old=%h new=%h", seg, cc, what, ov, nv);
                errors = errors + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        cc = cc + 1;
        if (cc > MAXCC) begin
            $display("FAIL: 超时（%0d 拍）—— 多半是 FSM 卡住了", cc); $finish;
        end
        if (!reset) begin
            chk("raddr0",   o_raddr0, n_raddr0);
            chk("raddr1",   o_raddr1, n_raddr1);
            chk("waddr0",   o_waddr0, n_waddr0);
            chk("waddr1",   o_waddr1, n_waddr1);
            chk("raddr_tw", {16'd0,o_tw},     {16'd0,n_tw});
            chk("wen",      {31'd0,o_wen0},   {31'd0,n_wen0});
            chk("wen1",     {31'd0,o_wen1},   {31'd0,n_wen1});
            chk("brsel",    {31'd0,o_bs0},    {31'd0,n_bs0});
            chk("brsel1",   {31'd0,o_bs1},    {31'd0,n_bs1});
            chk("brselen",  {31'd0,o_bse0},   {31'd0,n_bse0});
            chk("brselen1", {31'd0,o_bse1},   {31'd0,n_bse1});
            chk("stage",    {29'd0,o_stage},  {29'd0,n_stage});
            chk("stagepwm", {29'd0,o_stage_pwm}, {29'd0,n_stage_pwm});
`ifdef HAS_PE1_PORTS
            chk("c_loop_pwm", {25'd0,o_loop_pwm}, {25'd0,n_loop_pwm});
            chk("raddr_b",    {25'd0,o_raddr_b},  {25'd0,n_raddr_b});
`endif
        end
    end

    // 激励：reset → FNTT → PWM2 → INTT，每段给足拍数
    // ⚠️ 不要等 done —— AG 没有 done 输出（约束 3：也不能写无界 while）
    localparam integer SEG_CC = 3000;
    initial begin
        #20 reset = 0;

        seg = "FNTT"; #10 start_fntt = 1; #10 start_fntt = 0;
        repeat (SEG_CC) @(posedge clk);

        seg = "PWM2"; #10 start_pwm2 = 1; #10 start_pwm2 = 0;
        repeat (SEG_CC) @(posedge clk);

        seg = "INTT"; #10 start_intt = 1; #10 start_intt = 0;
        repeat (SEG_CC) @(posedge clk);

        if (errors == 0) $display("PASS: L=%0d 逐拍等价，共 %0d 拍", LL, cc);
        else             $display("FAIL: L=%0d 共 %0d 处不一致", LL, errors);
        $finish;
    end
endmodule
```

- [x] **Step 2: 跑探针，确认它现在**必然失败**（新模块还不存在）

```bash
cd "C:/Users/l'x/Desktop/FPGA"
export PATH="/c/iverilog/bin:$PATH"
iverilog -g2005 -DCFG_L=7 -DHAS_PE1_PORTS -o /tmp/ag.vvp rtl/probes/ag_equiv_tb.v \
  rtl/pe1/addressgenerator.v rtl/ntt_core/addressgenerator.v
```

预期：**报 `addressgenerator` 找不到 / 文件不存在**。
这一步是确认探针本身能编、能跑 —— 不是确认业务逻辑。

- [x] **Step 3: 写参数化的 `addressgenerator.v`**

以 **`rtl/pe1/addressgenerator.v` 为底**（它是唯一功能验证过的配置），
把写死的常数逐条换成设计文档 §3.1 的统一式。
**逐块照抄结构，只换常数** —— 不要重写状态机。

模块头：

```verilog
module ntt_addressgenerator #(    // ⚠️ 模块名加 ntt_ 前缀（约束 13）
    parameter L         = 7,      // = $clog2(128/PE_NUMBER)：pe1→7, pe4→5, pe16→3
    parameter TW_ADDR_W = 9       // BROM 地址位宽：9/8/7。**推不出公式，手工选**（§3.3）
)(
    input  wire          clk, reset,
    input  wire          start_fntt, start_pwm2, start_intt,
    input  wire [2:0]    ct, pwm,
    output reg  [L:0]    raddr0, raddr1, waddr0, waddr1,
    output reg           wen0, wen1, brsel0, brsel1, brselen0, brselen1,
    output reg  [2:0]    stage_count, stage_count_pwm,
    output wire [L-1:0]  c_loop_pwm,          // pe1 独有；其余档保留但恒 0
    output wire [L-1:0]  raddr_b,             // pe1 独有；其余档保留但恒 0
    output wire [TW_ADDR_W-1:0] raddr_tw      // 位宽跟着 TW_ADDR_W 走，**不是** L
);
```

⚠️ **`raddr_tw` 的位宽不能用 `L` 表示**（设计文档 §3.3）。两种做法，**取后者**：

- ❌ `output wire [L+1:0] raddr_tw` —— 对 pe1 恰好是 9，对 pe4 是 7（应为 8）→ **错**
- ✅ 模块再加一个参数 `parameter TW_ADDR_W = 9`，端口写 `[TW_ADDR_W-1:0]`，
  由上层按档传 9 / 8 / 7（**已写进上面的模块头**）

⚠️ 上层传错这一档，**不会报错，只会静默读飞** —— 所以 Task 1 的 `_elab_check.v`
里有一条查表断言兜着（见 Task 1 Step 6/7）。

**各 always 块的替换对照表**（左边是 pe1 原文，右边是统一式）：

| 原文（pe1） | 统一式 | 位置 |
|---|---|---|
| `raddr[6:0]` / `waddre[7:0]` 等位宽 | `[L-1:0]` / `[L:0]` | 全文 |
| `c_loop == 7'd127` | `c_loop == {L{1'b1}}` | 全部计数器块 |
| `c_loop == 5'd31`（pe4） | 同上 | — |
| `if(c_stage == 3'd6)` FNTT 读 | `if(c_stage >= L-1)` | `:228` |
| `(3'd6-c_stage)` / `(3'd7-c_stage)` FNTT 读 | `(L-1-S)` / `(L-S)` | `:231-233` |
| `if(c_stage == 3'd6)` FNTT 写 | `if(c_stage >= ((L<6)?L:6))` | `:313` |
| `(3'd7-c_stage)` / `(3'd6-c_stage)` FNTT 写 | `(L-S)` / `(L-1-S)` | `:318-319` |
| INTT 读**前置恒等** | 新增 `if(c_stage < 7-L)` 分支 | `:240` 之前 |
| `(c_stage+3'd1)` / `(c_stage+3'd2)` INTT 读 | `(S+L-6)` / `(S+L-5)` | `:243-245` |
| INTT 写**前置恒等** | 新增 `if(c_stage < 6-L)` 分支 | `:333` 之前 |
| `(c_stage+3'd1)` / `(c_stage+3'd2)` INTT 写 | `(S+L-6)` / `(S+L-5)` | `:338-339` |
| `c_tw <= 9'd127 / 9'd254` | `T(L)` / `2*T(L)` | `:119` |
| `waddro[6:0] == 7'd127`（银行位） | `waddro[L-1:0] == {L{1'b1}}` | `:283` |
| `c_tw` 的 `case(c_stage)` | 按 §3.1(e) 的 L 式 | `:137-145` / `:170-178` |

`T(L)` 用函数写，别手算：

```verilog
function integer T;                    // twiddle 前向初值
    input integer LL;
    integer s;
    begin
        T = 0;
        for (s = 0; s <= 6; s = s + 1)
            T = T + ((s < LL) ? ((1<<s) - 1) : ((1<<LL) - 1));
        T = T + 7;
    end
endfunction
```

> 校验：`T(7)=127`、`T(5)=95`、`T(3)=39` —— 与三份源码里写死的常数一致
> （`rtl/pe1/addressgenerator.v:119`、`rtl/pe4/…:129`、`rtl/pe16/…:152`）。

**两处必须走 `generate` 分支**（设计文档 §3.2 / §5）：

```verilog
// （1）PWM2 地址：pe1 是双读口 + c_pwm 调制；PE>=4 退化为恒等扫描
generate
  if (L == 7) begin : G_PWM2_PE1            // ⚠️ 判据用 L 还是 PE_NUMBER，见下
    // 照抄 rtl/pe1/addressgenerator.v:236-238, 262-263, 325-331
  end else begin : G_PWM2_WIDE
    // 照抄 rtl/pe4/addressgenerator.v:262-263, 342-344
  end
endgenerate
```

> ⚠️ **分支判据用 `L == 7` 而不是 `PE_NUMBER == 1`。**
> `addressgenerator` 只收 `L`，收不到 `PE_NUMBER`。
> 若日后要支持 `PE_NUMBER = 2`（`L = 6`），这一支会自动落到 `WIDE` 分支 ——
> 那正是我们想要的（PE≥4 的恒等扫描对 L=6 同样成立），但**本轮不验证 L=6**，
> 文档里要写清这是「未验证的推断」。

```verilog
// （2）FSM 的 stall 状态：见设计文档 §5.2 的表逐档抄
//     pe1（L==7）：无 stall 状态，4 态 2 位
//     pe4（L==5）：STL0→FNTT、STL1→INTT，各 1 拍
//     pe16（L==3）：STL0/STL1/STL2，STL0/STL2 各 2 拍（靠 c_stl 相位计数器），STL1 1 拍
//     ⚠️ pe16 的 INTT 里 c_stage 与 c_loop 的 stall 条件**不同**，照抄别统一
```

- [x] **Step 4: 三档各跑一次等价探针**

```bash
cd "C:/Users/l'x/Desktop/FPGA"
export PATH="/c/iverilog/bin:$PATH"
iverilog -g2005 -DCFG_L=7 -DHAS_PE1_PORTS -o /tmp/ag7.vvp rtl/probes/ag_equiv_tb.v rtl/pe1/addressgenerator.v  rtl/ntt_core/addressgenerator.v && vvp /tmp/ag7.vvp
iverilog -g2005 -DCFG_L=5                 -o /tmp/ag5.vvp rtl/probes/ag_equiv_tb.v rtl/pe4/addressgenerator.v  rtl/ntt_core/addressgenerator.v && vvp /tmp/ag5.vvp
iverilog -g2005 -DCFG_L=3                 -o /tmp/ag3.vvp rtl/probes/ag_equiv_tb.v rtl/pe16/addressgenerator.v rtl/ntt_core/addressgenerator.v && vvp /tmp/ag3.vvp
```

预期：三条都 `PASS`，且**拍数相同**（新旧跑一样多拍）。

⚠️ **`-DCFG_L=7` 那一条必须带 `-DHAS_PE1_PORTS`** —— pe1 的 AG 多两个输出
（`c_loop_pwm` / `raddr_b`），不带这个宏旧那侧的例化会缺端口。pe4/pe16 **不能**带。

- [x] **Step 5: 阴性对照 —— 确认探针有分辨力**

故意把新模块里 FNTT 读地址的 `L-1-S` 改成 `L-2-S`，重跑一次 pe1：

```bash
iverilog -g2005 -DCFG_L=7 -DHAS_PE1_PORTS -o /tmp/ag7.vvp rtl/probes/ag_equiv_tb.v rtl/pe1/addressgenerator.v rtl/ntt_core/addressgenerator.v && vvp /tmp/ag7.vvp
```

预期：**必须 FAIL**。若仍 PASS，说明探针没有分辨力 —— **停下来修探针**，别继续。
对照做完**把那一行改回去**，再重跑确认恢复 PASS。

（本项目惯例：阴性对照是「验证通过」的成立条件之一。）

- [x] **Step 6: F2 / F3 的专测（Review Focus）**

`ag_equiv_tb.v` 的逐拍比对**已经覆盖** F2 与 F3（它们在同一个 FSM 里，任何差异都会改到
`waddr0/1` 或 `stage_count`）。但**要在探针里加一条显式的段标记**，
让失败时报出「错在哪一段」而不是只报拍号：

```verilog
reg [127:0] seg = "reset";
// 发 start_fntt 前： seg = "FNTT";  发 start_pwm2 前： seg = "PWM2";  发 start_intt 前： seg = "INTT";
// check 失败时 $display 里带上 seg
```

再补一条 F2 的阴性对照：**改新模块**（不是 pe16 —— 约束 5 规定上游三档只读）
里 pe16 分支的 INTT stall 条件一处，重跑 → 必须 FAIL；改回 → PASS。

⚠️ 必须用 `-DCFG_L=3`（pe16 档）跑，改动才在编译路径上 —— pe1 档走的是另一个 generate 分支。

- [x] **Step 7: 把探针接进 `run_probes.sh`，提交**

在 `rtl/probes/run_probes.sh` 末尾追加三档调用，输出格式与现有 ①②③④⑤ 保持一致
（`✅` / `❌` 前缀，见现有脚本）。同步更新 `rtl/probes/README.md`。

```bash
cd "C:/Users/l'x/Desktop/FPGA"
sh rtl/probes/run_probes.sh        # 全绿
git add rtl/ntt_core/addressgenerator.v rtl/probes/
git commit -m "addressgenerator 参数化（L）+ 逐拍等价探针

以 pe1 为底，把写死的常数换成 L 的表达式。两处走 generate：
PWM2 地址、FSM stall。新增 ag_equiv_tb.v：把旧三份与新模块
例化在一起、接同一激励、逐拍比对全部输出（含 raddr_tw 与
stage_count）。三档全 PASS，并做了阴性对照确认探针有分辨力。"
git push
```

---

## Task 3: 参数化核 `KyberHPMNTT.v` + 逐拍等价探针

**Files:**
- Create: `rtl/ntt_core/KyberHPMNTT.v`
- Create: `rtl/probes/core_equiv_tb.v`
- Modify: `rtl/probes/run_probes.sh`, `rtl/probes/README.md`

**Interfaces:**
- Consumes: Task 2 的 `ntt_addressgenerator #(.L, .TW_ADDR_W)`（端口名照旧，模块名带前缀）
- Produces: `KyberHPMNTT #(parameter PE_NUMBER = 1)`，
  端口与 `rtl/pe1/KyberHPM1PE.v` **同名同序**，只有 `din`/`dout` 位宽写成 `[12*PE_NUMBER-1:0]`

- [x] **Step 1: 写失败的等价探针 `core_equiv_tb.v`**

手法同 Task 2：旧的 `KyberHPM{1,4,16}PE` 与新的 `KyberHPMNTT` 同激励、逐拍比对。

```verilog
`timescale 1ns/1ps
module core_equiv_tb;
    localparam PE = `CFG_PE_NUM;       // 1 / 4 / 16
    localparam DW = 12*PE;
    localparam MAXCC = 200000;         // 护栏
    reg clk = 0, reset = 1;
    always #5 clk = ~clk;
    reg [DW-1:0] din = 0;
    reg lf=0, li=0, rf=0, ri=0, ra=0, rb=0, sab=0, sf=0, sp=0, si=0;
    wire [DW-1:0] od, nd;
    wire odone, ndone;
    integer cc = 0, errors = 0;
    // 每一拍比对 dout 与 done
    // 激励：装载 A → FNTT → 读出；装载 A/B → PWM2 → 读出；装载 → INTT → 读出
    // ⚠️ 装载必须**连续灌满**（H1 §四：没有 data-valid 选通，中途不能停）
endmodule
```

- [x] **Step 2: 跑一次确认它现在失败**（新模块不存在）

```bash
cd "C:/Users/l'x/Desktop/FPGA"; export PATH="/c/iverilog/bin:$PATH"
iverilog -g2005 -o /tmp/core.vvp -DCFG_PE_NUM=1 rtl/probes/core_equiv_tb.v \
  rtl/pe1/KyberHPM1PE.v rtl/ntt_core/KyberHPMNTT.v
```
预期：报文件不存在。

- [x] **Step 3: 写 `KyberHPMNTT.v`**

以 `rtl/pe1/KyberHPM1PE.v` 为底，把各处写死的常数换成 `PE_NUMBER` / `L` 派生式。
**重点在例化处**（上游三档的例化是位置连接、端口数还不一样）：

```verilog
localparam L = $clog2(128 / PE_NUMBER);
localparam TW_ADDR_W = (PE_NUMBER == 1) ? 9 : (PE_NUMBER == 4) ? 8 : 7;

ntt_addressgenerator #(.L(L), .TW_ADDR_W(TW_ADDR_W)) ag (
    .clk(clk), .reset(reset),
    .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
    .ct(ct), .pwm(pwm),
    .raddr0(raddr0), .raddr1(raddr1), .waddr0(waddr0), .waddr1(waddr1),
    .wen0(wen0), .wen1(wen1),
    .brsel0(brsel0), .brsel1(brsel1), .brselen0(brselen0), .brselen1(brselen1),
    .stage_count(stage_count), .stage_count_pwm(stage_count_pwm),
    .c_loop_pwm(c_loop_pwm), .raddr_b(raddr_b), .raddr_tw(raddr_tw)
);
```

⚠️ **改用命名连接**（上游是位置连接）。理由：参数化后端口数在档间不再变化，
但位置连接在 15+ 端口上极易错位，而错位恰恰是「编译能过、行为全错」的那类 bug。

**F5 的非法参数守卫**（Review Focus）—— 加在模块顶部：

```verilog
initial begin
    if (128 % PE_NUMBER != 0 || (128/PE_NUMBER) & ((128/PE_NUMBER)-1)) begin
        $display("FATAL: PE_NUMBER=%0d 不是 128 的 2 的幂次约数，L 无意义", PE_NUMBER);
        $finish;
    end
end
```

- [x] **Step 4: 三档各跑等价探针**

```bash
cd "C:/Users/l'x/Desktop/FPGA"; export PATH="/c/iverilog/bin:$PATH"
CORE="$(ls rtl/ntt_core/*.v | grep -v _top)"   # ⚠️ 双引号 —— 单引号不会展开
iverilog -g2005 -o /tmp/c1.vvp  -DCFG_PE_NUM=1  rtl/probes/core_equiv_tb.v rtl/pe1/KyberHPM1PE.v   $CORE && vvp /tmp/c1.vvp
iverilog -g2005 -o /tmp/c4.vvp  -DCFG_PE_NUM=4  rtl/probes/core_equiv_tb.v rtl/pe4/KyberHPM4PE.v   $CORE && vvp /tmp/c4.vvp
iverilog -g2005 -o /tmp/c16.vvp -DCFG_PE_NUM=16 rtl/probes/core_equiv_tb.v rtl/pe16/KyberHPM16PE.v $CORE && vvp /tmp/c16.vvp
```

预期：三档 `PASS`。

> ⚠️ **核的探针必须排除顶层** —— 用 `$(ls rtl/ntt_core/*.v | grep -v _top)`，
> 不要裸写 `rtl/ntt_core/*.v`。顶层的探针（Task 4 / Task 6）反过来**要包含** `_top`。
> 两种写法在各自的文件里都成立，别互相"统一"掉。

- [x] **Step 5: F5 的非法参数用例（Review Focus）**

```bash
# PE_NUMBER=3：128/3 不是整数 → 必须在 elaboration 期炸，而不是静默算错
iverilog -g2005 -o /tmp/cbad.vvp -DCFG_PE_NUM=3 \
  rtl/probes/core_equiv_tb.v $(ls rtl/ntt_core/*.v | grep -v _top) 2>&1 | head -5
```

预期：报错或 `$finish` 打出 `FATAL`。
**⚠️ 若它编译通过且跑出了「结果」，说明守卫没生效 —— 必须修到它会炸。**

- [x] **Step 6: 提交**

```bash
git add rtl/ntt_core/KyberHPMNTT.v rtl/probes/
git commit -m "核 KyberHPMNTT 参数化 + 逐拍等价探针

以 pe1 为底，例化改命名连接。含非法 PE_NUMBER 的 elaboration 守卫。"
git push
```

---

## Task 4: 固定 12 位接口的 `KyberHPMNTT_top.v`

**Files:**
- Create: `rtl/ntt_core/KyberHPMNTT_top.v`
- Create: `rtl/probes/top_behavior_tb.v`

**Interfaces:**
- Consumes: Task 3 的 `KyberHPMNTT #(.PE_NUMBER)`
- Produces: `KyberHPMNTT_top #(parameter PE_NUMBER = 1)`，外部端口
  **与 `rtl/pe1/KyberHPM1PE_top.v` 同名**，但 `din`/`dout` 固定 `[11:0]`
  （**三档永远一样**）—— 这就是把 pe16 的 397 个引脚压到 37 个的那一层

- [x] **Step 1: 写失败的对外行为探针**

```verilog
`timescale 1ns/1ps
module top_behavior_tb;
    localparam PE = `CFG_PE_NUM;
    localparam MAXCC = 200000;
    reg clk = 0, reset = 1;
    always #5 clk = ~clk;
    reg [11:0] din;
    reg lf=0, li=0, rf=0, ri=0, ra=0, rb=0, sab=0, sf=0, sp=0, si=0;
    wire [11:0] dout;  wire done;
    KyberHPMNTT_top #(.PE_NUMBER(PE)) uut (...);

    // ① 装载必须刚好 256 拍（三档都一样）
    // ② read_* 之后第 5 拍出第一个有效 dout（_top 的两级寄存，见 H1 §二）
    // ③ 有效 dout 恰好 256 拍（第 257 拍是越界回卷，要丢弃）
    // ④ done 相对 start_* 的拍数 = CC+3（H1 §二的表）
endmodule
```

- [x] **Step 2: 跑一次确认失败**

```bash
cd "C:/Users/l'x/Desktop/FPGA"; export PATH="/c/iverilog/bin:$PATH"
iverilog -g2005 -o /tmp/t1.vvp -DCFG_PE_NUM=1 rtl/probes/top_behavior_tb.v rtl/ntt_core/KyberHPMNTT_top.v 2>&1 | head -3
```
预期：报文件不存在。

- [x] **Step 3: 写序列化器**

核心是**攒够 `PE_NUMBER` 个系数再喂核一拍**：

```verilog
// 装载：外部每拍一个 12 位系数，攒 PE_NUMBER 个组成一拍宽数据
//   ⚠️ 切片方向（H1 §五 实测）：**最高**切片 = 本拍**最低**下标
//       din_core[12*(PE-1-j) +: 12] = coeff[k*PE + j]
//   PE_NUMBER==1 时退化为直通：din_core = din
// 读出：反向拆开，每拍吐一个 12 位
```

- [x] **Step 4: F4 的直通与非直通两组用例（Review Focus）**

**这是 F4 的专测。** 三档喂**同一串** 12 位激励，外部行为必须**完全一致**
（只有 `done` 的拍数不同）：

```bash
for n in 1 4 16; do
  iverilog -g2005 -o /tmp/t$n.vvp -DCFG_PE_NUM=$n rtl/probes/top_behavior_tb.v rtl/ntt_core/*.v && vvp /tmp/t$n.vvp
done
```

预期：三档的 `dout` 序列**逐位相同**（只有 `done` 的拍数不同）。

`done` 相对 `start_*` 的拍数 = **`CC + 3`**（`_top` 比核多两级寄存，
见 `rtl/H1_port_spec.md` §二 的「用 `_top` 还是用核」表）：

| | FNTT | PWM2 | INTT |
|---|---:|---:|---:|
| pe1 | 907 | 650 | 907 |
| pe4 | 235 | 170 | 236 |
| pe16 | 72 | 50 | 74 |

> ⚠️ **别把 `CC+1` 当成 `_top` 的值。** H1 §五 那张表是**核**（`KyberHPM1PE`）的。
> pe1 `_top` 的 FNTT 实测 `done_start_delta = 907`、`first_dout = read+5`，
> 与 `904+3` 一致（`rtl/probes/pe1_timing_tb.v` 的 ② 输出）。

> 再加一条 pe1 专属对照：把上游 `KyberHPM1PE_top` 与新的 `KyberHPMNTT_top #(.PE_NUMBER(1))`
> 并排例化、同激励、逐拍比对 —— pe1 是唯一功能验证过的配置，**它必须一点不变**（R1）。

- [x] **Step 5: 提交**

```bash
git add rtl/ntt_core/KyberHPMNTT_top.v rtl/probes/top_behavior_tb.v
git commit -m "KyberHPMNTT_top：固定 12 位接口 + 核外序列化

三档对外接口完全一致（din/dout 恒 12 位），pe16 的引脚从 397 降到 37。
PE_NUMBER=1 时序列化器是直通，pe1 行为逐拍不变。"
git push
```

---

## Task 5: 三档周期数探针（判据 2）

**Files:**
- Modify: `rtl/probes/run_probes.sh`, `rtl/probes/README.md`

**Interfaces:**
- Consumes: Task 4 的 `KyberHPMNTT_top`
- Produces: 一张三档 `CC` 实测表（写进 `rtl/folding_param_design.md` §一 的判据 2 表）

- [x] **Step 1: 在 `run_probes.sh` 里加三档周期数输出**

复用 `top_golden_tb.v` 的格式（新增 `-DWITH_INTT` 一条腿），段 ⑨ 末尾统一打印
FNTT / PWM2 / INTT 三条路的三档 `done − start − 3`，并直接和下表比对。
本步实际只新增了 **INTT 一格** —— FNTT / PWM2 在 Task 4 的 `-DWITH_PWM2` 那趟里
已经从顶层量到过。

- [x] **Step 2: 与上游实测值逐个对齐**

| | FNTT_CC | PWM2_CC | INTT_CC |
|---|---:|---:|---:|
| pe1 | 904 | 647 | 904 |
| pe4 | 232 | 167 | 233 |
| pe16 | 69 | 47 | 71 |

**实测 12 格全中**（段 ⑨ 每次跑自动重验，任一格不符即打 `❌ 判据 2 未通过`）。
FNTT 在两趟 build 里各量一次，两处一致 —— 表内部的交叉验证。

- [x] **Step 3: 提交**

```bash
git add rtl/probes/
git commit -m "三档周期数探针：CC 与上游逐档对齐（判据 2）"
git push
```

---

## Task 6: 三档功能对拍（判据 3）

**Files:**
- Create: `rtl/probes/ntt_func_tb.v`
- Modify: `rtl/probes/run_probes.sh`

**Interfaces:**
- Consumes: Task 4 的 `KyberHPMNTT_top`；**只读**引用 `refsim/batch/ntt_batch_in.txt` / `ntt_batch_exp.txt`
- Produces: 三档各 4096/4096 的对拍结果

- [x] **Step 1: 先统计向量的非退化程度（约束 4）**

实测（段 ⑩ 每次跑都重印）：FNTT / INTT / PWM2 三个期望向量分别有
**2374 / 2355 / 2371** 个不同值 / 4096，零系数各 1~3 个 —— 远在退化线以上。

- [x] **Step 2: 写功能对拍 testbench** —— 见下方「实施记录」
- [x] **Step 3: 三档各跑一次，均须 4096/4096** —— **3 个运算 × 3 档 = 9 格全中**
- [x] **Step 4: 提交**

### 实施记录（2026-09-29）

**做法**：新建 `rtl/probes/ntt_func_tb.v`，16 组向量全跑（4096 系数），判「**多重集相等**」；
读出顺序不写进判据，而是单独量出来印在右边一列。装载协议写在 TB 的 `DEF_MODE` 里。

**判据 3 实测**：

| 运算 | pe1 | pe4 | pe16 | 读出顺序 |
|---|---|---|---|---|
| FNTT | ✅ 4096 | ✅ 4096 | ✅ 4096 | pe1 = σ｜pe4/pe16 = 自然序 |
| INTT | ✅ 4096 | ✅ 4096 | ✅ 4096 | 三档都是 τ |
| PWM2 | ✅ 4096 | ✅ 4096 | ✅ 4096 | 三档都是 σ |

**这一步踩到的坑（已写进 `probes/README.md` 与 `H1_port_spec.md` §五）**：

1. **协议按 (运算, 折叠度) 分档**。第一版照抄 pe1 的 `pwm2_batch_tb.v` 去驱动 pe4/pe16，
   拿到 **22/4096**（= 随机命中），看着像 RTL 挂了 —— 其实只是装载顺序不同：
   pe1 的 PWM2 用 `_i` + σ，pe4/pe16 用 `_i` + **自然序**。扫一遍两个候选就分出来了。
   阴性对照留在段 ⑩ 末尾（把顺序拨错，多重集必须塌到 ~22/4096）。
2. **上游只在 pe1 上按运算拆过 bench**（`_FNTT`/`_INTT`/`_PWM2`），pe4/pe16 只有
   `_ALL_FULL`/`_ALL_HALF`。所以 pe4/pe16 的协议**没有上游文档可抄**，只能扫。
3. **pe1 是唯一的自检锚**：pe1 三处的读出顺序必须和 B 的 bench 逐字一致，
   段 ⑩ 单独打 `校准 ✅`。没有它，「4096/4096」可能只是自己跟自己对上了。
4. 向量文件按运算**分开命名**。原先三个运算共用一个文件名靠「跑之前重铺一遍」，
   分析脚本一读就串味（拿 pwm2 的期望去判 FNTT）。

**仍未覆盖**：完整乘法（FNTT→PWM2→INTT）端到端；PWM2 两 bank 装**不同**数据的
情形（现有黄金向量 a == b，这一格实际是平方）。

```bash
cd "C:/Users/l'x/Desktop/FPGA"
python3 -c "
import collections
v=[l.strip() for l in open('refsim/batch/ntt_batch_in.txt')][:4096]
print('总系数', len(v), '不同值', len(set(v)))
"
```
预期：4096 个系数、**2000+ 个不同值**。若不同值很少，说明向量是退化的，**换一组再跑**。

- [ ] **Step 2: 写功能对拍 testbench**

判据用「**多重集合相等**」（`rtl/H1_port_spec.md` §八 的手法）：
装载顺序与读出顺序分开判，不互相污染。

**Files（实际）:**
- Create: `rtl/probes/ntt_func_tb.v`
- Modify: `rtl/probes/run_probes.sh`（段 ⑩）、`rtl/probes/README.md`

⚠️ **pe4 / pe16 此前从未做过功能对拍**（`logs/` 里的已知缺口）——
本次首次跑通，结论已回填进 `logs/` 与 `H1_port_spec.md` §五。

---

## Task 7: 三档 Vivado 综合与引脚预算（判据 1）

**Files:**
- Modify: `rtl/vivado/run_folding_sweep.sh`（指向新树）
- Modify: `rtl/vivado/折叠度对比表.md`（补新树一列）

- [x] **Step 1: 改扫描脚本指向 `rtl/ntt_core/`，三档各综合一次**

⚠️ **Vivado 必须从 `C:\fpga_work\` 启动**（仓库路径含撇号）。
脚本本身已有重试（`R5` 综合抖动）。

- [x] **Step 2: 抄出 Bonded IOB，确认三档都 ≤ 125**

预期：**三档都是 37**（13 控制 + 24 数据）。
这是本轮最直观的成果 —— pe16 从 **397** 降到 **37**。

- [x] **Step 3: 记录资源与 Fmax**

把三档的 LUT / FF / DSP / RAMB18 / WNS / Fmax 抄进 `折叠度对比表.md`，
与上游三档并排对比（**上游那三列留着**，是「优化前后对比表」——报告 §3.3.5.3 要）。

- [x] **Step 4: 提交**

```bash
git add rtl/vivado/
git commit -m "三档综合：引脚 397→37，资源与频率记录（判据 1）"
git push
```

### 实施记录（2026-09-29）

**判据 1 通过。** 三档 Bonded IOB 实测**都是 37**，且**三档都布完线** ——
上游 pe16 是 397，在 `Phase 1.2 IO Placement` 就失败，所以这是 pe16 第一次在
7020 上布完线。37 = 12 控制 + 1 时钟 + 12 `din` + 12 `dout`（**端口数与折叠度无关**，
这正是收窄接口换来的）。逐档数字见 `折叠度对比表.md` §9.1。

**非退化证据**：DSP 精确 = 1 / 4 / 16（蝶形数）；LUT 727 → 2000 → 8922；
FF 388 → 880 → 2933，逐档单调。

**两条实测带出的结论（原计划没预料到）：**

1. ⚠️ **「量的是核还是顶层」是两个不同的边界。**
   上游那三份已提交报告量的是**核**（`KyberHPMNPE`）；本轮参数化版量的是**顶层**
   （含 12 位串行化的外壳）。IOB 两边一样（上游 `_top` 不改端口位宽），
   但 LUT/FF 差一级寄存器。所以脚本加了 `TREE=upstream_top` 专门量上游顶层对照，
   对比表里逐行标了边界 —— **混着比会被评委问**。
   另：pe16 上游只跑到综合，其 WNS 是综合估算，**不可与参数化版的布线后实测直接比**。

2. ✅ **门控时钟被 Vivado 收成了 BUFG 使能，不是 LUT 门控时钟。**
   `clk_core = clk & ce_lat` 被推成 LUT2 → `BUFGCTRL_X0Y0`，单个 BUFG 带 2865 个负载；
   `Clock Summary` 里**仍只有一个 `clk` 时钟域**（5516 端点），`WHS = +0.077 ns`。
   → 上板**不需要**额外约束或手工 BUFGCE。

**踩到的两个坑（都已修）：**

- `synth_one.tcl` 的 generic：**只传裸数字**。整串 `PE_NUMBER=4` 从命令行进来会被
  Vivado 在 `=` 处切成两个参数，generic 取到 0，报的是
  `part-select [-1:0] does not match declaration` 这种**看着像 RTL 写错了**的错。
- 判据 1 的结论**只对 `TREE=ncore` 打印**。上游那两棵树本来就超预算（pe4 109 / pe16 397），
  对它们打印「✅ 判据 1 通过」等于把不达标说成达标。

**复现**：`rtl/vivado/折叠度对比表.md` §七（基线）/ §9.5（参数化版）。
⚠️ 量上游要显式 `TREE=upstream_top` 或 `TREE=upstream`，否则默认量参数化版。

---

## Task 8: 文档与跨队同步

**Files:**
- Modify: `rtl/H1_port_spec.md`（§五）
- Modify: `rtl/folding_param_design.md`（状态行）
- Modify: `logs/FPGA竞赛_项目记录.md`（§一、§二）

- [x] **Step 1: 改 `H1_port_spec.md` §五**

原文说 pe4 = 48 位 / pe16 = 192 位。参数化后**三档统一 12 位**。
在 §五 顶部加一段「**本节已被 `rtl/ntt_core/` 取代**」并指向新表。
**不要删原文** —— B 的协议按 `PE_NUMBER=1` 冻结，旧值是当时的真实状态。

- [x] **Step 2: 把 `folding_param_design.md` 的状态行从「设计定稿，待实现」改成「已实现」**

并把 Task 5 / 6 / 7 的实测数字回填进 §一 的判据表。

- [x] **Step 3: 更新项目记录**

`logs/FPGA竞赛_项目记录.md` §一「还差」行划掉参数化版本那一项；
§二 B 里的「参数化折叠度版本」标完成。**只改状态，不写过程**（过程进 `_变更.md`）。

- [x] **Step 4: 给 B / C 的转发话术**

写两段可直接复制粘贴的话：给 B（接口统一 12 位 + pe4/pe16 验证台谁建）、
给 C（报告 §3.3.5.3 的「优化前后对比表」材料在哪）。

- [x] **Step 5: 提交并推送**

```bash
git add rtl/H1_port_spec.md rtl/folding_param_design.md logs/FPGA竞赛_项目记录.md
git commit -m "参数化版本收尾：H1 §五 标注被取代 + 项目记录状态同步"
git push
```

### 实施记录（2026-09-29）

- **Step 1 的实际改法**：§五 在 Task 4 / Task 6 时**已经**加了一个小节
  「2026-09-29 新增：参数化顶层 `KyberHPMNTT_top` 的读出顺序（实测）」，
  所以本次只在 §五 **顶部**补一段导语，说明「下表的**位宽**那一列只描述上游宽接口；
  周期数 / 有效拍数是按 `PE_NUMBER` 算的，两版都成立」。原文一行没删。
- **Step 4 的产物**：`A给B_回复_2026-09-29.txt`、`A给C_2026-09-29.txt`（仓库根，**已提交**）
  —— 由 A 转发。`B给A_回复_2026-09-29.txt` 是 B 的来信，**未提交**：别人的文档，
  不替对方决定要不要进仓库。
- **Step 3 改的是共享文件**：`logs/` 是三个人的共享目录，改动前已确认
  `git pull` 干净、远端无新提交、无未提交的并改。改动**只碰状态行**，
  过程写在本节，不写进入口文件。

---

## 收尾：判据核对

三条判据全过才算完成：

- [x] **判据 1**：三档综合通过，Bonded IOB ≤ 125（预期三档都是 37）
      → 实测三档**都是 37**，且三档都布完线（Task 7）
- [x] **判据 2**：三档 FNTT/PWM2/INTT 的 `CC` 与上游逐个相等（Task 5，12/12 格）
- [x] **判据 3**：三档各 4096/4096 功能对拍通过（Task 6，3 运算 × 3 档 × 16 组）

外加**阴性对照**（本项目惯例，缺了判据不算成立）：

- [x] Task 2 Step 5 的地址公式破坏 → 探针必须 FAIL
- [x] Task 2 Step 6 的 stall 条件破坏 → 探针必须 FAIL
- [x] Task 3 Step 5 的非法 `PE_NUMBER` → 必须炸
