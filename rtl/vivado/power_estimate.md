# 功耗估算（Vivado report_power）—— 六版位流

> 2026-10-18 · A ｜ 出彩组合第 7 件里 A 负责的那一半
> 证据：`rtl/vivado/reports/power_pe{1,4,16}_{50,80,75,62}mhz.rpt`
> 复跑：见 §五

## 一、结论

| 档 | 频率 | 总功耗 | 动态 | 静态 | 结温 | 其中 MMCM | 证据 |
|---|---:|---:|---:|---:|---:|---:|---|
| pe1 | 50 MHz | **0.130 W** | 0.023 W | 0.106 W | 26.5 °C | — | `power_pe1_50mhz.rpt` |
| pe4 | 50 MHz | **0.170 W** | 0.062 W | 0.107 W | 27.0 °C | — | `power_pe4_50mhz.rpt` |
| pe16 | 50 MHz | **0.335 W** | 0.223 W | 0.112 W | 28.9 °C | — | `power_pe16_50mhz.rpt` |
| pe1 | 80 MHz | **0.257 W** | 0.148 W | 0.108 W | 28.0 °C | **0.116 W** | `power_pe1_80mhz.rpt` |
| pe4 | 75 MHz | **0.300 W** | 0.191 W | 0.109 W | 28.5 °C | **0.116 W** | `power_pe4_75mhz.rpt` |
| pe16 | 62.5 MHz | **0.440 W** | 0.326 W | 0.114 W | 30.1 °C | **0.105 W** | `power_pe16_62mhz.rpt` |

## 二、三个结论

1. **静态功耗占大头。** 50 MHz 三档的静态都是 **0.106–0.112 W**，占总功耗的 33%–81%。
   它是器件漏电，与设计几乎无关 —— 所以 pe1 的 0.130 W 里，真正「我们的逻辑在动」的只有 0.023 W。
2. **折叠度越深，动态功耗越高。** pe1 → pe4 → pe16：动态 **0.023 → 0.062 → 0.223 W**（约 9.7×），
   对应 LUT 727 → 2,000 → 8,922、BRAM 2.5 → 9 → 34.5 tile、DSP 1 → 4 → 16。
   折叠度买来的是周期数（904 → 69），付的是面积与动态功耗。
3. **提频的代价主要是 MMCM 自己。** pe1 从 0.130 W 涨到 0.257 W，**+0.127 W；其中 MMCM 占 0.116 W**，
   逻辑只多了约 0.01 W。也就是说：**在这块板上，提频 1.6× 的功耗代价几乎全落在时钟管理器上**，
   而不是运算逻辑。67 °C 的温升余量（Max Ambient 82 °C vs 结温 28 °C）说明**不需要散热措施**。

## 三、口径（引用时必须连这段一起写）

- **这是 vectorless 估算，不是实测。** Vivado 2020.2 没有 SAIF/VCD（`Simulation Activity File: ---`），
  用默认开关活动率传播，报告自己的 Confidence Level 是 **Medium**。
  绝对值可能有 ±20%–30% 的偏差；**只能用来看量级与相对趋势**，不能当毫瓦级结论引。
- **只算片内 PL。** 不含 CH340、电平转换、LDO 损耗、LED —— **整板功耗会比这个数高**。
- **环境是 25 °C、典型工艺角**；结温是估算值（`Effective TJA` 11.5 °C/W，无散热器）。
- **输入活动率未指定**：报告自己标了「More than 5% of inputs are missing user specification」。
  真实数据通路的翻转率取决于送进去的向量；本项目的向量是满负荷随机系数，实际可能更高。
- **没有做实测**：板上没有分流电阻 / PMBus 可读，做实测要改硬件，超出本轮范围。

## 四、为什么值得写进报告

评分项「性能与资源优化效果 20 分」要的不只是「快」，还要说清**代价**。这三条结论正好把
「折叠度」与「提频」两件事的代价量化了：

- 折叠度：周期数 13× 的收益，代价是 LUT 12× 与动态功耗 9.7×；
- 提频：频率 1.6× 的收益，代价是 **+0.116 W 的 MMCM**，而逻辑功耗几乎不变。

## 五、复跑

```sh
# 1) 出布线后的 DCP（TAG 只影响产物名，不影响设计）
DCP=/c/vivado_work/dcp_pwr TAG=_pwr50 PE=1 \
  VIVADO_RUNS=rtl/vivado/_runs/pwr50_pe1 sh rtl/vivado/run_board_synth.sh

# 2) 在 DCP 上跑 report_power
sh rtl/vivado/run_board_power.sh \
   /c/vivado_work/dcp_pwr/ntt_board_pe1_pwr50.dcp \
   rtl/vivado/reports/power_pe1_50mhz.rpt

# 提频版：加 TOP=ntt_board_top_mmcm MMCM_MULT=<m> MMCM_DIV=<d>，TAG 相应改
```

⚠️ `run_board_power.sh` 只读 DCP，不碰板子；单次约 40 秒。
