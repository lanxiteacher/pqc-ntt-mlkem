# ===========================================================================
# vivado_nonproject.tcl —— 非工程模式：综合 → 优化 → 布局 → 布线，出报告
#
# 这是「量数字」用的模板，不是「上板」用的。**不建 .xpr、不写 bitstream、
# 不加引脚约束** —— 那些是做完选型、定下配置之后另起的活。
#
# 用法：
#   vivado -mode batch -source vivado_nonproject.tcl \
#       -tclargs <标签> <顶层模块> <器件> <周期ns> <源码目录> <报告目录> [<generic值>]
#
#   例：
#   vivado -mode batch -source vivado_nonproject.tcl \
#       -tclargs pe4 KyberTop xc7z020clg400-2 5 src ../reports 4
#
# ⚠️ **一定要从源码目录之外启动**（见下面「两个环境雷区」）。
#
# 依赖：Vivado 2018.x 以上（`report_utilization` / `get_timing_paths` 都稳定）
# ===========================================================================

# ---- 参数 ----------------------------------------------------------------
set tag     [lindex $argv 0]      ;# 报告文件名前缀，例如 pe4
set top     [lindex $argv 1]      ;# 顶层模块名
set part    [lindex $argv 2]      ;# 器件，例如 xc7z020clg400-2
set period  [lindex $argv 3]      ;# 目标周期，ns
set srcdir  [lindex $argv 4]      ;# 源码目录（绝对路径）
set repdir  [lindex $argv 5]      ;# 报告输出目录
set gval    [lindex $argv 6]      ;# 可选：顶层 generic 的**裸数值**

# ⚠️ 只传裸数值（`4`），不要传整串 `PE_NUMBER=4`。
#    Vivado 命令行解析会把 `=` 当分隔符切开，Tcl 侧收到 "PE_NUMBER"，
#    `4` 掉进下一个 argv —— 于是 generic 取到 0，
#    报出来的错是「位选 [-1:0] 与声明不匹配」这种看着像 RTL 写错了的错。
#    这个坑排查起来很费时间，因为报错位置离真正的原因很远。

puts "=== $tag | top=$top | part=$part | period=${period}ns | generic=${gval} ==="

# ---- 收集源码 ------------------------------------------------------------
# 排除 testbench：它们含 $readmemh / $display / #delay，不参与综合
set srcs {}
foreach f [lsort [glob -nocomplain -directory $srcdir *.v]] {
    if {[string match "*_tb*" [file tail $f]]} { continue }
    if {[string match "*_test_*" [file tail $f]]} { continue }
    lappend srcs $f
}
puts "  设计文件 [llength $srcs] 个（testbench 已排除）"
if {[llength $srcs] == 0} { error "在 $srcdir 下没找到 .v" }
read_verilog $srcs

# ---- 综合 ----------------------------------------------------------------
# ⚠️ 综合选项**一律用默认值**。
#    一旦加了 -flatten_hierarchy / -retiming 之类的开关，
#    你跑出来的数字就**没法跟别人（论文、基线）对比**了 ——
#    除非对方也用了同一组开关，而且你能证明这一点。
#    做「优化前后对比」时，两边的开关必须一致。
if {$gval ne ""} {
    synth_design -top $top -part $part -generic PE_NUMBER=$gval
} else {
    synth_design -top $top -part $part
}

# ---- 约束 ----------------------------------------------------------------
# 只给时钟。如果要「反推最高频率」，就把周期给得比设计能达到的更紧 ——
# 这样一定不收敛、WNS 一定为负，用 T_min ≈ 周期 - WNS 反推 Fmax。
# ⚠️ 反过来：如果 WNS 是**正的**，说明周期太松、设计没被逼到底，
#    这时报出来的 Fmax 没有意义，要收紧周期重跑。
create_clock -period $period -name clk [get_ports clk]

opt_design

# ---- 布局 / 布线 ---------------------------------------------------------
# ⚠️ place / route **分开 catch**：器件可能装不下（引脚或资源不够），
#    那种情况下我们**仍然要拿到综合后的报告**，不能让整个脚本崩掉、什么都不留。
set impl_ok 1
if {[catch {place_design} err]} {
    puts "  !! place_design 失败：$err"
    set impl_ok 0
}
if {$impl_ok && [catch {route_design} err]} {
    puts "  !! route_design 失败：$err"
    set impl_ok 0
}

# ---- 报告 ----------------------------------------------------------------
file mkdir $repdir
report_utilization   -file "$repdir/${tag}_util.rpt"
report_timing_summary -max_paths 10 -file "$repdir/${tag}_timing.rpt"
if {!$impl_ok} {
    puts "  NOTE: place/route 没跑完 —— 时序报告只是**综合后估值**"
    puts "        （⚠️ 报告里那句 Design State 可能仍写着 Fully Placed，与实际不符；"
    puts "          判断实到哪一步要看这份日志，不要只看那句话）"
}

# ---- 机读摘要 ------------------------------------------------------------
# 打一行 SUMMARY 到 stdout，脚本外面用 grep 取数，不必为了一个数字整份读日志。
# ⚠️ 用 get_timing_paths，不要用 report_timing 的 -setup/-hold 选项（那边不认）。
if {[catch {
    set tp [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
    if {[llength $tp]} {
        puts "RESULT $tag WNS_NS [get_property SLACK $tp]"
    } else {
        puts "RESULT $tag WNS_NS NO_PATH"
    }
} err]} {
    puts "RESULT $tag WNS_NS QUERY_FAILED -- $err"
}
puts "RESULT $tag IMPL_OK $impl_ok"
puts "RESULT $tag DONE"

# ===========================================================================
# 两个环境雷区（本项目实测踩过，写在这里省得下次再踩）
#
# 1. **仓库/工程路径里的撇号会让综合引擎崩掉。**
#    本机路径是 `C:\Users\l'x\Desktop\...`，Vivado 内部拼 shell 命令行调用 ABC 时，
#    那个 `'` 提前闭合了引号 —— 症状是报看不懂的错，或者悄悄读到错的文件内容。
#    对策：**一律从仓库外的干净目录启动 Vivado**，源码用绝对路径传进去：
#        cd /c/fpga_work && vivado -mode batch -source /path/to/this.tcl ...
#    ⚠️ 在仓库目录里**用 GUI 建工程同样会中招**。
#
# 2. **综合 helper 子进程会间歇性报「某个文件读不到」**，而那个文件确实存在。
#    对策：外层脚本带重试（3 次足够）。
#    ⚠️ **重试前必须先删掉本轮要重写的报告** —— 否则上一轮的旧报告还在，
#       会把「失败」误判成「成功」（脚本以为跑完了，其实跑的是上次的产物）。
# ===========================================================================
