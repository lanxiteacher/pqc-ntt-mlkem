# B 通用检查组件：第一步范围与人工验收（2026-10-17）

## 当前决定

用户要求 AI 辅助技术工作，同时由 B 参与实际操作与判断。本轮在 B 主责的 refsim 内新增离线整数结果检查组件；不改 C 的 skill/，也不修改现有运算或协议。它是未来 PYNQ Skill 的候选基础，还不是完整 PYNQ 工具，也不承诺额外加分。

依据：A 的 `logs/letter_2026-10-15_A_to_C.txt` §四只提出方向，尚未正式定任务。`logs/guideline_excerpts_2026-10-15.md` §四要求面向 PYNQ 且不绑定题目。本轮只推进可复用比较逻辑；进入 PYNQ 接口与正式 skill/ 交付前，需对齐 A/C 的范围，并确认运行环境。

## 最小功能

输入两份 UTF-8 JSON 整数数组：一份期望、一份实际。按位置精确比较，检查长度，并生成终端摘要和可选 JSON 报告。长度不同、数据缺失、顺序不同都失败；空期望值、布尔值、浮点数、字符串和非法 JSON 报输入错误。

无硬编码的 256 点、3329 模数、NTT 类型、build 或板卡型号。可用于有符号整数及不同长度。算法特定的域转换与排列必须由调用者先处理，禁止检查器自行归一化或排序来掩盖错误。报告中的 index 从 0 数，position 从 1 数；详情可截短，总错误数仍完整统计。

第一步不提供浮点容差、硬件调用、Overlay 加载、DMA、计时、硬件超时控制或板卡兼容性保证。不把离线比较耗时当硬件性能。

## 使用

```powershell
python refsim/compare_integer_results.py expected.json actual.json --report report.json
```

退出码：0=全部相同，1=结果不匹配，2=输入或报告写入错误。它不生成“实际硬件结果”，actual 必须有真实来源，演示数据则注明合成。

新增组件的离线检查：`python refsim/test_compare_integer_results.py`。这不调用 RTL、板卡或 PYNQ；原有验证入口不迁移、不重跑。

## B 亲手做的任务（已由用户截图确认）

演示是一组人工构造的向量加法：A=[1,2,3,4]，B=[10,20,30,40]，期望=[11,22,33,44]，没有运行 FPGA。

1. 在本机练习目录打开 actual.json，把第四个数字 44 改成 45，保存；expected.json 保持不变。
2. 运行比较工具并输出 report.json。
3. 核对是否只报一处错误、是否明确指出第 4 个值应为 44、实际为 45。
4. 把自己的观察告诉 AI：你改了哪一个值、报告指出什么、是否容易找到错误。若看不懂，指出具体哪个词需要改。需要时可留下实际终端输出作为人工验收证据。

这一步由 B 负责判断报告是否可读，也检查“人为引入的错误确实被发现”。AI 的自动化检查与 B 的人工操作分别记录，不能把预期结果写成用户已完成。

## 后续交接

AI：已编写范围、比较器和自动化检查；实际结果见同日组件日志。
B：已提供前后两次执行截图并确认符合预期。首次第 4 个值 44→45，显示 matched=3、mismatched=1，准确指出位置；恢复后 matched=4、mismatched=0。未提供进一步的可读性修改建议。截图副本见 logs/verification_2026-10-17_B_manual_compare.png。
A：PYNQ 镜像来源、启动与实际 Overlay 使用条件待确认。
C：未来 skill/ 的负责人及材料整合尚未对齐，本轮未动其目录。

## 后续离线准备（本轮已完成）

1. 可复现的向量加法、前缀累加两种合成算法示例，以及错值、错序、缺值三个阴性用例：refsim/run_generic_compare_demo.py。
2. 一键生成每例输入、答案、实际值、比较报告，以及 JSON/Markdown 总表；明确 source=synthetic_python、hardware_validated=false，不生成硬件性能。
3. Notebook 模板 refsim/generic_compare_template.ipynb，默认只执行离线部分；提供接收已采集整数数组的接口，不伪造硬件调用。
4. 复跑说明、输入约定与 PYNQ 接入前置条件：refsim/generic_compare_README.md。
5. 原比较器六项测试、新增两项集成测试及五个演示用例已通过；Notebook 代码单元通过 Python 直接执行，未验证 Jupyter 界面或 PYNQ。输出见 logs/verification_2026-10-17_B_generic_followup.txt。

## 有环境后才做的事（仍未完成）

- 确认板卡兼容镜像、启动、PYNQ 版本、自有 Overlay 加载。
- 根据实际接口提供适配层并验证寄存器或 DMA、缓存一致性、有限等待和资源释放。
- 用真实硬件输出复跑比较，采集有来源的性能；如声称跨板可用需增加相应验证。
- A/C 确认正式 Skill 选型与整合。当前材料仍在 B 主责 refsim/，不代表比赛加分已取得。
