# 基于 FPGA 的后量子密码硬件加速平台

> AMD 赛道 · 3.3 自主选题（初级组）
> 目标器件：正点原子领航者 ZYNQ-7020（XC7Z020）
> 许可证：[Apache License 2.0](LICENSE)

以 ML-KEM 的核心运算 **NTT（数论变换）** 为切入点，在 FPGA 上实现低延迟的
多项式乘法加速核，并配套一条以 FIPS 203 官方考题为终点的**软硬协同验证链**。

---

## 一、这是什么

ML-KEM（FIPS 203，即 CRYSTALS-Kyber）是 NIST 后量子密码标准中的密钥封装算法。
其中计算量最大的一步是 **NTT** —— 在模 q = 3329 的有限域上，对 256 点多项式做变换。

本仓库包含两部分：

| 部分 | 内容 |
|---|---|
| **硬件加速核** | `refsim/pe1/` —— 在开源硬件基线 `kyber-polmul-hw/pe1` 上改造的工作副本；`rtl/` —— 交付给 Vivado 工程的产物（当前为 twiddle 表） |
| **验证台** | `refsim/` —— 用官方考题锚定参考实现，再拿参考实现逐比特对拍 RTL |

验证台是本仓库的核心资产。它回答的问题不是"作者的 testbench 跑没跑通"，
而是"**这份 RTL 算得对不对**"——这两件事不一样，理由见 `refsim/README.md` 开头。

---

## 二、当前进度

### 已验证

| 项 | 结果 |
|---|---|
| FNTT（正向 NTT） | ✅ 16 组向量，4096/4096 系数逐比特一致 |
| INTT（逆向 NTT） | ✅ 16 组向量，4096/4096 |
| PWM2（点乘，NTT 域） | ✅ 16 组向量，4096/4096 |
| 完整多项式乘法 FULL（FNTT→FNTT→PWM2→INTT） | ✅ 16 组向量，4096/4096（端到端，无缩放因子） |
| 半程多项式乘法 HALF（FNTT→PWM2→INTT） | ✅ 16 组向量，4096/4096（端到端，无缩放因子） |
| 往返自检（RTL 的 FNTT 实际输出灌回 RTL 的 INTT） | ✅ 4096/4096 回到时域原值 |
| 阴性对照（人为改坏一个期望值） | ✅ 恰好报出 1 个系数不符，且位置正确 |
| 非退化性 | ✅ 每 4096 个系数中 2355～2374 个不同值，最常见值占比 < 0.25% |

"验证通过"必须配"非退化"才作数——向量全是常量时，全中也可能只是巧合。
上表最后一行是这个判据的实测值。

### 尚未验证

- **ML-KEM 更外层的运算**：向量级点乘累加（`polyvec_basemul_acc_montgomery` 那一层）、
  base case 乘法、以及 `poly_tomont` / `poly_reduce` 归位。
- **多 PE 配置**：只验了 `PE_NUMBER=1`，`pe4` / `pe16` 未验。
- **上板实测**：Vivado 综合、时序收敛、资源占用、功耗均未做。
- **上位机**：`host/` 尚未开工，目前只有目录说明（`host/README.md`），串口协议未冻结。

覆盖边界的完整说明在 `refsim/README.md` 第八节。

---

## 三、快速开始

需要 `git`、`gcc`、`python 3`、`iverilog`。详见第七节。

```sh
git clone <本仓库地址> FPGA
cd FPGA/refsim

sh run_fntt_check.sh          # NTT 全流程：KAT → 参考实现 → RTL
sh run_intt_pwm2_check.sh     # INTT + 点乘 + 往返自检
sh run_polmul_check.sh        # 完整多项式乘法（端到端）：FULL + HALF
sh run_ntt_layers.sh          # 导出并机器验证 twiddle 层序表
```

三条主脚本都是全自动的。`iverilog` 不在 PATH 里时脚本会自己加
`/c/iverilog/bin`。预期输出见 `refsim/README.md` 第三节。

---

## 四、目录结构

```
FPGA/
├── CLAUDE.md                  AI 协作约定与项目环境说明
├── logs/                      项目记录与进度排期
│   ├── FPGA竞赛_项目记录.md   当前状态与待办 —— 开工只读这一份
│   ├── FPGA竞赛_项目记录_背景.md  硬约束/评分规则/风险 —— 做决策时读
│   ├── FPGA竞赛_项目记录_变更.md  变更记录（只增）—— 追溯时读
│   ├── FPGA竞赛_项目记录_归档.md  更早的过程
│   └── FPGA竞赛_进度与排期_通俗版.md  人话版，可直接转发队友
├── LICENSE                    Apache License 2.0
├── NOTICE                     Apache-2.0 要求的声明文件
├── THIRD_PARTY_LICENSES.md    第三方组件清单与许可证
│
├── refsim/                    RTL 软硬件一致性验证台
├── host/                      PC 上位机（串口喂数据 + 收回 + 自动比对）
├── rtl/                       改造后的 RTL、引脚约束、Vivado 工程
├── team/                      分工与个人计划
├── demo/  docs/  assets/      演示页 / 报告 / 截图录屏素材
│
├── research/                  参考资料（只读）
│   ├── ref_rtl/               开源 NTT 硬件基线
│   ├── kyber_ref/             ML-KEM C 参考实现（地面真值）
│   ├── mlkem_kat/             FIPS 203 兼容考题 1000 条
│   ├── standards/             NIST FIPS 203 / 204 / 205
│   └── PQC-NTT_ML-KEM_技术资料汇编.md
│
├── selection/                 历史：选题过程
└── _refbuild/                 历史：参考实现早期 bench
```

目录名一律英文。`research/` 是只读的——对基线 RTL 的任何修改都在
`refsim/pe1/` 的副本上做。

---

## 五、验证链

```
   FIPS 203 兼容考题（1000 条，逐比特）
              │  kat_verify.c 四项独立复算，1000/1000 通过
              ▼
   C 参考实现（research/kyber_ref/）  ←── 从此它是"地面真值"
              │
              ▼
   黄金向量 ── 灌进 RTL ── 逐比特对拍
              ▼
   ∴ 这份 RTL 的 NTT / INTT / 点乘 / 完整多项式乘法符合 FIPS 203
```

**为什么不能只跑作者的 testbench**：作者的 testbench 是拿作者自己给的期望输出
去比作者自己的 RTL，只能证明自洽。万一期望值本身就错了（twiddle 表排错、
域约定选错），testbench 照样打印 `Correct!`。

**作者数据也被独立复算过**：`KYBER_DIN*_MFNTT.txt` 与参考实现逐比特一致
（512/512 个系数），这同时证明作者的数据没错、且我们对域约定与输出顺序的
理解与作者一致。

**单运算与端到端性质不同**：INTT / PWM2 的期望值需按常数因子换算
（R = 2¹⁶ mod q = 2285，R⁻¹ = 169），配有往返自检背书；FULL / HALF 端到端
没有任何缩放因子，逐比特直接比。

完整的验证设计、踩过的坑、覆盖边界见 **`refsim/README.md`**。

---

## 六、环境要求

| 需要 | 怎么来 | 备注 |
|---|---|---|
| `iverilog` 12.0 | `winget install --id Icarus.Verilog` | 装在 `C:\iverilog\bin`，**不在 PATH 里** |
| `gcc` | MinGW-w64 或任意带 gcc 的发行版 | 编译 C 参考实现外壳 |
| `python 3` | 任意 | 向量生成与比对 |
| `git` | 任意 | |

脚本是 `.sh`，在 Git Bash 里跑（命令前加 `sh`）。

⚠️ **行尾被 `.gitattributes` 锁死为 `* -text`，不做任何转换。**
不要改成 `text=auto` 或 `eol=lf`——那两种都会在 checkout 时改写字节，
会让对拍 `diff` 报出"256 行全不同"而数值一个不差。理由写在 `.gitattributes` 注释里。

---

## 七、第三方组件与许可证

本作品依据 **Apache License 2.0** 发布。所用第三方组件均为宽松许可
（CC0 / MIT / Apache-2.0），与本作品许可证兼容，详见
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)。

与本作品源代码直接相关的两处：

| 组件 | 出处 | 许可证 |
|---|---|---|
| 多项式乘法硬件基线 `research/ref_rtl/kyber-polmul-hw/` | Mert & Yaman | CC0 1.0 |
| ML-KEM C 参考实现 `research/kyber_ref/` | pq-crystals/kyber | CC0 1.0 或 Apache-2.0 |

`rtl/` 与 `refsim/pe1/` 下的 RTL 是在前者基础上改造得到的。

---

## 八、团队分工

| 角色 | 负责 |
|---|---|
| **A** | `rtl/` —— RTL 改造、引脚约束、Vivado 综合与上板 |
| **B** | `refsim/` `host/` —— 验证台、上位机、开源仓库 |
| **C** | `demo/` `docs/` `assets/` —— 演示页、设计报告、录屏素材 |

细节见 `team/` 目录。
