# 后量子密码FPGA加速平台

## 摘要

后量子密码标准 ML-KEM（FIPS 203）依赖数论变换（NTT）完成多项式乘法，密钥生成、封装与解封装都要多次调用，是嵌入式平台上最重的运算之一。本作品在 Xilinx Zynq-7020 的可编程逻辑（PL）内，实现了一个折叠度可配置的 NTT / INTT / 点乘硬件加速核：同一套 Verilog 源码，只改一个 PE_NUMBER 参数，就能在每拍 1、4、16 个蝶形之间切换，三档 NTT 周期数分别为 904、232、69。

主要难点在接口。上游基线把数据口宽度设为 12 位乘以蝶形数，做到 16 蝶形需要 397 个引脚，而本器件可用 IOB 只有 125 个，布局直接失败。本作品把宽接口留在核内，在核外增加序列化与反序列化，对外固定 12 位字宽，三档引脚恒为 37，三档全部完成综合、布局、布线与真板验证。

正确性由三层证据保证：FIPS 203 兼容考题 1000 条全部通过；C 参考实现与 RTL 在 4096 个系数上逐比特一致，并附阴性对照；ML-KEM 的三份 transcript 在真板上回放 135 次、34,560 个系数全部一致。板上 50 MHz 下三档单次 NTT 耗时 18.08 / 4.64 / 1.38 µs，其中 pe4 与 PC 端参考实现（4.80 µs）同量级，资源仅 2000 LUT。另提供三档提频位流（80 / 75 / 62.5 MHz）；在 921600 波特率演示中，单次事务的串口线上时间由 184 ms 降到 23 ms。全部报告、日志和复跑脚本入库，可逐数溯源。

## 功能与特性

本作品实现 ML-KEM 多项式运算的三类核心功能及其组合：数论变换（NTT）、逆变换（INTT）、点乘（半乘与全乘）。板级协议提供 #PING、#NTT、#INTT、#PMUL NTT、#PMUL TIME、#PMUL FULL 六条命令，每条命令完成一次 256 系数多项式的装载、计算与读出，结果按行返回，由上位机比对。

同一份 RTL 通过 PE_NUMBER 参数生成 pe1、pe4、pe16 三个实现：每拍处理 1、4、16 个蝶形。三档对外接口完全一致（12 位数据、37 个引脚、同一套命令），上位机不需要知道板内烧的是哪一档；上电后板卡主动输出一行 #RDY，携带协议版本、折叠度与状态，供上位机自动识别。

所有功能在真实开发板上以 50 MHz 验证：三档各六条命令全部通过，半乘与全乘各以 4096 个系数逐项比对；另有三档提频位流（80 / 75 / 62.5 MHz）同样全过。本作品只覆盖 NTT / INTT / 点乘，不含 Keccak、采样与编码，因此不是完整的 ML-KEM 芯片。

## 应用领域

ML-KEM 已被 NIST 于 2024 年发布为 FIPS 203，是后量子迁移中的主流密钥封装算法，典型部署位置包括 TLS / VPN 网关、物联网安全芯片、智能网卡与密码机。这些场景都要批量做多项式乘法，而 NTT 是其中最耗时的部分；用 FPGA 卸载 NTT 可以在低主频、低功耗条件下获得确定时延。

本作品面向教学与原型验证：三档折叠度对应「极小面积」「面积吞吐均衡」「高吞吐」三类需求，可在同一块 Zynq-7020 上按需选择；固定 12 位对外接口使同一套上位机与约束文件可复用于不同档位，便于在资源受限的器件上做方案对比。

边界同样明确：作品只实现 NTT / INTT / 点乘，尚未集成 Keccak、采样与压缩编码，不能单独作为 ML-KEM 产品使用；也不含侧信道防护。它适合作为密码加速 IP 的核心部件，或作为教学与评测的基准实现。

## 主要技术特点

（1）参数化折叠度。三档的地址生成使用同一套公式，仅由 PE_NUMBER 决定并行度；上游三份手工复制的 RTL 被合并为一份，避免长期漂移。

（2）固定宽度接口与核外序列化。核内保持 12×PE 的宽数据通路，核外完成串并转换，对外恒为 12 位，解决引脚数随折叠度线性增长的问题。

（3）纯 PL 实现。UART 收发、协议状态机、行组装、系数缓冲与计算核全部为 Verilog，不含 HLS、PS 程序或操作系统。

（4）自描述接口。上电自报 #RDY（协议版本、折叠度、状态），配合有限写超时与事务级超时，便于自动化测试。

（5）可复现。仿真、对拍、上板、指标、报告五条链都有脚本与原始日志，一条命令可复跑。

## 主要性能指标

三档量化指标如下，数值来自 post-route 报告与真板实测：

| 指标 | pe1 | pe4 | pe16 |
|---|---|---|---|
| NTT 周期数 | 904 | 232 | 69 |
| 单次 NTT @50 MHz | 18.08 µs | 4.64 µs | 1.38 µs |
| LUT / FF | 727 / 388 | 2000 / 880 | 8922 / 2933 |
| DSP / BRAM tile | 1 / 2.5 | 4 / 9 | 16 / 34.5 |
| 对外引脚 IOB | 37 | 37 | 37 |
| 推算 Fmax（5 ns 约束） | 168 MHz | 160 MHz | 154 MHz |
| 板上提频 | 80 MHz | 75 MHz | 62.5 MHz |
| 功耗（估算，50 MHz） | 0.130 W | 0.170 W | 0.335 W |

## 主要创新点

（1）固定宽度接口加核外序列化：16 蝶形所需引脚由 397 降到 37，三档同口。

（2）一套 RTL 生成三档：三档地址数学统一为一个公式，消除三份副本漂移。

（3）#RDY 自描述折叠度：上位机无需人工记录板内档位。

（4）三层验证链：KAT、C 参考、RTL 逐比特比对，带阴性对照与真板回放。

（5）完整可复现：五条链的脚本、原始输出与报告全部入库。

## 设计流程

文献调研并复现开源基线的验证 → 改造为参数化折叠度（地址生成、BRAM/BROM、核与顶层）→ 核外序列化与固定接口 → iverilog 仿真与 C 参考对拍（16 组向量、三档）→ Vivado 综合、实现与时序分析（50 MHz 及提频）→ 真板上板（六条命令、真板 trace、浸泡）→ 指标与功耗估算 → 报告与复现脚本。每一步的判据与证据文件均在仓库内可查。

## 系统整体介绍

系统只有两端：PC 通过 USB 转串口与开发板相连，板内 PL 完成全部计算。

数据流：上位机把 256 个 12 位系数编码成十六进制行，经 UART 115200（演示模式 921600）送入板卡；协议状态机解析命令与数据行，行组装模块把 12 位字拼成 256 系数缓冲；计算核从缓冲取数，完成 NTT / INTT / 点乘后写回；序列化模块把结果按 12 位串行输出，经 UART 返回 PC；PC 解包并与参考结果比对。

模块关系：协议状态机是唯一的控制入口，根据命令选择运算与装载顺序；系数缓冲为双 bank（256×12×2），支持点乘两路输入；#RDY 在复位释放后自发一行，标识协议版本、折叠度与状态。

![图 1  系统整体框图：宽接口留在核内，对外固定 12 位](report/figures/architecture.svg)

## 2.2.1 硬件整体介绍

开发板为正点原子领航者 ZYNQ（XC7Z020CLG400-2），本作品只使用 PL 部分，PS 不参与。PL 内自建时钟与复位（sys_clk 50 MHz，sys_rst_n 低有效），UART 引脚经板载 CH340C 接到 USB。

三档设计使用同一套顶层与约束文件，仅综合时传入不同的 PE_NUMBER。资源与时序结果见第一部分性能表与第三部分特性表。另综合了 MMCM 提频版本，pe1 / pe4 / pe16 分别在 80 / 75 / 62.5 MHz 上板跑通；100 MHz 版布线不收敛（pe1 WNS −0.066 ns），未纳入交付。

## 2.2.2 机械设计介绍

本作品无机械结构：不使用外壳、支架或自制结构件，开发板直接放置于桌面，通过 USB 线供电与通信。第三部分的实物照片为开发板及工作台现场状态。

## 2.2.3 电路各模块介绍

本作品不包含自制 PCB。硬件平台为现成正点原子领航者 ZYNQ 开发板，自研部分全部位于 PL 内部逻辑与引脚约束。

使用的外部引脚四个，均 LVCMOS33，约束文件 rtl/board/ntt_board.xdc 已与全板 IO 表逐条核对：

| 信号 | 引脚 | 说明 |
|---|---|---|
| sys_clk | U18 | 50 MHz 板载时钟 |
| sys_rst_n | N16 | 复位，低有效 |
| uart_rxd | T19 | 板载 CH340C 转 USB |
| uart_txd | J15 | 板载 CH340C 转 USB |

三档设计对外 IOB 均为 37 个（含上述四个），占器件可用 IOB 的 29.6%；上游未序列化版本 pe16 需要 397 个，无法布局。电路级验证：三档位流逐一烧录后，六条命令（#PING 与五条计算）各 256/256 一致；提频位流上重复同样验证。

## 2.3.1 软件整体介绍

PC 侧软件全部为 Python，分三层：传输层负责串口打开、帧封装、写超时与读超时；事务层负责命令-响应状态机、行计数与错误处理；应用层负责解包、与参考实现比对、生成报告。

另有验证与演示工具：iverilog 仿真台、ML-KEM trace 回放器、网页演示（四幕：输入、逐层、对拍、计时资源）、指标生成器与报告构建脚本。PS 侧没有软件，作品为纯 PL。

![图 2  演示界面「对拍」一幕：4096 个系数全部一致](assets/2026-10-19_C_gui_act3_match_all_pass.png)

## 2.3.2 软件各模块介绍

| 模块 | 职责 | 关键输入 / 输出 |
|---|---|---|
| link.py | 串口收发与帧定界 | 命令与数据行 / 原始回读行 |
| host.py | 事务状态机、行计数、超时 | 命令与期望行数 / 事务结果与计时 |
| unpack.py | 解析 12 位系数并比对 | 回读行与参考向量 / 差异列表 |
| board_run.py | 真板命令行入口 | 命令、串口、位流信息 / 日志与通过失败 |
| fake_board.py | 无板陪练，模拟板端协议 | 命令 / 模拟响应 |
| kem_trace*.py | 从 KAT 生成 trace 并在 RTL 或真板回放 | KAT 序号 / 逐次比对结果 |
| gui.html | 四幕演示 | 预生成 JSON / 动画与比对结果 |
| gen_metrics.mjs | 指标汇总 | 日志与报告 / metrics.csv |

调用关系自上而下为：命令行入口 → 事务层 → 传输层；验证脚本直接调用仿真或串口入口，结果写入 logs/，再由指标生成器汇总。

## 3.1 整体介绍

图 3 为作品现场：开发板上电、JTAG 与 USB 串口均已连接，PL 内运行 pe16 位流；图 4 为工作台全局，左侧 PC 终端正运行上位机与开发板对拍。系统无外壳，桌面即工作台。

![图 3  作品现场：开发板上电、JTAG 与串口连接](assets/2026-10-29_A_board_photo_oblique.jpg)

![图 4  工作台全局：PC 终端与开发板同框](assets/2026-10-29_A_board_photo_setup_overview.jpg)

## 3.2.1 机械成果

本作品无机械结构，无机械成果实物。

## 3.2.2 电路成果

图 5 为开发板俯视全景，可见 Zynq 芯片、板载 USB-UART、JTAG 座与扩展排针。作品未自制 PCB，电路成果为上述引脚约束与板级顶层设计：四个外部引脚、37 个 IOB、三档同一套约束。

50 MHz 三档 WNS 分别为 +7.339 / +6.547 / +4.789 ns，失败端点 0；提频版 WNS +0.698 / +0.754 / +1.720 ns，同样失败端点 0。六版位流（三档基线加三档提频）全部上板跑通。

![图 5  开发板俯视全景：Zynq 芯片与板载外设](assets/2026-10-29_A_board_photo_full_view.jpg)

## 3.2.3 软件成果

图 6 为演示界面「输入」一幕：可切换三档、选择运算并装载系数；图 7 为「计时资源」一幕：左为逐层耗时，右为三档资源与 ATP 对比。上位机命令行入口在真板上完成六条命令的逐项比对，原始输出保存在 logs/ 与 rtl/vivado/reports/。

![图 6  演示界面「输入」一幕](assets/2026-10-19_C_gui_act1_input.png)

![图 7  演示界面「计时资源」一幕](assets/2026-10-19_C_gui_act4_timing_resources.png)

## 3.3 特性成果

| 特性 | 结果 | 证据 |
|---|---|---|
| KAT 兼容性 | 1000 条全部通过 | research/mlkem_kat/ |
| 三运算对拍 | NTT / INTT / 点乘各 16 组、4096 系数逐比特一致 | logs/verification_*_refsim.txt |
| 完整多项式乘法 | FULL / HALF 三档各 4096/4096 | refsim/run_polmul_check.sh |
| 真板功能 | 三档各 6/6（#PING 加五条计算） | rtl/vivado/reports/board_pe*_txn.txt |
| 真板 trace 回放 | 135 次 / 34,560 系数全一致 | logs/verification_2026-10-21/29_A_* |
| 长时间稳定 | 40 分钟 9,233 次 #NTT，0 失败 | logs/verification_2026-10-21_A_soak.txt |
| 周期恒定 | 三档 103 组输入周期恒为 904 / 232 / 69 | team/handoff_2026-10-18_B_strengthening.md |
| 变异测试 | 51 个变异体捕获 50 个（1 个等价） | logs/verification_2026-10-21_B_phase2_mutations.json |
| 高速串口 | 线上 184 → 23 ms（8.0×），0 误码 | rtl/vivado/high_baud_demo.md |
| 复现 | 全新 clone 22 阶段全部通过 | logs/clean_clone_2026-10-29_66d7912.json |

## 可扩展之处

（1）补全 ML-KEM：加入 Keccak / SHA3、CBD 采样、压缩编码与消息封装，形成完整 KEM。

（2）总线化：以 AXI4-Lite 做控制、AXI-Stream 做数据，接入 PS 或片上系统。

（3）提高并行：radix-4 蝶形、双核并行，进一步压缩周期。

（4）侧信道防护：掩码与洗牌，需配套泄漏评估。

（5）工具链对比：开源综合流程与 Vivado 的时序资源对照。

## 心得体会

我们三个人都没有写过 Verilog，也没有上过板。这个项目对我们来说，第一步不是写代码，而是先把「怎么知道它是对的」建起来。回头看，真正花时间的地方几乎都不是算法本身，而是判据。

最早的一版验证台用 while (done == 0) 等结束信号，单次跑没事，套进循环后只要有一轮异常就永久挂死。后来所有等待都加了计数护栏。还有一次，向量全是 0 和常量，比对全中，我们就以为通了，直到有人问「这些数里有几个不同的值」，才发现这次通过什么也证明不了。从那以后，灌数据前先统计不同值，成了固定动作。

分工上，A 负责 RTL 与上板，B 负责验证台与上位机，C 负责报告、演示与复现。三个人在三台机器上改同一个仓库，最容易出事的是同时改同一份文档。我们后来定了一条很朴素的规矩：开工先拉，收工先推，一个能跑通的小步就提交。冲突了就停下来问，不硬合。这条规矩救过不止一次。

大模型几乎参与了每一环：读手册、改 RTL、写测试台、生成图表、整理报告。它的价值在于把零基础的人推到「能跑起来」的位置，但它也会自信地给出不存在的函数、过期的事实、前后矛盾的数字。我们逐渐形成一个习惯：任何一个结论，要么有脚本输出，要么有报告页码，否则不写进正式材料。报告里的每个数字都能指回一份日志或一个报告文件，这条是我们给自己定的底线。

印象最深的一次，是我们花了很大力气去重建一张根本不存在的表。动手「复现」之前先确认它存在，这句话后来被写进了项目约定。另一类是文档自己过期：待办写着「无阻塞项」，其实是三天前的实况，没人回头改，它就成了最贵的误导。现在我们会定期回头核一遍，而不是相信待办里那句话。

代码和文档都在仓库里，换一台机器从零 clone 就能跑。对我们来说，这个项目的收获不是拿到了什么名次，而是第一次完整体会到：工程的可信度不来自写得漂亮，而来自能被别人重复。

## 参考文献

[1] NIST. Module-Lattice-Based Key-Encapsulation Mechanism Standard: FIPS 203[S]. Gaithersburg: National Institute of Standards and Technology, 2024.

[2] CRYSTALS-Kyber Team. CRYSTALS-Kyber: Algorithm Specifications and Supporting Documentation (Version 3.0)[R]. 2020.

[3] pq-crystals. Kyber: reference implementation of CRYSTALS-Kyber / ML-KEM[CP/OL]. https://github.com/pq-crystals/kyber, 2024.

[4] post-quantum-cryptography. KAT: FIPS 203 compatible known answer tests for ML-KEM-768[CP/OL]. https://github.com/post-quantum-cryptography/KAT, 2024.

[5] Sonbul O S, Rashid M, Masud M I, et al. Deeply pipelined NTT accelerator with ping-pong memory and LUT-only Barrett reduction for post-quantum cryptography[J]. Electronics, 2026, 15(3): 513. DOI: 10.3390/electronics15030513.

[6] Bisheh-Niasar M, Azarderakhsh R, Mozaffari-Kermani M. Instruction-set accelerated implementation of CRYSTALS-Kyber[J]. IEEE Transactions on Circuits and Systems I, 2021, 68(11): 4648-4659. DOI: 10.1109/TCSI.2021.3106639.

[7] Xing Y, Li S. A compact hardware implementation of CCA-secure key exchange mechanism CRYSTALS-KYBER on FPGA[J]. IACR Transactions on Cryptographic Hardware and Embedded Systems, 2021(2): 328-356.

[8] Kieu-Do-Nguyen B, Binh N T, Pham-Quoc C, et al. Compact and low-latency FPGA-based number theoretic transform architecture for CRYSTALS Kyber postquantum cryptography scheme[J]. Information, 2024, 15(7): 400. DOI: 10.3390/info15070400.

[9] Bertels J, Verbauwhede I. A high throughput Kyber NTT[R]. IACR Cryptology ePrint Archive, Paper 2025/1763, 2025.

[10] Kamba M. FoldNTT: a multiplier- and twiddle-lean NTT core with formally verified arithmetic for Proth primes[R]. arXiv: 2609.06412, 2026.

[11] Zhao Y, Pan S, Ma H, et al. Side channel security oriented evaluation and protection on hardware implementations of Kyber[J]. IEEE Transactions on Circuits and Systems I, 2023, 70(12): 5025-5035.

[12] Bertels J, Norga Q, Verbauwhede I. A better Kyber butterfly for FPGAs[C]. 2024 34th International Conference on Field-Programmable Logic and Applications (FPL), 2024: 171-177. DOI: 10.1109/FPL64840.2024.00032.

[13] Kundi K, Bermudo Mera D, Strub S, et al. High-performance NTT hardware accelerator to support ML-KEM and ML-DSA[C]. ASHES '24, 2024. DOI: 10.1145/3689939.3695785.

[14] Ni Z, Khalid A, Liu W, et al. Towards a lightweight CRYSTALS-Kyber in FPGAs: an ultra-lightweight BRAM-free NTT core[C]. IEEE International Symposium on Circuits and Systems (ISCAS), 2023.

[15] Yaman F, Mert A C, et al. A hardware accelerator for polynomial multiplication operation of CRYSTALS-KYBER PQC scheme[C]. Design, Automation and Test in Europe (DATE), 2021: 1020-1025.

[16] Longa P, Naehrig M. Speeding up the number theoretic transform for faster ideal lattice-based cryptography[C]. CANS 2016, LNCS 10052: 124-139.

[17] Nguyen T H, Pham C K, Hoang T T. A high-efficiency modular multiplication digital signal processing for lattice-based post-quantum cryptography[J]. Cryptography, 2023, 7(4): 46.

[18] acmert. Kyber-polmul-hw: polynomial multiplication hardware for CRYSTALS-Kyber[CP/OL]. https://github.com/acmert/Kyber-polmul-hw, 2021.

[19] axytho. KyberButterflyCollection: butterfly variants for CRYSTALS-Kyber[CP/OL]. https://github.com/axytho/KyberButterflyCollection, 2024.

[20] AMD. Vivado Design Suite User Guide: Synthesis (UG901); Implementation (UG904); UltraFast Design Methodology (UG949)[Z]. 2020.
