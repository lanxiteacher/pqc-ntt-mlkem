# probe_parts.tcl —— 查本机 Vivado 装在哪些器件
#
#   用法:  vivado -mode batch -source probe_parts.tcl
#
# 为什么需要: 论文 (research/papers/yaman.pdf) 用的 Artix-7 xc7a200tffg1156-3
# 只是拿来跟我们的 Zynq-7020 数字做交叉核对。装了就多跑一轮，没装就只做纸面对比。

puts "=== PARTS PROBE ==="
foreach p {xc7z020clg400-2 xc7a200tffg1156-3} {
    if {[catch {set hits [get_parts -quiet $p]} err]} {
        puts "  ERROR   : $p  ($err)"
    } elseif {[llength $hits] == 0} {
        puts "  MISSING : $p"
    } else {
        puts "  FOUND   : $p"
    }
}
if {[catch {puts "  xc7a200t* 系列命中数: [llength [get_parts -quiet xc7a200t*]]"} err]} {
    puts "  ERROR   : xc7a200t*  ($err)"
}
puts "=== PROBE DONE ==="
