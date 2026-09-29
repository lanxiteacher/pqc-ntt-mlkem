"""ML-KEM NTT 串口协议 —— 公共库（暗号本）。

用途
    上位机（host）和「假串口 / 板子」两端**共用同一份**协议规则，
    保证两边算出的校验、拼出的命令逐字节一致。
依据
    host/proto.md   §5.4 校验

本文件目前只实现「校验」这一小块（4 个函数）。
数据行的编解码、命令字表、状态机等属于后续步骤，这里暂不涉及。

三条写死的约定（来自 proto.md §5.4 细则 1~3）
    1. 要校验的内容 = 该行 '*' 之前的**全部**字符，含开头的 '#' 和中间的空格。
    2. '*' 本身、行尾的 LF、被忽略的 CR，都不参与计算。
    3. 结果写成 2 位**小写**十六进制；'*' 前缀由调用方加。
"""


def xor_checksum(body):
    """把 body 逐字节异或，取低 8 位。

    body: 要校验的内容（'*' 之前的整行）。str 或 bytes 都可以。
    返回: 0 ~ 255 的整数。

    空载荷也照算 —— '#PING' 的结果是 0x33 而**不是** 0（proto.md 细则 4）。
    """
    total = 0
    for unit in body:
        # str 迭代出的是单字符，bytes 迭代出的是整数，统一成整数再异或
        total ^= unit if isinstance(unit, int) else ord(unit)
    return total & 0xFF


def checksum_hex(body):
    """同 xor_checksum，但返回 '33' 这样的 2 位小写十六进制字符串。"""
    return format(xor_checksum(body), '02x')


def append_checksum(body):
    """把校验贴到行尾：'#PING' -> '#PING*33'。

    只拼字符串，不附加换行 —— 用 LF 还是 CRLF 由发送方决定（proto.md §5.3.5）。
    """
    return body + '*' + checksum_hex(body)


def split_checksum(line):
    """把一整行拆成 (正文, 校验)：'#PING*33' -> ('#PING', '33')。

    line 末尾的 LF / CR 会先去掉。
    按**最后一个** '*' 切分，所以正文里万一含 '*' 也不会切错。

    格式不符就抛 ValueError：
      - 整行里没有 '*'
      - '*' 后面不是正好 2 位
      - 这 2 位里出现了 0-9 / a-f 以外的字符
        （**大写 A-F 也算不符** —— proto.md 细则 3 规定全协议只用小写）

    注意：本函数只负责「拆」，不负责「验」。校验对不对由调用方比对。
    """
    text = line.rstrip('\r\n')
    pos = text.rfind('*')
    if pos < 0:
        raise ValueError("这一行没有 '*'：%r" % (line,))
    body, tail = text[:pos], text[pos + 1:]
    if len(tail) != 2 or any(c not in '0123456789abcdef' for c in tail):
        raise ValueError("'*' 后面不是 2 位小写十六进制：%r" % (line,))
    return body, tail
