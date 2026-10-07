# scripts —— 校验脚本

选题指导 §8.2 点名的三类校验：**① 自动比对黄金模型 ② 检查资源与时序
③ 验证工程可复现性**。下面分别是它们在本仓库的位置与用法。

---

## 本目录的三个脚本（新写的，零依赖）

| 脚本 | 做什么 | 用法 |
|---|---|---|
| [`check_data_format.sh`](check_data_format.sh) | 校验数据文件格式：每行恰好 3 位小写十六进制 + LF | `sh check_data_format.sh <文件或目录> [...]` |
| [`check_nondegenerate.sh`](check_nondegenerate.sh) | 统计不同值个数与最常见值占比，判「全中」有没有意义 | `sh check_nondegenerate.sh <文件或目录> [...]` |
| [`check_reproducible.sh`](check_reproducible.sh) | 干净临时目录里全新 clone，从零跑入口脚本 | `sh check_reproducible.sh [--from-remote]` |

**依赖：只有 `sh` + `awk`。** Linux / macOS / Git Bash 自带，**不需要装任何东西**。

> **为什么用 sh+awk 而不是 python：** 这三个脚本的价值在于「别人拿去立刻能跑」。
> 写成 python 就多一个「先装 python」的门槛 —— 而本项目的经验是，
> **一个没装 python 的机器会把这件事卡住**（见 `../checklists/toolchain-and-board.md`）。
> 用 awk 写完，任何人拿到都能跑。

### 各自要解决的具体问题

**`check_data_format.sh`** —— 格式坑的表现全是「**数值全对、比对全错**」：
十六进制没补零（`27` vs `027`）、行尾 CRLF（`diff` 报「256 行全不同」）。
人对着一屏数字看不出来，脚本一秒列出**哪一行、什么原因**。
它会同时报出 CRLF 与「末行缺换行」，三类问题分别可辨。

**`check_nondegenerate.sh`** —— 「4096/4096 全中」这句话，
在**向量本身没有区分度**的时候没有意义（一个把输入原样输出的设计，
在全零向量上也能全中）。默认判据：不同值占比 ≥ 30%、最常见值占比 ≤ 2%；
本项目实际是 58% 与 < 0.25%。

**`check_reproducible.sh`** —— 「在我机器上能跑」证明不了任何事。
本项目真实踩过：两条脚本依赖三个编译出的 `.exe`，而 `*.exe` 被 `.gitignore`
挡住、**根本没进仓库**；本机因为留着上次的产物，一直看不出问题。
所以判据必须是「干净目录 + 全新 clone + 从零跑」。
⚠️ 它默认从**本地** clone（离线快），能查出「依赖未入库的产物」，
**查不出「文件没 push」** —— 判定可复现请用 `--from-remote`。

---

## 每项的四件套（《选题指南》§3.3.5.2）

指南要求**每一项**写明 **适用场景 / 使用方法 / 失效条件 / 已验证的效果**，
并说明**是从哪些失败或观察中总结得出**。「已验证的效果」一列**写实测数**，
不写「设计如此」。

| 项 | 适用场景 | 使用方法 | 失效条件 | 已验证的效果 |
|---|---|---|---|---|
| `check_data_format.sh` | 任何要**逐字节比**的数据文件 | `sh check_data_format.sh <文件或目录> [...]` | 只查「**每行 3 位小写十六进制 + LF**」这一种格式 | 10-05 实测 `refsim/batch/`：53 文件 / 71168 行 → **23 文件 / 1290 行**不合规，并标出 **1 个 CRLF 文件**；每条违规给行号与原因（未补零 / CRLF / 末行缺换行可辨） |
| `check_nondegenerate.sh` | 「全中」结论的可信度存疑时 | `sh check_nondegenerate.sh <文件或目录> [...]` | 判据（不同值 ≥ 30%、最常见 ≤ 2%）是**经验阈值**，非普适 | 10-05 实测：`ntt_batch_in` 4096 行 → **2355 个不同值（57.5%）、最常见值 0.17%**；intt / pwm2 均 2374（58.0%）、0.15% |
| `check_reproducible.sh` | 判定「别人能不能跑通」时 | `sh check_reproducible.sh [--from-remote]` | 默认从**本地** clone **查不出「没 push」** → 判可复现须加 `--from-remote` | 起源于真实事故（两条脚本依赖 3 个被 `.gitignore` 挡住的 `.exe`，本机看不出来）。10-05 `--from-remote` **首次真绿**（通过 4／跳过 0／失败 0，退 0）；同轮逼出 `run_intt_pwm2_check.sh` 把入库文件写成 CRLF（**10-06 已修**：`cp`→`tr`；10-07 复跑确认工作区干净、4/4 过） |
| `refsim/` 四条入口（**不复制**） | 验「RTL 算得对不对」（而非「作者 testbench 跑没跑通」） | `cd refsim && sh run_{fntt,intt_pwm2,polmul}_check.sh` / `run_ntt_layers.sh` | 需 gcc + iverilog + python3；覆盖**止于一次多项式乘法** | 四条链各 **16 组 × 256/256** 全过；10-05 在**非作者**机器上、全新 clone 逐条真跑通 |

> 「从哪些失败中总结」：前三条分别来自——`diff` 假失败（格式坑）、
> 「全零向量上也能全中」（无区分度）、「本机能跑但产物没入库」。
> 四条入口的来历见 `../../refsim/README.md`。

---

## ① 比对黄金模型：现成的在 `refsim/`（不复制，直接用）

这块是本仓库最成熟的资产，四条入口脚本各自自包含（`$(dirname "$0")` 定位、
自带依赖检查）。**本目录不复制它们** —— 复制会分叉，改一处忘一处。

```sh
cd refsim
sh run_fntt_check.sh          # 正变换全流程：KAT → 参考实现 → RTL
sh run_intt_pwm2_check.sh     # 逆变换 + 点乘 + 往返自检
sh run_polmul_check.sh        # 完整多项式乘法（端到端）
sh run_ntt_layers.sh          # 导出并机器验证 twiddle 层序表
```

需要 **gcc + iverilog + python 3**（先跑 `check_reproducible.sh` 看缺什么）。

**这套链的设计要点**（比脚本本身值得抄）：

```
国际标准测试向量（FIPS 203 兼容 KAT，1000 条）
        │  独立复算，逐比特
        ▼
参考实现（自己编译的官方实现）   ←── 从此它是"地面真值"
        │  复算上游给的输入
        ▼
上游自带的期望输出  ── 逐比特一致
        │
        ▼
上游 RTL  ── 用自己生成的 16 组向量，逐比特一致
```

中间那一环是关键：**上游的期望输出与参考实现逐比特一致**，
既证明上游数据没错，也证明我们对参考实现的理解（域约定、输出顺序）与上游一致 ——
否则后面拿自己的向量去灌 RTL，**顺序对不上会假报失败**。

**「跑通作者自带的 testbench」什么也证明不了** —— 那是拿作者的期望值比作者的 RTL，
只能证明自洽。详见 `../checklists/verification.md` 第 5 条。

---

## ② 检查资源与时序：解析报告，不手抄数字

工具报告是文本，**可以机器解析**。本项目的做法在 `../../metrics/gen_metrics.mjs`：
从报告里解析出 LUT / FF / DSP / BRAM / IOB / WNS，**生成**指标表 ——
而不是让人往表里敲数字（敲过一次就不会再回来改第二次）。

同一份思路的通用版可直接抄：`../../metrics/gen_metrics.mjs` 的 `utilField()` /
`timingSummary()` 两个函数。

**解析报告时必查的四条**（都踩过，详见 `../checklists/rtl-and-timing.md`）：

1. **BRAM 的「个数」有三种口径，差 2 倍** —— RAMB18 个数 / Vivado 的 Block RAM Tile
   （RAMB18 记 0.5）/ BRAM36 当量。引数字必须带单位。
2. **`Design State : Fully Placed` 可能是假的** —— 要跟日志交叉核，
   `place_design` 失败时那句照样写着。
3. **WNS 为负是设计如此**（约束故意给紧、反推频率），
   但**断言 `WNS < 0`**：为正是约束太松、Fmax 没有意义。
   ⚠️ 解析时**别用「以 `-` 开头就跳过」过滤横线** —— 负 WNS 也被吃掉，
   脚本会扫到别处拿到正数，表现为「几档频率一模一样」。
4. **不同实现阶段不可比** —— 只到综合的 WNS 是估值，布线后的是实测。

---

## ③ 验证工程可复现性：`check_reproducible.sh`

判据、用法、局限都写在上面那张表与脚本头部注释里。
**交给评审判定「可复现」之前，用 `--from-remote` 跑一遍** ——
那才是评委拿到的东西。

---

## 相关

- 验证方法学（怎么才算「验过了」）：`../checklists/verification.md`
- 数据格式的坑：`../checklists/data-format.md`
- 报告解析与时钟约束的坑：`../checklists/rtl-and-timing.md`
- 本项目的验证台（四条入口 + 覆盖边界）：`../../refsim/README.md`
- 本项目的指标表（机器生成）：`../../metrics/README.md`
