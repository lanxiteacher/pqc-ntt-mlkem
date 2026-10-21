# assets —— 截图 / 录屏 / 波形素材归档

**主责：C**（维护者）｜ 状态：🔄 **演示页 4 张（10-01）+ GUI 5 张（10-19）+ A 的关键路径截图 2 张（10-15）已入库**；
A 的上板录屏原始 112 MB 因超出仓库单文件上限**不入库**（文件在 A 处）；**2026-10-21 另压了一份 1080p / 14.9 MB 的入库版**（`_1080p.mp4`，给 C 剪辑用，原始件仍是母版）；B 的 `refsim/` 波形截图仍可选

全组的截图、录屏、波形图，统一命名、统一目录。
**素材来源是 A、B**，你是收口的人。

---

## 命名约定

```
assets/YYYY-MM-DD_<who>_<what_it_proves>.<ext>
```

例：

```
2026-09-22_A_folding_sweep_three_configs.png
2026-09-23_B_16_vectors_bitwise_match.png
2026-09-25_A_board_uart_first_receive.mp4
2026-09-28_C_ntt_layer1_butterfly_anim.gif
```

### 细则

| 字段 | 规则 |
|---|---|
| `YYYY-MM-DD` | **素材产生那天**，不是补录那天。补录会毁掉时间线 |
| `<who>` | `A` / `B` / `C`，**单个大写字母** |
| `<what_it_proves>` | **英文**（小写字母 / 数字 / 下划线），说清**「这张图证明了什么」**。不许写 `screenshot1` `untitled` `new_file` |
| 后缀 | `.png` 静态图（截图 / 波形图 / Vivado 报告截图）<br>`.mp4` 录屏<br>`.gif` 30 秒以内的短动效（能直接插进报告的那种） |

⚠️ **`<what_it_proves>` 必须是英文 —— 这是竞赛硬规定。** 《选题指南》§3.2.5 与
§3.3.5.4 两处原话都是「仓库内所有目录名与文件名**须**使用纯英文（小写字母、数字、
下划线或连字符）……中文只出现在文件的正文内容中」。2026-10-05 全仓刚把 17 个中文名
清成英文（其中 4 个在 `assets/`）—— **照中文命名做出来的文件，正好是当天被清掉的那一类。**

---

## 规矩

**1. 每完成一小步就丢进来，别攒。**
「对拍通过」那张截图是报告和视频里最有说服力的素材，而它只在那 10 分钟里存在过。
A、B 忙起来最容易忘 —— **忘了 C 就去要**。

**2. 存原始文件，不要只存进 PPT/Word。**
剪视频时要从原始文件取，从 PPT 里抠出来的图是糊的。

**3. 一个素材至少被用三次。**
报告配图、演示视频、答辩 PPT 都从这里出 —— 所以命名要让人**六个月后还找得到**。

**4. 报告里用到的图不要在这里删。**
`../report/figures/` 里的是"报告用的那一版"（可能裁过、加过标注），
这里是原始件。两边都留着。

---

## 当前内容

| 文件 | 证明什么 |
|---|---|
| `2026-10-01_C_demo_fntt_layer3_highlight.png` | 正变换走到第 3 层，变过的格子高亮、选中的数与它的配对可点开看算式 |
| `2026-10-01_C_demo_intt_layer4_highlight.png` | 逆变换同上（GS/DIF 蝶形，方向与正变换镜像） |
| `2026-10-01_C_demo_match_4096_all_pass.png` | 对拍页：RTL 落盘输出 vs 黄金向量，**4096/4096 全中**，全场无红格 |
| `2026-10-01_C_demo_negative_control_1_mismatch.png` | 同一页点「改坏一条期望值」→ 网格里**正好 1 个红格**，说明这个测试有牙齿 |
| `2026-10-19_C_gui_act1_input.png` | 现场演示 GUI 第①幕：KAT 向量输入 + 256 格预览 + 页面自检徽标（32/32 组） |
| `2026-10-19_C_gui_act2_layer4.png` | 第②幕：自动走到第 4 层，整排数字变化 + 当前蝶形算式 |
| `2026-10-19_C_gui_act3_match_all_pass.png` | 第③幕：单组 **256/256** 逐值一致，右侧列出四类运算的判定与证据 |
| `2026-10-19_C_gui_act3_negative_control.png` | 第③幕点「阴性对照」→ **正好 1 个红格**（脚本按红格数断言，不靠目视） |
| `2026-10-19_C_gui_act4_timing_resources.png` | 第④幕：三档周期/延迟/资源/Fmax 卡片 + 两张图 + 两句口径 |
| `2026-10-15_A_critical_path_board_pe1.png` | 板级关键路径（协议状态机，布线占比约八成） |
| `2026-10-15_A_critical_path_core_pe1.png` | 核内关键路径（蝶形，布线占比约七成） |
| `2026-10-15_A_board_uart_five_transactions_1080p.mp4` | 上板串口实拍：五条计算事务逐条 256/256（屏幕 + 板子同框）；**1080p 压缩版**，母版 112 MB 在 A 处 |

**怎么重新截**（本机没有 GUI 可手动截，走无头 Edge）：

```bash
node demo/gen_shots.mjs          # 全部（会重写已归档的旧 PNG）
node demo/gen_shots.mjs gui      # 只截文件名含 gui 的 5 张（推荐，不动旧素材）
```

⚠️ 页面数据是生成物。**改过 `demo/` 之后先重跑数据生成器，再截图**，
否则截到的是旧图：

```bash
node demo/gen_layers.mjs && node demo/gen_compare.mjs && node demo/gen_gui_data.mjs && node demo/gen_shots.mjs
```

> 上面 **2026-10-01 那 4 张**是**原图**（深色主题）。⚠️ 深底不适合黑白打印 —— **报告用的浅底版已另做**：
> `../report/figures/demo_ntt_layer3.png` / `demo_compare_pass.png` / `demo_compare_negctrl.png`
> （同一个脚本加 `?theme=light` + 裁切生成，见 `../report/figures/README.md` §一）。
> 惯例：**原始件留在这里，报告那一版放 `report/figures/`，两边都留**（见下「规矩」第 4 条）。

**A 的素材（10-15 已交，10-21 补入库版）**：关键路径两组截图已在上表；上板串口录屏
`2026-10-15_A_board_uart_five_transactions_1080p.mp4` **1080p / 14.9 MB，已入库**，C 可直接拿去剪；
**母版 `..._five_transactions.mp4`（112 MB）仍被 `.gitignore` 挡住，留在 A 处**（画质更高，需要时向 A 要）。
压缩参数：libx264 `-crf 26 -vf scale=-2:1080`，1:12，音轨 AAC 128k；抽第 40 秒一帧核过终端文字可读。
**B 的素材**：`refsim/` 对拍波形截图仍可选（段 4 不用它也能讲清楚）。

---

## 相关

- 谁在什么时候往这里丢：`../team/roles_and_duties.md` §七
- 环境与工作方式：`../team/env_align_C.md` 第七节
- 报告配图：`../report/figures/`
