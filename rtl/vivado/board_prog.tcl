# ===========================================================================
# board_prog.tcl —— 把 bitstream 烧进 PL（JTAG 直配，不是写 flash）
#
#   用法（由 run_board_prog.sh 调用，一般不直接跑）:
#     vivado -mode batch -source board_prog.tcl -tclargs <bitfile> <mode>
#       mode = scan     只连下载器、扫 JTAG 链、报芯片名，**不烧任何东西**
#       mode = program  连上 → 烧 bitfile
#
#   为什么默认先 scan：烧之前先确认「下载器看得见」，能把两类完全不同的故障
#   （线/座没插对 vs bitstream 有问题）分开。09-29 验通时走的也是这条顺序。
#
#   ── 硬件前提（09-29 实测，缺一条都表现为「看不到设备」）──────────────
#     · JTAG 下载器插**底板右侧的 14-Pin JTAG 座**
#       ⚠️ `USB_UART` 与 `USB_SLAVE` 两个口**都不能**下载程序
#     · 底板 **P5 跳 PL 档**（3–5、4–6 短接）
#     · 启动拨码 **JTAG 档**（两位都 ON）
#
#   ⚠️ 位流是 SRAM 配置，**掉电即失** —— 断电后要重烧。
#
#   ⚠️ 与综合一样，必须从仓库外目录启动 Vivado（仓库路径含撇号，见
#      run_board_synth.sh 文件头）。本脚本自身放在仓库里没问题 ——
#      `-source` 的参数路径带撇号不影响，出问题的是**进程工作目录**。
# ===========================================================================

set bitfile [lindex $argv 0]
set mode    [lindex $argv 1]
if {$mode eq ""} { set mode program }

puts "=== board_prog | mode=$mode ==="
puts "    bitfile=$bitfile"

open_hw_manager

if {[catch {connect_hw_server} err]} {
    puts "RESULT prog HW_SERVER FAIL -- $err"
    exit
}
puts "RESULT prog HW_SERVER OK"

# ---- 找 JTAG 链 ------------------------------------------------------------
set tgts [get_hw_targets]
puts "RESULT prog TARGETS [llength $tgts]"
if {[llength $tgts] == 0} {
    puts "  !! 看不到下载器。按顺序查："
    puts "     ① 下载器是否插在底板**右侧 14-Pin JTAG 座**（USB_UART / USB_SLAVE 都不能下载）"
    puts "     ② 底板 P5 跳线是否在 PL 档（3–5、4–6 短接）"
    puts "     ③ 启动拨码是否在 JTAG 档（两位都 ON）"
    puts "     ④ 板子是否上电"
    puts "RESULT prog NO_TARGET"
    exit
}

set tgt [lindex $tgts 0]
puts "    target: $tgt"
current_hw_target $tgt

if {[catch {open_hw_target} err]} {
    puts "RESULT prog OPEN_TARGET FAIL -- $err"
    exit
}
puts "RESULT prog TARGET_OPEN OK"

foreach d [get_hw_devices] { puts "    device: $d" }

# 已知器件名是 xc7z020_1；取不到就退回「链上第一个」，免得名字随版本变
set dev [lindex [get_hw_devices xc7z020_1] 0]
if {$dev eq ""} {
    set dev [lindex [get_hw_devices] 0]
    puts "  NOTE: 没找到 xc7z020_1，退回链上第一个器件"
}
current_hw_device $dev
puts "RESULT prog DEVICE $dev"

# ---- scan 模式到此为止 -----------------------------------------------------
if {$mode eq "scan"} {
    puts "RESULT prog SCAN_OK （只扫链，未烧任何东西）"
    close_hw_target
    puts "RESULT prog DONE"
    exit
}

# ---- 烧 --------------------------------------------------------------------
if {![file exists $bitfile]} {
    puts "RESULT prog BITFILE MISSING $bitfile"
    puts "  !! 先跑 rtl/vivado/run_board_synth.sh 产出 bitstream"
    exit
}

set_property PROGRAM.FILE $bitfile [current_hw_device]
if {[catch {program_hw_devices [current_hw_device]} err]} {
    puts "RESULT prog PROGRAM FAIL -- $err"
    exit
}

# 27-3164 是 Zynq PL 配置完成的标志，日志里出现它才算真进去了
puts "RESULT prog PROGRAMMED $bitfile"

close_hw_target
puts "RESULT prog DONE"
