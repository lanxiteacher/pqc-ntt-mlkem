# checklists —— 踩坑清单

**这个目录里的每一条都是本项目真实踩过的**，不是从网上抄的通用建议。
每条按同一个格式写：

```
现象 → 原因 → 怎么修 → 怎么预防
```

外加两行：**怎么发现的**（这一条最重要，它决定下次能不能更快发现）和 **谁扛**
（AI 能代写代码，但概念、常数来源、板级调试只能人扛）。

---

## 索引

| 文件 | 主题 | 条数 |
|---|---|---|
| [`data-format.md`](data-format.md) | 数据文件的编码与行尾（跨平台最容易出事的一类） | 6 |
| [`verification.md`](verification.md) | 验证方法学：怎么才算「验过了」 | 9 |
| [`rtl-and-timing.md`](rtl-and-timing.md) | RTL、时序、资源报告 | 6 |
| [`toolchain-and-board.md`](toolchain-and-board.md) | 工具链与上板 | 8 |
| [`ai-collaboration.md`](ai-collaboration.md) | 与 AI 协作时特有的坑 | 5 |

---

## 怎么用这份清单

**如果只读三分钟**：读 `data-format.md` 第 1 条、`verification.md` 第 1 条和第 3 条、
`toolchain-and-board.md` 第 1 条 —— 这四条是「不知道就会卡半天、而且卡得莫名其妙」的那一类。

**如果是新项目起步**：按 `data-format.md` → `verification.md` → `toolchain-and-board.md`
的顺序把清单过一遍，把能提前设防的设上（`.gitattributes`、有界循环、相对路径）。

**如果是排查具体问题**：清单里的「现象」一栏是按症状写的，用来检索。

---

## 一句话规律

> **AI 能写大约 90% 的代码；剩下 10% 是概念理解、常数来源、板级调试。**
> 那 10% 决定作品成不成。

本项目里反复出现的一类失败是**看上去失败、其实只是约定不同**：

- 对拍报「256 个系数全错」，实际只差一个常数因子（`verification.md` 第 4 条）
- 灌数据报「256 个系数全错」，实际只是读出顺序不同（`rtl-and-timing.md` 第 5 条）
- `diff` 报「256 行全不同」，实际每个数都一样（`data-format.md` 第 1 条）

**三者的排查方法一模一样：先别怀疑逻辑，先看比值 / 看字节。**
恒定比值 = 约定问题；杂乱比值 = 功能问题。
