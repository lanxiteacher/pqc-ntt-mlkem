# ===========================================================================
# ntt_board.xdc —— 板级引脚与时序约束
#
# 四条引脚照抄正点原子 19_uart_loopback 例程的 XDC
# （prj/uart_loopback.srcs/constrs_1/new/uart_loopback.xdc），
# 已与全板 NAVIGATOR_ZYNQ_IO.xdc 交叉核对一致。
#
# 板子：正点原子领航者 ZYNQ，器件 xc7z020clg400-2。
#
# ⚠️ 全板 XDC 里 uart_rxd / uart_txd 定义了**三次**，是互斥备选：
#      USB UART       T19 / J15   ← 本文件用这一组
#      PL_UART(RS232) K14 / M15
#      RS485          （另一组）
#    只能用一组。本板走板载 CH340C，用 USB UART 那组。
#
# ⚠️ sys_rst_n（N16）是**低有效**；而 NTT 核的 reset 是**异步高有效**。
#    顶层 ntt_board_top 里已取反（reset = ~sys_rst_n）。约束只认引脚，
#    不认极性 —— 极性在 RTL 里保证。
#
# 复位键在板子上的物理位置（2026-10-07 回正点原子《FPGA 开发指南》V3.4 核过，
# 见 §11.2 图 11.2.1「按键与 LED 实物图」与图 11.2.2 原理图）：
#    板子**右下侧**一排 5 个按键 + 4 个 LED。
#    **最左边那个红色按键 = PL_RESET = 本文件的 sys_rst_n（N16）**，
#    按键旁丝印就写着 `PL_RESET`。右边四个黄色按键依次是
#    PL_KEY0 / PL_KEY1 / PS_KEY0 / PS_KEY1（L14 / K16 / … ，本工程不用）。
#    全板 NAVIGATOR_ZYNQ_IO.xdc 第 10–11 行、以及
#    《领航者ZYNQ IO引脚分配总表.xlsx》PL 页都把 N16 标作「复位按键」。
#    ⚠️ 别跟**核心板上那个 PS_RST** 搞混 —— 那是 PS 端的复位，
#       JTAG 档下 PS 根本不启动，按它对我们没有任何作用。
# ===========================================================================

# 时钟：sys_clk = U18，50 MHz → 周期 20 ns
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

# ---------------------- 系统时钟 ----------------------
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports sys_clk]

# ---------------------- 系统复位（低有效）--------------------
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]

# ---------------------- USB UART ----------------------
set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS33} [get_ports uart_rxd]
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33} [get_ports uart_txd]
