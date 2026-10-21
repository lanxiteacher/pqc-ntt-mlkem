# 三档 FULL 变异矩阵（2026-10-21 B）

每个组合 16 组、4096 系数；基线三档均通过。编译失败与超时不计捕获。

| 变异 | pe1 | pe4 | pe16 |
|---|---|---|---|
| add_modulus | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| sub_modulus | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| sub_sign | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| mul_operator | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| div2_parity | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| ct_input | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| ct_delay | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| inverse_delay | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| twiddle_delay | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| butterfly_output | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| read_address | 捕获：数值差异 | 捕获：数值差异 | 捕获：完整输出含未知值 |
| write_address | 捕获：完整输出含未知值 | 捕获：完整输出含未知值 | 捕获：完整输出含未知值 |
| twiddle_address | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| bank_select | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| pwm_bank | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |
| serializer_order | 存活（等价） | 捕获：数值差异 | 捕获：数值差异 |
| load_alignment | 捕获：数值差异 | 捕获：数值差异 | 捕获：数值差异 |

合计 50/51 捕获；1 个存活等价项不计捕获。

pe1 serializer_order：rsub 复位为 0，PE=1 时更新仍为 0，原 PE_NUMBER-1-rsub 和变异后的 rsub 均为 0。
源码位置：rtl/ntt_core/KyberHPMNTT_top.v 的 rsub 递推与 dsel 赋值。
每个测试名称为 mutations/pe<N>/<变异名>/simulate；命令、源副本、原始输出均在同名 ZIP。
只覆盖 FULL 与既定 16 组；不能外推至 HALF、所有输入或所有故障。
