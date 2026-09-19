# RTL 软硬件一致性验证台

这个目录回答一个问题：**`kyber-polmul-hw/pe1/` 里那份 NTT 硬件，算得对不对？**

"跑通了作者的 testbench" 回答不了这个问题。作者的 testbench 是拿
**作者自己给的期望输出**去比 **作者自己的 RTL** —— 只能证明自洽，
万一作者的期望值本身就错了（比如 twiddle 表排错、域约定选错），
testbench 照样打印 `Correct!`。

所以这里搭了一条独立的验证链，终点是 **FIPS 203**。

---

## 一、验证链（这是全部价值所在）

```
   FIPS 203 KAT 向量集（1000 条，逐比特）
              │
              │  kat_verify.c 四项独立复算，1000/1000 通过
              ▼
   C 参考实现（kyber_ref/）  ←── 从此它是"地面真值"
              │
              │  ntt_ref_tool.c 复算作者的输入
              ▼
   作者期望输出 KYBER_DIN*_MFNTT.txt  ── 逐比特一致（512/512 个系数）
              │
              │  反过来：作者 RTL 在仿真里也产出同样的值
              ▼
   作者 RTL (KyberHPM1PE)  ── FNTT 16 组独立向量全过（4096/4096 个系数）
              │
              ├──▶ INTT   16 组独立向量全过（4096/4096）
              │
              ├──▶ PWM2   16 组独立向量全过（4096/4096）
              │
              ├──▶ 往返自检：把 RTL 的 FNTT **实际输出**灌回 RTL 的 INTT，
              │     4096 个系数全部回到时域原值
              │
              ├──▶ 完整乘法 FULL  FNTT(A)→FNTT(B)→PWM2→INTT  16 组（4096/4096）
              │
              ├──▶ 半程乘法 HALF  FNTT(A)→PWM2→INTT          16 组（4096/4096）
              │
              ▼
   ∴ 这份 RTL 的 NTT / INTT / 点乘 / 完整多项式乘法都符合 FIPS 203
```

中间那一环很关键：**作者的期望输出和参考实现逐比特一致**，
这既证明作者的数据没错，也证明我们对参考实现的理解（域约定、输出顺序）
和作者一致 —— 否则后面拿自己的向量去灌 RTL，顺序对不上会假报失败。

后面分成两类，**性质不同**：

**单运算（INTT / PWM2）：期望值要按常数因子换算。** 这两步 RTL 的域约定
和参考实现不一样，见第七节。为这件事专门配了往返自检 —— 它**完全不经过
C 参考实现**，只依赖"FNTT 已经验过"，所以能反过来证明那个换算因子不是自我
安慰：拿 RTL 的真实输出喂回 RTL，能不能回到原值，这个骗不了人。

**端到端（FULL / HALF）：没有任何缩放因子。** 期望值就是参考实现的输出，
逐比特直接比。原因是那两个常数因子（点乘的 R、INTT 的 R⁻¹）在链上正好抵消。
这不只是"少写个常数"—— 它反过来给单运算那一层的标定做了背书：
**若 R 或 R⁻¹ 有一个标错了，端到端这两组就不可能严丝合缝地全过。**

---

## 二、怎么跑

```sh
sh run_fntt_check.sh          # NTT 全流程：KAT → 参考实现 → RTL
sh run_intt_pwm2_check.sh     # INTT + 点乘：生成向量 → 灌 RTL → 往返自检
sh run_polmul_check.sh        # 完整多项式乘法（端到端）：FULL + HALF 两条通路
sh run_ntt_layers.sh          # 导出并机器验证 twiddle 层序表
```

前三个都是全自动的。需要 `gcc`、`iverilog`、`python`。

**iverilog 不在 PATH 里**时脚本会自己加 `/c/iverilog/bin`。
它是用 winget 装的：`winget install --id Icarus.Verilog`。

---

## 三、实测结果

`run_fntt_check.sh`：

```
✅ DIN0：作者期望输出 == 参考实现（256/256）
✅ DIN1：作者期望输出 == 参考实现（256/256）
✅ 16 组黄金向量自洽（ntt_out.hex == poly_ntt(ntt_in.hex)）
★ 全部 16 组向量通过 —— RTL 输出与 KAT 校验过的参考实现逐比特一致
```

`run_intt_pwm2_check.sh`：

```
✅ INTT 16 组全过（4096/4096 个系数）
✅ PWM2 16 组全过（4096/4096 个系数）
✅ 往返自检：RTL FNTT 的实际输出 → RTL INTT → 时域原值（4096/4096）
```

`run_polmul_check.sh`：

```
★ 全部 16 组完整乘法（FULL）通过 —— FNTT→FNTT→PWM2→INTT 端到端与参考实现逐比特一致
★ 全部 16 组半程乘法（HALF）通过 —— FNTT→PWM2→INTT 端到端与参考实现逐比特一致
```

非退化统计（"通过"必须配"非退化"才作数）：

| 向量集 | 行数 | 不同值 | 最常见值占比 |
|---|---|---|---|
| `intt_batch_in`  | 4096 | 2374 | 0.15% |
| `intt_batch_exp` | 4096 | 2355 | 0.17% |
| `pwm2_batch_a`   | 4096 | 2374 | 0.15% |
| `pwm2_batch_exp` | 4096 | 2371 | 0.22% |
| `fullmul_a` / `_b` | 4096 | 2355 | 0.17% |
| `fullmul_exp`    | 4096 | 2357 | 0.20% |
| `halfmul_b`      | 4096 | 2374 | 0.15% |
| `halfmul_exp`    | 4096 | 2357 | 0.20% |

覆盖 0..3327 全域，无越界。这种熵下 4096 个系数全中不可能是巧合。

### 阴性对照：证明这套测试有牙齿

一个永远通过的测试没有价值。改坏一个期望值，看它抓不抓得到：

```sh
# 把第 7 组第 100 号系数改掉，重跑，应报"恰好 1 个系数不符"且指向该位置
cp batch/fullmul_exp.txt batch/_bak.txt
python -c "L=[l.strip() for l in open('batch/fullmul_exp.txt') if l.strip()];L[7*256+100]='001';open('batch/fullmul_exp.txt','wb').write(('\n'.join(L)+'\n').encode())"
vvp batch_fullmul.vvp | grep -E '向量  7|共'
mv batch/_bak.txt batch/fullmul_exp.txt        # 恢复
```

实测输出：

```
向量  7 [100]: 期望 001 得到 3d4
向量  7: ❌ 255/256
✗ 共 1 个系数不符
```

恰好 1 个不符、位置正确，且 RTL 报出的 `3d4` 正是原值 —— 说明 RTL 是对的，
测试也确实能把错抓出来。

---

## 四、文件

| 文件 | 作用 |
|------|------|
| `run_fntt_check.sh` | **入口①** —— NTT 全流程一条命令 |
| `run_intt_pwm2_check.sh` | **入口②** —— INTT + 点乘 + 往返自检 |
| `run_polmul_check.sh` | **入口③** —— 完整多项式乘法（端到端） |
| `run_ntt_layers.sh` | 入口④ —— 导出 twiddle 层序表并机器验证 |
| `ntt_ref_tool.c` | 参考实现外壳：读系数文本 → `poly_ntt` / `poly_invntt_tomont` → 写回文本 |
| `ntt_once_tool.c` | 单多项式 NTT/INTT 外壳（`--ntt` / `--invntt`） |
| `polmul_ref_tool.c` | **两输入**点乘外壳（时域进，内部补两步 NTT） |
| `basemul_nttdomain_tool.c` | 点乘外壳，输入已经是 NTT 域，不再做 NTT |
| `polmul_full_tool.c` | **完整乘法**外壳：`--full` / `--half`，时域进时域出 |
| `ntt_layers.c` | 导出 twiddle 层序表 |
| `gen_batch_vectors.py` | 生成 INTT / PWM2 / 完整乘法批量向量 + 非退化检查 |
| `batch/ntt_batch_*.txt` | NTT 的 16 组输入/期望 |
| `batch/intt_batch_*.txt` | INTT 的 16 组输入/期望 |
| `batch/pwm2_batch_{a,b,exp}.txt` | 点乘的 16 组双输入/期望 |
| `batch/fullmul_{a,b,exp}.txt` | 完整乘法（FULL）的 16 组 |
| `batch/halfmul_{a,b,exp}.txt` | 半程乘法（HALF）的 16 组 |
| `pe1/fntt_batch_tb.v` | **批量 testbench** —— FNTT，16 组循环灌进 RTL |
| `pe1/fntt_batch_tb_dump.v` | 同上，多一个 `+dump=1` 开关，把 RTL 实际输出落盘 |
| `pe1/intt_batch_tb.v` | 同上 —— INTT，**读出顺序与 FNTT 不同** |
| `pe1/pwm2_batch_tb.v` | 同上 —— 点乘，**两路输入** |
| `pe1/fullmul_batch_tb.v` | 同上 —— 完整乘法，**串四个运算** |
| `pe1/halfmul_batch_tb.v` | 同上 —— 半程乘法，**B 用 `load_b_i` 灌** |
| `pe1/*.v` | RTL 源码副本（24 个），改动见下 |
| `pe1/test_pe1/` | 作者自带的数据文件（10 个） |
| `ref_ntt0/1.txt` | 参考实现复算作者输入的结果，供 diff |
| `_scratch/` | 排查期间的中间产物，**跑验证不需要**，见其 `README.md` |

---

## 五、对源码副本做的改动（原始目录没动）

`pe1/` 是从 `../research/ref_rtl/kyber-polmul-hw/pe1/` **复制**来的。
只在这个副本上改了两处，原始源码保持原样：

1. **`$readmemh` 路径**
   `../../../../test_pe1/` → `test_pe1/`
   （原路径是给上游仓库的目录层级用的，这里层级不同）

2. **`$stop` → `$finish`**
   `vvp` 遇到 `$stop` 会掉进交互模式并挂住，非交互跑批必须换掉。

---

## 六、批量 testbench 相对作者版的改动

控制时序是**照抄**作者版的（那是已知能跑通的），只把单次执行改成循环：

1. **等待 `done` 改成有界循环**。作者版是 `while(done == 1'b0)`，无界；
   放进 16 轮循环里，任何一轮异常都会让仿真**永久挂死**而不是报错退出。
   现在加了 `TIMEOUT=5000` 个周期的护栏（`FNTT_CC=904`，绰绰有余），
   超时会报 `❌ 超时` 并继续，不会卡住。

2. **每轮重新 `load_a_f` 灌数据，不复位**。查过 FSM 确认这是安全的：
   加载时写 bank 0（`dw2 = {2{1'b0, di_cntr[6:0]}}`），FNTT 输出在 bank 1
   （`op_out_a <= 1`），所以重灌即可重复，不必每轮复位。

### 三种运算的读写顺序不一样 ⚠️

读出顺序 `0,2,1,3,4,6,5,7,...` 原样保留了作者版的写法 —— 那是 BRAM 分两 bank
交织的结果，不是笔误。**但 INTT 不一样**，照抄 FNTT 的循环去做 INTT 会得到
"256 个系数全错"的假失败：

| 运算 | 输入顺序 | 输出顺序 |
|---|---|---|
| FNTT | `0,2,1,3,4,6,5,7,...` | `0,2,1,3,4,6,5,7,...` |
| INTT | `0,2,1,3,4,6,5,7,...` | **`0,1,2,3,4,5,6,7,...`（顺序）** |
| PWM2 | A、B 各一份，都是交织序 | `0,2,1,3,4,6,5,7,...` |

### `load_*_f` 和 `load_*_i` 是**两种摆放**，不是两种写法 ⚠️

四个加载端口看着像同一件事的两种拼写，其实是**数据放进 BRAM 的哪个半区**：

| 端口 | 灌数顺序 | 落到哪 | 给谁用 |
|---|---|---|---|
| `load_a_f` / `load_b_f` | 顺序 `0,1,2,...` | 各 BRAM **低半区**（地址 0..127） | FNTT 的输入 |
| `load_a_i` / `load_b_i` | 交织 `0,2,1,3,...` | 各 BRAM **高半区**（地址 128..255） | INTT / 已展开的 NTT 域输入 |

依据是 `KyberHPM1PE.v` 的 `load_type` 逻辑（第 134-145 行选 type、
第 303-310 行按 type 决定 `dw2` 和 `de2`）：

```verilog
{dw2[0],dw2[1]} = (load_type == 1'd0) ? {2{1'b0,di_cntr[6:0]}}   // _f：低半区
                                       : {2{1'b1,di_cntr[7:1]}}; // _i：高半区
```

**为什么这个坑很阴**：用错了不会报错，数据也一个不少地进去了，只是**位置不对**，
结果是 256 个系数全错 —— 而"全错"又很容易被误判成 RTL 有 bug。
`halfmul_batch_tb.v` 里 B 必须用 `load_b_i`，就是因为 PWM2 期望在 B 侧的高半区
找到已经展开好的 NTT 域系数。

### PWM2 的两路输入要串行灌

作者版把「灌 A」和「灌 B」拆在两个 `initial` 块里，靠 `#1500` 的时间差错开。
批量循环里不能这么写 —— 所有轮次共用一个时间轴。批量版改成顺序执行：
灌 A（`load_a_i`）→ 灌 B（`load_b_i`）→ `start_pwm2`。

---

## 七、踩过的坑

**行尾符会让 diff 全线误报。** 第一次对拍时 `diff` 报 `1,256c1,256`，
看着像 256 个系数**全错**，实际数值一个不差 —— 作者的测试数据是 LF，
而 `fopen(..., "w")` 在 Windows 上会把 `\n` 翻成 `\r\n`。
现在 `ntt_ref_tool.c` 用 `"wb"` 强制写 LF，`diff` 干净通过，
不需要 `--strip-trailing-cr` 这种遮掩手段。

**教训**：跨平台对拍文本文件，先把行尾统一了再去解读 diff 结果。

**域约定不同，不是 RTL 有 bug。** 第一次拿参考实现的 INTT / 点乘输出直接
当期望值，16 组**全部** `0/256`。看着像 RTL 坏了，其实是两边对"这个函数的
输出到底该带不带 Montgomery 因子"的理解不一样：

| 运算 | RTL 输入域 | RTL 输出 与 参考实现的关系 |
|---|---|---|
| INTT | NTT 域 | RTL = `poly_invntt_tomont(x)` × R⁻¹（真逆变换，无 tomont 缩放） |
| PWM2 | NTT 域 | RTL = `poly_basemul_montgomery` × R（少一级 Montgomery 归约） |

R = 2¹⁶ mod q = **2285**，R⁻¹ = **169**。

怎么定位的：**不看"通不通过"，改看比值**。逐系数相除，比值集合大小为 1
（不是 248 种随机值）—— 说明逻辑没错，只差一个全局常数因子。这一步同时
排除了"点乘被误当成逐系数乘法"这类真正的功能错误。

怎么确认这个因子不是自我安慰：`run_intt_pwm2_check.sh` 第 ④ 步做往返自检，
把 RTL 的 FNTT **实际输出**灌回 RTL 的 INTT，要求回到时域原值。这条路完全
不经过 C 参考实现，也就不可能被"我标的定标因子"带偏。

**教训**：对拍全错时，先算比值再怀疑逻辑。恒定比值 = 约定问题；
杂乱比值 = 功能问题。两者排查方向完全不同。

---

## 八、这条链没覆盖什么

- **验到"一次多项式乘法"为止，不是"一次 ML-KEM 运算"为止。**
  FULL / HALF 已经是端到端（时域进、时域出、无缩放因子），但 ML-KEM
  解封装还差更外层的东西：`polyvec_basemul_acc_montgomery` 那种**累加多个**
  点乘结果的向量运算、base case 乘法（2×2 的 Karatsuba 那步）、
  以及最终的 `poly_tomont` / `poly_reduce` 归位。这些尚未验。
- **期望值的换算依赖仍存在于单运算那一层。** INTT / PWM2 的期望值由参考实现
  输出乘一个常数因子得到（有往返自检背书）。端到端的 FULL / HALF 没有这个问题。
- **只验了 PE_NUMBER=1 的配置。** 多 PE 并行版本没验。
- **没验面积/时序/功耗。** 这是功能验证，不是实现质量评估。
- **作者的 testbench 数据只对了 2 组**，样本量小；我方补的 16 组是主力。
- **作者 INTT testbench 里有个打印 bug**：报错那行的 `$display` 把
  `doub[m]` 写成了 `doua[m]`（`pe1/KyberHPM1PE_test_INTT.v` 第 227 行）。
  只在失败时才打印，不影响结论，但真出问题时会把排查带偏。

---

## 九、和别处的关系

- KAT 校验环境、向量生成器：`../research/mlkem_kat/README.md`
- 算法本体讲解（三层结构、索引规则、域/缩放陷阱）：
  `../research/PQC-NTT_ML-KEM_技术资料汇编.md`
- 参考实现源码：`../research/kyber_ref/`
- 原始 RTL（未改动）：`../research/ref_rtl/kyber-polmul-hw/pe1/`
