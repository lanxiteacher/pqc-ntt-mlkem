# ML-KEM-768 正向 NTT trace：本机提取、校验与回放准备

这是 B 的出彩组合第 1 项的无板部分。运行一次公开兼容 KAT 的密钥生成、封装、正常解封装，从软件参考实现取出每一次 poly_ntt 的输入输出。不会将完整 ML-KEM 搬进 FPGA。本工具不覆盖逆 NTT、点乘调用或无效密文拒绝路径的 trace。

## 一次手动验收

从仓库根目录执行，依赖 Python 3、gcc（沿用现有参考程序编译环境）：

```powershell
$env:PYTHONIOENCODING='utf-8'
python refsim/accept_kem_trace.py --output ../B_kem_manual_01
```

预计数秒至几十秒，命令内部每个子进程有 120 秒上限。目录必须不存在，重跑时更换后缀，不删除已有证据。四个阶段均 PASS，最后输出“software trace acceptance complete; board replay NOT performed”。失败返回 2，只有所有步骤完成才会生成 acceptance.json。失败目录可能含已完成阶段的中间结果，不能把单独某阶段 summary.json 当整套通过证明。

用户只需运行这一条，不需逐条调用内部脚本。2026-10-18 用户已实际执行并截图确认四阶段通过，截图见 `../logs/verification_2026-10-18_B_kem_manual.png`；AI 执行记录与用户手动验收分别保留。这仍不包含真板回放。

## 输入来源与实际调用数

- 输入：research/mlkem_kat/kat_MLKEM_768.rsp 的首条 count=0，d/z/msg 与期望 pk/sk/ct/ss；社区维护的 FIPS 203 兼容向量，非 NIST 官方发布。
- 固定 KYBER_K=3，确定性接口 keypair_derand(d||z)、enc_derand(msg)、dec(ct,sk)。randombytes 哨兵如果被意外调用会失败，不提供伪随机默认值。
- keygen：skpv、e 各 3 个多项式，共 6 次。
- encaps：sp 的 3 个多项式，共 3 次。
- decaps：解密 b 的 3 次，加 FO 复加密 sp 的 3 次，共 6 次。
- 合计 15 次、3840 个系数。矩阵直接采样到 NTT 域，不应虚构相应 NTT 调用。一次正常流程不等于覆盖全部 KEM 输入或拒绝分支。

源码依据：research/kyber_ref/indcpa.c 的 polyvec_ntt 调用、polyvec.c 对每个元素调用 poly_ntt；kem.c 的正常解封装包含复加密。trace 的 phase 表示外层 KEM 阶段，不把 decaps 内的复加密标成独立 encaps。

## 钩子、表示与校验边界

poly_ntt = ntt + poly_reduce。工具在临时目录仅替换 poly.c 内这一函数体，加前后记录钩子；要求原函数体精确匹配一次，不匹配就停止。research 原件不改，运行前后逐文件比较并记录 SHA-256。记录保留有符号 int16 原值。

导出串口输入时，显式将每个系数取模 3329 到 0..3328，再写恰好 3 位小写十六进制加 LF。符号变化属于模域表示转换，不是按位截断。输入保持自然顺序；C poly_ntt 输出顺序作为期望。真板的物理读出顺序仍由现有 unpack 按 build 还原，不能排序掩盖差异。

自动检查分四层：

1. 原版与带钩子分别编译，二者 pk/sk/ct/ss 和 decaps ss 均与同一兼容 KAT 一致；完整产物字节也互相一致。
2. 另跑一次带钩子程序，trace 和产物逐字节一致；调用编号、阶段分布、256 值长度及 int16 类型范围严格检查。
3. 独立编译现有 ntt_once_tool.c 和未修改的原版 C，对每次规范化输入重新计算 poly_ntt，逐项比较规范化后的 trace 输出。它是同一参考算法的另一次独立构建，不是另一个密码实现，也不是 RTL 正确性证明。
4. 三档已知答案陪练走实际 Host、Link、装载和 unpack，共 45 次/11520 系数。故意缺调用、重复编号、损坏输出、缺值、布尔值、错阶段、不完整回放均被拒；旧输出目录保护被验证。

## 输出与复跑入口

| 文件 | 含义 |
|---|---|
| trace.json | 15 次有符号输入输出，含阶段、调用编号和表示约定 |
| manifest.json | 每次调用的输入/期望文件及 #NTT 1 命令；声明硬件尚未验证 |
| ntt_XXX_phase/input.hex、expected.hex | 每次 256 行规范化输入与答案，适合 $readmemh 或逐行发送 |
| summary.json、summary.md | 提取阶段结果、参考源码及 KAT 哈希、gcc 版本、负向控制 |
| offline_replay/replay.json | 三档已知答案陪练的原始返回行、解包值、尝试次数和事务日志 |
| acceptance.json | 全部四步成功后的总验收记录 |
| negative_incomplete_trace.json | 故意缺少最后一次调用的负向测试文件，不能当完整 trace |

分开运行（常规验收用上面一条即可）：

```powershell
python refsim/kem_trace.py --output ../B_trace_new
python refsim/kem_trace_replay.py ../B_trace_new/trace.json --output ../B_trace_new/offline_replay
```

默认陪练从本次 trace 创建临时向量库，精确匹配输入并回放答案。它不能验证任意 trace 的数学正确性；应先完成提取器的 C 复核，不能只靠回放通过。

## 有板后（本轮未执行）

实际串口回放需要显式 --port 和 --build，例如 A 先确认实际串口、位流和档位后使用：

```powershell
python refsim/kem_trace_replay.py ../B_trace_new/trace.json --port COM实际号 --build 4 --output ../B_trace_new/serial_pe4
```

此命令只是调用示例，COM实际号需替换为现场值。若收到 RDY 与显式档位不一致立即拒绝；未收到 RDY 时依靠已核实的显式档位。serial 模式尚无本 trace 的实体板卡结果。后续已补失败检查点：合法输入创建新输出目录后，成功/失败均保存 replay.json，逐次保留事务现场。直接使用本低层命令仍沿用 SerialLink 的无显式写入/flush 超时限制；A 推荐使用 `run_kem_board.py` 的独立子进程总超时入口，见 `trace_delivery_README.md`。

真板回放应各档分别运行并保留位流来源/频率、串口、当前提交、完整终端输出和 JSON。波特率默认 115200；--baud 参数不是 921600 已验证证明。不能用默认陪练或 TAG 证明硬件频率。后续新增 `kem_trace_rtl.py` 已补三档实际 RTL 回放，证据见 `trace_delivery_README.md`；本 trace 的真板回放仍待执行，不能将此工作标为 A 计划中“全部 NTT 送板比对”已完成。

本工具只用于公开测试向量，trace 含算法内部多项式，不应用于采集真实业务密钥或生产随机性。
