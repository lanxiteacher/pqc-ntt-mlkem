# 通用整数结果检查：离线准备与 PYNQ 接入模板

本目录组件由 B 准备，正式 Skill 的选型与整合仍待 A/C 对齐。使用 Python 3 标准库，不需要板卡、Vivado、PYNQ、NumPy 或 Jupyter。Notebook 仅在需要图形界面时才需要 Jupyter。

## 现在可复跑的内容

从仓库根目录执行（输出目录必须尚不存在）：

```powershell
python refsim/run_generic_compare_demo.py --output ../B_generic_demo_01
```

生成两种算法的五个用例：向量加法正确/改错一项，前缀累加正确/交换顺序/缺少末项。两种长度分别为 5、7，含正数、负数和零。每个用例保留 inputs、expected、actual、report 四份 JSON；根目录 summary.json 和 summary.md 汇总结果。所有实际值均是 Python 合成结果，不是硬件输出。已有目录会被拒绝，换一个新目录名即可重跑。

正常输出为 Synthetic checks: 5/5。它表示两个正确样例通过、三个故意出错样例被发现；不表示五份计算结果全正确。三个阴性样例的 observed_status 应是 mismatch。没有采集性能或资源，不用离线耗时推断硬件速度。

单独检查一组数据：

```powershell
python refsim/compare_integer_results.py ../B_generic_demo_01/vector_add_bad_value/expected.json ../B_generic_demo_01/vector_add_bad_value/actual.json --report ../B_generic_demo_01/manual_report.json
```

本条应返回 MISMATCH，第 4 个值应为 44、实际为 45，退出码 1。退出码 0=匹配，1=结果不同，2=输入或输出错误。报告中的 expected_count/actual_count 是数量，details 中 expected/actual 是具体数值；position 从 1 数，index 从 0 数。

## 复用规则

输入为 UTF-8 JSON 一维整数数组；标准答案非空。按位置精确比较，长度差异也失败。禁止布尔值、浮点数、字符串与自动排序/模约减/补零。若算法需要转换模域、位宽或输出顺序，由算法适配层明确处理并独立验证；这个检查器不猜。

将别的算法结果导出为相同格式即可使用，不限定 NTT、256 点、3329 或特定板卡。两个合成算法只能证明离线比较接口的复用，不能证明跨板兼容。

## Notebook 与以后接入 PYNQ

`generic_compare_template.ipynb` 可直接在 Jupyter 中打开；默认代码只做离线演示。也可不用安装 Jupyter，按上面的 Python 命令运行。Notebook 含一个接收已采集整数列表的函数，不负责操作硬件，硬件来源标签不能替代原始证据。

接板时保留比较器，在它前面实现适配层：

1. A 确认板卡、镜像来源、PYNQ/Python 版本以及能加载自有 Overlay；记录实际异常，不能只看芯片型号。
2. 提供与目标板匹配的 bit/hwh、IP 接口契约、数据位宽/符号/顺序。当前项目为纯 PL UART，不能直接假设存在 AXI DMA 或 register_map。
3. 适配层负责装载、送数、有限等待、收数和释放资源，返回一维 Python int 列表；NumPy 整数需显式 int 转换，先确认符号及溢出语义。
4. 参考结果独立计算；记录输入、标准答案、原始硬件输出、转换规则与比较报告。不要把 expected 复制为 actual。
5. 用真硬件重复正确/改错/缺失结果的检查；超时与 DMA/cache 问题需由真实接口单独验证。

验收清单和证据边界见 `../team/plan_B_generic_compare.md`。本轮不提供未经环境确认的 DMA 调用，也没有执行 Overlay、缓存、硬件超时或跨板测试。
