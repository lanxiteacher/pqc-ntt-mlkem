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

⚠️ 串口那条路（SerialLink）**验到什么程度，说清楚**（2026-10-06 订正）
    它**本身**现在能借 `serial_for_url("loop://")` 在**没有板子**的机器上跑
    （test_link.py 第 9 条）——「开 / 关 / 收发 / 行缓冲接线」这几件事被跑过了。
    但 loop:// 是**进程内的假串口**，它验不到**电气层**：
    波特率与真实时序、USB 丢字节、CH340 流控、以及「真口号到底开不开得起来」。
    所以口径是：**接线层验过，电气层一行没验** —— H6 联调第一天仍要先跑
    `host/src/board_run.py`（见 KNOWN_ISSUES C2）。
    pyserial 用**懒加载**：只有真的要开串口时才 import，
    所以没装 pyserial 也照样能跑陪练那一整套。

    ⚠️ 另外单独拆出来验的是**「按设备名找口号」**那一段（match_port）——
        它是纯函数，不碰硬件、也不 import pyserial，所以本机就能验（test_link.py 第 8 条）。
"""

import time

LF = b"\n"

# §4.1:145 —— 波特率是**可改参数，不是写死的常数**（改要统一改，§5.5 的超时值按它推导）。
# 8N1 = 1 起始 + 8 数据 + 1 停止 = 每字节 10 位。
DEFAULT_BAUD = 115200

# host/README.md:21-23 —— 板载 CH340C 的**设备名**。按名字找口，**不写死口号**：
# 口号是 Windows 按「插在哪个 USB 口」现分配的（这块板子见过 COM10，也见过 COM9），
# 写死一个数字，迟早把数据发到别的设备上去。找口逻辑见下面的 match_port / find_port。
CH340_NAME = "USB-SERIAL CH340"

# 想开串口却没有 pyserial 时，统一报这一句人话（两处入口共用，免得各写一版）。
_NO_PYSERIAL = (
    "!! 串口这条路要装 pyserial，本机没有。\n"
    "   装它：pip install pyserial\n"
    "   只想先跑协议逻辑、不碰硬件：改用默认的 loopback 插座，"
    "一条命令都不用装。")

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

    # 2026-10-18：允许上位机把整段数据行**一次写出去**吗？
    #   真串口置 True —— 逐行 write 会逐行 flush，921600 时那 256 次 USB 往返
    #   比线上 23 ms 还贵（实测 0.094 s → 约 0.03 s）。
    #   陪练保持 False：test_host.py 按「一次 write = 一行」数发送行数，
    #   批量写会让那条断言从 512 变成 1；陪练本来就跑不出 USB 开销，不必改它。
    BULK_WRITE = False

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

    ⚠️ **建好的一刻，收缓冲里就已经有板子开机自发的那一行 `#RDY`**（见 __init__）——
       陪练是「已上电」的，不是「等你喂第一行才醒」。`Host.handshake()` 就靠它。
    """

    def __init__(self, board):
        self.board = board
        self._to_board = bytearray()   # 上位机 → 板子，还没凑够一行的字节
        self._rx = LineBuffer()        # 板子 → 上位机

        # 板子**早就上电了**，复位释放时自发的那一行 `#RDY`（§5.2）已经在线路上等着 ——
        # 「先开串口、再复位板子」是最常见的次序，也是唯一会撞上它的次序。
        # 所以这里把它预先塞进收缓冲：上位机 `Host.handshake()` 读到的第一行就是它。
        # 陪练没有 `boot_lines`（比如测试里的替身）就跳过 —— 那种陪练就当它不发这一行。
        boot = getattr(board, "boot_lines", None)
        if boot is not None:
            for reply in boot():
                self._rx.feed(reply.encode("ascii") + LF)

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

    ⚠️ **它只被 `loop://` 跑过**（test_link.py 第 9 条）—— **电气层没验过**：
       波特率/真实时序、USB 丢字节、CH340 流控、真口号开不开得起来。
       别当它是「上板验过」的。见模块 docstring 末尾。
    """

    BULK_WRITE = True   # 见 Link.BULK_WRITE：真串口才吃「整段一次写」这条快路

    def __init__(self, port=None, baud=DEFAULT_BAUD):
        try:
            import serial
        except ImportError:
            raise SystemExit(_NO_PYSERIAL)

        # 不点名就**现找** —— 口号会变，写死一个数字迟早发到别的设备上。
        # （口号不是「配置」，是 Windows 每次插拔现分的，所以不存在一个正确的默认值。）
        if port is None:
            port = find_port()

        self.port = port
        self.baud = baud
        self._rx = LineBuffer()
        self._ser = None
        try:
            # 8N1：bytesize=8 / PARITY_NONE / STOPBITS_ONE（§4.1:145、§5.5:555）。
            # timeout 设成一小片，配合下面的截止时间做轮询。
            #
            # 用 serial_for_url 而不是 serial.Serial：前者是后者的**超集** ——
            # 给裸口号（"COM9"）时走同一条真串口路径；给 "loop://" 时开一个
            # **进程内的假串口**，于是 SerialLink 的真身（开关 / 收发 / 行缓冲接线）
            # 在**没有板子**的机器上也能被 test_link.py 跑到（见它第 9 条）。
            self._ser = serial.serial_for_url(port, baudrate=baud, bytesize=8,
                                              parity=serial.PARITY_NONE,
                                              stopbits=serial.STOPBITS_ONE,
                                              timeout=POLL_SLICE)
        # ValueError 必须一起接：serial_for_url 认不出 scheme（如 "foo://bar"）时
        # 抛的是 ValueError，**不是** SerialException —— 漏掉它就会冒裸 traceback，
        # 绕过下面这句人话。真口号打不开那条路仍旧走 SerialException。
        except (serial.SerialException, ValueError) as e:
            raise SystemExit(
                "!! 打不开串口 %s（%d-8N1）：%s\n"
                "   常见原因：板子没插 / 别的程序（串口助手）正占着它 / 这块口不是板子。\n"
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


def match_port(ports, name=CH340_NAME):
    """在一列 `(口号, 设备名)` 里按设备名找一个串口，返回它的口号。

    ⚠️ 这是**纯函数**：不 import pyserial、不碰硬件，喂一列名字进去就行。
       拆出来单放的理由是**手上没有板子**（pyserial 装没装也不一定）—— 找口这段逻辑
       要是跟开串口写在一起，就一行都验不了（见 test_link.py 第 8 条）。
       这也正是 host/README.md:21-23 说的「不要写死数字」的落点。

    ⚠️ 一条都不匹配、或者匹配到**不止一条**，都**响亮报错、不猜**：
       猜错口号就是把数据发到别人的设备上。大小写不敏感 —— Windows 报的
       设备名大小写不稳定，别让大小写决定找不找得到。
    """
    name_l = name.lower()
    hits = [(dev, desc) for dev, desc in ports
            if desc and name_l in desc.lower()]
    if not hits:
        raise SystemExit(
            "!! 没找到设备名里含 %r 的串口。\n"
            "   看一眼本机现在有哪些串口：python -m serial.tools.list_ports\n"
            "   （板子没插 / 驱动没装 / 设备名变了，都会落到这一条。）" % (name,))
    if len(hits) > 1:
        listing = "、".join("%s(%s)" % (d, s) for d, s in hits)
        raise SystemExit(
            "!! 设备名里含 %r 的串口有 %d 个：%s\n"
            "   不替你猜是哪一个 —— 用 --port 显式指定。" % (name, len(hits), listing))
    return hits[0][0]


def list_serial_ports():
    """列出本机所有串口，返回 `[(口号, 设备名), ...]`。（要 pyserial）

    pyserial 的细节只在本文件里出现 —— 上位机其余部分不认识它。
    """
    try:
        from serial.tools import list_ports
    except ImportError:
        raise SystemExit(_NO_PYSERIAL)
    return [(p.device, p.description or "") for p in list_ports.comports()]


def find_port(name=CH340_NAME):
    """按设备名找**当前**是哪个口号。找不到/多于一个的规矩见 match_port。（要 pyserial）"""
    return match_port(list_serial_ports(), name)


def open_link(kind="loopback", board=None, port=None, baud=DEFAULT_BAUD):
    """按名字开一个插座。**默认 loopback** —— 不点明就不碰硬件。

    kind="loopback" 时要一个陪练实例；不给就自己造一个（延迟 import，
    免得只在跑串口时也把陪练整包拉起来）。
    kind="serial" 时 port 不给就按设备名现找（见 find_port）。
    """
    if kind == "loopback":
        if board is None:
            import fake_board
            board = fake_board.FakeBoard()
        return LoopbackLink(board)
    if kind == "serial":
        return SerialLink(port=port, baud=baud)
    raise SystemExit("!! 不认识的插座类型：%r。只认 loopback / serial。（默认 loopback）" % (kind,))
