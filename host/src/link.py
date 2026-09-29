"""传输层 —— 「插座」。

上位机只认这个插座：往里塞字节、等一行回来、必要时把收到的半行掏出来扔掉。
**插座后面接的是真板子还是陪练，上位机不知道，也不需要知道。**
这样整套协议逻辑在没硬件的时候就能跑，插上板子那天只换插头，上面一个字不改。

三个动作
    write(data)              往插座里塞一串字节
    read_line(max_wait)      等一行回来；等不到返回 None
    discard_pending()        把还没收完的半行掏出来扔掉，**并告诉你扔了什么**

「一行」怎么算
    从缓冲开头到**第一个 LF（含 LF）**。**不剥** LF、**不剥** CR ——
    交给上位机去判。插座不替上位机做决定：
    CR 到底算不算错，是协议层的规矩，不是插座该管的事。

超时为什么不清空缓冲（这条最容易做错）
    等超时返回 None 时，**已经收到的半个行留在缓冲里**。
    理由：上位机必须能发现「对面发了半行就没声了」。
    要是插座自作主张把半行吞掉，下一次读就会读到一串错位的东西 ——
    症状看起来像协议错，其实是被吞了半个行。
    要清缓冲就显式调 discard_pending()，它会报出扔了什么（不做静默恢复）。

本文件**不认识协议**（这条有验收标准卡着，见 test_link.py 的说明）
    这里不许出现任何命令字、应答字、校验算法。
    插座一旦开始懂协议，事务状态机就会跟它抢活，那是以后返工的头号来源。

⚠️ 串口那条路（SerialLink）**从没被运行过**
    本机没装 pyserial，手上也没有板子。这段代码是写好了、但一次都没跑过的。
    没跑过的代码就是可能有 bug 的代码 —— 别把它当已验证的用。
    pyserial 用**懒加载**：只有真的要开串口时才 import，
    所以没装 pyserial 也照样能跑陪练那一整套。
"""

import time

LF = b"\n"

# §4.1:145 —— 波特率是**可改参数，不是写死的常数**（改要统一改，§5.5 的超时值按它推导）。
# 8N1 = 1 起始 + 8 数据 + 1 停止 = 每字节 10 位。
DEFAULT_BAUD = 115200

# CLAUDE.md:37 / host/README.md:21 —— 板载 CH340C 的串口号。
DEFAULT_PORT = "COM10"

# 串口轮询的粒度（秒）。取一小片而不是睡满整个 max_wait，
# 是为了让「等一行」能及时返回，而不是每次都卡到上限。
POLL_SLICE = 0.02


class LineBuffer:
    """收方向的行缓冲：塞字节进去，取整行出来。

    ⚠️ 它是 read_line 的**里子**。LoopbackLink 和 SerialLink 各持一个，
       所以「行怎么算、超时丢不丢」这两件事全仓库只有一份实现。
       测它就等于测 read_line 的行为 —— read_line 只是它外面的一层薄壳。
    """

    def __init__(self):
        self._buf = bytearray()

    def feed(self, data):
        """收进来的原始字节，原样追加。"""
        self._buf += data

    def take_line(self):
        """取一行（含结尾 LF）。缓冲里还没有完整的一行就返回 None，**不动缓冲**。"""
        i = self._buf.find(LF)
        if i < 0:
            return None
        line = bytes(self._buf[:i + 1])
        del self._buf[:i + 1]
        return line

    def pending(self):
        """缓冲里还没凑成一行的字节（副本，不改缓冲）。"""
        return bytes(self._buf)

    def discard(self):
        """清空缓冲，**返回被扔掉的字节** —— 调用方拿它记日志。"""
        thrown = bytes(self._buf)
        self._buf.clear()
        return thrown


class Link:
    """插座的形状。上位机只依赖这三个动作（外加 close）。"""

    def write(self, data):
        raise NotImplementedError

    def read_line(self, max_wait):
        raise NotImplementedError

    def discard_pending(self):
        raise NotImplementedError

    def close(self):
        pass


class LoopbackLink(Link):
    """插座后面接**陪练**（`fake_board.FakeBoard`）。全在同一个进程里，不用任何硬件。

    ⚠️ 陪练是按「行」工作的（喂一行进去，回若干行），所以**行框（framing）
       由本类负责**：攒字节 → 遇到 LF 就切出一行 → 喂给陪练 → 把回的行拼回字节流。

    ⚠️ **本类不看时钟**，和陪练是一个毛病：进程内没有真的时间。
       陪练是在被喂字节的那一刻**同步**就回的，所以「缓冲里没有」和「等超时了」
       是同一件事，max_wait 收下但用不上。
       后果：**「发半行就停 → 板子等超时」这条路径在陪练上复现不了**。
       那需要有人显式调 `board.timeout()` 来模拟「时间到了」，
       属于协议层的注错自测，不在这里假装能跑。
    """

    def __init__(self, board):
        self.board = board
        self._to_board = bytearray()   # 上位机 → 板子，还没凑够一行的字节
        self._rx = LineBuffer()        # 板子 → 上位机

    def write(self, data):
        self._to_board += data
        while True:
            i = self._to_board.find(LF)
            if i < 0:
                break
            line = bytes(self._to_board[:i + 1])
            del self._to_board[:i + 1]
            # 陪练自己会去掉 CR / LF，也会忽略空行（§5.5:541），这里原样交给它。
            # ⚠️ 陪练收发的是**字符串**（它用 str.replace 处理 CR/LF），
            #    插座这头是**字节**。交界处就在这里：严格 ASCII 解，乱码就当场炸。
            for reply in self.board.feed(line.decode("ascii")):
                self._rx.feed(reply.encode("ascii") + LF)

    def read_line(self, max_wait):
        return self._rx.take_line()

    def discard_pending(self):
        return self._rx.discard()

    def close(self):
        pass


class SerialLink(Link):
    """插座后面接**真串口**（板载 CH340C / 或一对虚拟串口）。

    ⚠️ **本类从没被运行过** —— 见模块 docstring 末尾。别当它是已验证的。
    """

    def __init__(self, port=DEFAULT_PORT, baud=DEFAULT_BAUD):
        try:
            import serial
        except ImportError:
            raise SystemExit(
                "!! 串口这条路要装 pyserial，本机没有。\n"
                "   装它：pip install pyserial\n"
                "   只想先跑协议逻辑、不碰硬件：改用默认的 loopback 插座，"
                "一条命令都不用装。")

        self.port = port
        self.baud = baud
        self._rx = LineBuffer()
        self._ser = None
        try:
            # 8N1：bytesize=8 / PARITY_NONE / STOPBITS_ONE（§4.1:145、§5.5:555）。
            # timeout 设成一小片，配合下面的截止时间做轮询。
            self._ser = serial.Serial(port, baudrate=baud, bytesize=8,
                                      parity=serial.PARITY_NONE,
                                      stopbits=serial.STOPBITS_ONE,
                                      timeout=POLL_SLICE)
        except serial.SerialException as e:
            raise SystemExit(
                "!! 打不开串口 %s（%d-8N1）：%s\n"
                "   常见原因：板子没插 / 串口号不是这个 / 别的程序（串口助手）正占着它。\n"
                "   看一眼本机有哪些串口：python -m serial.tools.list_ports" % (port, baud, e))

    def write(self, data):
        self._ser.write(data)
        # 必须等真的发完再返回。协议里的时序全靠「这一行已经出去了」这几个字，
        # 缓冲里还堆着就往下走，等于骗自己。
        self._ser.flush()

    def read_line(self, max_wait):
        deadline = time.monotonic() + max_wait
        while True:
            line = self._rx.take_line()
            if line is not None:
                return line
            if time.monotonic() >= deadline:
                return None
            chunk = self._ser.read(4096)      # timeout=POLL_SLICE：没数据也会回来
            if chunk:
                self._rx.feed(chunk)

    def discard_pending(self):
        thrown = self._rx.discard()
        n = self._ser.in_waiting
        if n:
            thrown += self._ser.read(n)
        return thrown

    def close(self):
        if self._ser is not None and self._ser.is_open:
            self._ser.close()


def open_link(kind="loopback", board=None, port=DEFAULT_PORT, baud=DEFAULT_BAUD):
    """按名字开一个插座。**默认 loopback** —— 不点明就不碰硬件。

    kind="loopback" 时要一个陪练实例；不给就自己造一个（延迟 import，
    免得只在跑串口时也把陪练整包拉起来）。
    """
    if kind == "loopback":
        if board is None:
            import fake_board
            board = fake_board.FakeBoard()
        return LoopbackLink(board)
    if kind == "serial":
        return SerialLink(port=port, baud=baud)
    raise SystemExit("!! 不认识的插座类型：%r。只认 loopback / serial。（默认 loopback）" % (kind,))
