# -*- coding: utf-8 -*-
"""生成 cmd_parse_tb.v —— 测试向量**机器生成**，不手写。

为什么要有这个生成器：
    cmd_parse.v 里那 20 多个十六进制常量（48'h23_4E54_5420 之类）是手写的。
    如果测试台里的向量也手写，一旦我数错一位，两边就会**一致地错** ——
    测试照样全绿，却什么也没验证到。
    所以向量由本脚本的**独立**异或实现算出。这份实现已与 host/proto.md §5.4
    那张表逐条核对过（#PING*33 / #NTT 1*7c / #INTT 1*35 / #PMUL TIME 1*03 /
    #PMUL NTT 1*58 / #ABORT*69 全中），协议表里没有的（#PMUL FULL 1）也由它补出。

用法：  python gen_cmd_parse_tb.py
产物：  cmd_parse_tb.v （与本脚本同目录）
"""

import os

# --------------------------------------------------------------------------
# 独立实现的异或校验（与 RTL 无关，逐字节 XOR）
# --------------------------------------------------------------------------
def xor_ck(payload: bytes) -> int:
    a = 0
    for c in payload:
        a ^= c
    return a

def with_ck(payload: bytes) -> bytes:
    """命令本体 → 完整命令行（追加 `*` + 2 位小写十六进制）"""
    return payload + b'*' + ('%02x' % xor_ck(payload)).encode('ascii')

def vlit(b: bytes) -> str:
    """字节串 → 512 位 Verilog 字面量，**右对齐**（末字符落在 [7:0]）。

    b.hex() 按字节顺序输出十六进制，正好符合仓库的「字符串左对齐 = 位串右对齐」
    约定：先到的字节在高位。例 b'#NTT 1' → "234e54542031"。

    ⚠️ 空字节串要特判：`512'h` 后面什么都不跟是**非法**字面量（iverilog 直接报
    syntax error）。空行用例走这里。
    """
    return "512'h" + (b.hex() if b else '0')


def note_to_ascii(s: str) -> str:
    """用例说明 → 只含 ASCII 的字符串（给 Verilog 的 $display 用）。

    中文注释留在 `//` 注释行里（那没问题），但**字符串字面量**里不放非 ASCII：
    本机控制台是 GBK，显示出来是乱码，反而看不清哪条 FAIL 了。
    """
    out = []
    for ch in s:
        if ord(ch) < 128:
            out.append(ch)
        elif ch in '→':
            out.append('->')
        elif ch in '（）':
            out.append('(' if ch == '（' else ')')
    return ''.join(out)

# --------------------------------------------------------------------------
# 与 RTL 里 localparam 同名的文本（生成时只写名字，不写数值）
# --------------------------------------------------------------------------
CMD = {'NONE': 0, 'PING': 1, 'NTT': 2, 'INTT': 3, 'PMUL': 4, 'ABORT': 5}
DOM = {'NONE': 0, 'NTT': 1, 'TIME': 2, 'FULL': 3}

CASES = []          # (line, cmd, dom, exp_lines, cksum_ok, n_ok, ck_got, ck_exp, note)

def hexval(c: int) -> int:
    """一个字符的数值（大小写都认，非 hex 字符给 0）——对应 RTL 里的 hexval()"""
    if 0x30 <= c <= 0x39: return c - 0x30
    if 0x61 <= c <= 0x66: return c - 0x61 + 10
    if 0x41 <= c <= 0x46: return c - 0x41 + 10
    return 0

def add(payload, cmd, dom, exp, cs, nok, note, raw=None):
    line = raw if raw is not None else with_ck(payload)
    # RTL 里 payload_len = max(0, line_len-3)，xacc = 前 payload_len 字节的异或
    plen = max(0, len(line) - 3)
    ck_exp = xor_ck(line[:plen])
    # RTL 读的是 line[15:8] / line[7:0]，即**右对齐后的最后两个字节**
    ck_got = ((hexval(line[-2]) << 4) | hexval(line[-1])) if len(line) >= 2 else 0
    CASES.append((line, cmd, dom, exp, cs, nok, ck_got, ck_exp, note))

# --------------------------------------------------------------------------
# 一、正常命令（校验正确、参数合法）—— 七条，正好是协议 §5.2 命令表的全集
# --------------------------------------------------------------------------
add(b'#PING',        'PING',  'NONE', 0,   1, 1, 'PING  无数据行')
add(b'#NTT 1',       'NTT',   'NONE', 256, 1, 1, 'FNTT  256 行')
add(b'#INTT 1',      'INTT',  'NONE', 256, 1, 1, 'INTT  256 行')
add(b'#PMUL NTT 1',  'PMUL',  'NTT',  512, 1, 1, '点乘 NTT  域 512 行')
add(b'#PMUL TIME 1', 'PMUL',  'TIME', 512, 1, 1, '点乘 TIME 域 512 行')
add(b'#PMUL FULL 1', 'PMUL',  'FULL', 512, 1, 1, '点乘 FULL 域（协议表缺这条，本脚本算出）')
add(b'#ABORT',       'ABORT', 'NONE', 0,   1, 1, 'ABORT 无数据行')

# --------------------------------------------------------------------------
# 二、校验值不对 → cksum_ok = 0（RTL 必须**完全不认**这行，cmd 保持 NONE）
#     对应协议：`#ERR 03`
# --------------------------------------------------------------------------
good = with_ck(b'#NTT 1')                          # "#NTT 1*7c"
bad_ck = good[:-2] + b'7d'                         # 末位 c→d
add(b'#NTT 1', 'NONE', 'NONE', 0, 0, 0, '校验值错一位(*7c→*7d)', raw=bad_ck)

add(b'#NTT 1', 'NONE', 'NONE', 0, 0, 0, '校验值大写(*7C)——协议只认小写', raw=good[:-2] + b'7C')

add(b'#NTT 1', 'NONE', 'NONE', 0, 0, 0, '分隔符不是 *（写成 @）', raw=good[:-3] + b'@' + good[-2:])

add(b'#NTT 1', 'NONE', 'NONE', 0, 0, 0, '校验只有一位(*7)——长度对不上', raw=good[:-1])

# --------------------------------------------------------------------------
# 三、命令字不认识 → cmd = NONE 但 cksum_ok = 1
#     对应协议：`#ERR 01`。这一格专门用来验证「校验和命令识别是两件事」
# --------------------------------------------------------------------------
add(b'#FOO 1', 'NONE', 'NONE', 0, 1, 0, '未知命令，但校验是对的 → #ERR 01')

# --------------------------------------------------------------------------
# 四、命令认出来了、参数不合法 → n_ok = 0
#     对应协议：`#ERR 02`。这一格是这次返工的直接原因 ——
#     第一版会把这四条全报成 #ERR 01（未知命令），协议要求 02（参数非法）
# --------------------------------------------------------------------------
add(b'#NTT 2',       'NTT',  'NONE', 256, 1, 0, 'n=2   → 命令认得，参数非法')
add(b'#NTT 0',       'NTT',  'NONE', 256, 1, 0, 'n=0   → 同上')
add(b'#INTT 2',      'INTT', 'NONE', 256, 1, 0, 'INTT n=2')
add(b'#PMUL NTT 2',  'PMUL', 'NTT',  512, 1, 0, '点乘 NTT 域 n=2')
add(b'#PMUL TIME 2', 'PMUL', 'TIME', 512, 1, 0, '点乘 TIME 域 n=2')
add(b'#PMUL XXX 1',  'PMUL', 'NONE', 512, 1, 0, '域词 XXX 不认识 → #ERR 02（不是 01）')

# --------------------------------------------------------------------------
# 五、退化边界
# --------------------------------------------------------------------------
add(b'#', 'NONE', 'NONE', 0, 0, 0, '只有一个 #', raw=b'#')
add(b'',  'NONE', 'NONE', 0, 0, 0, '空行',      raw=b'')

# --------------------------------------------------------------------------
# 生成
# --------------------------------------------------------------------------
HEAD = '''// ===========================================================================
// cmd_parse_tb.v —— cmd_parse 的**自检**测试台
//
// ⚠️ 本文件由 gen_cmd_parse_tb.py **机器生成**，不要手改 ——
//    改了下次重跑生成器就没了。要加用例请改生成器。
//
// 为什么非要这个测试台：
//    cmd_parse.v 里 20 多个十六进制常量全是手写的，一个 nibble 写错不会有任何
//    编译错误，只会在上板后表现成「某条命令莫名其妙不响应」。而这类错误用
//    仿真跑到完整协议 FSM 里再查，代价极高。
//    这里把常量单独拉出来验一遍：七条正常命令 + 十二种异常。
//
// 怎么跑：
//    export PATH="/c/iverilog/bin:$PATH"
//    cd rtl/board/tb
//    iverilog -g2005 -o chk.vvp ../cmd_parse.v cmd_parse_tb.v && vvp chk.vvp
//    末行出现 ALL PASS 即通过；有任何 FAIL 会逐条打印期望值与实际值。
//
// 覆盖了什么 / 没覆盖什么：
//    覆盖 —— 七条命令的识别、四种校验失败、未知命令、参数非法、
//            以及「校验和命令识别是两件独立的事」这一格。
//    没覆盖 —— 多位数的 n（见 cmd_parse.v 头部「已知简化」；§六第 2 条已把
//            n 冻结为 1，这条分支实际不可达）。真长度超过 64 字节的行也不归这里，
//            那是 uart_line_rx 的事。
// ===========================================================================

`timescale 1ns/1ps

module cmd_parse_tb;

    reg  [511:0] line;
    reg  [6:0]   line_len;

    wire [2:0]   cmd;
    wire [1:0]   dom;
    wire [9:0]   exp_lines;
    wire         cksum_ok;
    wire         n_ok;
    wire [6:0]   payload_len;
    wire [7:0]   ck_got;
    wire [7:0]   ck_exp;

    cmd_parse #(.MAXLEN(64)) dut (
        .line        (line),
        .line_len    (line_len),
        .cmd         (cmd),
        .dom         (dom),
        .exp_lines   (exp_lines),
        .cksum_ok    (cksum_ok),
        .n_ok        (n_ok),
        .payload_len (payload_len),
        .ck_got      (ck_got),
        .ck_exp      (ck_exp)
    );

    localparam CMD_NONE  = 3'd0, CMD_PING = 3'd1, CMD_NTT = 3'd2,
               CMD_INTT  = 3'd3, CMD_PMUL = 3'd4, CMD_ABORT = 3'd5;
    localparam DOM_NONE  = 2'd0, DOM_NTT = 2'd1, DOM_TIME = 2'd2, DOM_FULL = 2'd3;

    integer fails = 0;
    integer cases = 0;

    // 一个用例：灌一行，比对六个输出
    task chk;
        input [511:0] l;
        input [6:0]   len;
        input [2:0]   ecmd;
        input [1:0]   edom;
        input [9:0]   eln;          // 期望的 exp_lines（输入数据行数）
        input         ecs;
        input         enok;
        input [7:0]   egot;         // 期望的 ck_got
        input [7:0]   eck;          // 期望的 ck_exp
        input [255:0] nm;
        begin
            line = l;
            line_len = len;
            #1;
            cases = cases + 1;
            if (cmd !== ecmd || dom !== edom || exp_lines !== eln ||
                cksum_ok !== ecs || n_ok !== enok ||
                ck_got !== egot || ck_exp !== eck ||
                payload_len !== (len >= 7'd3 ? len - 7'd3 : 7'd0)) begin
                fails = fails + 1;
                $display("FAIL  %0s", nm);
                $display("      cmd=%0d(exp %0d)  dom=%0d(exp %0d)  exp_lines=%0d(exp %0d)",
                         cmd, ecmd, dom, edom, exp_lines, eln);
                $display("      cksum_ok=%0d(exp %0d)  n_ok=%0d(exp %0d)  payload_len=%0d(exp %0d)",
                         cksum_ok, ecs, n_ok, enok, payload_len,
                         (len >= 7'd3 ? len - 7'd3 : 7'd0));
                $display("      ck_got=%02h(exp %02h)  ck_exp=%02h(exp %02h)",
                         ck_got, egot, ck_exp, eck);
            end
            else begin
                $display("ok    %0s", nm);
            end
        end
    endtask

    initial begin
        $display("=== cmd_parse 自检：%0d 个用例 ===", total_cases);
'''

TAIL = '''
        $display("--------------------------------------------");
        if (fails == 0) $display("ALL PASS  (%0d/%0d)", cases, cases);
        else            $display("*** FAIL ***  %0d / %0d", fails, cases);
        $finish;
    end

endmodule
'''

body = []
for (raw, cmd, dom, exp, cs, nok, got, eck, note) in CASES:
    body.append('        // %s\n' % note)
    body.append('        chk(%s, 7\'d%0d, CMD_%s, DOM_%s, 10\'d%0d, 1\'b%0d, 1\'b%0d, 8\'h%02x, 8\'h%02x, "%s");\n'
                % (vlit(raw), len(raw), cmd, dom, exp, cs, nok, got, eck,
                   note_to_ascii(note)))
    body.append('\n')

out = HEAD.replace('total_cases', str(len(CASES))) + ''.join(body) + TAIL

here = os.path.dirname(os.path.abspath(__file__))
dst = os.path.join(here, 'cmd_parse_tb.v')
# 二进制写 + LF：仓库统一行尾，别让 Windows 翻成 CRLF
with open(dst, 'wb') as f:
    f.write(out.encode('utf-8'))

print('wrote %s  (%d cases)' % (dst, len(CASES)))
print()
print('--- 顺带把每条命令行打出来，方便人眼核对 ---')
for (raw, cmd, dom, exp, cs, nok, got, eck, note) in CASES:
    try:
        s = raw.decode('ascii')
    except UnicodeDecodeError:
        s = repr(raw)
    print('  %-22s len=%-3d cmd=%-5s dom=%-4s exp=%-4d cs=%d n_ok=%d got=%02x exp=%02x   %s'
          % (s if s else '(空)', len(raw), cmd, dom, exp, cs, nok, got, eck, note))
