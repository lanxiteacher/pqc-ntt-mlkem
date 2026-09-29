# rtl/probes —— NTT 核接口时序探针

`../H1_port_spec.md` 里所有周期数和顺序表，都由这里的脚本跑出来。
不引用任何 gitignored 的中间文件，全新 clone 直接能跑。

## 跑

```sh
sh run_probes.sh
```

需要 `iverilog`（`/c/iverilog/bin`，不在 PATH 里，脚本自己加）和 `python`。

## 四个探针

| 文件 | 测什么 | 编出来的可执行 |
|---|---|---|
| `pe1_timing_tb.v` | pe1 的**接口时序**：`load_*` 怎么给、几拍出 `done`、`read_*` 后几拍出第一个 `dout`、有效读数多少拍 | `-DUSE_TOP` 则换成测 `KyberHPM1PE_top` |
| `order_tb.v` | pe4 / pe16 的**装载顺序和读出顺序**：一拍里 PE_NUMBER 个 12 位切片各对应哪个系数下标 | `-DPE16` 切到 pe16，默认 pe4 |
| `leaf_elab_tb.v` | `../ntt_core/` 的叶子（`ntt_BRAM` / `ntt_BROM`）三档**能否例化**、深度/位宽对不对、BROM 内容抽查 | `-DCFG_PE_NUM=` / `-DCFG_TW=` |
| `ag_equiv_tb.v` | `../ntt_core/ntt_addressgenerator` 与 `../pe{1,4,16}/addressgenerator` 的**逐拍等价**：同一份激励喂两个模块，每个时钟沿比 18 路输出 | `-DCFG_L=`（7/5/3），pe1 另需 `-DHAS_PE1_PORTS` |

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

向量来源是 `refsim/batch/ntt_batch_in.txt` 和 `ntt_batch_exp.txt`
（FNTT 的 16 组黄金向量，已由 FIPS 203 KAT 校验过的 C 参考实现算出）。
脚本只取第 0 组（前 256 行）。

## 判据

- 时序探针：直接打印带周期编号的时间线。
- 顺序探针：打印每一拍 `dout` 的原始十六进制，脚本再和黄金向量比对 ——
  **用「多重集合相等」判装载顺序**（顺序对了，输出的 256 个值作为集合必然等于黄金向量；
  读出顺序只影响先后）。装载顺序定下来之后，再逐位反推读出顺序。
