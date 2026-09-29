# 参数化折叠度 NTT 核 · 设计说明

> 状态：**设计定稿，待实现**（2026-09-29）
> 主责：A ｜ 目标器件：`xc7z020clg400-2`（正点原子领航者 ZYNQ，125 个 IOB）

---

## 一、目标与验收判据

把上游**三份手工复制**的设计（`rtl/pe1/` `rtl/pe4/` `rtl/pe16/`，合计 7638 行、三个独立目录树）
改造成**一份**以 `PE_NUMBER` 为参数的 RTL，三档都能综合进板上那颗 7020 并放得下。

**验收判据**（三条全过才算完成）：

| # | 判据 | 怎么验 |
|---|---|---|
| 1 | 三档综合通过，**Bonded IOB ≤ 125** | `rtl/vivado/run_folding_sweep.sh`，看 reports 里的 IOB 数 |
| 2 | 三档的**周期数与上游逐拍一致** | 探针实测 FNTT / PWM2 / INTT 的 `CC`，与下表逐个对齐 |
| 3 | 三档**功能对拍通过** | pe1 现有的 FIPS 203 KAT 验证链扩到 pe4 / pe16 |

判据 2 的基准值（上游实测，`rtl/vivado/折叠度对比表.md`）：

| | FNTT_CC | PWM2_CC | INTT_CC |
|---|---:|---:|---:|
| pe1 | 904 | 647 | 904 |
| pe4 | 232 | 167 | 233 |
| pe16 | 69 | 47 | 71 |

> **判据 2 是这次重构的主安全网。** 周期数对折叠度极其敏感（任何一处地址公式或 stall
> 写错都会改拍数），而它又几乎零成本可测。三档 CC 全对，说明折叠算法本身没被改坏。

---

## 二、问题陈述：为什么必须做

### 2.1 接口宽度随折叠度线性增长 → pe16 放不下

上游把 `din` / `dout` 做成 `[12*PE_NUMBER-1:0]`：

| 档 | din + dout | 控制信号 | 合计 IOB | 板子可用 | 占比 |
|---|---:|---:|---:|---:|---:|
| pe1 | 24 | 13 | 37 | 125 | 29.6% |
| pe4 | 96 | 13 | 109 | 125 | 87.2% |
| pe16 | 384 | 13 | **397** | 125 | **317.6%** |

pe16 的 `place_design` 在 IO 阶段直接失败。对照实验已坐实这是**封装引脚预算**问题而非逻辑问题：
同一份网表放到 Artix-7 `xc7a200tffg1156-3`（500 IOB）就布完了，而 pe16 的 LUT 只占 7020 的 15.9%。

### 2.2 ⚠️ `PE_NUMBER` 参数是**假的**

三个核文件都写了 `#(parameter PE_NUMBER=1/4/16)`（`rtl/pe1/KyberHPM1PE.v:30` 等），
但它**只用于数组维度和 generate 循环上界**，**从来没传进 `addressgenerator`**。
地址位宽在核里也是硬编码的（`rtl/pe4/KyberHPM4PE.v:91` 写 `reg [5:0] dw0 [...]`）。

**后果：今天把 `PE_NUMBER` 改成 8，地址生成器不会跟着变，设计直接错。**
所以「折叠度可配置」这句话在当前代码上是不成立的 —— 本设计要把它变成真的。

### 2.3 三份手工复制的漂移

`modred.v` 在 pe1 里**缺了**上游的 CC0 版权注释头（pe4/pe16 有）。
合并时统一，正好把许可证口径理顺。

---

## 三、关键分析结论

### 3.1 地址数学：三档是**同一个公式**

定义折叠参数：

```
L = log2(128 / PE_NUMBER)        pe1 → 7 ｜ pe4 → 5 ｜ pe16 → 3
```

`addressgenerator.v` 里全部地址公式、twiddle 递增规则、恒等门限、位宽，
都是 **L 的同一个表达式**。三份文件里看似不同的常数代进去就统一：

下表每一条都在三份源码里逐一核过（引用行号见注）。`S` = `c_stage`（0..6）。

| 写死的东西 | pe1（L=7） | pe4（L=5） | pe16（L=3） | 统一式 |
|---|---|---|---|---|
| `c_loop` 位宽 / 终值 | 7 / 127 | 5 / 31 | 3 / 7 | `L` / `2^L-1` |
| 地址切片 | `raddr[6:0]` | `raddr[4:0]` | `raddr[2:0]` | `raddr[L-1:0]` |
| 乒乓翻转位 | `raddr[7]` | `raddr[5]` | `raddr[3]` | `raddr[L]` |
| `c_tw` 初值（前向 / 逆向） | 127 / 254 | 95 / 190 | 39 / 78 | `T(L)` / `2·T(L)` |
| **FNTT** `raddr` 恒等门限 | `S==6` | `S>3` | `S>1` | `S >= L-1` |
| **FNTT** `raddr` 置换：掩码 & 项一移位 | `6-S` | `4-S` | `2-S` | `L-1-S` |
| **FNTT** `raddr` 置换：项二移位 | `7-S` | `5-S` | `3-S` | `L-S` |
| **INTT** `raddr` 前置恒等 | **无此支** | `S < 2` | `S < 4` | `S < 7-L`（pe1 时 `7-L=0`，恒假 → 无需该支） |
| **INTT** `raddr` 末级恒等 | `S==6` | `S==6` | `S==6` | `S == 6`（**三档相同**） |
| **INTT** `raddr` 置换：掩码 & 项一移位 | `S+1` | `S-1` | `S-3` | `S+L-6` |
| **INTT** `raddr` 置换：项二移位 | `S+2` | `S` | `S-2` | `S+L-5` |

> 行号（以源码为准）：FNTT/INTT 的 `raddr` 块
> `rtl/pe1/addressgenerator.v:227-247`、`rtl/pe4/addressgenerator.v:253-275`、
> `rtl/pe16/addressgenerator.v:292-314`。

**注意 INTT 与 FNTT 的置换方向相反**：FNTT 的移位量随 `S` **递减**（`L-1-S`），
INTT 随 `S` **递增**（`S+L-6`）。这与「正逆变换共用同一张 `zetas[]`、只是读的方向相反」
是同一件事。

**三档共有、无分歧**的部分：`raddr` 在 `start_*` 时清零、`INTT` 的 `S==6` 末级恒等、
地址切片的位宽关系。这些直接写成一份即可。

**决定性数值证据**：twiddle 计数器的前向初值应当是

```
T(L) = Σ_{S=0}^{min(6,L-1)} (2^S − 1)  +  Σ_{S=L}^{6} (2^L − 1)  +  7
```

算得 `T(7)=127`、`T(5)=95`、`T(3)=39` —— 与三份文件里实际写的
`9'd127`（`rtl/pe1/addressgenerator.v:119`）、`8'd95`（`rtl/pe4/addressgenerator.v:129`）、
`7'd39`（`rtl/pe16/addressgenerator.v:152`）**分毫不差**。
三者同时命中同一个非平凡公式的概率可忽略，据此判定三份是同一算法的三个实例。

### 3.2 两处**不是** L 的函数（真结构分歧）

| | pe1 | pe4 / pe16 |
|---|---|---|
| **PWM2 地址** | 双读口 `raddr` + `raddr_b`，写地址受 `c_pwm` 调制；另吐 `raddr_b`、`c_loop_pwm` 两个顶层要用的信号 | **退化为恒等扫描** `raddr <= c_loop`，`waddre = waddro <= c_loop` |
| **FSM 结构** | 4 态、2 位编码，**无 stall 状态** | 有 stall 状态：pe4 加 `STL0/STL1`（6 态），pe16 加 `STL0/STL1/STL2`（7 态、3 位编码）并配 `c_stl` 计数器 |

- **PWM2 分歧**是数据布局决定的：PE=1 时「点乘 + 折叠最后一阶」的数据重排
  必须由地址生成器显式完成；PE≥4 时被并行度免费吸收。
- **stall 分歧**：三档都在「一轮扫完」的时刻（`c_loop == 2^L-1`）决定要不要多停一拍，
  但**停的条件三档各不相同**：

  | | FNTT 在哪儿停 | INTT 在哪儿停 |
  |---|---|---|
  | pe1 | **一处都不停** | **一处都不停** |
  | pe4 | `S == L-1` 停 1 拍 | `S == 0` 停 1 拍 |
  | pe16 | `S <= L-1` 停（前 3 个 stage 各停 1 拍） | 另有 stall 点，实现时按源码逐条抄 |

  （pe1 那两处 `S == L-1` 的位置上**没有** stall —— 这正是它不能由 L 唯一决定的原因。）

→ 这两处**只能分支保留**，不能强求统一式。

---

## 四、架构

### 4.1 目录

新建 `rtl/ntt_core/`（一份，替掉三个目录）：

```
rtl/ntt_core/
├── KyberHPMNTT.v        核    #(parameter PE_NUMBER=1)
├── KyberHPMNTT_top.v    顶层  输入/输出寄存 + 固定 12 位接口 + 序列化器
├── addressgenerator.v   参数化  #(parameter L)
├── BRAM.v               #(parameter ADDR_W)
├── BROM.v               twiddle 表
├── butterfly.v  modadd.v  modsub.v  modred.v  modmul.v  intmul.v
└── dt0.v dt1.v dt2.v dt3.v  FA.v HA.v div2.v shiftreg.v
```

- 叶子模块（`butterfly` `modadd` `modmul` `intmul` `FA` `HA` `div2` `shiftreg` `dt1–3`）
  三档**逐字节相同**，直接取一份。
- `dt0.v` 三档只差一个空行；`modred.v` pe1↔pe4 只差 CC0 注释头 → 合成一份。
- `rtl/pe1|pe4|pe16/` **暂时保留** —— 它们是折叠度对比表的基线。
  等新树三档验过再决定去留（`research/ref_rtl/` 有上游原件，删了不丢基线）。

### 4.2 参数传递

对外只暴露 `PE_NUMBER`，内部派生 L 并一路传下去：

```
KyberHPMNTT_top #(.PE_NUMBER(16))
  └── KyberHPMNTT #(.PE_NUMBER(16))
        ├── addressgenerator #(.L(L))    L = $clog2(128/PE_NUMBER)
        ├── BRAM            #(.ADDR_W(L+1))
        └── BROM            #(.TW_ADDR_W(...))
```

**这是参数化能否成立的关键一环** —— 现在断在这里。

### 4.3 接口：核保持宽，序列化放在核**外**

```
KyberHPMNTT_top #(.PE_NUMBER(16))
  ├── 外部：din[11:0] / dout[11:0]     固定 12 位，三档完全相同
  ├── 中层：序列化 / 反序列化器
  └── 核 KyberHPMNTT                    宽接口 din[12*PE-1:0]
```

选择理由：

- **核的 FSM 一行不用改** —— 风险最小。装载态仍是「每拍写一次 BRAM」，只是拍数回 256
- `PE_NUMBER=1` 时序列化器是**直通**的 → pe1 已验证的时序完全不受影响
- 序列化器能**单独测**
- 换器件时核的宽接口仍在

代价：pe16 装载/读出由 16 拍变回 256 拍。**但 UART 比装载口慢 17,361 倍**，
这点差距淹没在串口里（见 `rtl/H1_port_spec.md` §四）。

### 4.4 参数化后三档的对外行为

| | `din`/`dout` | 装载拍数 | 读出拍数 | `done` = `CC+1` |
|---|---|---|---|---|
| pe1 | **12** | 256 | 256 | 905 / 648 / 905 |
| pe4 | **12** | 256 | 256 | 233 / 168 / 234 |
| pe16 | **12** | 256 | 256 | 70 / 48 / 72 |

接口三档完全一致，只有 `done` 的周期数不同。

---

## 五、两处 `generate` 分支

### 5.1 PWM2 地址（`PE_NUMBER == 1` vs `else`）

```verilog
generate
  if (PE_NUMBER == 1) begin : G_PWM2_PE1
    // 双读口 + c_pwm 调制，并输出 raddr_b / c_loop_pwm
    raddr    <= (c_pwm < 2) + ((c_loop >> 1) << 1);
    raddr_b  <= c_pwm[0]    + ((c_loop >> 1) << 1);
    waddre   <= ((0 < c_pwm) && (c_pwm < 3)) + ((c_loop >> 1) << 1);
    waddro   <= waddre;
  end else begin : G_PWM2_WIDE
    // PE≥4：数据布局天然对齐，恒等扫描
    raddr  <= c_loop;
    waddre <= c_loop;
    waddro <= c_loop;
  end
endgenerate
```

`raddr_b` / `c_loop_pwm` 在 `PE_NUMBER > 1` 时不输出（顶层的对应通路也走 generate 关掉）。

> **为什么不把 pe1 也改成恒等扫描以消掉分支？** 那会改掉 pe1 已经验证过的数据布局，
> 连带 `refsim/pe1/` 的 KAT 链和 `rtl/H1_port_spec.md` §三 的读出顺序全要重来。
> 收益（少一个分支）远小于代价。**保持 pe1 行为逐拍不变是本次重构的第一约束。**

### 5.2 FSM stall

上游三档的 stall 是手工调的，本设计**不推导新规则**，只把现状编码成参数，
保证行为逐拍不变：

```verilog
// 每档的 stall 配置：从上游源码逐一抄出，不做归纳
localparam integer STALL_N = (PE_NUMBER == 1) ? 0 :
                            (PE_NUMBER == 4) ? 2 : 3;
```

具体每档在哪个 `c_stage` 停几拍，实现时按上游源码逐条抄写，
由「判据 2：三档 CC 逐拍一致」兜底 —— **抄错了 CC 就对不上，跑一次探针立刻暴露**。

---

## 六、验证策略

按强到弱三层，全部可一条命令复跑：

| 层 | 验什么 | 工具 | 位置 |
|---|---|---|---|
| ① 周期数一致 | 三档 FNTT/PWM2/INTT 的 `CC` 与上游逐个相等 | iverilog 探针 | `rtl/probes/`（扩展） |
| ② 功能对拍 | 三档各跑 FIPS 203 KAT 全链，4096/4096 | iverilog + python | `refsim/`（**B 的主责，需协调**） |
| ③ 综合与引脚 | 三档 IOB ≤ 125、资源数、Fmax | Vivado | `rtl/vivado/run_folding_sweep.sh` |

**阴性对照**（本项目惯例）：人为改坏一处地址公式，第 ① 层必须报错。
不报错说明探针本身没有分辨力。

---

## 七、风险

| # | 风险 | 影响 | 对策 |
|---|---|---|---|
| R1 | 重构改坏 pe1 —— **它是唯一功能验证过的配置** | 高 | 第一约束是 pe1 逐拍不变；KAT 全链每步都跑 |
| R2 | stall 表抄错 | 中 | 判据 2 兜底（CC 对不上立刻暴露） |
| R3 | L 的推导在某些 `c_stage` 边界不成立 | 中 | 判据 1+2 覆盖；探针逐档扫 |
| R4 | `raddr_tw` / `c_tw` / BROM 深度三处位宽必须联动，漏一处读飞 | 中 | 全部由 L 派生，不允许留硬编码常数 |
| R5 | 综合抖动（Vivado 2020.2 已知问题） | 低 | `run_folding_sweep.sh` 自带重试 |

---

## 八、跨队影响（需 A 主动告知）

| 对象 | 影响 | 处置 |
|---|---|---|
| **B · `refsim/pe1/`** | 验证台例化的是 `KyberHPM1PE`。新树用 `KyberHPMNTT`，**不改名就不会编译不过**（新树是新增目录，`refsim/pe1/` 有自己的副本） | 新增目录 → 无影响；但 pe4/pe16 的验证台要 B 建 |
| **B · `rtl/H1_port_spec.md`** | §五 写的是 pe4 = 48 位 / pe16 = 192 位。参数化版把三档接口统一成 **12 位**，该节被取代 | 跟 B 打招呼；协议按 `PE_NUMBER=1` 冻结，眼下不受影响 |
| **C · 报告** | 本篇是 §3.3.5.3「设计原理与功能框图」「优化过程」的原始材料 | 交付后告知 C |

---

## 九、本设计**不做**的事

- **不推导新的折叠算法** —— 只把上游三档的行为统一到一份参数化 RTL，行为逐拍不变
- **不改 pe1 的数据布局** —— 包括 PWM2 的双读口结构
- **不动 `refsim/`** —— B 的主责目录
- **不删 `rtl/peN/`** —— 等三档验过再说

---

## 十、复现与依据

- 折叠度实测数据：`rtl/vivado/折叠度对比表.md`
- 接口时序：`rtl/H1_port_spec.md`（探针 `rtl/probes/`）
- 上游原件（只读）：`research/ref_rtl/kyber-polmul-hw/pe{1,4,16}/`
- 本设计的分析依据：三份 `addressgenerator.v` 的逐行比对 + `T(L)` 数值验证
