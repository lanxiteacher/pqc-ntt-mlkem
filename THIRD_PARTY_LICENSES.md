# 第三方组件与许可证

本仓库包含来自第三方的材料。逐条列在下面，含出处、版权人与许可证。
分发本作品时请一并保留本文件。

许可证全文未逐字复制的，给出了官方链接；标注「全文见下」的已附在文末。

---

## 一、清单

### 1. `research/ref_rtl/kyber-polmul-hw/` —— 多项式乘法硬件基线

| 项 | 内容 |
|---|---|
| 作者 | Ahmet Can Mert, Ferhat Yaman |
| 论文 | *A High-Performance and Scalable Hardware Architecture for Kyber's Polynomial Multiplication*，IEEE，DOI 见 <https://ieeexplore.ieee.org/abstract/document/9474139> |
| 许可证 | **CC0 1.0 Universal**（公有领域奉献） |
| 许可证链接 | <https://creativecommons.org/publicdomain/zero/1.0/> |

**授权依据是逐文件的声明，不是 README。** `pe1/` 下每个 `.v` 文件的头部都写着：

```
To the extent possible under law, the implementer has waived all copyright
and related or neighboring rights to the source code in this file.
http://creativecommons.org/publicdomain/zero/1.0/
```

注意：同仓库的 `README.md` 里另有一句 "the implementations are for academic
research only and does not come with any support or any responsibility"。
该句与逐文件的 CC0 声明不一致。CC0 是**不可撤销**的权利放弃，逐文件声明
构成实际授权；README 那句按免责声明（不提供支持、不承担责任）理解。
此处如实记录两者，以备查阅。

`rtl/` 与 `refsim/pe1/` 下的 RTL 是在本组件基础上改造得到的。
改动清单见 `refsim/README.md` 第五节。

### 2. `research/ref_rtl/KyberButterflyCollection/` —— 蝶形单元合集

| 项 | 内容 |
|---|---|
| 作者 | Bertels, Norga, Verbauwhede（KU Leuven COSIC） |
| 论文 | *A Better Kyber Butterfly for FPGAs*，FPL 2024，ePrint 2024/1367 |
| 许可证 | **CC0 1.0 Universal** |
| 许可证全文 | 见 `research/ref_rtl/KyberButterflyCollection/LICENSE` |

### 3. `research/kyber_ref/` —— ML-KEM C 参考实现

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/pq-crystals/kyber> |
| 许可证 | **CC0 1.0 Universal 或 Apache License 2.0**（双许可，任选其一） |
| 上游 LICENSE 原文 | 见文末第二节 |

上游 LICENSE 原文全文如下：

```
Public Domain (https://creativecommons.org/share-your-work/public-domain/cc0/);
or Apache 2.0 License (https://www.apache.org/licenses/LICENSE-2.0.html).

For Keccak and AES we are using public-domain
code from sources and by authors listed in
comments on top of the respective files.
```

其中 `fips202.c` 的头部另注明源自公有领域实现：

```
Based on the public domain implementation in crypto_hash/keccakc512/simple/ from
http://bench.cr.yp.to/supercop.html by Ronny Van Keer and the public domain "TweetFips202"
implementation from https://twitter.com/tweetfips202 by Gilles Van Assche, Daniel J. Bernstein,
and Peter Schwabe
```

注：上游仓库根目录有 `LICENSE` 文件，但本仓库内的副本未一并复制该文件。
上游许可证正文已在此处完整列出，作为替代。

### 4. `research/mlkem_kat/` —— ML-KEM-768 已知答案测试向量

| 项 | 内容 |
|---|---|
| 出处 | <https://github.com/post-quantum-cryptography/KAT> |
| 版权人 | Copyright (c) 2024 Krzysztof Kwiatkowski |
| 许可证 | **MIT License** |
| 许可证全文 | 见文末第一节 |

涉及的文件：`kat_MLKEM_768.rsp`（1000 条向量）、`KAT_README.md`、
`PQCgenKAT_kem.c`。

关于这批向量的性质与可信度，见 `research/mlkem_kat/README.md` 开头的说明。

### 5. `research/standards/` —— NIST 标准文档

| 文件 | 标准 |
|---|---|
| `NIST.FIPS.203.pdf` | ML-KEM（模块格密钥封装） |
| `NIST.FIPS.204.pdf` | ML-DSA（模块格数字签名） |
| `NIST.FIPS.205.pdf` | SLH-DSA（无状态哈希数字签名） |

美国政府作品，**公有领域**，不受版权保护。

### 6. `research/papers/`、`research/kyber_ref/papers/`

第三方出版方的论文 PDF 与网页，**不在本仓库内**（见 `.gitignore`）。

---

## 二、许可证全文

### 1. MIT License（`post-quantum-cryptography/KAT`）

```
MIT License

Copyright (c) 2024 Krzysztof Kwiatkowski

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### 2. pq-crystals/kyber 的双许可声明

见上文第 3 条。CC0 1.0 全文见
<https://creativecommons.org/publicdomain/zero/1.0/legalcode>，
Apache License 2.0 全文见同目录 `LICENSE`。

---

## 三、本作品自身的许可证

本作品（`refsim/`、`host/`、`rtl/`、`docs/`、`team/` 等目录下我方原创的部分）
依据 **Apache License 2.0** 发布，全文见同目录 `LICENSE`。

本次选用的许可证与上述全部第三方许可证兼容：上游组件均为 CC0（无任何限制）
或 MIT / Apache-2.0（宽松许可，非传染性），不要求本作品改用其他许可证。
