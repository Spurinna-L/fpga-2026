//=============================================================================
// global_def.v — SDRAM 控制器全局宏定义
//-----------------------------------------------------------------------------
// 内容：
//   DATA_WIDTH = 32        SDRAM 数据位宽（bit）
//   ADDR_WIDTH = 21        用户地址位宽（2M × 32bit = 8MB）
//   DM_WIDTH   = 4         字节掩码位宽
//   ROW_WIDTH  = 11        行地址位宽
//   BA_WIDTH   = 2         bank 地址位宽
//   SDR_CLK_PERIOD         125MHz 周期（ns 整数近似）
//   SELF_REFRESH_INTERVAL  自刷新间隔（按行数换算）
//
// 用途：
//   被 sdram.v 用 `include 引入，同时被加密的 sdr_as_ram / sdr_wrrd /
//   sdr_init_ref 共用，保证各层位宽一致。
//
// 备注：
//   本文件不是模块，只有宏定义；改位宽会同时影响加密核，务必谨慎。
//=============================================================================
`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

`define	  SDR_CLK_PERIOD				1000000000/125000000
// 刷新间隔：原式按 2048 行 / 64ms 计算（≈31.25µs/行）。
// 实测闲置槽会缓慢丢数据（花屏小点逐渐增多），说明该间隔对本硬核偏慢，
// 这里除以 4（≈7.8µs/行，等效 8192 行），代价仅约 1% 带宽。
`define   SELF_REFRESH_INTERVAL			64000000/`SDR_CLK_PERIOD/2**(`ROW_WIDTH)/4

