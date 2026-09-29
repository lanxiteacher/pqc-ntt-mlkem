"""unpack.py 的自测 —— 解包、落盘、按数值对拍。

运行
    PYTHONIOENCODING=utf-8 python host/src/test_unpack.py

它在验 11 件事
    1. **两张表都是双射** —— 256 个下标互不重复、正好盖住 0..255。
    2. **两张表确实不同** —— FNTT 和 INTT 要是同一张，§5.3.4 那张表就是白写的。
    3. **代码里的表和 proto.md 对得上** —— 运行时去读 §5.3.4:370-374 那张表，
       把「输出顺序」列的**前几项**拿出来，和公式算出来的比。
       （比全表强：文档里写的是 `0,2,1,3,4,6,5,7,...`，本来就只有前几项 + 省略号。）
    4. **投毒** —— 故意拿 FNTT 的表去解 INTT 的数据，必须**响亮地失败**，
       而且错的是「一大片」不是「一个」。
    5/6/7. **真向量往返** —— 拿 `*_exp.txt` 的真数据，用逆序摆成「板子该发的
       物理序」，再喂给 `unpack`，必须**逐个数值**等于原文件。
       （FNTT / INTT / PWM2 三条走 `vectors.read_vector` 的**严格**读法。）
    8. **落盘合铁律** —— 读回**原始字节**：行尾只有 LF、没有 CR；每行 3 位小写 hex。
    9. **「按数值比」不是空话** —— 拿真实的**变长**文件 `fullmul_exp.txt` 当证据：
       我们写 3 位、它是变长，**文本逐字节必然不同**，而按数值比**必须相等**。
    10. **防呆** —— 行数不对 / 形状不对 / 命令不认识 / 值越界，一律**响亮报错**，
        不静默、不猜、不跳过。
    11. **假绿的机理** —— 把「文件序」当成「板子回的物理序」喂进去，**必然全错**。
        这条是那个假绿陷阱的警钟。

关于第 3 条（这是第 4 步报告之外**我自己加的**一条）
    报告里我只列了 10 条。动手时意识到：如果把两张表的数字**凭记忆抄**进代码，
    文档哪天改了，代码不会跟着动，而且**没有任何测试会报警**（跑的是代码，不是文档）。
    项目里已经有先例：`test_proto.py` 运行时去读 proto.md 的校验值表，
    `fake_board.py` 运行时去读 proto.md 的命令表。所以这里也用同一套办法。
    ⚠️ 只读**输出顺序**那一列。**输入顺序**那一列有争议（见第 4 步报告），本步不碰它。

⚠️ 覆盖范围的实话
    · 这里验的是「顺序摆得对不对」，**不是**「板子算得对不对」。后者要真板子。
    · 真板子还没有；本文件里出现的「物理序」全是**我们自己用逆序造出来的**。
      所以它能证明「解包逻辑自洽」，**不能**证明「真板子真的按这个序回传」。
    · 真板子到底回什么序，最终依据是 §5.3.4:366 引的那几处 iverilog 实测。
"""

import re
import sys
import tempfile
from pathlib import Path

import unpack
import vectors

FAILS = []
CHECKS = [0]

B = vectors.BATCH_DIR
PROTO_MD = Path(__file__).resolve().parent.parent / "proto.md"

# proto.md 里那张表的表头（§5.3.4:368-374 —— 写**区间**：368 那一行正是表头本身，
# 单行指到表头等于没指，test_citations.py 的第 4 条会拦下来）。
# ⚠️ 锚点用整行比对。文档改了表头，这里会**响亮地失败**而不是悄悄读不到。
ORDER_ANCHOR = "| 运算 | 输入顺序 | 输出顺序 |"


def check(cond, what):
    CHECKS[0] += 1
    if not cond:
        FAILS.append(what)


def eq(got, want, what):
    CHECKS[0] += 1
    if got != want:
        FAILS.append("%s\n      得到：%r\n      该是：%r" % (what, got, want))


def raises(fn, what):
    """要它**响亮报错**。不报错就是失败。"""
    CHECKS[0] += 1
    try:
        fn()
    except SystemExit:
        return
    except Exception as e:
        FAILS.append("%s：抛的是 %s，不是一句人话：%s" % (what, type(e).__name__, e))
        return
    FAILS.append("%s：居然没报错" % what)


# ---------------------------------------------------------------- 读 proto.md 那张表

def read_doc_output_orders():
    """从 proto.md §5.3.4 那张表里读出「输出顺序」列的**前几项**。

    返回 {"FNTT": [0,2,1,3,4,6,5,7], "INTT": [0,128,1,129,2,130], "PWM2": [...]}
    读不到就**响亮报错** —— 读不到时返回空表，会让第 3 条变成假绿。
    """
    lines = PROTO_MD.read_text(encoding="utf-8").splitlines()
    try:
        i = lines.index(ORDER_ANCHOR)
    except ValueError:
        raise SystemExit("!! 在 %s 里找不到那张顺序表的表头：%r"
                         % (PROTO_MD, ORDER_ANCHOR))

    out = {}
    for line in lines[i + 2:]:            # +2：跳过表头本身和它下面那条分隔线
        if not line.startswith("|"):
            break
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3:
            continue
        name, cell = cells[0], cells[2]
        # 单元格里可能带 ** 加粗、` 反引号、⚠️ 提醒。只取省略号**之前**那一段数字，
        # 免得把「与 FNTT 不同」这种话里的字也当成数据。（省略号有两种写法，都算。）
        head = re.split(r"\.\.\.|…", cell)[0]
        nums = [int(n) for n in re.findall(r"\d+", head)]
        for key in ("FNTT", "INTT", "PWM2"):
            if name.startswith(key):
                out[key] = nums
    return out


def main():
    # ------------------------------------------------------------ 1
    print("=== 1：两张表都是双射（256 个下标互不重复、盖住 0..255）===")
    for kind in ("FNTT", "INTT", "PWM2"):
        perm = unpack.permutation(kind)
        eq(len(perm), 256, "%s 的序长度不是 256" % kind)
        eq(len(set(perm)), 256, "%s 的序里有重复下标 —— 不是双射，解包会丢数据" % kind)
        eq(min(perm), 0, "%s 的序最小值不是 0" % kind)
        eq(max(perm), 255, "%s 的序最大值不是 255" % kind)
        print("  %-5s perm 前 8 项 = %s   （双射 ✓）" % (kind, list(perm[:8])))

    # ------------------------------------------------------------ 2
    print("")
    print("=== 2：FNTT 和 INTT 确实不是同一张表 ===")
    f, i_ = unpack.permutation("FNTT"), unpack.permutation("INTT")
    check(f != i_, "FNTT 和 INTT 的序竟然一样 —— 那 §5.3.4 那张表就是白写的")
    n_diff = sum(1 for a, b in zip(f, i_) if a != b)
    check(n_diff > 128, "两张表只有 %d 处不同，几乎一样 —— 八成是抄错了" % n_diff)
    eq(unpack.permutation("PWM2"), f, "PWM2 该和 FNTT 同序")
    print("  两个序有 %d / 256 处不同" % n_diff)
    print("  FNTT 前 8：%s" % list(f[:8]))
    print("  INTT 前 8：%s" % list(i_[:8]))

    # ------------------------------------------------------------ 3
    print("")
    print("=== 3：代码里的表 vs proto.md 里写的（运行时去读，不是抄一遍）===")
    docs = read_doc_output_orders()
    eq(sorted(docs), ["FNTT", "INTT", "PWM2"], "proto.md 那张表没读出正好三行")
    for key in sorted(docs):
        pref = docs[key]
        # 防呆：解析坏了会得到空表或一两个数，那样「对得上」是假的。
        check(len(pref) >= 4, "proto.md 的 %s 行只解析出 %d 个数 —— 解析八成坏了"
                              % (key, len(pref)))
        eq(list(unpack.permutation(key)[:len(pref)]), pref,
           "proto.md 写的 %s 输出序，和代码里公式算出来的对不上 —— "
           "文档改了，代码没跟着改" % key)
        print("  %-5s 文档 %s  ←→  代码同样（✓）" % (key, pref))

    # ------------------------------------------------------------ 4
    print("")
    print("=== 4：投毒 —— 拿 FNTT 的表去解 INTT 的数据，必须响亮地失败 ===")
    intt_exp0 = [int(x, 16)
                 for x in vectors.split_groups(
                     vectors.read_vector(B / "intt_batch_exp.txt"),
                     "intt_batch_exp.txt")[0]]
    phys = unpack.to_physical_order("INTT", intt_exp0)
    eq(unpack.unpack("INTT", phys), intt_exp0, "用对表竟然还原不回来")
    got = unpack.unpack("FNTT", phys)
    n_bad, diffs = unpack.compare_values(got, intt_exp0)
    check(n_bad > 200, "用错表只错了 %d 个 —— 投毒没生效，这条检查是假的" % n_bad)
    print("  用对表：0 个错")
    print("  用错表：%d / 256 个错（第一个不同在第 %d 位，%03x ←→ %03x）"
          % (n_bad, diffs[0][0], diffs[0][1], diffs[0][2]))

    # ------------------------------------------------------------ 5 / 6 / 7（含 FULL/TIME）
    print("")
    print("=== 5/6/7：真向量往返 —— 摆成物理序，再解回来，必须逐个数值相等 ===")
    roundtrip = [
        ("#NTT 1",       "ntt_batch_exp.txt",    "FNTT", True),
        ("#INTT 1",      "intt_batch_exp.txt",   "INTT", True),
        ("#PMUL NTT 1",  "pwm2_batch_exp.txt",   "PWM2", True),
        # ⚠️ 下面两条的 exp 文件是**变长**的，vectors.read_vector 会响亮拒绝
        #    （实测：fullmul_exp 291 行、halfmul_exp 291 行不是 3 位），
        #    所以这两条走 unpack.read_values。
        ("#PMUL FULL 1", "fullmul_exp.txt",      "INTT", False),
        ("#PMUL TIME 1", "halfmul_exp.txt",      "INTT", False),
    ]
    for cmd, name, want_kind, strict in roundtrip:
        eq(unpack.kind_of(cmd), want_kind, "%s 该推出 %s" % (cmd, want_kind))
        if strict:
            exp0 = [int(x, 16)
                    for x in vectors.split_groups(vectors.read_vector(B / name), name)[0]]
            reader = "vectors.read_vector（严格 3 位）"
        else:
            exp0 = unpack.read_values(B / name)[:256]
            reader = "unpack.read_values（宽容 1~3 位）"
        phys2 = unpack.to_physical_order(unpack.kind_of(cmd), exp0)
        got2 = unpack.unpack(unpack.kind_of(cmd), phys2)
        eq(got2, exp0, "%s：往返之后没还原回来" % cmd)
        check(phys2 != ["%03x" % v for v in exp0],
              "%s 的物理序竟然和自然序一模一样 —— 那这个测试什么都没验" % cmd)
        print("  %-14s %-20s %s  → 往返一致（✓）" % (cmd, name, reader))

    # ------------------------------------------------------------ 8
    print("")
    print("=== 8：落盘合 §5.3.5:384 的铁律（二进制模式 + LF）===")
    values = [0, 171, 3328] + list(range(253))       # 3328 = 0xd00，正好 3 位
    eq(len(values), 256, "测试数据没造够 256 个")
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "out.txt"
        unpack.write_result(p, values)
        raw = p.read_bytes()
        check(b"\r" not in raw, "落盘的文件里有 CR —— 被 Windows 改成 CRLF 了")
        lines = raw.split(b"\n")
        eq(lines[-1], b"", "文件最后没有以 LF 结尾")
        lines = lines[:-1]
        eq(len(lines), 256, "落盘行数不对")
        bad_shape = [l for l in lines if not re.fullmatch(rb"[0-9a-f]{3}", l)]
        check(not bad_shape, "有行不是「3 位小写 hex」：%r" % bad_shape[:3])
        eq(unpack.read_values(p), values, "读回来和写进去的不一样")
        print("  写出去 %d 字节；CR 个数 %d；每行都是 3 位小写 hex ✓"
              % (len(raw), raw.count(b"\r")))
        print("  前 3 行 %r" % lines[:3])
        print("  边界：0 → %r，3328 → %r，4095 → %r"
              % (b"%03x" % 0, b"%03x" % 3328, b"%03x" % 4095))

    # ------------------------------------------------------------ 9
    print("")
    print("=== 9：拿真实的变长文件当证据 —— 文本必然不同，数值必须相等 ===")
    full = unpack.read_values(B / "fullmul_exp.txt")
    exp_full = full[:256]
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "ours.txt"
        unpack.write_result(p, exp_full)
        ours = p.read_bytes().split(b"\n")[:256]
        theirs = (B / "fullmul_exp.txt").read_bytes().split(b"\n")[:256]
        n_text = sum(1 for a, b in zip(ours, theirs) if a != b)
        check(n_text > 0, "两边文本竟然一模一样 —— 那就证明不了「按数值比」的必要性")
        n_bad, _ = unpack.compare_values(unpack.read_values(p), exp_full)
        eq(n_bad, 0, "按数值比竟然不相等")
        print("  文件 %s：前 256 行里，%d 行文本不同（它是变长的，我们写 3 位）"
              % ("fullmul_exp.txt", n_text))
        print("  按**文本**逐字节比 → 会报「%d 行全不同」" % n_text)
        print("  按**数值**比       → 不同的个数 0（✓）")
    whole = unpack.read_values(B / "fullmul_exp.txt")
    n_unpadded = sum(1 for l in (B / "fullmul_exp.txt").read_bytes().split(b"\n")[:-1]
                     if len(l) != 3)
    eq(len(whole), 4096, "fullmul_exp.txt 的行数不是 4096")
    print("  顺带实证：整个 fullmul_exp.txt 4096 行里有 %d 行不是 3 位"
          "（§5.3.5:389-393 说的那批）" % n_unpadded)

    # ------------------------------------------------------------ 10
    print("")
    print("=== 10：防呆 —— 形状不对一律响亮报错，不许静默 ===")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        shaped = td / "bad_line.txt"
        shaped.write_bytes(b"001\nzz\n")
        truncated = td / "no_lf.txt"
        truncated.write_bytes(b"001\n002")
        cases = [
            ("解包时行数不对（255 行）", lambda: unpack.unpack("FNTT", ["001"] * 255)),
            ("解包时行数不对（257 行）", lambda: unpack.unpack("FNTT", ["001"] * 257)),
            ("解包时行只 1 位十六进制", lambda: unpack.unpack("FNTT", ["1"] * 256)),
            ("解包时行不是十六进制",     lambda: unpack.unpack("FNTT", ["zzz"] * 256)),
            ("解包时行是空串",           lambda: unpack.unpack("FNTT", [""] * 256)),
            ("命令认不出",               lambda: unpack.kind_of("#WHAT 1")),
            ("#PMUL 缺域参数",           lambda: unpack.kind_of("#PMUL")),
            ("不认识的 #PMUL 域",        lambda: unpack.kind_of("#PMUL BOGUS 1")),
            ("不认识的运算类型",         lambda: unpack.permutation("NOPE")),
            ("写盘时值越界（4096）",     lambda: unpack.write_result(td / "x.txt", [4096])),
            ("摆物理序时长度不对",       lambda: unpack.to_physical_order("FNTT", [1, 2, 3])),
            ("对拍两边长度不同",         lambda: unpack.compare_values([1], [1, 2])),
            ("读到非十六进制的行",       lambda: unpack.read_values(shaped)),
            ("读到最后一行没 LF",        lambda: unpack.read_values(truncated)),
        ]
        for what, fn in cases:
            raises(fn, what)
            print("  响亮报错 ✓  %s" % what)

    # ------------------------------------------------------------ 11
    print("")
    print("=== 11：假绿的机理 —— 把「文件序」当成物理序喂进去，必然全错 ===")
    # 实测（2026-09-29）：陪练 fake_board 现在回吐的就是 exp 文件的**文件序**，
    # 而 §5.3.4:376 定的是「原样回传**物理序**」。两者对不上 = 假绿。
    # 这里不 import 陪练 —— 它是第 5 步要改的东西，别把 unpack 的测试绑在它身上。
    # 直接演示机理：文件序 == 自然序，当物理序喂进去 = 把自然序又按 perm 摆了一遍。
    got_bad = unpack.unpack("INTT", ["%03x" % v for v in intt_exp0])
    n_bad, diffs = unpack.compare_values(got_bad, intt_exp0)
    check(n_bad > 200, "把自然序当物理序喂进来，只错了 %d 个 —— 机理没被钉住" % n_bad)
    print("  错了 %d / 256 个（第一个不同在第 %d 位）→ 这就是「静默变 256 个全错」" % (n_bad,
                                                                        diffs[0][0]))
    print("  ⚠️ 所以：谁把陪练的输出直接当物理序喂给 unpack，谁就会看到这一幕。")
    print("     第 5 步把陪练改成吐物理序之后，这一幕才会消失。")

    # ------------------------------------------------------------
    print("")
    if FAILS:
        print("%d 项检查，%d 项不过：" % (CHECKS[0], len(FAILS)))
        for f in FAILS:
            print("  x " + f)
        return 1
    print("%d 项检查通过。" % CHECKS[0])
    print("")
    print("⚠️ 记住覆盖范围：这里验的是「顺序摆得对不对」，不是「板子算得对不对」。")
    print("   本文件里的「物理序」全是我们自己用逆序造的，真板子还没见过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
