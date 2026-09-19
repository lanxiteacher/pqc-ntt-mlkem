# ML-KEM-768 KAT 校验环境

这套东西解决一个问题：**凭什么相信一份 ML-KEM 实现是对的？**

答案是用已知答案测试（KAT）逐比特比对。这个目录里放的是能在本机跑起来的校验
环境，不依赖 OpenSSL，也不依赖网络。

> **⚠️ 向量出处要说清楚（答辩可能被问）**
>
> `kat_MLKEM_768.rsp` **不是 NIST 官方发布的文件**。它来自社区仓库
> `post-quantum-cryptography/KAT`，由一份 Rust 实现生成，其自述文件声称
> "Compliant with FIPS-203, published on August 13, 2024"，
> 并注明与 FIPS 203 的差异是「不含密钥校验（key validation）测试」。
>
> 为什么仍然可信：**我们用参考实现把 70 条向量逐比特复算通过了** ——
> 一份错误的向量集不可能让独立的实现四项全中。但措辞上应说
> 「社区维护的 FIPS 203 兼容向量集，已由参考实现独立复算验证」，
> 而不要说成「NIST 官方 KAT」。
>
> 真正的 NIST 官方测试向量走 **ACVP**（`github.com/usnistgov/ACVP-Server`），
> 是 JSON 格式、面向算法验证系统，与这里的 `.rsp` 格式不同。

---

## 一、快速使用

```sh
sh build_kat.sh                       # 编译（只需 gcc）
./kat_verify.exe kat_MLKEM_768.rsp    # 跑全部向量
./kat_verify.exe kat_MLKEM_768.rsp 10 # 最多打印 10 条失败的细节
```

实测输出（**1000 条全部通过**）：

```
=== ML-KEM-768 KAT 校验 ===
参数: K=3  pk=1184 B  sk=2400 B  ct=1088 B  ss=32 B

=== 汇总 ===
  完整记录: 1000
  通过:     1000
  失败:     0

  ✅ 全部通过 —— 参考实现与该向量集逐比特一致
```

1000 条跑完约 **1.3 秒**（`-O2`），所以完全可以当成回归测试反复跑 ——
改完参考实现或对接 FPGA 之后，一条命令就能确认没弄坏东西。

---

## 二、每一条向量验了什么

KAT 文件里每条记录给了 `z / d / msg / pk / sk / ct / ss / ct_n / ss_n`。
校验器用这些字段做 **四项互相独立的复算**：

| # | 检查 | 怎么算 | 比对什么 |
|---|------|--------|----------|
| ① | KeyGen | `coins = d‖z` 喂给 `crypto_kem_keypair_derand` | `pk`(1184B)、`sk`(2400B) |
| ② | Encaps | `coins = msg` 喂给 `crypto_kem_enc_derand` | `ct`(1088B)、`ss`(32B) |
| ③ | Decaps | `crypto_kem_dec(ct, sk)` | 是否还原出同一个 `ss` |
| ④ | 隐式拒绝 | `crypto_kem_dec(ct_n, sk)`，`ct_n` 是无效密文 | 结果须 == `ss_n`，**且** != `ss` |

第 ④ 项最容易被忽略，但它才是 FO 变换正确性的唯一证据。

**为什么第 ④ 项要额外加一条「且 != ss」**：如果实现把拒绝分支写错、直接返回了
正常解密结果，那么「== ss_n」这条单看是会通过的（因为 ss_n 就是按错误逻辑算出来的
那种情形）。两者一起判，才能把「拒绝路径真的生效了」和「压根没走拒绝路径」区分开。
这也是为什么 KAT 里要专门给一组 `ct_n`。

**注意 `z` 和 `d` 的顺序**【已验证】：FIPS 203 里 KeyGen 的输入是 `d‖z`，不是一个
64 字节的「随机种子」。落库到 sk 尾部的是 `z`（供拒绝时派生伪随机输出用），
而 `d` 只用于生成公私钥。

> 顺序用反了会怎样：**推断**是 ① 失败而 ②③④ 全过（因为 ②③④ 只消费已经算好的
> `pk/sk`，不再碰 `d/z`）。这个"只有 KeyGen 挂"的特征本身就是个诊断信号。
> 但这条我们**没有实测**（改代码专门去跑一个必然失败的用例，性价比不高），
> 当成排查时的方向参考即可，别当成已验证结论。

`coins = d‖z` 这个顺序本身是**实测确认**的 —— 用它跑 70 条向量全过；
如果顺序错了，那 70 条一条都过不了。

---

## 三、为什么走 `_derand` 接口

参考实现有两套入口：

```c
crypto_kem_keypair(pk, sk);                    /* 内部调 randombytes() */
crypto_kem_enc(ct, ss, pk);                    /* 内部调 randombytes() */

crypto_kem_keypair_derand(pk, sk, coins);      /* 随机性由调用者给 */
crypto_kem_enc_derand(ct, ss, pk, coins);      /* 随机性由调用者给 */
```

FIPS 203 的 KAT 文件把随机性**显式写成了 `d/z/msg` 字段**，所以走 `_derand`
可以完全绕开 DRBG。好处有三个：

1. **不需要 OpenSSL** —— 本机 MinGW 环境没有 OpenSSL 头文件，原生 `rng.c` 编译不过
2. **不需要 `/dev/urandom`** —— Windows 上根本没有
3. **逐比特可复现** —— 不引入任何环境相关的不确定性

代价是 `kem.o` 里仍然留着对 `randombytes` 的符号引用（非 derand 版在用），
所以链接时需要 `randombytes_stub.c` 提供这个符号。它被设计成**一旦真被调用就
立刻报错退出** —— 万一哪天误用了非 derand 入口，会在第一现场炸掉，而不是拿着
假随机数算出一堆「看起来正常」的结果。后者才是最难查的 bug。

---

## 四、★ 迁移到 FPGA：这个 harness 就是你的软硬件一致性测试台

现在 ①② 两步是「让软件算」，③④ 是「让软件验」。上板之后只要把 ①② 换成
**「从 FPGA 取回 pk/sk/ct/ss」**，③④ 一字不改：

```
   软件参考                          你的 FPGA
   ─────────                        ──────────
   ① keypair_derand  ──┐        ┌── ① KeyGen 模块
   ② enc_derand      ──┤        ├── ② Encaps 模块
                       ↓        ↓
                  比对 pk/sk/ct/ss  ← 同样的 d/z/msg，同样的期望值
                       ↑
   ③ dec(ct,sk)      ──┤        ├── ③ Decaps 模块
   ④ dec(ct_n,sk)    ──┘        └── ④ 拒绝路径
```

关键点：**KAT 给的是同一个 `d/z/msg` 输入下的标准答案**，这正好是 FPGA 需要的
激励向量。上板时把 `d/z/msg` 送进 FPGA，把输出的 `pk/sk/ct/ss` 读回来，跟
`.rsp` 里的期望值比即可 —— 这是端到端的功能验证。

**但要注意 KAT 验不了「只做了 NTT」的核**：KAT 的字段是 KEM 级的（pk/sk/ct/ss），
一个只有 NTT 的模块既吃不进也吐不出这些字段。NTT 核要用另一套方法验：直接对拍
参考实现的 `ntt()` 输出 —— 见 `gen_ntt_vectors.c`：

```sh
sh build_ntt_vectors.sh
./gen_ntt_vectors.exe      # 产出 ntt_in.hex / ntt_out.hex / intt_*.hex / basemul_*.hex
```

> ⚠️ 别和上一级目录的 `../ntt_golden.py` 搞混。那是**独立的黄金模型**
> （另一套自己写的实现，已证明与 C 参考位精确一致，见汇编 §1.3 判据②）；
> 本目录的 `gen_ntt_vectors.c` 是从 **C 参考实现**导向量给 testbench 用。
> 两者都可信，但独立性不同 —— 黄金模型的价值正在于它是独立写的。

---

## 五、文件清单

| 文件 | 作用 |
|------|------|
| `kat_verify.c` | **主程序** —— KAT 校验器 |
| `build_kat.sh` | 编译脚本 |
| `kat_MLKEM_768.rsp` | 向量集，FIPS 203 格式，**1000 条**，12,012,890 字节（出处见文首警告） |
| `fetch_kat.py` | 可断点续传的抓取脚本（见第六节） |
| `randombytes_stub.c` | `randombytes()` 哨兵桩，被调用即报错退出 |
| `gen_ntt_vectors.c` | NTT/INTT/basemul 黄金向量生成器（FPGA testbench 用） |
| `build_ntt_vectors.sh` | 上面那个的编译脚本 |
| `ntt_in/out.hex`、`intt_in/out.hex`、`basemul_*.hex` | 生成出来的对拍向量，可直接 `$readmemh` |
| `ntt_vectors.txt` | 向量说明与实测常数（缩放因子、R²、128⁻¹） |
| `aes256_ecb.c` / `.h` / `aes_tables.h` | 自包含 AES-256，已独立验证 |
| `test_aes.c` / `testvec.txt` | AES 的 FIPS-197 + 500 条随机向量交叉验证 |
| `gen_aes_tables.py` | 生成 S-box（GF(2⁸) 求逆 + 仿射变换，非手打） |
| `gen_testvec.py` | 用 Python `cryptography` 库生成 AES 交叉验证向量 |
| `PQCgenKAT_kem.c` / `rng.c` / `rng.h` | NIST 原始 KAT 生成器（备用） |
| `rng_nossl.c` | `rng.c` 去掉 OpenSSL 后的版本（由 `patch_rng.py` 生成） |
| `patch_rng.py` | 生成 `rng_nossl.c` 的脚本 |

---

## 六、已知问题与踩过的坑

### 网络：0.8~1.6 MB 处必断

这个网络环境下，**任何大文件下载都会在 0.8~1.6 MB 处被掐断**。实测：

| 方式 | 结果 |
|------|------|
| `codeload.github.com` 拉 tarball | HTTP 200，但 1,627,740 B 处截断，gzip 校验失败 |
| `codeload` + Range 头 | 服务端**忽略** Range，仍返回 200 全文，一样截断 |
| `raw.githubusercontent.com` | HTTP 000，不可达 |
| `api.github.com` contents API | 1,530,357 B 处截断 |
| `api.github.com` + `?ref=` blobs API | 652 KB 处截断 |
| **`api.github.com` + Range 头** | ✅ **206 Partial Content，精确返回请求的字节数** |

所以唯一可靠的路子是 **Range 分块 + 断点续传**，代价是未认证用户每小时只有
60 次请求。`fetch_kat.py` 就是干这个的：200 KB 一块，61 块正好 12,012,890 字节；
碰到 403 就查 `rate_limit` 接口的 `reset` 时间戳，睡到重置再继续；已经落盘且大小
正确的块直接跳过，所以中途被打断不丢进度。

```sh
PYTHONIOENCODING=utf-8 python fetch_kat.py
```

### ✅ jsDelivr：绕开 API 限流的正路（重要发现）

被 `api.github.com` 的 60 次/小时卡住时，**不要干等重置** —— 试 jsDelivr CDN，
它代理 GitHub 文件，**不共享 api.github.com 的配额**：

```sh
curl -r 12000000-12012889 \
  "https://fastly.jsdelivr.net/gh/OWNER/REPO@BRANCH/PATH"
```

本次实测（同一份 12 MB 文件、同一个时间段）：

| 主机 | 结果 |
|------|------|
| `cdn.jsdelivr.net` | HTTP **416**（Range 不满足） |
| **`fastly.jsdelivr.net`** | ✅ **HTTP 206，精确返回 12,890 字节** |
| `gcore.jsdelivr.net` | HTTP **416** |

三个镜像行为不一致，**要逐个试**，别试了一个就下结论。`fastly` 这次是通的。

本次就是靠它拿到的尾部：文件前 12,000,000 字节来自 GitHub API、最后 12,890 字节
来自 jsDelivr，两源拼接后 **1000 条记录全部逐比特通过** —— 这反过来证明两个源的
文件完全一致（边界上错一个字节，第 998/999 条就会挂）。

### 成品指纹（日后核对用）

```
kat_MLKEM_768.rsp   12,012,890 字节
md5    87b81ca7e225a6cd315dced67989eb55
sha256 6ecab47c229a80b85afd8e9b1b76e604317b2505ac35382b0e288116e1ba860a
```

### ⚠️ 分块下载必须校验「内容」，光比大小会吃大亏

这是这套东西里最值得记的一条教训。

分块抓取时，**403 限流返回的不是空响应，而是一个 279 字节的 JSON 错误页**：

```json
{"message":"API rate limit exceeded for 36.110.14.175. ..."}
```

如果合并逻辑只检查"这一块字节数对不对"，这种错误页在某些情况下会被当成正常数据
写进产物里。本次就真的发生了：产出的 `kat_MLKEM_768.rsp` 大小看起来接近正常
（12,000,279 字节），前 12,000,000 字节也完全正确，**但最后 12,890 字节被换成了
一个 279 字节的错误页**，导致最后两条记录（count=998/999）残缺。

**所以：抓取时校验内容，交付前校验产物。** 两道都要有：

```sh
# ① 大小必须精确等于 12,012,890
ls -l kat_MLKEM_768.rsp

# ② 记录数必须正好 1000，且 11 个字段各出现 1000 次
grep -c "^count = " kat_MLKEM_768.rsp
grep -o "^[a-z_]* =" kat_MLKEM_768.rsp | sort | uniq -c

# ③ 最硬的判据：跑校验器，看有没有 "记录不完整/已跳过"
./kat_verify.exe kat_MLKEM_768.rsp
```

第 ③ 条最关键 —— 校验器会把残缺记录显式报出来（`⚠️ 末尾 count=N 记录不完整`），
所以**只要它说了"跳过"，产物就是坏的**，别被"通过: 998 失败: 0"迷惑。

`complete_kat.py` 里已按这个原则写了内容校验（拒绝含 `"message"` 的响应）。

### `randombytes.c` 没下下来

上游 `kyber_ref/randombytes.c` 抓到的是一张 GitHub 限流错误页（278 字节 JSON），
不是源码。已用 `randombytes_stub.c` 替代 —— 它不参与任何密码学运算，不影响校验
正确性（理由见第三节）。**如果日后需要非 derand 入口，必须补回真正的实现。**

### `rng.c` 的 OpenSSL 依赖

原生 `rng.c` 依赖 `<openssl/evp.h>` 等头文件做 AES-256 单块加密，本机 MinGW
没有这套东西。为此写了一个自包含的 `aes256_ecb.c`，并用 **FIPS-197 附录 C.3
官方向量 + 500 条与 Python `cryptography` 库交叉验证的随机向量**验证通过，
然后用 `patch_rng.py` 把 `rng.c` 里的 OpenSSL 块换掉，生成 `rng_nossl.c`。

这条路线目前是**备用**的 —— 主线走 `_derand` 根本不需要 DRBG。留着的价值是：
万一以后要复现 NIST 原生 `PQCgenKAT_kem.c` 的输出，这条链是通的。

---

## 七、和项目其它部分的关系

- 算法本体的讲解（三层结构、NTT 索引规则、域/缩放陷阱）见
  `../PQC-NTT_ML-KEM_技术资料汇编.md`
- 参考实现源码在 `../kyber_ref/`
- 标准原文在 `../standards/`（FIPS 203/204/205）
- 被推翻的旧结论见 `../已核实结论_修正选题指导文档.md`
