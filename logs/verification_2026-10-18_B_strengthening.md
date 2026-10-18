# B verification strengthening evidence (2026-10-18)

最终整体验收：PASS。真实板卡未测试。被测来源以 JSON 中的源码 SHA-256 为准；git_head 是运行开始时版本，新脚本当时尚未提交。运行期间合入 A 的功耗资料和 C 的指标文档更新，没有改变被测源码。

## RTL 变异

原始 pe4/FULL 基线：多重集与逐项(tau)均 4096/4096；每个变异使用相同 16 组不同 A/B。期望经本次编译 C 复核。编译失败、仿真异常和超时不计成功捕获。

| ID | 故障 | 检测 | 逐项正确 / 4096 |
|---|---|---|---|
| add_modulus | 模加模数差一 | detected_mismatch | 1 |
| sub_modulus | 模减模数差一 | detected_mismatch | 2 |
| sub_sign | 模减借位修正反转 | detected_mismatch | 1 |
| mul_operator | 乘法误写为加法 | detected_mismatch | 0 |
| div2_parity | 除二奇数补偿差一 | detected_mismatch | 4 |
| ct_input | CT 输入选择交换 | detected_mismatch | 2 |
| ct_delay | CT 输入流水线旁路 | detected_mismatch | 1 |
| inverse_delay | 逆变换输出流水线旁路 | detected_mismatch | 32 |
| twiddle_delay | 逆变换 twiddle 延迟旁路 | detected_mismatch | 64 |
| butterfly_output | 蝶形奇输出误用偶输出 | detected_mismatch | 0 |
| read_address | 读地址差一 | detected_mismatch | 1 |
| write_address | 写地址差一 | detected_unknown | X/Z，无法数值比较 |
| twiddle_address | twiddle 索引差一 | detected_mismatch | 0 |
| bank_select | bank A 写选择反转 | detected_mismatch | 2 |
| pwm_bank | PWM bank B 半区地址错误 | detected_mismatch | 1 |
| serializer_order | 输出 lane 次序反转 | detected_mismatch | 2 |
| load_alignment | 输入串行对齐差一 | detected_mismatch | 1 |

17/17：16 个数值不同、1 个 X/Z 输出（写地址错误）。完整运行输出、首差异、替换前后和哈希在 JSON/压缩证据中。

## NTT 周期与输出

种子 20261018：100 个不同随机输入 + 全零/全3328/交替三个边界输入，三档使用同一批数据，样本之间不复位。

| 档位 | 次数 | 核周期 | 实测外层周期 | 正确输出系数 | 有效地址序列一致数 | 原始地址序列种数 |
|---|---|---|---|---|---|---|
| pe1 | 103 | 904 | 907 | 26368 | 103 | 2 |
| pe4 | 103 | 232 | 235 | 26368 | 103 | 2 |
| pe16 | 103 | 69 | 72 | 26368 | 103 | 2 |

三档均是首次运算开头 8 拍闲置写地址与后续不同，对应写使能为 0。后续 102 个样本原始序列彼此一致。写使能无效时屏蔽对应写地址，读地址/twiddle/写使能不屏蔽，得到相同的有效访问序列。原始日志和原始 SHA-256 均保留。

静态控制依赖核查及边界见 refsim/strengthening_README.md。只支持所测输入的固定延迟和有效地址一致性，不是形式化或完整侧信道证明。

## 保护与开发记录

损坏一个期望系数被拒（4095/4096）；已有输出目录被拒且证据哈希不变；子进程超时被拒并保留 stdout/stderr 和超时命令记录。

开发首轮 17 个变异已捕获，但 pe1 原始地址线必须完全一致的断言失败。确认差异只在未使能写地址，修正判据后整套从头重跑通过。首轮失败摘要及原始输出在压缩包 development_first_attempt/ 下，未将失败记录覆盖为成功。

本机最终运行各子进程耗时合计约 248 秒。用户手动验收仍待本人执行新增统一入口；原 trace 人工验收已另行闭环。
