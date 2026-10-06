# ===========================================================================
# vvp_verdict.sh —— 「仿真跑完了」和「仿真通过了」是两件事
#
# 被谁用：run_fntt_check.sh / run_intt_pwm2_check.sh / run_polmul_check.sh /
#         run_uart_check.sh —— 都是 `. "$HERE/vvp_verdict.sh"` 取函数，不执行别的。
#
# ── 为什么要有这个文件（2026-10-06 查出来的**假绿**）──────────────────────
# 本仓库所有 testbench 结尾都是 `$finish`。**`$finish` 不改变退出码** ——
# 哪怕 tb 整整打了一屏「✗ 共 256 个系数不符」，vvp 的退出码仍然是 **0**。
# （`$fatal` 才是 1。用一个最小实验证实过，不是推测。）
# 于是脚本里那句 `vvp xxx.vvp | sed 's/^/  /'` **永远不会失败**：
#   ① `set -e` 帮不上忙 —— 管道的退出码取**最后一个命令**（sed）的，sed 总是 0；
#   ② 就算去掉 sed，vvp 自己也返回 0。
# 净效果：RTL 改坏了、量化误差进来了、比对一条没跑，脚本照样打「═══ 完成 ═══」，
# 绿油油一片。这正是本项目最怕的那类错误 —— **假绿**。
# （「检查条数变少也是假绿」这条告警，是 `run_uart_check.sh` 文件头 17–20 行
#   自己写的 —— **不是** host/KNOWN_ISSUES.md 的 C3；C3 的结论恰好相反，
#   它记的是「原警示被证伪 · 已办」。别再往那儿引。）
#
# ── 为什么改 shell 侧，而不去改 tb 把 `$finish` 换成 `$fatal` ──────────────
# ① tb 是 A 的资产，动它要打招呼；shell 侧是 B 的，改了自己说了算。
# ② 更重要的：`$fatal` 只能抓「不匹配」一种假绿。**向量文件读不到**
#    （iverilog 打一行 `ERROR: $readmemh: Unable to open…` 或
#      `WARNING: … Not enough words in the file …`，然后**接着跑**，退出码照旧 0）
#    和 **「检查条数变少」**（真跑的组数从 16 掉到 3 也照样说「全部通过」）
#    都抓不到。shell 侧能一次把这三样全盖上。
#
# ── 判据（四条，全部要过）─────────────────────────────────────────────
#   ① 没有 `$readmemh` 的两类失败话术（`Unable to open` / `Not enough words`）
#      —— 有则检查是无意义的（在残缺或空输入上比）
#   ② 没出现失败锚点（批量 tb 的「✗ 共」/ uart tb 的「结论：**有失败**」）
#   ③ 出现了通过锚点 —— 没有 = 仿真没跑到结尾（中途 $stop / 卡死 / 编译过了没跑）
#   ④ **真跑了几组 / 真比了几个点 == 调用方给的基线** —— 防「检查悄悄变少」
#      ⚠️ 批量 tb 数的是**行首无空格的 `向量 NN: …` 行**（每组一行、运行时真打），
#         **不是**「★ 全部 N 组」里那个 N —— 那是 tb 的编译期常量 `parameter NV`，
#         循环少跑一半它照样印 16，拿它当判据等于没判（2026-10-06 实测：
#         把 fntt_batch_tb.v 的循环改成只跑 1 组，它仍打印「★ 全部 16 组向量通过」）。
#
# ── 三条写 shell 判定时的坑（都踩过）──────────────────────────────────
#   ① **每条 grep 都得 `|| true`**（这里统一用 `grep -q` 配 if，天然安全；
#      但换成 `x=$(... | grep -c ...)` 就必踩）：set -e 下 grep 找不到匹配返回 1，
#      会把整个脚本打断 —— 而那恰好是「不通过」的正常情况。
#   ② 判定函数**只 `return 1`，不自己 `exit`** —— 收场方式留给调用方
#      （调用方统一写 `|| exit 1`）。
#   ③ **凡是用到中文的 grep/sed，前面都挂 `LC_ALL=C`**：本脚本和日志都是 UTF-8
#      字节，`C` 按字节比反而对得准。不挂的话，在 `zh_CN`（GB2312）/ `zh_TW`
#      （BIG5）这类旧中文 locale 下，sed 会把捕获组切歪 —— **RTL 明明全过，
#      脚本却退出 1**（假红）。方向是安全侧（不放过真失败），但一样要修。
#      显式挂在**每条命令前**，**不要 `export LC_ALL=C`** —— 那会改掉调用方的
#      locale。2026-10-06 实测：`C` / `POSIX` / 各 UTF-8 变体全正常，
#      只有 GB2312 / BIG5 中招。
#
# 基线从哪来：**当前实测值**，不是猜的。改了 tb 或加了用例就必须同步改基线，
# 否则会响亮的误报 —— 这是故意的，误报比假绿好。
# ===========================================================================


# ── 跑一条 vvp 命令并接住它的全部输出 ────────────────────────────────────
# 用法：  _vvp_capture vvp batch_fntt.vvp || exit 1
#         _VVP_LOG     ← 输出（stdout + stderr 合并，含 vvp 和 iverilog 的警告）
#
# ⚠️ 这就是那个「不能写成管道」的地方：`vvp ... | sed ...` 的退出码是 sed 的。
_vvp_capture() {
    _VVP_LOG="$("$@" 2>&1)" || {
        printf '%s\n' "$_VVP_LOG" | sed 's/^/  /'
        echo "  ❌ vvp 本身就跑不起来（退出码非 0，见上）"
        return 1
    }
    return 0
}

# 把接住的输出缩进打印出来（不加滤镜，就是给人看的）。
_vvp_show() {
    printf '%s\n' "$_VVP_LOG" | sed 's/^/  /'
}

# ── 判据 A：批量向量 tb（fntt / intt / pwm2 / fullmul / halfmul）──────────
# 锚点（五个 tb 的结尾一模一样）：
#   通过  ★ 全部 %0d 组….通过
#   失败  ✗ 共 %0d 个系数不符
# 用法：  vvp_verdict_batch "FNTT" 16 "$_VVP_LOG" || exit 1
vvp_verdict_batch() {
    _name="$1"; _want="$2"; _log="$3"; _rc=0

    # ① 向量文件必须**真读到**。$readmemh 有两种失败话术，两种都得算：
    #    a) 文件不在：          `$readmemh: Unable to open … for reading.`
    #    b) 文件在但行数不够/空：`$readmemh(…): Not enough words in the file …`
    #    两种 iverilog 都会**接着跑到 $finish**、退出码仍是 0 —— 不抓就是假绿。
    if printf '%s\n' "$_log" \
       | grep -qE 'readmemh: Unable to open|Not enough words in the file'; then
        echo "  ❌ $_name：向量文件没读到（上面有 \$readmemh 打不开 / 行数不够的警告）"
        echo "     这时 tb 是在**残缺或空输入**上比对的，通过与否都不算数。"
        _rc=1
    fi

    # ② 失败锚点（中文 → LC_ALL=C，见文件头坑③）。
    if printf '%s\n' "$_log" | LC_ALL=C grep -q '✗ 共 '; then
        _bad=$(printf '%s\n' "$_log" \
               | LC_ALL=C sed -n 's/.*✗ 共 \([0-9][0-9]*\) 个系数不符.*/\1/p' | head -1)
        echo "  ❌ $_name：RTL 与参考实现不符 —— ${_bad:-若干} 个系数（上面标 ✗ 的行）"
        _rc=1
    fi

    # ③ 通过锚点必须存在 —— 没有 = 没跑到结尾。
    if ! printf '%s\n' "$_log" | LC_ALL=C grep -q '★ 全部 '; then
        echo "  ❌ $_name：没找到通过行「★ 全部 N 组…通过」—— 仿真大概没跑到结尾"
        _rc=1
    fi

    # ④ 到底**真跑了几组**。数行首无空格的 `向量 NN: …` —— 每个批量 tb 每组
    #    必打且只打一行。（失败明细行是 `  向量 NN [MM]: …`，行首两个空格，
    #    被行首锚定挡在外面。）这一条才是真的「条数」；「★ 全部 N 组」里那个 N
    #    是编译期常量 `parameter NV`，数它没用。
    #    `|| true`：grep -c 一条没匹配到会返回 1，set -e 下会把脚本打断
    #    （文件头坑①）—— 而那恰好是「不正常」时该走到的地方。
    _groups=$(printf '%s\n' "$_log" | LC_ALL=C grep -c '^向量 ' || true)
    if [ "$_groups" != "$_want" ]; then
        echo "  ❌ $_name：tb 实际只跑了 $_groups 组，基线是 $_want 组 —— 有检查没跑（假绿）"
        _rc=1
    fi

    if [ "$_rc" -eq 0 ]; then
        echo "  ✅ $_name：$_want 组向量全部通过（真跑组数 $_groups 对得上基线 $_want）"
    fi
    return "$_rc"
}

# ── 判据 B：串口协议 tb（pe1/uart_proto_tb.v）────────────────────────────
# 它不用 ★/✗ 那套，结尾两行是：
#     比对点 %0d 个，失败 %0d 个
#     结论：全部通过。   /   结论：**有失败**（上面标 [FAIL] 的行）。
# ⚠️ 基线：全套 **273**，带 +fast **14**（2026-10-06 实测，写在 run_uart_check.sh
#    的文件头）。**N 变小 = 有检查没跑**，所以这里必须逐值对。
# 用法：  vvp_verdict_uart "UART" 273 "$_VVP_LOG" || exit 1
vvp_verdict_uart() {
    _name="$1"; _want="$2"; _log="$3"; _rc=0

    # ① 向量文件必须真读到 —— 两种失败话术都算（同批量 tb，见 vvp_verdict_batch）。
    if printf '%s\n' "$_log" \
       | grep -qE 'readmemh: Unable to open|Not enough words in the file'; then
        echo "  ❌ $_name：向量文件没读到（上面有 \$readmemh 打不开 / 行数不够的警告）—— 结论不算数"
        _rc=1
    fi

    if printf '%s\n' "$_log" | LC_ALL=C grep -q '结论：\*\*有失败\*\*'; then
        echo "  ❌ $_name：有比对点不符（上面标 [FAIL] 的行）"
        _rc=1
    fi

    _pair=$(printf '%s\n' "$_log" \
            | LC_ALL=C sed -n 's/.*比对点 \([0-9][0-9]*\) 个，失败 \([0-9][0-9]*\) 个.*/\1 \2/p' \
            | tail -1)
    if [ -z "$_pair" ]; then
        echo "  ❌ $_name：没找到汇总行「比对点 N 个，失败 M 个」—— 仿真没跑到结尾"
        _rc=1
    else
        _n=${_pair% *}; _bad=${_pair#* }
        if [ "$_bad" != "0" ]; then
            echo "  ❌ $_name：$_bad 个比对点不符（共 $_n 个）"
            _rc=1
        fi
        if [ "$_n" != "$_want" ]; then
            echo "  ❌ $_name：只比了 $_n 个点，基线是 $_want 个 —— 有检查没跑（假绿）"
            _rc=1
        fi
    fi

    # 通过行必须**明写**，不能只靠「没有失败行」推断 —— 少打一行也是假绿。
    if ! printf '%s\n' "$_log" | LC_ALL=C grep -q '结论：全部通过。'; then
        echo "  ❌ $_name：没找到「结论：全部通过。」这一行 —— 不许由「没报错」推断通过"
        _rc=1
    fi

    if [ "$_rc" -eq 0 ]; then
        echo "  ✅ $_name：$_want 个比对点全部通过（点数对得上基线 $_want）"
    fi
    return "$_rc"
}
