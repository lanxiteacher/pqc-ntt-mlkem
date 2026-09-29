"""hex 向量文件的读法与切组 —— 上位机和陪练**共用**这一份。

谁在用
    · 陪练（fake_board.py）：读 `*_exp.txt` 当「标准答案」回放；
    · 上位机：读**输入**文件决定「要发什么」，读 `*_exp.txt` 决定「该收到什么」。

    两边必须用**同一套读法**。否则一边切出 16 组、另一边切出 15 组，
    对拍失败会被误判成「协议不对」，查半天查到一个不存在的 bug。
    所以这块只有一个实现，谁都不许再抄一份（memory: proto-md-single-source）。

⚠️ 这里定死的两个数是**协议的一部分**，不是随手选的
    · 一行 = 恰好 3 位十六进制 —— §5.3.1:322（12 位 ÷ 4 位每 hex 字符 = 正好 3）
    · 一组 = 256 行 —— §4.2（每组 256 个系数）
    改这两条等于改协议，要同步改 proto.md。

读法一律**响亮失败**
    不补零、不截断、不静默跳过。向量文件坏了会让整轮对拍跑在错的基础上，
    症状是「256 个系数全错」—— 那比直接崩更坏，因为它很像 RTL 有 bug。
"""

import re
from pathlib import Path

# 一个系数的合法写法：恰好 3 位十六进制。
# 大小写都收 —— 板子端**宽容接收**大写（§5.3.1:323、§5.1:206）；
# 文件本身全是小写，但读文件时宽容一点没有坏处（真收到大写会立刻暴露）。
DATA_LINE_RE = re.compile(r"^[0-9a-fA-F]{3}$")

# 向量文件在哪（§5.2:271 指向各 testbench 的 $readmemh）
BATCH_DIR = Path(__file__).resolve().parent.parent.parent / "refsim" / "batch"

# 一个「组」有多少个系数。五个 *_batch_tb.v 都写着 `parameter NV = 16;`，
# 向量文件是 NV 组 × 256 行（例如 ntt_batch_in.txt = 16 × 256 = 4096 行）。
GROUP_LEN = 256

# 命令 -> (输入文件们, 输出文件)。**依据是各 *_batch_tb.v 的 $readmemh 原文**：
#   fntt_batch_tb.v:47-48      intt_batch_tb.v:45-46
#   pwm2_batch_tb.v:47-49      halfmul_batch_tb.v:47-49     fullmul_batch_tb.v:50-52
# 键是命令词元去掉 <n>（(`#PMUL`, `TIME`) 这样）。
VECTORS = {
    ("#NTT",):          (["ntt_batch_in.txt"],   "ntt_batch_exp.txt"),
    ("#INTT",):         (["intt_batch_in.txt"],  "intt_batch_exp.txt"),
    ("#PMUL", "NTT"):   (["pwm2_batch_a.txt", "pwm2_batch_b.txt"], "pwm2_batch_exp.txt"),
    ("#PMUL", "TIME"):  (["halfmul_a.txt", "halfmul_b.txt"],       "halfmul_exp.txt"),
    ("#PMUL", "FULL"):  (["fullmul_a.txt", "fullmul_b.txt"],       "fullmul_exp.txt"),
}


def read_vector(path):
    """读一个向量文件，返回每行的正文。

    ⚠️ 文件里出现的任何一行只要不是 3 位十六进制，就**响亮报错** ——
    向量错了会让整轮对拍都在错的基础上跑，比直接崩更坏。
    """
    out = []
    for i, ln in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        ln = ln.rstrip()          # .gitattributes 是 `* -text`，文件可能是 CRLF
        if not ln:
            continue
        if not DATA_LINE_RE.match(ln):
            raise SystemExit(
                "!! %s 第 %d 行不是 3 位十六进制：%r\n"
                "   向量文件坏了。别改这个文件来迁就代码 —— 先查是谁生成的它。"
                % (path, i, ln))
        out.append(ln)
    return out


def split_groups(lines, name):
    """把一整个向量文件按 GROUP_LEN 切成若干组。

    切不开（行数不是整倍数）或一组都切不出，都**响亮报错** —— 不补零、不截断。
    """
    if not lines:
        raise SystemExit("!! %s 是空的，一组向量都没有。" % name)
    if len(lines) % GROUP_LEN:
        raise SystemExit(
            "!! %s 有 %d 行，不是 %d 的整数倍 —— 组切不开。\n"
            "   向量文件坏了。别改这个文件来迁就代码 —— 先查是谁生成的它。"
            % (name, len(lines), GROUP_LEN))
    return [lines[i:i + GROUP_LEN] for i in range(0, len(lines), GROUP_LEN)]
