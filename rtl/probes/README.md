# rtl/probes —— NTT 核接口时序探针

`../H1_port_spec.md` 里所有周期数和顺序表，都由这里的脚本跑出来。
不引用任何 gitignored 的中间文件，全新 clone 直接能跑。

## 跑

```sh
sh run_probes.sh
```

需要 `iverilog`（`/c/iverilog/bin`，不在 PATH 里，脚本自己加）和 `python`。

## 三个探针

| 文件 | 测什么 | 编出来的可执行 |
|---|---|---|
| `pe1_timing_tb.v` | pe1 的**接口时序**：`load_*` 怎么给、几拍出 `done`、`read_*` 后几拍出第一个 `dout`、有效读数多少拍 | `-DUSE_TOP` 则换成测 `KyberHPM1PE_top` |
| `order_tb.v` | pe4 / pe16 的**装载顺序和读出顺序**：一拍里 PE_NUMBER 个 12 位切片各对应哪个系数下标 | `-DPE16` 切到 pe16，默认 pe4 |

向量来源是 `refsim/batch/ntt_batch_in.txt` 和 `ntt_batch_exp.txt`
（FNTT 的 16 组黄金向量，已由 FIPS 203 KAT 校验过的 C 参考实现算出）。
脚本只取第 0 组（前 256 行）。

## 判据

- 时序探针：直接打印带周期编号的时间线。
- 顺序探针：打印每一拍 `dout` 的原始十六进制，脚本再和黄金向量比对 ——
  **用「多重集合相等」判装载顺序**（顺序对了，输出的 256 个值作为集合必然等于黄金向量；
  读出顺序只影响先后）。装载顺序定下来之后，再逐位反推读出顺序。
