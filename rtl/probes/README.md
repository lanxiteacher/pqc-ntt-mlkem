# rtl/probes —— NTT 核接口时序探针

`../H1_port_spec.md` 里所有周期数和顺序表，都由这里的脚本跑出来。
不引用任何 gitignored 的中间文件，全新 clone 直接能跑。

## 跑

```sh
sh run_probes.sh
```

需要 `iverilog`（`/c/iverilog/bin`，不在 PATH 里，脚本自己加）和 `python`。

## 八个探针

| 文件 | 测什么 | 编出来的可执行 |
|---|---|---|
| `pe1_timing_tb.v` | pe1 的**接口时序**：`load_*` 怎么给、几拍出 `done`、`read_*` 后几拍出第一个 `dout`、有效读数多少拍 | `-DUSE_TOP` 则换成测 `KyberHPM1PE_top` |
| `order_tb.v` | pe4 / pe16 的**装载顺序和读出顺序**：一拍里 PE_NUMBER 个 12 位切片各对应哪个系数下标 | `-DPE16` 切到 pe16，默认 pe4 |
| `leaf_elab_tb.v` | `../ntt_core/` 的叶子（`ntt_BRAM` / `ntt_BROM`）三档**能否例化**、深度/位宽对不对、BROM 内容抽查 | `-DCFG_PE_NUM=` / `-DCFG_TW=` |
| `ag_equiv_tb.v` | `../ntt_core/ntt_addressgenerator` 与 `../pe{1,4,16}/addressgenerator` 的**逐拍等价**：同一份激励喂两个模块，每个时钟沿比 18 路输出 | `-DCFG_L=`（7/5/3），pe1 另需 `-DHAS_PE1_PORTS` |
| `core_equiv_tb.v` | `../ntt_core/KyberHPMNTT` 与 `../pe{1,4,16}/KyberHPM{1,4,16}PE` 的**逐拍等价**：每个时钟沿比全部端口 + 全部内部状态（三档 39 / 111 / 399 路） | `-DCFG_PE_NUM=` **和** `-DCFG_PE_MOD=`（两个都要给，见下） |
| `top_behavior_tb.v` | `../ntt_core/KyberHPMNTT_top` 的**对外行为**：三档喂**同一串** 12 位激励，走「load A → FNTT A → load B → FNTT B → PWM2 A → read A」，比读出的 256 个值 | `-DCFG_PE_NUM=`；pe1 另可加 `-DREF_PE1`（见下） |
| `top_golden_tb.v` | 同一条顶层，但拿 `../refsim/batch/ntt_batch_exp.txt` 第 0 组当**外部锚**（有锚才谈得上「对不对」，不只是「一不一样」）。`-DWITH_PWM2` 再走一遍上一条那条 PWM2 路；`-DWITH_INTT` 换走 INTT（只量周期数） | `-DCFG_PE_NUM=`；`-DWITH_PWM2` / `-DWITH_INTT`（见下） |
| `ntt_func_tb.v` | 同一条顶层，**16 组全跑**（3 个运算各 4096 系数）对黄金向量，判「多重集相等」；读出顺序单独量出来印在右边 | `-DCFG_PE_NUM=`；`-DOP_INTT` / `-DOP_PWM2` / `-DOP_PWM2AB`（a≠b，见段 ⑩；默认 FNTT） |

**`leaf_elab_tb.v` 的阴性对照**（在 `run_probes.sh` 段 ⓪ 里，每次跑都重验）：

| 改哪里 | 预期 |
|---|---|
| `-DCFG_PE_NUM=4 -DCFG_TW=9`（`TW_ADDR_W` 配错档） | FAIL —— 这套搭配**能编能跑**，只是 `c_tw`/`raddr_tw`/`BROM` 会静默读飞，所以必须在 elaboration 期拦住 |
| `-DCFG_PE_NUM=3` | FATAL —— `BROM` 的 `generate` 没有 `default`，不守会得到一个 `dout` 恒为 X 的「能跑的」设计 |

### `ag_equiv_tb.v` 的用法与坑

```sh
# L=7 → pe1｜L=5 → pe4｜L=3 → pe16
iverilog -g2005 -DCFG_L=7 -DHAS_PE1_PORTS -o w.vvp \
    ag_equiv_tb.v ../pe1/addressgenerator.v ../pe1/shiftreg.v \
    ../ntt_core/addressgenerator.v ../ntt_core/shiftreg.v
vvp w.vvp
```

- ⚠️ `-DHAS_PE1_PORTS` **只有 pe1（L=7）能带**。pe1 的 AG 多两个输出
  `c_loop_pwm` / `raddr_b`，旧那侧的例化不带宏会缺端口；pe4/pe16 没这两个脚，
  带了宏 iverilog 会在 elaborate 阶段直接报错。
- 两个 tree 能同场编进来，靠的是新树叶子叫 `ntt_*` —— iverilog 没有 namespace，
  同名必撞。这个探针本身就是「`ntt_` 前缀」这条约束的活证明。
- ⚠️ 上游 `ct` / `pwm` 是 **output reg**，不是输入。别把它们接常数。
- ⚠️ 别用 `ct` 判「模块在不在干活」：上游 IDLE 那一支是 `b_ct <= b_ct;`（保持），
  `ct` 一旦被 FNTT 拉高就再也不下来。探针里的 `busy` 用的是 `wen` / `brselen` / `pwm`
  —— 这三路在 IDLE 会被清 0。`busy` 只是给人看的参考量；判据是**输出逐拍全等**。
- 三档的 `busy`（wen/brselen/pwm 为高的拍数，**不是**完整周期数）：

  | | FNTT | PWM2 | INTT |
  |---|---|---|---|
  | pe1 | 897 | 384 | 897 |
  | pe4 | 226 | 96 | 226 |
  | pe16 | 60 | 24 | 62 |

  完整周期数以 `../H1_port_spec.md` 和 `pe1_timing_tb.v` 为准。

**阴性对照**（改一处必须 FAIL，否则探针没有分辨力）：

| 改哪里 | 预期 |
|---|---|
| FNTT 读地址的 `(L-1-c_stage)` → `(L-2-c_stage)` | 三档全 FAIL（实测 2712 / 2984 / 2826 处） |
| pe16 分支的 `STL0: next_state = (c_stl == 1'd1) ? FNTT : STL0;` → `= FNTT;` | **只有 L=3 FAIL**，L=7/L=5 仍 PASS |

### `core_equiv_tb.v` 的用法与坑

```sh
# PE_NUMBER=1 → pe1｜=4 → pe4｜=16 → pe16
# ⚠️ 上游那侧要连**整个目录**编进来（核里例化了 BRAM/BROM/butterfly/AG/shiftreg）
CORE="$(ls ../ntt_core/*.v | grep -v _top)"
iverilog -g2005 -DCFG_PE_NUM=4 -DCFG_PE_MOD=KyberHPM4PE -o w.vvp \
    core_equiv_tb.v ../pe4/*.v $CORE && vvp w.vvp
```

- ⚠️ **要两个 `-D`**：`CFG_PE_NUM` 选新核的参数，`CFG_PE_MOD` 选上游的模块名。
  上游三档模块名不同（`KyberHPM1PE` / `KyberHPM4PE` / `KyberHPM16PE`），必须编译期选；
  而 iverilog 12.0 **不支持** `` `if MACRO == 值 `` 这种带比较的预处理条件
  （只认 `ifdef`/`ifndef`/`elsif <名>`），没法从 `CFG_PE_NUM` 反推模块名。
  手工敲命令时自己保证两个配套；`run_probes.sh` 是从同一个循环变量生成的，不会各说各话。
- ⚠️ 上游那侧**不传参数**（`PE_NUMBER` 默认值就是 1/4/16），新那侧传 `CFG_PE_NUM`。
- ⚠️ 上游是**异步高有效**复位，探针里 `reset` 就是高有效。
- ⚠️ 想读 bank B 时：本拍**同时**拉 `read_a`/`read_b`，之后**只留 `read_b`**。
  pe4/pe16 的 `OP_IDLE` 只认 `read_a`（拿它进 `OP_READ_DATA`），而 `read_ab` 的赋值优先级是
  `read_a` > `read_b` > IDLE 清零 —— 所以得先用 `read_a` 把状态推过去，再靠持续挂着的
  `read_b` 在 `OP_READ_DATA` 期间把 `read_ab` 置 1。pe1 那句本来就是 `read_a || read_b`，两句都成立。
- `din` 由 LFSR 每拍驱动（非退化：三档分别有 1542 / 390 / 102 拍 `dout` 非零）。
- **非法 `PE_NUMBER` 会响亮地失败**：`-DCFG_PE_NUM=3` 时核自己的 `initial` 守卫与探针的守卫
  都会打 `FATAL` 并 `$finish`。注意 iverilog 这时**只报警告不报错**——`generate` 的 `else` 支
  会拿 3 个 bank 去跑 pe16 的 32 bank 数据通路，编译期刷 2470 条 out-of-bounds 警告后照样产出
  可执行文件。所以判据是**看 `FATAL` 那一行**，不是看编译器退出码。

**阴性对照**（改一处必须 FAIL，否则探针没有分辨力）：

| 改哪里 | 预期 | 实测不符处数 |
|---|---|---|
| 共享骨架：`do0_lo` 改读 `do0[dg]`（原本读高半 `do0[PE_NUMBER+dg]`） | 三档全 FAIL | 384 / 96 / 24 |
| pe16 分支：装载写地址高位取反 `{32{1'b0,di_cntr[L-1:0]}}` → `{32{1'b1,...}}` | **只有 PE=16 FAIL**，PE=1/PE=4 仍 PASS | 19091 |

上面两条都写在 `run_probes.sh` 段 ⑦ 里，每次跑都会重新验一遍；对照用的改动落在
`_work/negA`、`_work/negB` 的临时副本上，`../ntt_core/` 里始终是原件。

- ⚠️ 写阴性对照时**别用「对调两行连续赋值」当改动** —— `assign` 是顺序无关的，
  对调前后语义完全一样，只是 `.vvp` 的字节不同，跑出来照样 PASS。

### `top_behavior_tb.v` 的用法与坑

```sh
CORE="$(ls ../ntt_core/*.v | grep -v _top)"      # 核里例化了 BRAM/BROM/butterfly/AG/shiftreg
iverilog -g2005 -DCFG_PE_NUM=4 -o w.vvp \
    top_behavior_tb.v $CORE ../ntt_core/KyberHPMNTT_top.v && vvp w.vvp
```

查四件事：① 装载相位过去后脉冲 `start_*` 能收到 `done`（有界等待护栏）；
② 读出起点；③ **连着 256 拍**有效 `dout`，一拍不多一拍不少；④ `done` 在 `start_*` 后第 `CC+3` 拍。

- ⚠️ **读出起点不是三档统一的**，是 `read` 之后第 `2*PE_NUMBER+3` 拍
  （pe1 **5** / pe4 **11** / pe16 **35**）。核自己的读出延迟固定，但 `ce` 每 `PE_NUMBER`
  拍才来一次，第一拍宽结果最早也要等第 3 个 `ce`（前两个 `ce` 上核在清 `do_cntr`），
  此前没有数据可拆。硬要三档都在 `read+5` 吐第一个值，只能吐假的。
  所以「接口一致」= **端口一致 + 值序列一致，不含延迟一致**。
  ⚠️ `../folding_param_plan.md` 的 Task 4 写「第一条有效 `dout` 在 `read+5`（三档都是）」——
  这句**只对 pe1 成立**，别照抄。
- ⚠️ `-DREF_PE1` **只有能带**：那一档另外例化一份上游 `KyberHPM1PE_top` 逐拍对比
  （接口同名同位宽，可直连）。pe4/pe16 的 `_top` 是**宽**接口，不是同一个东西，没有可比对象。
- ⚠️ `-DDBG_WIDE` 另开一段调试打印：逐拍打出核那侧的**宽** `din`/`dout` 以及
  `sub`/`rsub`/`dsel`/`ce`。核对「哪个 12 位切片被搬到了哪一拍」时用这个，比对着 `dout` 猜快得多。

**这条探针自己踩过的三个坑**（每一个都让探针**看起来在通过**）：

| 坑 | 症状 | 正解 |
|---|---|---|
| LFSR 被 X 毒死 | `always @(negedge clk)` 在 t=0 因 `clk` 的 X→0 触发一次，那一刻 `initial` 还没播种 → 全 X 的 LFSR 永远停在 X；两棵树"一起 X"，逐拍对拍报 **0 处不符** | 加 `if (!reset)` |
| 空数组槽被当成非零 | `cap[]` 没抓到的槽是 X，而 `X !== 0` 恒真 → 「有效窗口之前必须为空」这条结构判据**假 FAIL** | 抓取使能要在脉冲**之前**开 |
| bank B 的数据三档不同 | 装载 A 三档都在第 3 拍（数据天然一样），但装载 B 分别在第 **1188 / 519 / 368** 拍，LFSR 一路自由跑 → 三档装进 bank B 的系数**不是同一串**，PWM2 结果自然不同 | 每次装载前**重新播种**（A / B 用不同种子）。这条最像 RTL 的 bug 而其实不是 —— 先怀疑激励 |

**阴性对照**（在 `run_probes.sh` 段 ⑧ 里）：把反序列化的切片号写成正着数
（`dsel = PE_NUMBER-1-rsub` → `(rsub==0) ? 0 : PE_NUMBER-rsub`），组内顺序变成 0,3,2,1。
预期 **pe16 与 pe1 不同（16 处）而 pe1 不受影响**（`PE=1` 时 `rsub` 恒 0，两式同值）——
后半条同时也是「三档在这条路上逐位相同」这条判据**有分辨力**的证明：没有它，那个 ✅
只说明三档跑得一样，不说明跑对了。
⚠️ 但「跑对了」最终还是要有**外部锚**才算数 —— 这正是 `top_golden_tb.v` 存在的理由，
而它一上锚就照出：FNTT 读数路上三档并不一致。所以这条阴性对照证明的是
**这条探针能分辨顺序**，不是**三档已经统一**。

**没覆盖到的**：bank B 的读出（`read_b`）、INTT 方向。这条只走
「load A → FNTT A → load B → FNTT B → PWM2 A → read A」，够证明序列化器；其余留给 Task 6。

⚠️ **那个 ✅ 的适用范围比看上去窄。** 它只说三档在**这条读数路**（PWM2 之后）上一样。
别读成「固定 12 位接口成立」—— FNTT 之后直接读的那条路三档**不一样**，见下面 `top_golden_tb.v`。

### `top_golden_tb.v` 的用法与坑

```sh
CORE="$(ls ../ntt_core/*.v | grep -v _top)"
iverilog -g2005 -DCFG_PE_NUM=1 -o w.vvp \
    top_golden_tb.v $CORE ../ntt_core/KyberHPMNTT_top.v && vvp w.vvp
# 再加 -DWITH_PWM2 走 ⑧ 那条路（顺带把 FNTT B / PWM2 A 的 CC+3 也在顶层量一遍）
# 再加 -DWITH_INTT 换走「装载 A → INTT A → 读 A」，**只量周期数不判值**
#   （INTT 的装载/读出约定还没有黄金锚，值判据在 Task 6）
```

跑完打印 256 个读出值，段 ⑨ 的 python 把它们**逐位锚到黄金向量的下标**上，
认出来的约定写成人话（`自然序` / `交织 0,2,1,3`）。

**实测结论（这是 Task 4 目前唯一没达标的一条）**：

| 读数路 | pe1 | pe4 | pe16 |
|---|---|---|---|
| 装载 A → FNTT A → 读 A | **交织 `0,2,1,3`** | 自然序 | 自然序 |
| 装载 B → FNTT B → PWM2 A → 读 A | 三档逐位相同 | ← | ← |

- 三档的**装载**都是自然序，**变换结果**都能对上海量黄金向量（多重集 256/256）——
  所以对不上的只有 pe1 在 FNTT 读数路上的那个交织。
- **交织是上游 pe1 自己的约定，不是这次参数化引入的。** 证据在 B 的目录里：
  `refsim/pe1/fntt_batch_tb.v` 按自然序灌数（第 75 行），读回时靠
  `fout[4m+0], fout[4m+2], fout[4m+1], fout[4m+3]`（第 113-117 行）反交织才对上
  FIPS 203 黄金向量；`pwm2_batch_tb.v` / `intt_batch_tb.v` 的文件头也写明
  FNTT/PWM2 进出都是交织、**INTT 输出是自然序**。核与上游逐拍等价（段 ⑦），
  所以约定被原样继承。
- ⚠️ 因此**不能**引用 ⑧ 的 ✅ 说「三档 dout 序列逐位相同」。要让它成立，
  得在 `KyberHPMNTT_top` 里按「操作 + 折叠度」做反交织 —— 留给 Task 6。

**判据 2：三档周期数（实测，段 ⑨ 每次跑都重验）**

顶层量到的 `done` 拍 − `start_*` 起点 − 3 = 核周期数。三档 × 三个运算全中：

| | FNTT | PWM2 | INTT |
|---|---|---|---|
| pe1 | 904 | 647 | 904 |
| pe4 | 232 | 167 | 233 |
| pe16 | 69 | 47 | 71 |

与 `../H1_port_spec.md` §五 的上游实测值逐个相同。FNTT 是**两个 build 各量一次**
（纯 FNTT 路 + PWM2 路里的 FNTT A/B），两处结论一致 —— 这是同一张表的内部交叉验证。

- ⚠️ 周期数**不含延迟**：`done` 与折叠度无关地落在 `start_*+CC+3`，但第一条有效
  `dout` 是 `read_*+2*PE_NUMBER+3`（见 `top_behavior_tb.v`）。两件事别混。
- ⚠️ INTT 这一格**只量周期数**。`-DWITH_INTT` 那趟的 256 个读出值**没有黄金锚**
  （H1 §五 只锚了 FNTT），所以段 ⑨ 的 python 只读 `gold_fntt_*` / `gold_pwm2_*`，
  不去碰 `gold_intt_*`。INTT 的值判据在 Task 6。
- ⚠️ 探针自己的坑：**抓取必须和 `cyc` 自增在同一个 `always` 块里**。
  分成两块各带 `#1` 就是竞争，`cap[]` 会出现没写过的 X 槽，
  表现为「多重集不等 / `xxx` 值」这种看着像 RTL 挂了的现象。
- ⚠️ 还有一条**不是**探针的坑、而是常被误判的：`start_fntt(A)` 之后 `done` 还没来
  就把 `done_cyc` 打出来，会看到 `actual_done -1`。打印要放在 `step(CC+3+8)` **之后**。

向量来源是 `refsim/batch/ntt_batch_in.txt` 和 `ntt_batch_exp.txt`
（FNTT 的 16 组黄金向量，已由 FIPS 203 KAT 校验过的 C 参考实现算出）。
脚本只取第 0 组（前 256 行）。

### `ntt_func_tb.v` 的用法与坑

```sh
CORE="$(ls ../ntt_core/*.v | grep -v _top)"
iverilog -g2005 -DCFG_PE_NUM=4 -DOP_INTT -o w.vvp \
    ntt_func_tb.v $CORE ../ntt_core/KyberHPMNTT_top.v && vvp w.vvp
```

跑满 16 组向量（每组 256 系数），打出 `DOUT <组> <m> <值>`；段 ⑩ 的 python 逐组比
**多重集**，再从「读出位置 m ↔ 黄金下标」反推**读出顺序**。

**判据 3 的实测结果（段 ⑩ 每次跑都重验）：3 个运算 × 3 档，各 4096/4096 多重集相等；
PWM2 另加一版 `a ≠ b`（下表末行），同样 3 档 4096/4096。**

| 运算 | 装载路径 | 串行口给的顺序 | 读出顺序 |
|---|---|---|---|
| FNTT | `_f` | 三档都**自然序** | pe1 = 交织 σ｜pe4/pe16 = 自然序 |
| INTT | `_i` | 三档都 **σ** | 三档都是 τ |
| PWM2 | `_i` | pe1 = **σ**｜pe4/pe16 = **自然序** | 三档都 = 交织 σ |
| PWM2 **a ≠ b**（`-DOP_PWM2AB`） | `_i` | 同上（硬件路径完全相同） | 三档都 = 交织 σ |

σ(m) = 4·(m/4) + [0,2,1,3][m%4]（组内 0,2,1,3）｜τ(e) = e/2 + 128·(e%2)（0,128,1,129）

- ⚠️ **协议按 (运算, 折叠度) 分档，没有一套通用的。**
  **装载侧尤其：`_i` 不是一套规则，别按路径外推** ——
  `INTT _i` 三档都 σ，而 `PWM2 _i` 只有 pe1 是 σ、pe4/pe16 是自然序。
  （两者路径相同、要求不同，看的是**下一级消费者**：蝶形网络 vs pwm2 乘法器。）
  抄 pe1 那套去驱动 pe4/pe16 的 PWM2 会得到 **22/4096**（= 随机命中，看着像 RTL 挂了）；
  反过来把 INTT 的 σ 拨成自然序会塌到 **19/4096**。都不是 bug，是**顺序不同**。
  读出侧反而可以一句话概括：按**最后一次运算**，只有 FNTT 那格分折叠度。
- ⚠️ 上游只在 pe1 上按运算拆过 bench（`_FNTT`/`_INTT`/`_PWM2`），pe4/pe16 只有
  `_ALL_FULL`/`_ALL_HALF` —— 所以上表 pe4/pe16 那两列**没有上游文档可抄**，是扫出来的。
  ⚠️ 而「扫出来的」这句**直到 2026-10-04 才真的成立**：此前 `ntt_func_tb.v` 把 INTT / FNTT
  的装载顺序**写死在代码里**，只有 PWM2 那支认 `-DA_NAT/-DA_SIG`。表征是拿 `-DA_NAT`
  重跑 INTT 得到**逐字节相同**的转储、且不报任何错 —— 开关被无声忽略。
  三支现已统一走 `AMODE/A_I`。**凡做「拨开关重扫」这类验证，先确认开关真的到达了代码。**
- ⚠️ **pe1 是唯一的自检锚**：pe1 三处的读出顺序**必须**和 B 的 bench 一字不差
  （σ / τ / σ），段 ⑩ 会把这一条单独打出来（`校准 ✅`）。对不上说明是探针的脚手架错了，
  不是 RTL 错了。
- ⚠️ **读出顺序随数据变 = 探针有问题**。段 ⑩ 会逐组反推映射表并两两比对，
  有冲突就打 `⚠️ N 处组间冲突`。16 组都拿到同一张表才说明它是个固定置换。
- ✅ **阴性对照**（段 ⑩ 末尾，两条）：
  ① 把 pe4 的 PWM2 顺序拨成 σ，多重集必须塌到 ~22/4096；
  ② 拿 **a == b 的期望**去判 `a ≠ b` 那一跑（`func_pwm2ab_*`），三档必须塌到 ~17/4096。
  没有它们，「4096/4096」只说明自己跟自己对上了。
- ⚠️ **这条判据不含读出顺序**。三档的读出顺序**不统一**（见 `top_golden_tb.v` 一节），
  所以「固定 12 位接口」的**值序列一致**这一条仍未成立 —— 那是接口的事，不是功能的事。
- ⚠️ **`OP_PWM2` 那两个 bank 的输入逐位相同**（`pwm2_batch_a.txt` == `pwm2_batch_b.txt`，
  md5 一致、4096 行全同）——**这一格测的是平方**。它能判出「配对是否搞反」
  （配错了就变成 a[i]·a[j]，多重集立刻不等），但**分辨不出**「B 口没接上 / 装歪 /
  被 A 覆盖」：那些缺陷在 a == b 下照样给出 4096/4096。
  ✅ **2026-10-05 已由 `-DOP_PWM2AB` 补上这一格**：B 换成 A 的**下一组**
  （配对口径照 `refsim/gen_batch_vectors.py` 的 `gen_polmul()`：A 第 v 组、B 第 v+1 组循环），
  三档 4096/4096。期望值由 `run_probes.sh` 现算，**算它的 python 先用 a == b 的平方
  与仓库里冻结的 `pwm2_batch_exp.txt` 逐位对齐（4096/4096），对不上就地退出** ——
  不拿一个没对齐的实现去造新期望。`refsim/batch/` 一个字节没动，新增三份只落 `_work/`。
  ⚠️ **别把这条读成「PWM2 乘法器没验过 a ≠ b」**：真板子的 `#PMUL TIME` / `#PMUL FULL`
  喂的就是两份不同多项式（`halfmul_a/b`、`fullmul_a/b` 逐组逐位都不同），三档 5/5 × 256/256 全过。
  缺的只是**本探针**这一格 —— 现已不缺。
- ⚠️ 记一条现象、不下结论：`_f` 装载 + `start_pwm2`（两个 bank 都 `_f`，或者 A`_f`B`_i`
  混着）在本探针里读出**全是 X**。两个 bank 要用**同一条**装载路径。
- 非退化（约束 4）：四个 build 的期望向量分别有 2374 / 2355 / 2371 / **2336** 个不同值 / 4096
  （末一个是 `pwm2ab`；它和 `pwm2` 的期望**逐位相同的 0/4096** ⇒ 确实换了多项式，不是复读）。

## 判据

- 时序探针：直接打印带周期编号的时间线。
- 顺序探针：打印每一拍 `dout` 的原始十六进制，脚本再和黄金向量比对 ——
  **用「多重集合相等」判装载顺序**（顺序对了，输出的 256 个值作为集合必然等于黄金向量；
  读出顺序只影响先后）。装载顺序定下来之后，再逐位反推读出顺序。
