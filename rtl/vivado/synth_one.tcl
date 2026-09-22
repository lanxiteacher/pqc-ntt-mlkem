# synth_one.tcl —— 对一个折叠度配置跑 综合→优化→布局→布线，出资源与时序报告
#
# 用法（由 run_folding_sweep.sh 调用，一般不直接跑）:
#   vivado -mode batch -source synth_one.tcl \
#       -tclargs <标签> <顶层> <器件> <周期ns> <源码目录> <报告目录>
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

puts "=== $tag | top=$top | part=$part | period=${period}ns ==="

# 只读设计文件；testbench 排除（它们含 $readmemh / $display / #delay，不参与综合）
set srcs {}
foreach f [lsort [glob -nocomplain -directory $srcdir *.v]] {
    if {[string match "*_test_*" [file tail $f]]} { continue }
    lappend srcs $f
}
puts "  design files: [llength $srcs] (testbench excluded)"
if {[llength $srcs] == 0} { error "no .v found in $srcdir" }

read_verilog $srcs

synth_design -top $top -part $part

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
