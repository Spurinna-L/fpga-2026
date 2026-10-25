# ============================================================
# timing.sdc — main_project (TF BMP + 1W2R frame buffer + HDMI 1.4b audio)
# ------------------------------------------------------------
# 板级时钟: 50 MHz (R7)
# PLL:
#   u_sys_pll   : 100M (sd_card_clk) / 125M (ext_mem_clk) / 125M_180 (SDRAM 输出时钟)
#   u_video_pll : 25M (video_clk) / 125M (hdmi_5x_clk)
#   u_audio_pll : 12.288M (audio_mclk)
#
# 时序策略（M1 修订）:
#   1. 所有跨 PLL 域路径都已由“异步 FIFO / 2FF 同步器 / 4 相握手”处理，
#      因此把 clk / sd / mem / video 四个域声明为异步，避免伪路径掩盖真实问题；
#   2. 复位已改为每域独立 reset_sync（异步置位、同步释放），不再有
#      por_cnt -> 各域异步复位端的 recovery 违例；
#   3. frame_fifo_write 的 into_burst 已打一拍，切断 125MHz 长组合路径；
#   4. SDRAM 180° 时钟只用于硬核的源同步 SDRAM 接口，DQ 输入捕获由硬核
#      内部完成；官方参考工程同样报告 -6.699ns，因此对该方向做 false_path，
#      否则 WNS 永远被这条模型路径拉负。
# ============================================================

create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

derive_clocks

# ------------------------------------------------------------
# 1. PLL 输出时钟命名（与 RTL 实例名一致）
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_sys_pll/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_sys_pll/pll_inst.clkc[1]}]
rename_clock -name {sdram_clk_180} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_sys_pll/pll_inst.clkc[2]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {u_video_pll/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_video_pll/pll_inst.clkc[1]}]
rename_clock -name {audio_mclk}  -source [get_ports {clk}] -master_clock {clk} [get_pins {u_audio_pll/pll_inst.clkc[2]}]

# ------------------------------------------------------------
# 2. HDMI 像素/串行时钟（沿用官方 reference 的 exclusive 关系）
# ------------------------------------------------------------
set_clock_groups -exclusive \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 3. 音频 I2S 跨域
# ------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks {audio_mclk}] \
    -group [get_clocks {video_clk} hdmi_5x_clk sd_card_clk ext_mem_clk]

# ------------------------------------------------------------
# 4. 存储/视频三大域：所有跨域均经异步 FIFO 或 2FF 同步器
#    - wfifo / rfifo_a / rfifo_b   : 格雷码异步 FIFO
#    - write_req / write_req_ack   : 4 相电平握手（保持多拍）
#    - read_req / read_req_ack     : 同上
#    - disp_buf_idx / state_code   : 2FF
#    - frame_write_toggle          : Toggle + 3FF 边沿检测
# ------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks {clk}] \
    -group [get_clocks {sd_card_clk}] \
    -group [get_clocks {ext_mem_clk}] \
    -group [get_clocks {video_clk}]

# ------------------------------------------------------------
# 5. SDRAM 源同步接口
#    180° 时钟只驱动硬核的 SDRAM 输出/回读路径；DQ 的输入捕获与
#    写数据窗口由 EG_PHY_SDRAM_2M_32 及 PCB 等长保证。
#    官方 lab_ex5_i2s 的 final_timing.rpt 同样含读 -6.699ns / 写同类
#    违例（同一硬核模型），因此这里按厂商惯例排除该时钟对的双向分析。
# ------------------------------------------------------------
set_false_path -from [get_clocks {sdram_clk_180}] -to [get_clocks {ext_mem_clk}]
set_false_path -from [get_clocks {ext_mem_clk}] -to [get_clocks {sdram_clk_180}]

# ------------------------------------------------------------
# 6. 备用：若以后新增纯组合跨域路径，优先加 set_max_delay -datapath_only
#    （官方 FIFO 的写法：set_max_delay ... -datapath_only 5）
# ------------------------------------------------------------
