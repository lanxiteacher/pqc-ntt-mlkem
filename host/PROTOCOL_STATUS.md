# Protocol implementation status (2026-10-17, B)

本文件补充冻结件 `proto.md` 的现状；帧格式、时序和 RTL 接口未改。
原协议的历史冻结记录保留；10-17 已就地校正正文引用、输出行数、向量/H7/注错状态，既有正文行号不变。

- `#RDY`、build 决议、收发计数拆分均已实现。
- §5.5 三种错误注入已于 10-06 在陪练上完成；入口 `refsim/run_proto_accept.sh`。
  陪练通过不等于真 RTL 或真板错误路径通过。
- H7 已于 09-29 办结：逐层中间结果由 C 的演示页计算，协议不增加 `#LAYERS`。
  C 已加入仓库并于 10-05 完成独立复现。
- §七(a) 的 H7、§七(c) 的 C 入仓与 §八 的注错状态已回填。
- `schedule_plain.md` 的旧行号引用应按其 §三（总排期）与 §四（H1–H10 交接点）定位。
  W4 为 10/14–10/20，W5 为 10/21–10/27；截止 11/04 18:00。
- 10-17 仅规范三个实际被上位机读取的文件：`halfmul_b.txt`、`halfmul_exp.txt`、
  `fullmul_exp.txt`。只补零与统一 LF，4096 个数逐项未变；生成器也保持此格式。
  历史转储、`vref_*` 等不参与本次规范，不宣称全仓库都已统一。
- `test_fake_board_data.py` 已解除两条跳过，五条计算命令各 16 组全部执行。
- A 的 10-15 装载顺序表经 B 复核与端到端测试，符合 §5.3.4；输入排列与输出解包分开。

## 无板子的复核

```powershell
$env:PYTHONIOENCODING='utf-8'
python host/src/test_board_pipeline.py
python host/src/board_run.py --loopback --physical-order --fake-build 4 --check "#INTT 1"
```

`--physical-order` 是显式启用的已知向量回放模型，独立转录 §5.3.4 的输入/输出列。
它检查命令、握手、装载、行数、解包的衔接，不计算 NTT；不能充当硬件算术证据。
默认 `--loopback` 的历史文件序模式保留，避免改变既有调用者。

三档 × 五命令 × 16 组 = 240 次事务、61440 个系数；另跑 15 次真实 CLI 路径。
负向控制：损坏系数、遗漏装载交织、错报 build 都必须被拒绝。
原始执行记录见 `logs/verification_2026-10-17_B_host.txt`。

## 给 A 的剩余上板步骤

三份文件格式阻塞已解除，B 没有板子，尚不能宣称新的真板结果：

1. 拉取当前提交，烧对应档位流，现查串口号。
2. 用现有 `rtl/vivado/run_board_txn_report.sh` 重新验收，重点补 `#PMUL TIME 1`。
3. 对 pe4 / pe16 用同一入口复核，不用仓库外临时脚本代替。
4. 保存完整原始输出；新的通过记录出现前仍保留 10-15 的 5/6 结论。
