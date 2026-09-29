# rtl/probes —— NTT 核接口时序探针

`../H1_port_spec.md` 里所有周期数和顺序表，都由这里的脚本跑出来。
不引用任何 gitignored 的中间文件，全新 clone 直接能跑。

## 跑

```sh
sh run_probes.sh
```

需要 `iverilog`（`/c/iverilog/bin`，不在 PATH 里，脚本自己加）和 `python`。

## 五个探针

| 文件 | 测什么 | 编出来的可执行 |
|---|---|---|
| `pe1_timing_tb.v` | pe1 的**接口时序**：`load_*` 怎么给、几拍出 `done`、`read_*` 后几拍出第一个 `dout`、有效读数多少拍 | `-DUSE_TOP` 则换成测 `KyberHPM1PE_top` |
| `order_tb.v` | pe4 / pe16 的**装载顺序和读出顺序**：一拍里 PE_NUMBER 个 12 位切片各对应哪个系数下标 | `-DPE16` 切到 pe16，默认 pe4 |
| `leaf_elab_tb.v` | `../ntt_core/` 的叶子（`ntt_BRAM` / `ntt_BROM`）三档**能否例化**、深度/位宽对不对、BROM 内容抽查 | `-DCFG_PE_NUM=` / `-DCFG_TW=` |
| `ag_equiv_tb.v` | `../ntt_core/ntt_addressgenerator` 与 `../pe{1,4,16}/addressgenerator` 的**逐拍等价**：同一份激励喂两个模块，每个时钟沿比 18 路输出 | `-DCFG_L=`（7/5/3），pe1 另需 `-DHAS_PE1_PORTS` |
| `core_equiv_tb.v` | `../ntt_core/KyberHPMNTT` 与 `../pe{1,4,16}/KyberHPM{1,4,16}PE` 的**逐拍等价**：每个时钟沿比全部端口 + 全部内部状态（三档 39 / 111 / 399 路） | `-DCFG_PE_NUM=` **和** `-DCFG_PE_MOD=`（两个都要给，见下） |

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

向量来源是 `refsim/batch/ntt_batch_in.txt` 和 `ntt_batch_exp.txt`
（FNTT 的 16 组黄金向量，已由 FIPS 203 KAT 校验过的 C 参考实现算出）。
脚本只取第 0 组（前 256 行）。

## 判据

- 时序探针：直接打印带周期编号的时间线。
- 顺序探针：打印每一拍 `dout` 的原始十六进制，脚本再和黄金向量比对 ——
  **用「多重集合相等」判装载顺序**（顺序对了，输出的 256 个值作为集合必然等于黄金向量；
  读出顺序只影响先后）。装载顺序定下来之后，再逐位反推读出顺序。
