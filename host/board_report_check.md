# 真板日志离线检查（B，2026-10-18）

工具只读取现有日志，不打开串口、不访问板卡、不重跑运算。支持 run_board_txn_report.sh 的完整输出格式。它核查每条命令的执行段、事务结果、输入/输出数量、解包档位、比较结果、退出标记与汇总是否一致，避免只看到结尾 PASS 就判断全部成功。

## 运行

从仓库根目录执行：

```powershell
$env:PYTHONIOENCODING='utf-8'
python host/src/check_board_reports.py rtl/vivado/reports/board_pe1_txn.txt
python host/src/check_board_reports.py rtl/vivado/reports/board_pe1_txn_2026-10-15_5of6.txt
python host/src/check_board_reports.py rtl/vivado/reports/board_pe4_f75_txn.txt --build 4 --output ../B_board_audit_01
```

第一条应通过；第二条应指出半乘执行失败，退出码 1 是预期结果；第三条生成 summary.json 和 summary.md。输出目录必须尚不存在，防止覆盖记录。可一次传多份日志；--build 若给出，对所有输入都生效，检查混合档位时不要加此参数。

## 四种逐命令状态

| 状态 | 含义 |
|---|---|
| 通过 | 执行段与汇总满足当前格式检查，计算命令记录 256 个系数、0 差异 |
| 失败 | 记录有失败退出、事务 FAILED/STOP 或非零差异。可能是输入、驱动或链路问题，不直接归因硬件 |
| 证据不完整 | 执行段存在但被截断、重复、缺关键内容或有不一致 |
| 未见执行段 | 日志里找不到该命令执行段；只表示没看到证据，不能断言从未执行 |

整份状态：有明确失败时为失败；无失败但存在缺失/矛盾时为证据不完整；六条均通过且汇总一致才通过。退出码 0=全部通过，1=存在明确失败，2=证据不完整或输入输出错误。

报告含源文件路径、SHA-256、声明档位和 TAG，便于对应具体日志字节。TAG 是声明，不是频率测量；hardware_provenance_verified、frequency_verified、coefficients_recomputed 均为 false。日志未保存全部系数时，本工具不能复算全部结果；“通过”表示检查记录通过，不代表又做了一次独立算术或硬件验证。

旧的 10-04 摘要格式不包含当前要求的完整执行证据，显示证据不完整；不因此推翻其历史运行结果。陪练日志不作为真板证据。报告标签和文字可以被人为修改，文本检查不是真实性鉴定。

## 本次自动检查与人工练习

test_board_reports.py 的六项测试覆盖六份当前原频率/提频报告、历史 5/6 报告、10-04 格式、截断/缺段、重复、错档位、虚假 PASS、汇总冲突、输出保护及退出码。未运行 RTL 或访问真实串口。

本机练习目录 ../B_report_practice_01 中，missing_section.txt 是从当前 pe1 日志截去最后一条命令及汇总得到的人工构造样例，不能当作真实新测量。B 可执行：

```powershell
python host/src/check_board_reports.py ../B_report_practice_01/missing_section.txt
```

预期最后一条 #PMUL FULL 1 为“未见执行段”，整份为“证据不完整”。它与旧 5/6 日志中的明确失败不同。B 亲手运行和反馈待完成。
