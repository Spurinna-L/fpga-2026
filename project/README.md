# 智能商业展陈 HDMI 多媒体播放系统 — 工程框架

> 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 安路赛道 · 选题一
> 硬件：大拇指 DMZ_EG4S20 核心板（EG4S20BG256）+ 微处理器原理综合设计底板
> 定位：**纯 RTL、零处理器**的数字标牌（BMP 图片轮播 + WAV 音频）
>
> 详细路线见仓库根目录 `项目计划.md`；本文档描述**工程结构、逐文件接口约定与落地状态**。

---

## 1. 目录结构

```
project/
├── main_project.al          # TD 工程（已登记全部源码/约束，顶层 = top）
├── README.md                # 本文件
├── constraints/
│   └── top.adc              # 引脚约束（来自官方例程，权威）
├── rtl/
│   ├── top.v                # 系统顶层（数据流总装）
│   ├── common/              # 公共基础：复位同步 / CDC / 异步FIFO / 时钟
│   ├── video/               # 视频主链路：720p时序/测试图/HDMI/参数/转场/缩放
│   ├── compose/             # 合成：帧缓冲管理 / OSD 混合 / 文字层 / 字库
│   ├── storage/             # 存储：SD SPI / FAT32 / 媒体扫描 / SDRAM 控制器
│   ├── decode/              # 解码：BMP / WAV
│   ├── audio/               # 音频：PWM(Σ-Δ) / 可视化 / 麦克风
│   ├── control/             # 控制：主控FSM / 控制寄存器 / 数码管
│   └── reuse/               # 官方例程复用（不可改动的加密IP除外）
│       ├── sd/              # sd_initial / sd_read / sd_write / sd_pll
│       ├── sdram/           # Sdram_Control_4Port + 硬核 + FIFO + PLL
│       └── misc/            # ascii_3216 / key_filter / keyboard_scan / spi_rx / seg解码
├── ip/
│   └── hdmi/                # 官方加密 IP（黑盒）：hdmi_tx.vhd + *.enc.vhd + tx_pll
├── sim/tb/                  # 测试平台（待补）
└── doc/
    └── 框架说明.md          # 模块清单/状态、时钟复位CDC约定、存储映射、集成说明
```

## 2. 快速开始（TD 5.6.5+）

1. 用 **Anlogic TD** 打开 `project/main_project.al`。
2. 确认顶层模块为 `top`（已设置），源文件与 `constraints/top.adc` 已登记。
3. **（首要任务）重建像素时钟 PLL**：当前 `ip/hdmi/tx_pll.v` 是官方 1280×1024 配置
   （C1=107.5MHz），720p 需要 **C1=74.25MHz / C2=371.25MHz**。
   用 TD 的 IP 生成器重建并覆盖 `ip/hdmi/tx_pll.v`（详见 `doc/框架说明.md §6`）。
4. 综合 → 布局布线 → 下载，应看到 **HDMI 显示彩条测试图**（里程碑 M1）。
5. 若 720p 时序不收敛，按计划回退官方已验证分辨率。

## 3. 当前落地状态

| 模块 | 状态 | 说明 |
| :--- | :--- | :--- |
| `top` / 时钟 / 复位 / CDC / 异步FIFO | ✅ 实现 | 全链路已总装，可综合 |
| `video_timing_720p` | ✅ 实现 | 720p60 时序，自研，替换官方 TPG |
| `test_pattern` | ✅ 实现 | 彩条+移动方块+边框，M1 用 |
| `hdmi_tx_wrap` | ✅ 实现 | 软 TMDS 输出，黑盒加密 IP |
| `video_proc` | ✅ 实现 | 亮度/对比度已实现；饱和度留 TODO |
| `transition` | ✅ 实现 | 溶解/滑动/擦除，V-BLANK 对齐 |
| `fb_mgr` / `sdram_ctrl_wrap` | 🟡 骨架 | 接口定稿；帧缓冲实读待存储打通 |
| `bilinear_scaler` | 🟡 骨架 | 反向映射系数已算，双线性运算留 TODO |
| `osd_layer` | ✅ 实现 | 统一 alpha 混合单元 |
| `text_layer` / `font_rom` | 🟡 骨架 | 字库封装就绪，取模/跑马灯留 TODO |
| `sd_ctrl` | ✅ 实现 | 复用底层 + 自研握手与跨时钟FIFO |
| `fat32_reader` / `media_scan` | 🟡 骨架 | 第 2 周主工作量 |
| `bmp_decoder` / `wav_player` | 🟡 骨架 | 第 2 周 |
| `pwm_audio` | ✅ 实现 | 数字音量 + 一阶 Σ-Δ |
| `r2r_dac_audio` | ✅ 实现 | SDRAM 音频环缓 → 数字音量 → 8bit R-2R DAC（走 RD2 端口） |
| `audio_viz` | 🟡 骨架 | 第 4 周 |
| `mic_adc` | ✅ 实现 | 复用 spi_rx |
| `main_fsm` / `regs` / `seg_led` | ✅ 实现 | 基本流程可用 |

✅=可综合实现　🟡=接口骨架（TODO 待填）

---

## 4. 逐文件说明（功能 · 接口 · 通用性）

> 图例：**【自研】** 本项目原创；**【复用】** 来自官方例程（尽量不改）；
> **通用性** 指能否脱离本项目复用到其他工程。参数用 `#(...)` 标注。

### 4.1 `rtl/common/` — 公共基础单元（全通用）

#### `common/reset_sync.v` 【自研】
- **功能**：把板上按键/开关的异步复位，同步到某时钟域后再释放（异步拉低、同步释放），消除释放边沿的亚稳态。
- **接口**：
  ```verilog
  module reset_sync #(parameter SYNC_STAGES = 2) (
      input  wire clk,      // 目标时钟域
      input  wire arst_n,   // 异步复位输入（低有效）
      output wire rst_n     // 同步后复位输出（低有效）
  );
  ```
- **通用性**：★最高。无任何项目依赖，`SYNC_STAGES` 可调；任何多时钟域工程可直接复用。

#### `common/cdc_sync.v` 【自研】
- **功能**：多比特**慢变电平量**跨时钟域的两级同步（逐位独立打拍）。
- **接口**：
  ```verilog
  module cdc_sync #(parameter WIDTH = 1, parameter SYNC_STAGES = 2) (
      input  wire             clk_dst,
      input  wire             rst_n_dst,
      input  wire [WIDTH-1:0] d_async,
      output wire [WIDTH-1:0] q_sync
  );
  ```
- **通用性**：★最高。纯通用 CDC 原语。**注意限制**：用于慢变/逐位独立信号；要求多位"同时有效"语义时应改用 `async_fifo`（见文件头注释）。

#### `common/async_fifo.v` 【自研】
- **功能**：双时钟异步 FIFO，跨域搬运需原子有序的多比特流（SD 字节流、PCM、频谱）。格雷码指针 + 两级同步 + 空满比较。
- **接口**：
  ```verilog
  module async_fifo #(parameter DW = 8, parameter DEPTH = 512) (  // DEPTH 须为 2 的幂
      input  wire          wr_clk, wr_rst_n, wr_en,
      input  wire [DW-1:0] wr_data, output wire full,
      input  wire          rd_clk, rd_rst_n, rd_en,
      output wire [DW-1:0] rd_data, output wire empty
  );
  ```
- **通用性**：★高。宽度/深度参数化，纯 RTL 无 IP 依赖；任何跨时钟域数据搬运可复用。

#### `common/clk_gen.v` 【自研（内含黑盒 PLL）】
- **功能**：从 50MHz 生成像素时钟、TMDS 5× 位时钟与辅助时钟。内部例化 `ip/hdmi/tx_pll.v`（官方 PLL，需按 720p 重配）。
- **接口**：
  ```verilog
  module clk_gen (
      input  wire clk_50m, input wire areset,
      output wire clk_pix, clk_pix5x, clk_25m, output wire pll_locked
  );
  ```
- **通用性**：★低（**项目特定**）。依赖 `tx_pll` 的具体分频配置；换分辨率需重配 PLL。接口本身简单，可作为"时钟封装层"模板。

### 4.2 `rtl/video/` — 视频主链路

#### `video/video_timing_720p.v` 【自研】
- **功能**：CEA-861 标准的 **1280×720@60** 视频时序发生器，是全链路唯一"时间基准"（替换官方加密 TPG）。给出同步、数据有效与扫描坐标，供缩放/OSD/转场/输出统一使用。
- **时序常量**（模块内 localparam，唯一权威）：H 有效1280/前肩110/同步40/后肩220/总1650；V 有效720/前肩5/同步5/后肩20/总750；HS/VS 均正极性。
- **接口**：
  ```verilog
  module video_timing_720p (
      input  wire clk_pix, rst_n,
      output reg  hs, vs, de,
      output reg  [10:0] x, y,          // de 有效时的像素列/行
      output reg  frame_start, line_start
  );
  ```
- **通用性**：★中。分辨率相关常量已集中在文件头，改分辨率只需改 localparam；若要参数化到多分辨率，可加 `#(H_ACTIVE,...)`，当前为清晰起见写死常量。

#### `video/test_pattern.v` 【自研】
- **功能**：上电测试图（8 段彩条 + 移动方块 + 白边框），在真实素材通路打通前提供已同步图像，用于验证 M1 与时序收敛。
- **接口**：
  ```verilog
  module test_pattern (
      input  wire clk_pix, rst_n, de,
      input  wire [10:0] x, y,
      output reg  [15:0] rgb          // RGB565
  );
  ```
- **通用性**：★中。纯彩条图，可作为任何视频工程的 bring-up 源；坐标范围写死 720p，宽屏分辨率需调整。

> **注**：VGA 输出方案已砍掉，`vga_out.v` 已从工程移除，视频输出仅保留 **HDMI**。
> （原 VGA 引脚约束在 `constraints/top.adc` 中以注释形式保留，便于日后恢复。）

#### `video/hdmi_tx_wrap.v` 【自研封装 + 黑盒 IP】
- **功能**：把 RGB565 扩为 RGB888 后送入官方加密 `hdmi_tx`（软 TMDS/DVI 发送），输出 4 对 LVDS 差分。做黑盒隔离，便于将来替换/升级 IP。
- **接口**：
  ```verilog
  module hdmi_tx_wrap (
      input  wire clk_pix, clk_pix5x, rst_n, hs_i, vs_i, de_i,
      input  wire [15:0] rgb565,
      output wire hdmi_clk_p, hdmi_d0_p, hdmi_d1_p, hdmi_d2_p
  );
  ```
- **通用性**：★中。封装层通用（输入标准视频总线），但内部绑定 Anlogic 加密 IP；换厂商需替换内部例化与差分引脚。

#### `video/video_proc.v` 【自研】
- **功能**：实时视频参数处理——**亮度**（加偏置）与**对比度**（乘增益，128=1.0）已实现，通道 8bit 精度运算 + 饱和截断；**饱和度**留 TODO（需 YCbCr）。
- **接口**：
  ```verilog
  module video_proc (
      input  wire clk_pix, rst_n,
      input  wire [15:0] rgb_in, input wire de_in, hs_in, vs_in,
      input  wire signed [7:0] brightness,   // 亮度偏移
      input  wire [7:0] contrast,            // 128=1.0
      input  wire [7:0] saturation,          // 128=1.0（TODO）
      output reg  [15:0] rgb_out, output reg de_out, hs_out, vs_out
  );
  ```
- **通用性**：★高。基于 RGB565 输入输出，与分辨率无关；参数寄存器化的乘加处理可移植到任意图像流水线。

#### `video/transition.v` 【自研】
- **功能**：转场引擎，A/B 两帧按 `mode` 混合：0=淡入淡出/交叉溶解、1=水平滑动、2=水平擦除、3=垂直擦除；`blend 0→255` 控制进程；整帧流水，配合 V-BLANK 启动。
- **接口**：
  ```verilog
  module transition (
      input  wire clk_pix, rst_n,
      input  wire [15:0] a_rgb, b_rgb,
      input  wire hs_i, vs_i, de_i, input wire [10:0] x, y,
      input  wire [1:0] mode, input wire [7:0] blend,
      output reg  [15:0] rgb_o, output reg hs_o, vs_o, de_o
  );
  ```
- **通用性**：★高。标准视频流 A/B 混合器，分辨率仅影响边界计算常量（已用 localparam）；可复用到任意双帧切换场景。

#### `video/bilinear_scaler.v` 【自研（骨架）】
- **功能**：双线性缩放（扩展要求③），目标域**反向映射**：算源坐标 `f=x_out*src/dst`（Q16 定点），取 2×2 邻域加权。当前为接口定稿 + 旁路占位（仅 1:1 正确），双线性运算待第 3 周补。
- **接口**：
  ```verilog
  module bilinear_scaler #(parameter DW = 16) (
      input  wire clk_pix, rst_n, en,
      input  wire de_out, input wire [10:0] x_out, y_out, frame_start,
      input  wire [10:0] src_w, src_h, dst_w, dst_h,
      output wire [10:0] rd_x0, rd_y0,               // 源像素读取地址
      input  wire [DW-1:0] p00, p01, p10, p11,      // 2×2 邻域
      input  wire rd_valid,
      output reg  [DW-1:0] dst_pix, output reg dst_valid
  );
  ```
- **通用性**：★中。接口不绑定分辨率（尺寸走输入端口），但架构假定上游（`fb_mgr`）按需提供 2×2 邻域；换数据宽度只需改 `DW`。

### 4.3 `rtl/compose/` — 合成层

#### `compose/fb_mgr.v` 【自研（骨架）】
- **功能**：帧缓冲管理——Ping-Pong 双缓冲、帧末翻转（`frame_start` 处换前后台，防撕裂）、向 `sdram_ctrl_wrap` 发起读写、为扫描提供像素流；未就绪时输出 `fallback_rgb`（保证 M1 先跑通）。
- **接口**：
  ```verilog
  module fb_mgr (
      input  wire clk_pix, rst_n,
      input  wire hs_i, vs_i, de_i, input wire [10:0] x, y, input wire frame_start,
      input  wire [15:0] fallback_rgb,
      input  wire buf_ready, swap_req, output reg swap_done, output wire front_sel,
      input  wire [15:0] sdram_rd_data, output wire sdram_rd_req, output wire [20:0] sdram_rd_addr,
      input  wire dec_we, input wire [10:0] dec_x, dec_y, input wire [15:0] dec_data,
      output wire [15:0] rgb_o
  );
  ```
- **通用性**：★中。地址基址与像素格式（RGB565）项目相关，但"双缓冲 + 帧末翻转 + 读写口"结构是通用模式，可作模板。

#### `compose/osd_layer.v` 【自研】
- **功能**：**统一 alpha 混合单元**（扩展要求①的混合器）：`out=(base*(255-a)+ovl*a)/255`，把底图与任意外部叠加层合成；多层用画家算法串联本单元。
- **接口**：
  ```verilog
  module osd_layer (
      input  wire clk_pix, rst_n,
      input  wire [15:0] base_rgb, input wire hs_i, vs_i, de_i,
      input  wire [15:0] ovl_rgb, input wire [7:0] ovl_alpha, input wire ovl_valid,
      output reg  [15:0] rgb_o, output reg hs_o, vs_o, de_o
  );
  ```
- **通用性**：★高。纯混合逻辑、与图层内容无关；任何"底图+半透明叠加"场景可复用。

#### `compose/text_layer.v` 【自研（骨架）】
- **功能**：文字/字幕图层生成器（扩展要求①），在字幕带内按 16 像素字符格取字模、支持 `scroll_x` 跑马灯；当前为接口骨架（`ovl_valid` 恒 0），取模逻辑待第 3 周实现。
- **接口**：
  ```verilog
  module text_layer (
      input  wire clk_pix, rst_n, input wire de_i, input wire [10:0] x, y,
      output reg  [12:0] fnt_addr, input wire [7:0] fnt_data,   // 连接 font_rom
      output reg  [6:0]  txt_char_idx, input wire [6:0] txt_char_code, // 文本行RAM
      input  wire [10:0] txt_y, scroll_x, input wire [7:0] fg_alpha, input wire [15:0] fg_color,
      input  wire osd_en,
      output reg  [15:0] ovl_rgb, output reg [7:0] ovl_alpha, output reg ovl_valid
  );
  ```
- **通用性**：★中。取模/跑马灯逻辑通用，但字库地址编址与 `font_rom`/`ascii_3216` 结构绑定。

#### `compose/font_rom.v` 【自研封装 + 复用 BRAM】
- **功能**：字符点阵 ROM 封装（内部例化官方 `ascii_3216`，32×16 点阵，1 字符=16 行×4 字节=64B，95 字符=6080B）。
- **接口**：
  ```verilog
  module font_rom (input wire clk_pix, input wire [12:0] addr, output wire [7:0] data);
  // addr = { char_code[6:0], row[3:0], byte_sel[1:0] }，读出 1 拍
  ```
- **通用性**：★中。封装层通用；字库内容依赖 TD IP 的初始化文件，换字库需重生成。

### 4.4 `rtl/storage/` — 存储与缓存

#### `storage/sd_ctrl.v` 【自研（复用底层）】
- **功能**：SD 卡 SPI 底层控制器。复用官方 `sd_initial`(CMD0/8/55/41 初始化)+`sd_read`(CMD17 单块读 512B)+`sd_pll`(25MHz)；自研请求/完成握手与 **SD域→系统域的异步 FIFO**，对外提供"按扇区读、字节流输出"的干净接口。
- **接口**：
  ```verilog
  module sd_ctrl (
      input  wire clk, rst_n,
      output wire sd_clk, sd_cs, sd_mosi, input wire sd_miso,
      input  wire [31:0] rd_sec, input wire rd_req,
      output wire [7:0] rd_data, output wire rd_valid, input wire rd_pop,
      output wire rd_done, output wire init_done
  );
  ```
- **通用性**：★高。不涉及文件系统语义，是"SD 物理层 + CDC"的通用封装；换卡/换引脚只需改顶层与约束。

#### `storage/fat32_reader.v` 【自研（骨架）】
- **功能**：FAT32 只读文件系统（第 2 周主工作量）。阶段1 仅 8.3 短名+根目录，阶段2 扩展 LFN/子目录。解析 MBR→BPB→FAT 链→目录项，提供目录扫描与文件字节流。
- **接口**：
  ```verilog
  module fat32_reader (
      input  wire clk, rst_n,
      output reg  [31:0] sd_sec, output reg sd_req,        // → sd_ctrl
      input  wire [7:0]  sd_data, input wire sd_valid, sd_done, output wire sd_pop,
      output reg  [7:0]  file_data, output reg file_valid, output reg eof, input wire file_pop,
      input  wire start, input wire [31:0] file_cluster,   // 控制
      output reg  busy, done
  );
  ```
- **通用性**：★中。FAT32 解析算法通用，但只读、单分区、面向 BMP/WAV 场景；可复用到其他 SD 读取工程。

#### `storage/media_scan.v` 【自研（骨架）】
- **功能**：扫描根目录、识别 `*.BMP`/`*.WAV`，建立媒体索引表（类型/首簇/大小/序号），供轮播调度与数码管序号。
- **接口**：
  ```verilog
  module media_scan (
      input  wire clk, rst_n, input wire scan_start,
      output reg  scanning, done,
      output wire dir_pop, input wire dir_valid, input wire [7:0] dir_data, // ← fat32_reader
      output reg  idx_we, output reg [7:0] idx_addr, output reg [1:0] idx_type,
      output reg  [31:0] idx_cluster, idx_size, output reg [7:0] media_count
  );
  ```
- **通用性**：★中。后缀匹配+建表的思路通用，索引表字段可扩展。

#### `storage/sdram_ctrl_wrap.v` 【自研封装 + 复用控制器】
- **功能**：片内 SDRAM 帧缓存控制器封装。复用 `Sdram_Control_4Port`(4 端口 FIFO)+`sdram`(EG_PHY_SDRAM_2M_32 硬核)+`sdram_pll`(100M/100M@90°)；对外提供两组写口(WR1/WR2)+两组读口(RD1/RD2) 与时钟。
- **接口**：
  ```verilog
  module sdram_ctrl_wrap #(parameter ASIZE = 21, parameter DSIZE = 16) (
      input  wire clk_50m, rst_n,
      // WR1:  data,req,addr,max_addr,length,load,clk -> full,use
      // WR2:  同上
      // RD1:   data<-  ; req,addr,max_addr,length,load,clk -> empty,use
      // RD2:  同上
      output wire clk_sdr_ctrl, clk_sdram, pll_locked
  );
  // 地址组成 {bank[1:0], row[10:0], col[8:0]}；DSIZE=16 → 1 word = 1 个 RGB565 像素
  ```
- **通用性**：★中。封装思路通用（把 FIFO 型 SDRAM 控制器包成干净用户接口）；数据宽度/地址宽度参数化，但时钟与硬核绑定 EG4S20。

### 4.5 `rtl/decode/` — 解码

#### `decode/bmp_decoder.v` 【自研（骨架）】
- **功能**：BMP 解码，支持 24/32bit 非压缩、行 4 字节对齐补齐、正/反向行序；解析文件头后逐像素输出 RGB565 到帧缓冲。
- **接口**：
  ```verilog
  module bmp_decoder (
      input  wire clk, rst_n, output wire file_pop, input wire file_valid, input wire [7:0] file_data,
      output reg  [15:0] img_w, img_h, output reg header_ok, frame_done,
      output reg  [15:0] px_data, px_x, px_y, output reg px_we
  );
  ```
- **通用性**：★中。BMP 规范固定，解码逻辑通用；输出格式当前 RGB565，可参数化为 RGB888。

#### `decode/wav_player.v` 【自研（骨架）】
- **功能**：WAV/PCM 播放，支持 8/16bit、单/双声道、48kHz；解析 chunk 后按采样节拍输出 16bit 有符号 PCM。采样节拍由时钟派生，与画面同源。
- **接口**：
  ```verilog
  module wav_player (
      input  wire clk, rst_n, output wire file_pop, input wire file_valid, input wire [7:0] file_data,
      output reg  [31:0] sample_rate, output reg [2:0] channels, output reg [5:0] bits, output reg header_ok,
      output reg  [15:0] pcm_l, pcm_r, output reg pcm_valid, eof
  );
  ```
- **通用性**：★中。PCM 播放通用；采样节拍需按系统时钟配置。

### 4.6 `rtl/audio/` — 音频

#### `audio/pwm_audio.v` 【自研】
- **功能**：音频输出（基础要求③）。数字音量（`pcm*volume>>8`）+ **一阶 Σ-Δ 调制**产生 1bit 高过采样 PWM，经板载低通+功放还原；音质优于普通 8bit PWM。
- **接口**：
  ```verilog
  module pwm_audio (
      input  wire clk, rst_n, input wire [15:0] pcm, input wire pcm_valid,
      input  wire [7:0] volume, output reg audio_pwm
  );
  ```
- **通用性**：★高。Σ-Δ 调制与参数无关，任何"数字→模拟"PWM 输出可复用；改阶数/位宽即可。

#### `audio/r2r_dac_audio.v` 【自研】
- **功能**：**基础音频输出（R-2R DAC 通路）**。从 SDRAM「音频环形缓冲」（`0x1C2000`，131072 个 16bit 单元）里按 48kHz 逐个取出 PCM 采样（走 `sdram_ctrl_wrap` 的 **RD2** 端口，RD1 已给视频扫描占用），做数字音量后压成 8bit 无符号码输出到板载 R-2R 电阻网络 DAC。
- **原理要点**（详见文件内中文注释）：
  1. **开机装载**：复位后给 RD2 一次 `rd_load` 脉冲，把环形缓冲首地址 `AUDIO_BASE=0x1C2000` 装入控制器并清空该端口 FIFO；`rd_max_addr = AUDIO_BASE + AUDIO_WORDS + BURST_LEN`。
  2. **48kHz 节拍**：50MHz 下 50M/48k=1041.67 非整数，用「余数累加器」精确分频（每拍 `acc += 48000`，`acc >= 50000000` 时出一次节拍并 `acc -= 50000000`），只有 ±1 clk 抖动。
  3. **取数**：每到采样节拍且 FIFO 非空，给 `rd_req` 一拍脉冲，同时按 **show-ahead** 语义在当拍采样 `rd_data`（RD 端口 FIFO 提前显示最老数据）。FIFO 空则保持输出（静音续持）并置 `underrun` 调试标志。
  4. **三级流水**：采样捕获 → 有符号音量 `pcm*volume>>8` → `dac_out = 高 8bit ^ 0x80`（把有符号平移到单极性，128=中点/静音）。
- **接口**：
  ```verilog
  module r2r_dac_audio #(
      parameter integer CLK_HZ = 50_000_000, parameter integer SAMPLE_HZ = 48_000,
      parameter [20:0] AUDIO_BASE = 21'h1C2000, parameter [20:0] AUDIO_WORDS = 21'h20000,
      parameter [8:0] BURST_LEN = 9'd256) (
      input  wire clk, rst_n,
      output wire sdram_rd_clk, output reg sdram_rd_load,
      output wire [20:0] sdram_rd_addr, sdram_rd_max_addr, output wire [9:0] sdram_rd_length,
      output reg  sdram_rd_req, input wire [15:0] sdram_rd_data, input wire sdram_rd_empty,
      input  wire [7:0] volume, output reg [7:0] dac_out
  );
  ```
- **引脚**：`dac_out[7:0]` 与 8 个 LED 复用同组 IO（`B14,B15,B16,C15,C16,E13,E16,F16`）。本设计这组引脚用于 R-2R DAC，故顶层端口由 `led` 改为 `dac_out`（约束见 `constraints/top.adc`）。
- **通用性**：★高。环形缓冲 + 精确采样节拍 + 单极性码转换三者解耦，改 `AUDIO_BASE/WORDS/SAMPLE_HZ` 即可移植到任意 SDRAM 音频播放工程。

#### `audio/audio_viz.v` 【自研（骨架）】
- **功能**：音频可视化（扩展要求⑤）。分频段能量/Goertzel（8~16 段）优先、FFT 冲刺；声源可选播放 PCM 或麦克风现场采集。
- **接口**：
  ```verilog
  module audio_viz #(parameter BARS = 16) (
      input  wire clk, rst_n, input wire [15:0] pcm, input wire pcm_valid,
      input  wire [1:0] src_sel, output reg [BARS*8-1:0] bars, output reg bars_valid
  );
  ```
- **通用性**：★高。段数参数化，输入为通用 PCM，可移用到任何频谱显示工程。

#### `audio/mic_adc.v` 【自研封装 + 复用 spi_rx】
- **功能**：麦克风采集，复用官方 `spi_rx`（16bit 串口接收，自带 SCK/CS 时序），并在 clk 域分频出 `clk_baud`；输出采样与帧完成脉冲。
- **接口**：
  ```verilog
  module mic_adc #(parameter DIV = 8) (
      input  wire clk, rst_n,
      output wire adc_cs, input wire adc_miso, output wire adc_sck, adc_rst_n,
      output wire [15:0] sample, output wire sample_valid
  );
  ```
- **通用性**：★中。SPI ADC 采集封装通用（`DIV` 决定采样率），引脚/协议与具体 ADC 型号绑定。

### 4.7 `rtl/control/` — 控制

#### `control/regs.v` 【自研】
- **功能**：控制寄存器组（**无 CPU**，寄存器映射）。键盘/拨码通过写口更新，各模块只读字段；集中管理亮度/对比度/饱和度/转场/音量/序号/显示模式/使能。
- **接口**：
  ```verilog
  module regs (
      input  wire clk, rst_n, input wire wr_en, input wire [7:0] wr_addr, input wire [31:0] wr_data,
      output reg  [7:0] brightness, contrast, saturation, audio_volume, media_index,
      output reg  [1:0] transition_type, output reg [2:0] display_mode,
      output reg  osd_en, auto_play
  );
  // 地址映射见文件头（0x00..0x07；0x07 bit1 保留）
  ```
- **通用性**：★高。纯寄存器文件、无项目算法；地址表可按需增删字段，是"无 CPU 系统"的标准控制中枢模板。

#### `control/main_fsm.v` 【自研】
- **功能**：系统级主控状态机：上电自检 → 扫描 SD → 自动轮播（含转场）；响应键盘事件（切图/转场/模式）。所有画面切换只在 `frame_start` 生效（红线③）。
- **接口**：
  ```verilog
  module main_fsm #(parameter AUTO_INTERVAL_FRAMES = 32'd300_000_000) (
      input  wire clk_pix, rst_n, frame_start,
      input  wire sd_init_done, scan_done, input wire [7:0] media_count, input wire img_ready,
      input  wire ev_next, ev_prev, ev_mode, ev_auto,
      output reg  scan_start, output reg [7:0] media_index, output reg swap_req,
      output reg  [1:0] transition_mode, output reg [7:0] blend,
      output reg  transition_active, auto_play, output reg [2:0] state
  );
  ```
- **通用性**：★中。状态机骨架通用（自检/扫描/播放/转场四态），事件与周期参数可调；与具体模块的握手需按项目接线。

#### `control/seg_led.v` 【自研 + 复用解码器】
- **功能**：4 位七段数码管动态扫描显示；复用 `seg_led_decoder`（段码）/`seg_sel_decoder`（位选）。
- **接口**：
  ```verilog
  module seg_led (
      input  wire clk, rst_n, input wire [31:0] value, input wire [3:0] dot,
      output wire [3:0] seg_sel, output wire [7:0] seg_led
  );
  ```
- **通用性**：★高。位选/段码表已封装，`value` 为 4 位十六进制显示；换共阴/共阳只需改段码表。

### 4.8 `rtl/top.v` 与 `constraints/top.adc`

#### `rtl/top.v` 【自研】
- **功能**：系统顶层，按 4.1 数据流把全部模块总装：时钟/复位 → 视频时序 → 测试图 → 帧缓冲 → 参数处理 → OSD 合成 → 转场 → HDMI 输出；键盘 → 主控 → 数码管/LED；音频 PWM 与麦克风。端口即**真实板级引脚**。
- **接口（板级端口）**：`clk_50m, rst_n_in`；`hdmi_clk_p/d0_p/d1_p/d2_p`；`sd_clk,sd_cs,sd_mosi,sd_miso`；`audio_pwm`；`mic_cs,mic_miso,mic_sck,mic_rst_n`；`seg_sel[3:0],seg_led[7:0]`；`kb_row[3:0],kb_col[3:0]`；`led[7:0]`。
- **通用性**：★低（**项目总装**）。它是唯一与具体外设/引脚绑定的文件；其余模块尽量保持通用，便于替换与移植。

#### `constraints/top.adc` 【来源：官方例程】
- **功能**：引脚位置与 IO 标准约束（时钟/复位/HDMI(LVDS33)/SD/音频/麦克风/数码管/键盘/LED）；VGA 引脚已注释保留。
- **接口**：TD 语法 `set_pin_assignment { 信号 } { LOCATION = 引脚; IOSTANDARD = ...; }`，信号名对应 `top.v` 端口。
- **通用性**：★低（**板级强绑定**）。换板/换引脚需重写；已为拨码与蜂鸣器预留注释行。

### 4.9 `rtl/reuse/` — 官方复用（尽量不改）

| 文件 | 功能 | 接口要点 | 通用性 |
| :--- | :--- | :--- | :--- |
| `sd/sd_initial.v` | SD 初始化（CMD0/8/55/41） | `rst_n,SD_clk,SD_cs,SD_datain,SD_dataout,init_o,state` | ★中（SPI SD 通用） |
| `sd/sd_read.v` | 单块读 CMD17（512B） | `sec,read_req,mydata_o,myvalid_o,read_o...` | ★中 |
| `sd/sd_write.v` | 单块写 CMD24 | `sec,write_req,write_o...` | ★中（本项目只读，备用） |
| `sd/sd_pll.v` | 50→25MHz（模块名已改 `sd_pll`） | `refclk,reset,clk0_out` | ★低（IP） |
| `sdram/Sdram_Control_4Port.v` | 经典 4 端口 FIFO SDRAM 控制器 | WR1/2、RD1/2 的 data/req/addr/length/load/clk | ★中 |
| `sdram/{command,control_interface,sdr_data_path}.v` | 4 端口控制器子模块 | 内部 | ★低（配套） |
| `sdram/{Sdram_RD_FIFO,Sdram_WR_FIFO}.v` | 读写 FIFO（例化 `softfifo`） | 内部 | ★低（配套） |
| `sdram/{softfifo,ramfifo}.v` | 跨时钟 FIFO 软实现 | 内部 | ★中（通用FIFO实现） |
| `sdram/sdram.v` | EG_PHY_SDRAM_2M_32 硬核封装 | `clk,ras_n,cas_n,we_n,addr,ba,dq,cs_n,dm0-3,cke` | ★低（硬核） |
| `sdram/sdram_pll.v` | 100M/100M@90°（模块名已改 `sdram_pll`） | `refclk,reset,clk0..4_out` | ★低（IP） |
| `sdram/Sdram_Params.h` | 地址/数据宽度、SDRAM 时序参数（`include`） | 宏定义 | ★低（配置） |
| `misc/ascii_3216.v` | ASCII 32×16 字库 BRAM | `doa[7:0],addra[12:0],clka,rsta` | ★中 |
| `misc/key_filter.v` | 16 路按键 20ms 消抖 | `clk,rstn,key_in[15:0],key_deb[15:0]` | ★高 |
| `misc/keyboard_scan.v` | 4×4 矩阵键盘扫描 | `clk,RSTn,col[3:0],row[3:0],key[15:0]` | ★高 |
| `misc/spi_rx.v` | 16bit SPI 接收（含 SCK/CS 时序） | `clk_baud,sck,cs,miso,rst_n,data_out[15:0]` | ★中 |
| `misc/seg_led_decoder.v` | 4bit→7 段码 | `data_disp,dot_ena,seg_led[7:0]` | ★高 |
| `misc/seg_sel_decoder.v` | 2bit→位选 | `bit_disp,seg_sel[3:0]` | ★高 |

### 4.10 `ip/hdmi/` — 官方加密 IP（黑盒，禁止修改）

| 文件 | 功能 | 接口 |
| :--- | :--- | :--- |
| `hdmi_tx.vhd` | DVI/TMDS 发送顶层（VHDL wrapper） | `PXLCLK_I,PXLCLK_5X_I,RST_N,VGA_HS/VS/DE,RGB[23:0] -> HDMI_CLK_P/D2/D1/D0_P` |
| `DVITransmitter.enc.vhd` | 加密 DVI 发送核 | 内部黑盒 |
| `TMDSEncoder.enc.vhd` | 加密 8b/10b TMDS 编码 | 内部黑盒 |
| `SerializerN_1_lvds(.enc).vhd` | 加密 LVDS 串行化 | 内部黑盒 |
| `tx_pll.v` | 像素/5× 位时钟 PLL（**需按 720p 重配**） | `refclk,reset,extlock,clk0/1/2_out` |

> ⚠️ 这些文件**仅可黑盒例化、不可修改**；其为 DVI（无音频数据岛），故音频必须走板载 PWM。

---

## 5. 全局约定

- **视频总线**：`RGB565(16bit) + hs + vs + de + x[10:0] + y[10:0]`，全部由 `video_timing_720p` 提供时间基准；每级流水与 `hs/vs/de` 同步打拍，保证不撕裂/不错位。
- **复位**：低有效 `rst_n`，异步拉低、同步释放（`reset_sync`）。
- **跨时钟域**：多比特总线用 `async_fifo`；慢变电平用 `cdc_sync`；**会改变画面的控制量**（转场类型、缓冲指针）只在 `frame_start` 生效。
- **命名**：输入 `*_i`、输出 `*_o`（作者惯例见各模块）；时钟 `clk*`、复位 `rst*_n`。
- **存储映射**（SDRAM 2M×32，1 word=1 像素 RGB565）：
  帧缓冲A `0x000000`、帧缓冲B `0x0E1000`、音频环缓 `0x1C2000`、索引/暂存 `0x1E2000`。

## 6. 红线

1. 禁用一切处理器（含板上 Cortex-M0 软核），不外挂 MCU。
2. HDMI 加密 IP（`*.enc.vhd`）只黑盒例化，不可修改；其为 DVI，音频走 PWM。
3. 所有模式/转场切换只在 V-BLANK 内变更。
4. 素材统一：24bit 非压缩 BMP、48kHz WAV，放 SD 卡根目录。
