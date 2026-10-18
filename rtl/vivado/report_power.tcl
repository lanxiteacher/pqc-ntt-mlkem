# ===========================================================================
# report_power.tcl —— 在**布线后的 checkpoint** 上跑 report_power，抽几行机读结果
#
#   vivado -mode batch -source report_power.tcl \
#       -tclargs <输入.dcp> <输出.power.rpt>
#
# 为什么要它（2026-10-18）
#   run_board_synth.sh 只在给了 DCP= 时才写 checkpoint（非工程模式默认什么都不留）。
#   功耗必须在**布线后**的库上估 —— 综合后的网表没有真实走线电容，report_power
#   会低估动态功耗。所以：先出 DCP，再在 DCP 上单独跑本脚本。
#
# ⚠️ 这是 **vectorless 估算**，不是实测：
#    · Vivado 2020.2 默认开关活动率（没有 SAIF/VCD）；
#    · 只算片内（PL），不含板级（CH340、LED、LDO 损耗）；
#    · 25 °C、典型工艺角。
#   报告里必须写「估算」，不能写成「实测功耗」。
# ===========================================================================

set dcp [lindex $argv 0]
set out [lindex $argv 1]
if {$dcp eq "" || $out eq ""} { error "用法: -tclargs <dcp> <out.rpt>" }
if {![file exists $dcp]} { error "找不到 checkpoint: $dcp" }

open_checkpoint $dcp

# 时钟周期来自 DCP 里的约束；report_power 自己会用它。
report_power -file $out

# ---- 从报告里抽机读行 ------------------------------------------------------
set fh [open $out r]
set txt [read $fh]
close $fh

proc grab {txt label} {
    foreach line [split $txt "\n"] {
        if {[string first $label $line] >= 0} {
            # 表格行形如 "| Total On-Chip Power (W)  | 0.106 |"
            set parts [split $line "|"]
            if {[llength $parts] >= 3} {
                return [string trim [lindex $parts 2]]
            }
        }
    }
    return ""
}

set total [grab $txt "Total On-Chip Power"]
set dyn   [grab $txt "Dynamic (W)"]
set stat  [grab $txt "Device Static (W)"]
set junc  [grab $txt "Junction Temperature"]

puts "RESULT power DCP $dcp"
puts "RESULT power TOTAL_W $total"
puts "RESULT power DYNAMIC_W $dyn"
puts "RESULT power STATIC_W $stat"
puts "RESULT power JUNCTION_C $junc"
puts "RESULT power DONE"
