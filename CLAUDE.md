# CLAUDE.md

FPGA 竞赛项目：**AMD 赛道 · 3.3 自主选题（初级组）· 后量子密码 ML-KEM 的 NTT/INTT/点乘 FPGA 加速核**。
三人零基础队伍，AI-agent 打法，**PL 算核 + PS 轻量协同**。

**开工先读 `logs/FPGA竞赛_项目记录.md`**（当前状态 + 待办）。历史过程在 `logs/FPGA竞赛_项目记录_归档.md`，日常不用读。

**用户 = A。本机就是 A 的工位** —— Vivado 与板子都接在本机（见下方「环境」）。
对话里说"我"= A，**主责目录是 `rtl/`**。
`refsim/`(B)、`host/`(B)、`demo/ docs/ assets/`(C) **不是本机的主场** ——
要动先跟对应的队友对齐（见「多人协作」第 2 条）。三人分工见 `team/FPGA竞赛_三人分工.md`。

---

## 环境

- Windows 11 + Git Bash（`Bash` 工具）
- 每台机器上仓库路径不同（本机 `C:\Users\l'x\Desktop\FPGA`）——
  **脚本里一律用 `$(dirname "$0")` 定位自己，不写死绝对路径**
- **iverilog 12.0 在 `C:\iverilog\bin`，不在 PATH 里** —— 每次先 `export PATH="/c/iverilog/bin:$PATH"`
- 还需要 **gcc**（编译 C 参考实现外壳）和 **python 3**（向量生成与比对）
- **Vivado ML Standard 2020.2 装在本机** —— `E:\xilinx\Vivado\2020.2`
  （可执行文件 `E:\xilinx\Vivado\2020.2\bin\vivado.bat`；⚠️ 实际目录名是**小写** `xilinx`）
  **综合 / 上板 / 时序 / 资源的事在本机就能做**，不要说"做不了"
- **板子也接在本机**（正点原子**领航者 ZYNQ**，器件 `xc7z020clg400-2`，与板子完全一致）——
  板载 CH340C，串口号 **COM10**（设备名 `USB-SERIAL CH340`）。⚠️ 板子不常插着，
  **动手前先确认 COM10 在**（`[System.IO.Ports.SerialPort]::GetPortNames()`）。
  COM 口存在 ≠ PL 通路通：要烧 `19_uart_loopback` + 底板 **P5 跳 PL 档**才算确认
- **正点原子资料已在本机** —— `E:\BaiduNetdiskDownload\正点原子资料`（23 GB）。
  上板要的四个引脚（例程 XDC 与全板 `NAVIGATOR_ZYNQ_IO.xdc` 已交叉核对一致，均 LVCMOS33）：
  `sys_clk` **U18**（50 MHz）｜`sys_rst_n` **N16**（**低有效**）｜
  `uart_rxd` **T19**｜`uart_txd` **J15**
  ⚠️ **复位极性与我们的 RTL 相反** —— 上游 pe1/pe4/pe16 是 `reset` 异步**高**有效。
  ⚠️ 全板 XDC 里 `uart_rxd`/`uart_txd` 定义了**三次**，是互斥备选
  （USB UART `T19/J15`、PL_UART(RS232)/RS485 `K14/M15`）；我们只用 **USB UART 那组**。
  ⚠️ rar 里的源码/readme 是 **GBK**，本机**没有 iconv** —— 用 PowerShell
  `[System.IO.File]::ReadAllText($p, [System.Text.Encoding]::GetEncoding(936))`
- **B 全程不需要板子和 Vivado**，进度不被 A 卡住 —— 见 `team/FPGA竞赛_B_引导与计划.md`

## 目录

| 路径 | 内容 | 主责 |
|---|---|---|
| `refsim/` | **RTL 验证台**（本仓库的核心资产）—— 见下方「跑验证」 | B |
| `rtl/` | 改造后的 RTL、引脚约束、Vivado 工程 | A |
| `host/` | PC 上位机：串口喂数据 + 收回 + 自动比对 | B |
| `logs/` | **项目记录与进度排期**（当前状态、变更记录、人话版排期） | — |
| `team/` | 分工与个人计划（可直接转发队友） | — |
| `demo/` `docs/` `assets/` | 演示页 / 报告 / 截图录屏素材 | C |
| `research/` | **只读参考资料，谁都不改** | — |

`research/` 下四个关键入口：`ref_rtl/kyber-polmul-hw/pe1/`（开源 NTT 硬件基线，
**已通过 FIPS 203 验证**，是改造起点）｜`kyber_ref/`（C 参考实现 = 地面真值）｜
`research/mlkem_kat/`（FIPS 203 官方考题，1000 条全过）｜
`PQC-NTT_ML-KEM_技术资料汇编.md`（22 篇论文 + 标准汇编）。

**目录名一律英文**（竞赛要求开源仓库目录名纯英文）；文件名可以中文。
**新建目录前先看这份表**，别另起炉灶 —— 三个人对不上的时候，成本比一开始商量高得多。

`research/ref_rtl/` 是**只读原件**，任何修改都在 `refsim/pe1/` 的副本上做。

`research/papers/`（以及 `research/kyber_ref/papers/` 里的 PDF 和抓下来的网页）
**不进仓库** —— 版权属于各出版方，而本仓库最终要按竞赛要求转公开；也不影响复现。
规则和理由写在 `.gitignore` 里，别加回去。

## 跑验证

```bash
cd refsim && sh run_fntt_check.sh         # NTT 全流程：KAT → 参考实现 → RTL，一条命令
cd refsim && sh run_intt_pwm2_check.sh    # INTT + 点乘 + RTL 往返自检
cd refsim && sh run_polmul_check.sh       # 完整多项式乘法（端到端）：FULL + HALF
cd refsim && sh run_ntt_layers.sh         # 导出并机器验证 twiddle 层序表
```

验证链、设计取舍、覆盖边界都写在 `refsim/README.md`。

---

## 约定（每条都踩过坑）

1. **跨平台数据文件统一 LF 行尾，写文件用 `"wb"` 不用 `"w"`。**
   Windows 会把 `\n` 翻成 `\r\n`，导致 256 个数值全对、`diff` 却报"256 行全不同"。别用 `--strip-trailing-cr` 遮掩。
   **仓库层已用 `.gitattributes` 的 `* -text` 兜住**（不做任何行尾转换，存什么取什么）。
   Git for Windows 默认 `core.autocrlf=true`，会在 checkout 时把 LF 改写成 CRLF，
   等于让每个队友重踩一遍这个坑。**不要**改成 `text=auto` 或 `eol=lf` —— 那两种都会改写字节。

2. **testbench 里不要写无界 `while (done == 0)`。**
   单次跑没事，套进循环后任何一轮异常都会永久挂死而不是报错。加计数护栏。

3. **"验证通过"必须配"非退化"才作数。**
   灌数据前先统计有多少个不同值 —— 向量全是 0/常量时，"全中"可能只是巧合。现有多向量是 4096 系数 / 2355 个不同值。

4. **对拍前先确认比的是哪一个函数。**
   `poly_ntt()` = 裸 `ntt()` **+ `poly_reduce()`**，两者输出**不相等**。

5. **动手"复现"某个东西之前，先确认它存在。**
   曾花大力气重建一张根本不存在的 `zetas_inv` 表 —— 正逆变换共用同一张 `zetas[]`，只是方向相反。

6. **写给队友/第三方看的文档，不写评价性、安慰性语言**（如"这块不是打杂"）。
   只写事实与操作。自查：这句话删掉之后信息有没有损失？没有就删。

---

## 多人协作（三个人、多台机器、多个 Claude）

仓库在 Gitee 上，**A / B / C 各自 clone，可能同时有多个 Claude 会话在改同一个仓库**。

1. **开工先 `git pull`，收工 `git commit && git push`。** 别攒。
2. **只改自己主责的目录**（见上方目录表「主责」列）。
3. **`CLAUDE.md`、`logs/FPGA竞赛_项目记录.md`、`team/` 是共享的** —— 改之前先跟对方说一声。
4. **一个能跑通的小步 = 一个提交。** 不做完不合并，保持仓库随时可运行。
5. **冲突了不要硬合、不要 force push**，先停下来问。
6. **改共享文档前先 `git pull`** —— 两个 Claude 各拿一份过期文档同时改，是最容易出事的情形。

**文件互通格式**（黄金向量、批量对拍数据、RTL 端口说明、串口协议）见
`team/FPGA竞赛_B_Claude环境对齐指南.md` 第六节。
**B 的环境搭建与第一天 checklist** 见同一份文档。

---

## 与用户协作

- 用户是零基础队伍的组织者，**需要通俗解释**，但也要能直接用的结论
- 面向队友的文档要能**直接转发**，不要有只能自己看懂的黑话
- **禁止杀 `claude.exe` / `node.exe`** —— 它们就是会话本身
- 文件操作：**复制而不是移动**；损坏的文件移到 `_broken/`，**不要删除**
