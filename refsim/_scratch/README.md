# _scratch —— 排查过程中的中间产物，不是交付物

这里的东西**跑验证不需要**，删掉也不影响 `run_fntt_check.sh` /
`run_intt_pwm2_check.sh`。留着是因为其中几个是"域约定"那件事的原始证据，
以后有人质疑结论时可以回来看。

要跑验证就别进这个目录。

---

## 文件来历

| 文件 | 是什么 |
|---|---|
| `tmp_*.txt` | 排查期间的临时输入/输出，多是一次性的单组向量 |
| `dump_zetas.c` / `.exe` | 打印参考实现 `zetas[0..127]` 的小工具 |
| `zetas_dump.txt` | 上面那个工具的输出（`zetas[64..67] = -1103, 430, 555, 843`） |
| `tmp_author_pwm2_dump.v` | 作者版 PWM2 testbench 的插桩副本，用来 dump 它的 RTL 原始输出 |
| `batch/author_pwm2_out.txt` | 上面那个 dump 的结果 —— **"RTL 的 PWM2 输出 = 参考实现 basemul × R"这条结论的原始证据** |
| `test_pe1/` | `pe1/test_pe1/` 的残缺副本，作废 |
| `pe1/` | 排查期间的 RTL 副本 |

---

## 为什么会有这些

RTL 的域约定和 C 参考实现不一样，第一轮对拍是"256 个系数全错"。
排查路径是：先怀疑 RTL 有 bug → 发现作者自带 testbench 是过的 →
改怀疑自己的期望值 → 逐系数取比值，发现比值**恒定**（不是随机错），
于是定位到是约定差异而不是逻辑错误。

`author_pwm2_out.txt` 就是最后那一步用的：不看"通不通过"，直接 dump RTL
的真实输出，再和参考实现逐系数相除，比值的集合大小为 1 —— 这一步才把
"RTL 少一级 Montgomery 归约"钉死。

结论已经写进 `gen_batch_vectors.py` 的文件头和 `../README.md`。
