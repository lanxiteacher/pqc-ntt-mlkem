# synth_one.tcl —— 对一个折叠度配置跑 综合→优化→布局→布线，出资源与时序报告
#
# 用法（由 run_folding_sweep.sh 调用，一般不直接跑）:
#   vivado -mode batch -source synth_one.tcl \
#       -tclargs <标签> <顶层> <器件> <周期ns> <源码目录> <报告目录> [<蝶形数>] [<dcp输出路径>]
#
#   第 8 个参数可选：**给了才写 checkpoint**（GUI 里截关键路径图要用），见下文。
#
# 非工程模式（non-project）：不建 .xpr、不写 bitstream，只到 route 为止。
#   —— 本步的目的只是「量数字」，上板和引脚约束是后面 H6 另起的事。
#
# 综合选项一律用默认值，不加 -flatten_hierarchy / -retiming 之类的开关：
#   论文（research/papers/yaman.pdf）用的就是默认选项，
#   加了开关，跟论文的交叉核对就失去意义了。

set tag     [lindex $argv 0]
set top     [lindex $argv 1]
set part    [lindex $argv 2]
set period  [lindex $argv 3]
set srcdir  [lindex $argv 4]
set repdir  [lindex $argv 5]
# 第 7 个参数可省：蝶形数，用来给参数化版 `rtl/ntt_core/` 的顶层设 generic。
# 上游那三份独立目录没有参数，留空即可；省掉时 lindex 返回空串，走下面 else 分支。
#
# ⚠️ 这里只传**裸数字**（`4`），generic 的 `PE_NUMBER=` 部分在下面拼。
#    一开始直接把整串 `PE_NUMBER=4` 从命令行传进来，Vivado 的命令行解析把它
#    在 `=` 处切成了两个参数 —— Tcl 侧收到的是 "PE_NUMBER"，`4` 掉进了下一个 argv。
#    结果 `-generic PE_NUMBER` 让参数取到 0，报的是
#    「part-select [-1:0] does not match declaration」这种看着像 RTL 写错了的错。
set penum [lindex $argv 6]
# 第 8 个参数：布线后 checkpoint 的落点。空 = 不写（上游对照那几轮不需要）。
set dcpfile [lindex $argv 7]

puts "=== $tag | top=$top | part=$part | period=${period}ns PE_NUMBER=${penum} ==="

# 只读设计文件；testbench 排除（它们含 $readmemh / $display / #delay，不参与综合）
set srcs {}
foreach f [lsort [glob -nocomplain -directory $srcdir *.v]] {
    if {[string match "*_test_*" [file tail $f]]} { continue }
    lappend srcs $f
}
puts "  design files: [llength $srcs] (testbench excluded)"
if {[llength $srcs] == 0} { error "no .v found in $srcdir" }

read_verilog $srcs

# generic 只在参数化版传；上游三份目录的顶层没有参数，所以分支。
if {$penum ne ""} {
    synth_design -top $top -part $part -generic PE_NUMBER=$penum
} else {
    synth_design -top $top -part $part
}

# 唯一一条约束：时钟。clk 不分频直接进逻辑，所以这一条就够。
create_clock -period $period -name clk [get_ports clk]

opt_design

# place / route 分开 catch：pe16 有可能装不下 7020，
# 那种情况下我们仍然要拿到综合后的资源报告，不能整个脚本崩掉、什么都不留。
set impl_ok 1
if {[catch {place_design} err]} {
    puts "  !! place_design failed: $err"
    set impl_ok 0
}
if {$impl_ok && [catch {route_design} err]} {
    puts "  !! route_design failed: $err"
    set impl_ok 0
}

file mkdir $repdir
report_utilization -file "$repdir/${tag}_util.rpt"
report_timing_summary -max_paths 10 -file "$repdir/${tag}_timing.rpt"
if {!$impl_ok} {
    puts "  NOTE: place/route did not finish - timing report is a post-synthesis estimate"
}

# ---- 设计检查点（GUI 里看关键路径 Schematic 的配图要用）---------------------
# 与 synth_board.tcl 里同名的那一节同一个理由：非工程模式**什么都不留**，
# 不留 .dcp 就没法在 GUI 里打开设计、点开关键路径去截图
# （report/design/03_performance_and_resources.md §3.12 第 3 条的「核」那一组）。
#
# ⚠️ 可选：第 8 个参数为空就一个字都不写 —— 上游对照、只量数字的那几轮不需要。
# ⚠️ 与写报告同一条判断：只有 place/route 真走完才写。没布完的 checkpoint
#    打开后看不到实际走线，截出来的图跟报告里的数字对不上。
# ⚠️ 打开 .dcp 时 Vivado 要**从仓库外的目录**启动（病根是启动目录里的撇号，
#    见 run_folding_sweep.sh 文件头）；文件放在带撇号的路径下本身没问题。
if {$impl_ok && $dcpfile ne ""} {
    if {[catch {
        file mkdir [file dirname $dcpfile]
        write_checkpoint -force $dcpfile
    } err]} {
        puts "  !! write_checkpoint failed: $err"
    } else {
        puts "RESULT $tag DCP $dcpfile"
    }
}

# 一行摘要，方便 grep，免得为了一个数去整份读日志
# 注意：不要用 -setup/-hold，那是 report_timing 的选项，get_timing_paths 认不得
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
