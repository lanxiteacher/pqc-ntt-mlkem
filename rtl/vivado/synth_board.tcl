# ===========================================================================
# synth_board.tcl —— 完整板级流程：综合 → 实现 → 出 bitstream
#
#   用法（由 run_board_synth.sh 调用，一般不直接跑）:
#     vivado -mode batch -source synth_board.tcl \
#         -tclargs <器件> <源码目录> <板级目录> <报告目录> <输出目录> \
#                  [<周期ns>] [<折叠度>] [<dcp输出路径>]
#
#   第 8 个参数（dcp 输出路径）可选：**给了才写 checkpoint**。见下面「设计检查点」一节。
#
#   与同目录 `synth_one.tcl` 的区别 —— 两者**目的不同，不要混用**：
#     synth_one.tcl    非工程模式，跑到 route 为止，只为了「量数字」（资源/频率）
#     synth_board.tcl  要多做两件上板必须的事：
#                       ① 读引脚约束 .xdc（synth_one 不读约束，只给一条时钟）
#                       ② write_bitstream（synth_one 刻意不写，见其文件头）
#
#   ⚠️ 文件清单里**绝不能**出现 `rtl/pe1/`、`rtl/pe4/`、`rtl/pe16/` ——
#      那里有与 `rtl/ntt_core/` 同名同类的一整套（上游原件），一起加会撞模块名，
#      Vivado 报的是「模块重复定义」，看着像 RTL 写错了。理由也写在
#      `rtl/board/ntt_board_top.v` 的文件头。
#
#   ⚠️ 时钟约束在 `rtl/board/ntt_board.xdc` 里（create_clock -period 20 于 sys_clk），
#      **本脚本不再 create_clock** —— 加第二遍会出现重复时钟定义。
# ===========================================================================

set part    [lindex $argv 0]
set srcdir  [lindex $argv 1]   ;# rtl/ntt_core     —— 核，整目录
set brddir  [lindex $argv 2]   ;# rtl/board        —— 板级 wrapper（含 .xdc）
set repdir  [lindex $argv 3]   ;# 报告输出目录
set outdir  [lindex $argv 4]   ;# bitstream 输出目录
set period  [lindex $argv 5]   ;# 可选：覆盖 XDC 里的周期，默认不覆盖
set pe      [lindex $argv 6]   ;# 可选：折叠度 1/4/16，默认 1
set dcpfile [lindex $argv 7]   ;# 可选：布线后 checkpoint 的输出路径（空 = 不写）

set TOP ntt_board_top

# 折叠度守卫：只认 1 / 4 / 16。给错值必须**在这里**拦住 ——
#   核自己的 `initial` 守卫（KyberHPMNTT_top.v:103）是仿真用的，综合不看；
#   而非法值在 generate 那层只是刷一堆越界警告，照样能出 bitstream。
if {$pe eq ""} { set pe 1 }
if {![string is integer -strict $pe] || ($pe != 1 && $pe != 4 && $pe != 16)} {
    error "折叠度非法：'$pe' —— 只支持 1 / 4 / 16"
}

puts "=== board | top=$TOP | part=$part | PE_NUMBER=$pe ==="
puts "    srcdir=$srcdir"
puts "    brddir=$brddir"

# ---- 设计文件 --------------------------------------------------------------
# 核：rtl/ntt_core/ 下所有 .v
set srcs {}
foreach f [lsort [glob -nocomplain -directory $srcdir *.v]] { lappend srcs $f }
if {[llength $srcs] == 0} { error "no .v found in $srcdir" }

# 板级 wrapper：rtl/board/ 下所有 .v（**不含子目录**，tb/ 就是靠这一点排除的）
foreach f [lsort [glob -nocomplain -directory $brddir *.v]] { lappend srcs $f }

# 两个 UART 模块在 rtl/ 根下，不在上面两个目录里
set rtldir [file dirname $brddir]
foreach u {uart_rx.v uart_tx.v} {
    set p [file join $rtldir $u]
    if {![file exists $p]} { error "missing $p" }
    lappend srcs $p
}

puts "    design files: [llength $srcs]"
foreach f $srcs { puts "      [file tail $f]" }

read_verilog $srcs

# ---- 综合 ------------------------------------------------------------------
# PE_NUMBER 由命令行第 7 个参数给（run_board_synth.sh 的 PE=<n>），默认 1。
# 显式写出来是为了让**日志里**能一眼看到这版 bitstream 是哪一档 ——
# 拿错 bitstream 上板的症状是「数值全错」，很像 RTL 挂了，其实是档位不对。
# ⚠️ 板级 wrapper 的 READ_LAT 是 `2*PE_NUMBER+3`（ntt_board_top.v），
#    跟着这里一起变，不用另外传。
synth_design -top $TOP -part $part -generic PE_NUMBER=$pe

# ---- 约束 ------------------------------------------------------------------
set xdc [file join $brddir ntt_board.xdc]
if {![file exists $xdc]} { error "missing $xdc" }
read_xdc $xdc
puts "    xdc: $xdc"

# 可选：临时收紧/放松时钟周期（调试时序用，不改 XDC 文件）
if {$period ne ""} {
    puts "    NOTE: 覆盖时钟周期为 ${period}ns（只影响本次运行）"
    create_clock -period $period -name sys_clk [get_ports sys_clk]
}

# ---- 实现 ------------------------------------------------------------------
# 每步单独 catch：某一步失败时，前面已经拿到的报告仍然要留下 ——
# 整个脚本崩掉等于什么都没量到（synth_one.tcl 里同样的理由）。
set impl_ok 1
foreach step {opt_design place_design route_design} {
    if {[catch {$step} err]} {
        puts "  !! $step failed: $err"
        set impl_ok 0
        break
    }
}

file mkdir $repdir
# 报告名一律带折叠度前缀 —— 三档的数字本来就不同（pe1 LUT 5074 / pe4 6529），
# 同名会把已提交的上一次结果覆盖掉。2026-10-04 实际发生过一次：
# pe4 那轮一启动就 rm 掉了仓库里已提交的 pe1 三份报告。
set reppfx "board_pe$pe"
set rep_ok 1
if {[catch {report_utilization -file "$repdir/${reppfx}_util.rpt"} err]} {
    puts "  !! report_utilization failed: $err"
    set rep_ok 0
}
if {[catch {report_timing_summary -max_paths 10 -file "$repdir/${reppfx}_timing.rpt"} err]} {
    puts "  !! report_timing_summary failed: $err"
    set rep_ok 0
}
# ⚠️ report_io 需要设计里已经有**已布局的 IO**。opt/place 失败时它会报错；
#    但这时恰恰是「上板前要核对引脚落位」最有价值的时候，所以**不要**让它
#    拖垮整条流程 —— 用 catch 兜住，只记下来。
#    ⚠️ 这里**绝不能**写 `2>/dev/null` —— 那是 shell 的重定向语法，Tcl 不认，
#       会被当成 report_io 的**位置参数**，报错是
#       「Too many positional options when parsing '2>/dev/null'」。
#       （2026-10-04 第一版就是这么写的，把一次已经综合成功的运行毁在最后一步。）
if {[catch {report_io -file "$repdir/${reppfx}_io.rpt"} err]} {
    puts "  !! report_io failed: $err"
    set rep_ok 0
}
puts "RESULT board REPORTS $rep_ok"

# 两行摘要，方便 grep。
#   ⚠️ 2026-10-07 改：原来只有一行 `WNS_NS`，取的是**全设计最坏**那条路径。
#      板级三档时序全 MET 时，最坏的那条其实落在 `**async_default**` 组
#      （复位同步器 → 异步控制端的 recovery），**它不是时钟级 WNS**
#      —— `critical_paths.md` §一 专门警告过这个混淆，但这条机器可读的
#      `WNS_NS` 行恰恰就是那个容易抄错的数（10-07 两档实测：真 WNS 7.339 / 6.547，
#      而 `WNS_NS` 给的是 2.490 / 1.879）。所以现在拆成两行、名字各自写明口径，
#      不再留一个叫「WNS」却装着另一个组的数。
if {[catch {
    set tp [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
    if {[llength $tp]} {
        puts "RESULT board WNS_WORST_ANY_NS [get_property SLACK $tp]"
    } else {
        puts "RESULT board WNS_WORST_ANY_NS NO_PATH"
    }
} err]} {
    puts "RESULT board WNS_WORST_ANY_NS QUERY_FAILED -- $err"
}
if {[catch {
    set tpc [get_timing_paths -delay_type max -max_paths 1 -nworst 1 -group sys_clk]
    if {[llength $tpc]} {
        puts "RESULT board WNS_CLOCK_NS [get_property SLACK $tpc]"
    } else {
        puts "RESULT board WNS_CLOCK_NS NO_PATH"
    }
} err]} {
    puts "RESULT board WNS_CLOCK_NS QUERY_FAILED -- $err"
}

# ---- 设计检查点（GUI 里看关键路径 Schematic 的那张配图要用）-----------------
# 非工程模式跑完**什么都不留** —— 没有 .xpr、没有 .dcp。于是「打开设计、点开
# 关键路径、截 Schematic」这条路在 GUI 里根本走不通：没有东西可打开。
# 报告 `report/design/03_performance_and_resources.md` §3.12 第 3 条要的
# 「关键路径截图」就卡在这里。
#
# ⚠️ 可选：不传第 8 个参数（dcpfile 为空）就一个字都不写。
#    上游对照、只量数字的那几轮不需要它，别白占几十 MB。
# ⚠️ 打开 .dcp 时 Vivado 要**从仓库外的目录**启动 —— 病根是启动目录里的撇号，
#    见 run_board_synth.sh 文件头。文件本身放在带撇号的路径下没问题。
# ⚠️ 只有 impl_ok 才写：没布完的 checkpoint 打开后看不到实际走线，
#    拿它截图会得到一张与报告数字对不上的图。
if {$impl_ok && $dcpfile ne ""} {
    if {[catch {
        file mkdir [file dirname $dcpfile]
        write_checkpoint -force $dcpfile
    } err]} {
        puts "  !! write_checkpoint failed: $err"
    } else {
        puts "RESULT board DCP $dcpfile"
    }
}

# ---- bitstream -------------------------------------------------------------
# ⚠️ 只在布线**成功**时才写。没布完就 write_bitstream 会报一堆「未布线」的
#    错，而且可能留下一个半成品文件；上板时拿到坏 bitstream 比拿不到更费时间。
if {$impl_ok} {
    file mkdir $outdir
    if {[catch {write_bitstream -force "$outdir/ntt_board.bit"} err]} {
        puts "  !! write_bitstream failed: $err"
        set impl_ok 0
    } else {
        puts "RESULT board BIT [file join $outdir ntt_board.bit]"
        # ---- 档位戳 -------------------------------------------------------
        # 与 bitstream **同目录、同时刻**写一个一行的 `ntt_board.pe`。
        # 为什么值得单独一个文件：bitstream 的名字里没有档位信息（三档都叫
        # ntt_board.bit），而**拿错档位上板**的症状是「256 个值全错」——
        # 看着像 RTL 挂了。有了这个戳，`run_board_prog.sh` 烧录前能直接报出来。
        # 写完 bitstream 才写它，所以「戳存在」蕴含「bitstream 是完整的」。
        # ⚠️ `-translation lf`：Tcl 在 Windows 上默认把 `\n` 翻成 `\r\n`，
        #    戳里就会多一个 CR，`cat` 出来看着像「pe4\r」。仓库口径统一 LF
        #    （CLAUDE.md 约定 1），别在这里开一个例外。
        if {[catch {
            set fh [open [file join $outdir ntt_board.pe] w]
            fconfigure $fh -translation lf
            puts $fh $pe
            close $fh
        } err]} {
            puts "  !! 写档位戳失败: $err"
        }
    }
} else {
    puts "  NOTE: 布线未完成 —— 跳过 write_bitstream（不出 bitstream）"
}

puts "RESULT board PE $pe"
puts "RESULT board IMPL_OK $impl_ok"
puts "RESULT board DONE"
