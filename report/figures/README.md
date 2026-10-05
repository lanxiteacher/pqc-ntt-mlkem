# report/figures —— 报告配图

**主责：C** ｜ 状态：🔄 **3 张矢量图 + 3 张演示页截图（浅色报告版，2026-10-02）**

> 放**报告正文里要用的图**。素材原图（截图、录屏）在 `../../assets/`，
> 不要在这里重复存一份 —— 这里只放**排版好的、要进报告的**那一版。

---

## 一、现有的图

| 文件 | 用在哪 | 画的是什么 |
|---|---|---|
| `folding_sweep.svg` | `design/03_performance_and_resources.md` §3.3 | 折叠度三档（1 / 4 / 16 蝶形）的 **NTT 周期数 / LUT 占用 / 推算 Fmax** 三个面板 |
| `verify_chain.svg` | `design/04_functional_correctness.md` §4.3 | 验证链：FIPS 203 KAT → C 参考实现 → 作者期望输出 → RTL 对拍，四个入口脚本与结果标在链上 |
| `architecture.svg` | `design/02_design_and_innovation.md` §2.2 | 架构三层：`KyberHPMNTT_top` 的对外端口 / 核外的序列化-反序列化 / 核内的宽接口。实线 = 数据，虚线 = 控制 |
| `demo_ntt_layer3.png` | `design/05_reproducibility.md` §5.4 | 演示页（**浅色报告版**）：正变换走到第 3 层，右侧显示选中系数的蝶形算式与配对 |
| `demo_compare_pass.png` | `design/05_reproducibility.md` §5.4 | 演示页对拍页：RTL 落盘输出 vs 黄金向量，**4096/4096 全中**，全场无红格 |
| `demo_compare_negctrl.png` | `design/04_functional_correctness.md` §4.7 | 演示页阴性对照：改坏一条期望值 → 网格里**恰好 1 个红格** |

**这 3 张是截图，不是矢量图**（页面是交互式的，只能截）。生成方式：
`node demo/gen_shots.mjs` —— 无头 Edge 驱动，源页在 `../../demo/`。
它们用 **`?theme=light` 浅色主题**（专为黑白打印，深色原图在 `../../assets/`），
且只截「标题 + 网格」一小块（`clip`），不是整页。
⚠️ **对拍两张在出图前断言红格数**（pass = 0、negctrl = 1）—— 图名在断言的事由脚本核实，不靠目视。

**这张图的数字不是手抄的**，来源是 `../../metrics/data/metrics.csv`
（该 CSV 由 `../../metrics/gen_metrics.mjs` 从 `../../rtl/vivado/reports/*.rpt` 解析生成）。
图里的对比倍数（13.1× / 12.3× / 8%）也是脚本从 CSV 算的，不是写死的。

**重新生成**：

```bash
node report/figures/gen_figures.mjs      # → report/figures/folding_sweep.svg
```

⚠️ **参数化版本重测后（W5）要重跑这一步** —— 先跑 `node metrics/gen_metrics.mjs` 更新 CSV，
再跑本脚本更新图。两处都不需要手工改数字。

⚠️ `verify_chain.svg` 和 `architecture.svg` 与上面那张性质不同：它们是**结构示意图，
不是数据图**，手写 SVG、没有生成脚本。内容分别与 `../../refsim/README.md` §一、
`design/02_design_and_innovation.md` §2.2–§2.5 对齐 —— **改结构时要手工同步这两张图**。

⚠️ `architecture.svg` 里**引用了三个数字**（引脚 397 / 芯片可用 125 / 三档 IOB = 37）——
引用不等于推导，所以没配生成脚本，但**它们会随参数化版本 W5 重测而变，重测后要回来核一遍**
（出处：`../../rtl/vivado/folding_comparison.md` §五／§六／§九）。

⚠️ **本机没有 Vivado**（Vivado 与板子都在 A 的工位），所以这张图用的是**工具推算值**，
不是上板实测。图上已标注这一点。

---

## 二、还缺的图（要谁说清）

| 图 | 要什么 | 谁 / 什么时候 |
|---|---|---|
| **关键路径截图** | **两组各一张（pe1）**：① **核** —— `pe{1,4,16}_nc_timing.rpt` 的 `-max_paths 10` 段（对应 `design/03` §3.7）；② **板级** —— `board_pe{1,4,16}_timing.rpt`（对应 §3.13.4）。⚠️ 两个流程是**非工程模式**，跑完**不留 `.xpr` / `.dcp`**，GUI 里没有设计可打开 —— 2026-10-05 已给两者加可选 `DCP=` 产出 checkpoint（见 `../../logs/runbook_2026-10-05_h4_screenshot_and_recording.md`），此后可截 | 需要 Vivado —— **C 本机做不了**，A 截（两组各 pe1 一张；三档路径结构相同，要全截各多跑一次） |
| ~~**架构框图**（矢量版）~~ | ✅ **已成** `architecture.svg`（10-01） | C（已完成；`design/02` §2.2 已引用） |
| ~~**演示页截图**~~ | ✅ **原图 4 张在 `../../assets/`（深色）**；**报告版 3 张浅色截图已进本目录**（`demo_*.png`，10-02）。浅底版由 `?theme=light` + `clip` 裁到「标题 + 网格」生成 | C（**已完成**） |
| **波形截图** | `refsim/` 对拍时的波形 | 要 B 给（H5，W3 起） |

---

## 三、格式约定

- **矢量优先**：能生成 SVG 就用 SVG（Word / LaTeX 都能插，放大不糊）
- 位图截图用 **PNG**（不用 JPG —— 波形和界面上有细线，JPG 会糊）
- 文件名**英文小写 + 下划线**（本目录沿用 `skill/` 的口径，两条规则下都合规）
- 每张图在 `design/` 正文里要有一句「这张图说明什么」，不要只贴图不解释

---

## 相关

- 报告正文与进度：`../README.md`｜`../design/`
- 素材原图：`../../assets/`
- 指标数据源：`../../metrics/README.md`
