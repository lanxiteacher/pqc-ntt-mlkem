"""link.py 的自测 —— 传输层（插座）。

运行
    PYTHONIOENCODING=utf-8 python host/src/test_link.py

它在验什么
    验插座**只搬字节**，而且搬得不多不少、不吞不清：

    1. 来回搬字节正确 —— 把一条命令喂进插座，取回来的回帧**逐字节**等于板子该回的那一行；
    2. 缓冲不多不少 —— 一次塞两条回帧，两次 read_line 分别取到第一、第二条，第三次说没有；
    3. 超时不吞半行 —— 缓冲里只有半个行时返回 None，**半行还在**，补齐后能取到完整行；
    4. discard_pending() 报出扔了什么 —— 返回值就是被扔掉的那些字节，不是空；
    5. 行框（framing）—— 一行分两次塞进插座，照样能取到完整的一行；
    6. 插座不认识协议 —— **解析 link.py 的源码**（用 ast），确认里面没有任何命令字 /
       应答字 / 校验算法。只看**代码**，跳过注释和 docstring：
       注释里提一句协议不改变行为，代码里出现才是「插座开始懂协议」。
    7. 没装 pyserial 时串口那条路报**人话**，而且 loopback 是默认值（不点明不碰硬件）。
    8. **按设备名找口号**（`match_port`）—— 唯一命中就返回、大小写不敏感、
       一条都不命中/命中两条都**响亮报错不猜**、设备名为空的条目不许崩。
       这是 `host/README.md:23`「不要写死数字」的落点：猜错口号 = 把数据发到别人的设备上。
    9. **SerialLink 的真身**（装了 pyserial 才跑）—— 借 pyserial 自带的 `loop://`
       假串口，把「开 / 写 / 读整行 / 超时 / discard_pending / 关」在真的 pyserial
       上走一遍。**没有板子**也能跑，但**电气层验不到**（见文末「覆盖范围的实话」）。

这一版改了什么（两条都是**我自己**写错的，留着当教训）
    · 第 6 条第一版是**整文件字符串搜**禁词，把校验分隔符那个星号也列进去了 ——
      结果我注释里的 Markdown 加粗 `**这样**` 被命中 22 处。**单个字符**当禁词，
      分不清「代码里的符号」和「散文里的排版」，这条检查本身就是错的。
      改成只盯**代码**之后才说得通。
    · 同一个检查还漏过 `Q = 3329` —— 因为 3329 是**数字常量**，而第一版只收字符串常量。
      现在用 str() 一网打尽。
    教训：**新写的检查必须自己证明它会报错**。「干净」在没验过报错路径之前，
    既可能是真干净，也可能是检查坏了。

⚠️ 覆盖范围的实话
    · SerialLink 的**真身**借 `loop://` 假串口验了（**第 9 条**，要装了 pyserial 才跑）：
      开 / 写 / 读整行 / 超时 / discard / 关，都在真 pyserial 上走过一遍。
      ⚠️ 但 loop:// 是**进程内**的假串口，**电气层一行没验**：波特率与真实时序、
      USB 驱动延迟与丢字节、CH340 硬件流控、以及「真板子能不能打开串口号」。
      这些只有真板子能给 —— 别把「第 9 条全绿」读成「串口可用」。
    · **第 8 条**：`match_port` 被拆成纯函数（不 import pyserial、不碰硬件），
      所以「按名字找口号」这段不依赖任何硬件，永远验得到。`host/README.md:23`
      那句「不要写死数字」的落点就在这。
    · 「发半行就停 → 板子等超时」那条路径在陪练上**复现不了**（进程内没有真时钟），
      原因写在 link.py 的 LoopbackLink docstring 里。这里不假装能跑。
"""

import ast
import sys
from pathlib import Path

import link
import proto

FAILS = []
CHECKS = [0]


def check(cond, what):
    CHECKS[0] += 1
    if not cond:
        FAILS.append(what)


def eq(got, want, what):
    CHECKS[0] += 1
    if got != want:
        FAILS.append("%s\n      得到：%r\n      该是：%r" % (what, got, want))


# ---------------------------------------------------------------- 禁词检查

# 协议的字眼。出现在**代码**里 = 插座开始懂协议了，这不行。
PROTOCOL_WORDS = ["#PING", "#NTT", "#INTT", "#PMUL", "#ABORT", "#LAYERS",
                  "#OK", "#ERR", "#BEGIN", "#DONE", "#RDY",
                  "checksum", "xor", "3329"]

# 校验值分隔符那个星号。单独拎出来验，因为它是**单个字符** ——
# 混在词表里会把我自己注释里的 Markdown 加粗（`**这样**`）全判成违规。
# （第一版就是这么写的，22 处误报。见模块 docstring 末尾「这一版改了什么」。）
STAR = "*"


def code_strings_and_names(path):
    """挑出 link.py 里**代码**部分的字符串和标识符，跳过注释与 docstring。

    为什么要跳过：注释和 docstring 里提一句协议**不改变任何行为**，
    只有代码里出现才是「插座开始懂协议」。
    """
    tree = ast.parse(path.read_text(encoding="utf-8"))

    doc_nodes = set()                    # docstring 那些字符串常量节点
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            body = getattr(node, "body", [])
            if body and isinstance(body[0], ast.Expr) \
                    and isinstance(body[0].value, ast.Constant) \
                    and isinstance(body[0].value.value, str):
                doc_nodes.add(id(body[0].value))

    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant):
            if id(node) in doc_nodes:
                continue
            # ⚠️ 用 str() 一网打尽，**不只收字符串**：模数 3329 在代码里是个**数字**，
            #    第一版只查了 str 常量，`Q = 3329` 就漏过去了（真的漏过一次）。
            out.append((node.lineno, str(node.value)))
        elif isinstance(node, ast.Name):
            out.append((node.lineno, node.id))
        elif isinstance(node, ast.Attribute):
            out.append((node.lineno, node.attr))
        elif isinstance(node, ast.arg):
            out.append((node.lineno, node.arg))
    return out


def protocol_smells(path):
    """返回 [(行号, 命中的东西, 那一行是啥), ...]。空 = 干净。"""
    hits = []
    for lineno, text in code_strings_and_names(path):
        for tok in PROTOCOL_WORDS:
            if tok in text:
                hits.append((lineno, tok, text))
        if STAR in text:
            hits.append((lineno, STAR, text))
    return sorted(hits)


# ---------------------------------------------------------------- 陪练当住户

def fresh_link():
    """造一个「插座 + 陪练」的完整回路。"""
    import fake_board
    board = fake_board.FakeBoard()
    return link.LoopbackLink(board), board


def main():
    print("=== 1 / 2 / 5：来回搬字节、缓冲不多不少、行能分两次塞 ===")

    lk, _ = fresh_link()
    cmd = proto.append_checksum("#PING")
    lk.write((cmd + "\n").encode("ascii"))
    got = lk.read_line(1.0)
    want = (proto.append_checksum("#OK PING") + "\n").encode("ascii")
    print("  发出去：%r" % (cmd + "\n"))
    print("  收回来：%r" % got)
    print("  该是　：%r" % want)
    eq(got, want, "来回搬字节：取回的不是板子该回的那一行")

    eq(lk.read_line(1.0), None, "只发了一条命令，第二次读竟然还有东西")

    lk, _ = fresh_link()
    lk.write(((cmd + "\n") * 2).encode("ascii"))
    a = lk.read_line(1.0)
    b = lk.read_line(1.0)
    eq(a, want, "一次塞两条：第一条取错了")
    eq(b, want, "一次塞两条：第二条取错了")
    eq(lk.read_line(1.0), None, "一次塞两条，第三条不该有东西")

    lk, _ = fresh_link()
    raw = (cmd + "\n").encode("ascii")
    for byte in raw:                       # 一个字节一个字节地塞
        lk.write(bytes([byte]))
    eq(lk.read_line(1.0), want, "行拆成一个一个字节塞进去，拼不回来了")

    print("")
    print("=== 3 / 4：超时不吞半行、discard 报出扔了什么（直接验行缓冲）===")
    print("  （read_line 就是这层缓冲外面的薄壳，行为由它决定）")

    buf = link.LineBuffer()
    buf.feed(b"#OK P")                     # 半个行
    eq(buf.take_line(), None, "半个行不该被当成一行")
    eq(buf.pending(), b"#OK P", "超时之后半行竟然被吞掉了")
    buf.feed(b"ING\n")
    eq(buf.take_line(), b"#OK PING\n", "补齐之后取不到完整的一行")

    buf.feed(b"\r\n")                      # CR 不许被插座擅自剥掉
    eq(buf.take_line(), b"\r\n", "插座把 CR 偷偷剥掉了 —— 那是协议层该判的事")

    buf.feed(b"#OK P")
    eq(buf.discard(), b"#OK P", "discard_pending 没报出扔了什么")
    eq(buf.pending(), b"", "discard 之后缓冲没清干净")

    lk, _ = fresh_link()
    eq(lk.discard_pending(), b"", "刚开的插座，缓冲不该有东西")

    lk, _ = fresh_link()
    lk.write((cmd + "\n").encode("ascii"))       # 板子回了帧，就躺在缓冲里
    eq(lk.discard_pending(), want, "插座里明明躺着一条回帧，discard 却说没扔东西")
    eq(lk.read_line(1.0), None, "discard 之后那条回帧还在")

    print("")
    print("=== 6：插座不认识协议（解析 link.py 的代码，跳过注释和 docstring）===")

    src_path = Path(__file__).with_name("link.py")
    hits = protocol_smells(src_path)
    for lineno, tok, text in hits:
        print("  !! link.py:%d 代码里出现了 %r —— %r" % (lineno, tok, text))
    check(not hits, "link.py 的代码里出现了协议的字眼/符号：%r" % (hits,))
    print("  查了 %d 个协议词 + 那一个星号分隔符" % len(PROTOCOL_WORDS))
    print("  结果：%s" % ("代码干净，插座不认识协议" if not hits else "有 %d 处" % len(hits)))
    # 防呆：解析不出东西来时，「干净」是假的
    n_bits = len(code_strings_and_names(src_path))
    check(n_bits > 20, "只从 link.py 里挑出 %d 个字符串/标识符 —— 解析八成坏了" % n_bits)
    print("  顺带：从代码里挑出 %d 个字符串/标识符参与检查" % n_bits)

    print("")
    print("=== 7：没装 pyserial 时报人话；默认插座是 loopback ===")

    try:
        import serial                                    # noqa: F401
    except ImportError:
        try:
            link.SerialLink(port="COM_NOT_THERE")
        except SystemExit as e:
            msg = str(e)
            print("  SerialLink 的报错：")
            for ln in msg.splitlines():
                print("    " + ln)
            check("pyserial" in msg, "报错里没提 pyserial")
            check("pip install pyserial" in msg, "报错里没给装法")
            check("ModuleNotFoundError" not in msg, "报错里漏出了 ModuleNotFoundError")
        except ModuleNotFoundError:
            check(False, "裸的 ModuleNotFoundError 漏出来了，没被翻译成人话")
        except Exception as e:
            check(False, "抛出的是 %s，不是一句人话" % type(e).__name__)
        else:
            check(False, "没装 pyserial，SerialLink 居然开成功了")
    else:
        print("  !! 本机装了 pyserial —— 上面那条「没装时报人话」**这次没验**。")
        print("     要验它得在没装的环境里跑。别把这一行读成「验过了」。")

    lk = link.open_link()                     # 不传 kind
    check(isinstance(lk, link.LoopbackLink),
          "open_link() 默认不是 loopback —— 不点明就不该碰硬件")
    print("  open_link() 默认给出：%s" % type(lk).__name__)

    try:
        link.open_link("telepathy")
    except SystemExit as e:
        check("loopback" in str(e), "认不出插座类型时，报错里没提示默认值")
    else:
        check(False, "乱给一个插座类型居然也能开")

    print("")
    print("=== 8：按设备名找口号（纯函数，喂名字进去，不碰硬件）===")
    print("  为什么能在这验：match_port 不 import pyserial、不碰硬件。")
    print("  为什么必须验：它是 README 那句「不要写死数字」的落点 ——")
    print("  猜错口号不是报错，是**把数据发到别人的设备上**，所以宁可炸也不能猜。")

    # 8a 唯一命中
    eq(link.match_port([("COM9", "USB-SERIAL CH340"), ("COM1", "标准串口")]),
       "COM9", "唯一命中时没返回那一条的口号")

    # 8b 大小写不敏感（Windows 报的设备名大小写不稳定）
    eq(link.match_port([("COM9", "usb-serial ch340")]), "COM9",
       "设备名大小写不同就找不到了")

    # 8c 一条都不命中 -> 响亮报错
    try:
        link.match_port([("COM1", "标准串口"), ("COM4", "")])
    except SystemExit as e:
        msg = str(e)
        check("USB-SERIAL CH340" in msg, "找不到时没报出找的是哪个设备名")
        check("list_ports" in msg, "找不到时没给出「怎么看本机串口」的办法")
    else:
        check(False, "一条都没命中，match_port 居然返回了值（那就是猜了一个）")

    # 8d 命中两条 -> 响亮报错，并把候选都列出来（不许挑一个）
    try:
        link.match_port([("COM9", "USB-SERIAL CH340"),
                         ("COM11", "USB-SERIAL CH340 (2)")])
    except SystemExit as e:
        msg = str(e)
        check("COM9" in msg and "COM11" in msg,
              "命中两条时没把候选都列出来 —— 那就等于替你猜了")
    else:
        check(False, "命中两条，match_port 居然挑了一个")

    # 8e 设备名是空的 / None 的条目 -> 不许崩
    try:
        eq(link.match_port([("COM1", None), ("COM2", ""), ("COM3", "USB-SERIAL CH340")]),
           "COM3", "有空设备名的条目时找错了")
    except SystemExit as e:
        check(False, "有设备名为空的条目就崩了：%s" % e)

    # 8f 没装 pyserial 时，find_port 报的该是同一句人话
    try:
        import serial                                    # noqa: F401
    except ImportError:
        try:
            link.find_port()
        except SystemExit as e:
            check("pyserial" in str(e), "find_port 没装 pyserial 时没报人话")
        except Exception as e:
            check(False, "find_port 抛出的是 %s，不是一句人话" % type(e).__name__)
        else:
            check(False, "没装 pyserial，find_port 居然跑通了")
    else:
        print("  !! 本机装了 pyserial —— 8f 那条「没装时报人话」**这次没验**。")

    print("")
    print("=== 9：SerialLink 的**真身** —— 借 loop:// 假串口跑（只在装了 pyserial 时）===")
    try:
        import serial                                    # noqa: F401
    except ImportError:
        print("  !! 没装 pyserial —— 这一条**这次没验**（loop:// 是它的东西）。")
    else:
        # loop:// 是 pyserial 自带的**进程内**假串口：写进去的字节原样读回来。
        # 有了它，SerialLink 的构造 / 开关 / 收发 / 行缓冲接线在**没有板子**的机器上
        # 也能被真跑一遍 —— 这正是第 1~6 条验不到的那半（见文件头「覆盖范围的实话」）。
        # ⚠️ 它**验不了电气层**：波特率与真实时序、USB 驱动延迟与丢字节、CH340 硬件
        #    流控、以及「真板子能不能打开串口号」这一步。下面会把它打出来。
        try:
            lk = link.SerialLink(port="loop://")
        except SystemExit as e:
            check(False, "loop:// 居然没开起来（改 serial_for_url 之前它必然开不了）：%s" % e)
            print("  !! 开 loop:// 失败：%s" % e)
        else:
            check(isinstance(lk, link.SerialLink), "loop:// 开出来的不是 SerialLink")
            eq(lk.port, "loop://", "loop:// 下 port 没存对")
            eq(lk.baud, link.DEFAULT_BAUD, "loop:// 下 baud 没存对")

            # 9a 写进去 → 原样读回来（走真正 pyserial 的 write + flush）
            lk.write(b"#PING*33\n")
            eq(lk.read_line(1.0), b"#PING*33\n", "loop:// 下没把整行搬回来")

            # 9b 没数据时到点返回 None —— 不是半行，也不抛
            eq(lk.read_line(0.05), None, "没数据时 read_line 没返回 None")

            # 9c 一次两条回帧：两次 read_line 分别取到第一、第二条
            lk.write(b"AAA\nBBB\n")
            eq(lk.read_line(1.0), b"AAA\n", "loop:// 下第一条取错了")
            eq(lk.read_line(1.0), b"BBB\n", "loop:// 下第二条取错了")
            eq(lk.read_line(0.05), None, "两条取完之后不该还有")

            # 9d discard_pending 如实报出扔了什么
            lk.write(b"CCC\nDDD\n")
            tossed = lk.discard_pending()
            check(b"CCC" in tossed and b"DDD" in tossed,
                  "discard_pending 没如实报出扔掉的字节：%r" % tossed)

            # 9e 关得上，而且真的关了
            lk.close()
            check(not lk._ser.is_open, "close() 之后串口还是开的")

            print("  SerialLink 真身：开 / 写 / 读整行 / 超时 / discard / 关 —— 全部真跑过 ✓")
            print("  ⚠️ loop:// **验不到**：波特率与真实时序、USB 驱动延迟与丢字节、")
            print("     CH340 硬件流控、以及「真板子能不能打开串口号」这一步。")
            print("     任何「够不够快 / 会不会超时 / 板子在不在」的结论，必须上真板子。")

    print("")
    if FAILS:
        print("%d 项检查，%d 项不过：" % (CHECKS[0], len(FAILS)))
        for f in FAILS:
            print("  x " + f)
        return 1
    print("%d 项检查通过。" % CHECKS[0])
    print("")
    print("⚠️ 记住覆盖范围：SerialLink 的真身借 loop:// 跑过了（第 9 条），但那是**进程内**")
    print("   假串口 —— **电气层（波特率/时序、USB 丢字节、CH340 流控、能不能开真口号）")
    print("   一行没验**。详见本文件 docstring 末尾「覆盖范围的实话」。")
    print("   另：本文件的项数是**环境相关**的 —— 装了 pyserial 跑第 9 条、不跑第 7/8f 的")
    print("   「没装时报人话」分支（少 4 项），没装则反过来。上面这个数别当固定值引。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
