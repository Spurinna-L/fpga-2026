# 纯 RTL 零处理器 HDMI 多媒体展陈终端（v3.7）

> 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 选题一
> 平台：安路 **EG4S20BG256**（大拇指 DMZ_EG4S20 核心板 + 综合底板，已验证符合参赛标准；片内 8MB SDRAM）
> 架构：**纯 RTL、零处理器** · 输出：**640×480@60 HDMI 1.4b（24-bit 视频 + 48kHz 音频）**

---

## 1. 当前工程状态

> **工程基线声明**：
> - **唯一主线工程**：`project/src/td_project/main_project.al`；
> - 历史工程（720p + DVI 实验、R-2R 音频实验、旧 16-bit/720p 骨架）已全部归档至仓库根目录 `legacy/`，**不再参与编译**；
> - 冻结基线：tag `m1-final`（M1 基础）/ `m1-patch`（闲置槽噪点修复）；
> - 最终方案真源：[`doc/总体方案_v3.7.md`](doc/总体方案_v3.7.md)。

| 模块 / 里程碑 | 状态 | 说明 |
|:--|:--|:--|
| **基础通路（M0）** | ✅ 已上板 | TF 卡 BMP + SDRAM + 640×480 HDMI 1.4b + 48kHz 测试音 |
| **存储调度（M1）** | ✅ 已封档 | **开机 4 槽预载、运行期只读**；`frame_read_write`（1 写 1 读）+ `WRITE_V_FLIP=1`；K1/轮播瞬间切换，无横带 |
| **交互与状态（M1）** | ✅ 已封档 | 4×4 键盘、数码管、1Hz 心跳、参数复位 |
| **闲置槽保持（M1 补丁）** | ✅ 已上板 | `sdr_refresh_sweep` 消隐期顺序扫描 4 槽；静止 15 分钟以上切图无噪点 |
| **A/B 转场 + 亮度/OSD/Logo/字幕（M2）** | ✅ 已上板 | `frame_line_read` + 行缓冲；溶解/水平滑动；`video_post` 内亮度/对比度 + 参数 OSD + Logo + 11 字滚动字幕（**背景透明**） |
| **图片缩放（M3 扩展③）** | ✅ 已上板 | `bmp_read` 任意尺寸/行填充 + `bmp_scale` 双线性/保持比例黑边/640×480 旁路；行号标签行缓冲 + 源行首标志行锁定 + 源不足补黑 |
| **L2 合成 + 声波/频谱（M3 扩展⑤）** | 🟡 已并入主线，待上板 | `synth_player`（32 音 + 贝斯、3 音色）+ `wave_capture` + `spectrum_analyzer`（8 段，每路 3 级级联）+ `audio_viz`（右侧 160px 竖带）；K9 音源、K10 音色，可视化与 OSD 黑条共用 K4 两态开关 |
| **实时风格化滤镜（M3.3，创新点）** | 🟡 已并入主线，待上板 | `video_fx` 8 模式（直通/锐化/线稿/浮雕/卡通/灰度/反色/暖调），K14 循环；1 块行延迟 BRAM、0 DSP、固定 3 拍 |
| **QSPI 固化 + 烤机（M4）** | ⚪ 待开始 | 单镜像上电自启 + 2h 稳定性测试 |

**M1 补丁实测**：Setup `+0.174ns` / Hold `+0.019ns`，0 失败端点；LUT 3,994（20.38%）、REG 3,896、BRAM9K 18/64、DSP 0/29。
**M2 完整版实测**：Setup `+0.508ns` / Hold `+0.003ns`，0 失败；LUT 5,082（25.93%）、REG 4,212、BRAM9K 28/64、DSP 3/29；bit：`project/out/main_project_m2_scroll.bit`。
**M3 实测（branch2：L2 + 可视化）**：Setup `+0.541ns` / Hold `+0.019ns`，TNS 0 / FEP 0；LUT 8,026（40.95%）、REG 4,896（24.98%）、BRAM9K 29/64、DSP 4/29、PLL 3/4、IO 39。
**M3.1 实测（branch2：右侧竖带可视化）**：Setup `+0.792ns` / Hold `+0.003ns`，TNS 0 / FEP 0；LUT 9,055（46.20%）、REG 5,236（26.71%）、BRAM9K 29/64、DSP 4/29、PLL 3/4、IO 39。
**M3 交付 bit（main，图片缩放 + 字幕透明）**：Setup `+0.112ns` / Hold `+0.003ns`，0 失败；LUT 7,427（37.89%）、REG 5,307、BRAM9K 43/64、DSP 11/29。
**M3 合并版（图形缩放 + L2 + 可视化 + 滤镜）**：Setup `+0.344ns` / Hold `+0.019ns`，0 失败端点；LUT **12,116（61.82%）**、REG 6,557、BRAM9K **50/64（78.12%）**、DSP 12/29。

> **当前主 bit**：`project/out/main_project_m3_release.bit`（图片缩放 + 字幕透明，已上板验证；629,624 B，SHA256 `B6E39F44…D2DFCD`）。
> **合并版 bit**：`project/out/main_project_m3_merged.bit`（630,788 B，SHA256 `CAAC1D47…B72053`，待上板复测）。

---

## 2. 文档索引（按阅读顺序）

| 顺序 | 文档 | 内容 |
|:--:|:--|:--|
| 1 | [`../项目计划.md`](../项目计划.md) | 项目目标、范围、资源评估、11 月 4 日倒排计划 |
| 2 | [`doc/总体方案_v3.7.md`](doc/总体方案_v3.7.md) | **唯一真源**：冻结决策、4 槽预载架构、扩展方案、资源核算 |
| 3 | [`doc/进度看板.md`](doc/进度看板.md) | **做到哪一步了**：M0–M4 进度、实测资源与增量预算 |
| 4 | [`doc/音频合成方案.md`](doc/音频合成方案.md) | L1 测试音 + L2 多谐波/复调波表合成 + 声波/频谱可视化 |
| 5 | [`doc/顶层框图.svg`](doc/顶层框图.svg) | 系统顶层数据流总图（M1 基线；M2 视频链见框架说明 §2.2） |
| 6 | [`doc/框架说明.md`](doc/框架说明.md) | 模块层次、时钟复位、4 槽预载、M2/M3 视频链（行缓冲/混合/亮度/OSD/缩放）、CDC |
| 7 | [`doc/接口对接表.md`](doc/接口对接表.md) | I1–I11 接口定义、行读取、参数锁存、OSD/Logo 叠加 |
| 8 | [`doc/模块清单与分工.md`](doc/模块清单与分工.md) | 目录结构、模块状态、弃用清单 |
| 9 | [`doc/验证与里程碑.md`](doc/验证与里程碑.md) | M0–M4 验收清单、噪点定位过程、QSPI 固化流程 |
| 10 | [`doc/素材与字库规范.md`](doc/素材与字库规范.md) | BMP 规范、11 字滚动字库、Logo 点阵、ASCII 字库生成工具、TF 卡制作 |
| 11 | [`doc/引脚与硬件.md`](doc/引脚与硬件.md) | 引脚分配表、板卡硬件说明、3 PLL 配置 |
| 12 | [`doc/决策记录.md`](doc/决策记录.md) | 关键技术决策与废弃方案留痕 |

---

## 3. 目录结构

```
project/
├── src/
│   ├── td_project/
│   │   ├── main_project.al          # TD 主工程
│   │   └── al_ip/                   # PLL_HDMI_AUDIO（12.288MHz）
│   ├── user_source/
│   │   ├── hdl_source/
│   │   │   ├── top_tf_hdmi_audio.v  # 顶层
│   │   │   ├── SD/                  # 官方 SD/BMP + frame_read_write + sdr_refresh_sweep + sdram
│   │   │   ├── include/             # global_def + sdr_as_ram/sdr_init_ref/sdr_wrrd 加密核
│   │   │   ├── hdmi1.4b_transmitter_core/  # HDMI 1.4b 加密核（黑盒）
│   │   │   ├── ip/                  # sys_pll / video_pll / afifo（TD IP）
│   │   │   ├── video/               # 行读取/行缓冲/mixer/video_post/OSD/Logo/滚动字幕
│   │   │   ├── audio/               # L1 测试音 / I2S / ACR（M3 余项加 synth_player / audio_viz）
│   │   │   └── control/, hdmi/, ip/ # 键盘/数码管/复位、HDMI 核+PHY、PLL/FIFO
│   │   └── constraints_source/
│   │       ├── pin.adc              # 引脚约束
│   │       └── timing.sdc           # 时序约束
│   ├── sim/                         # iverilog 语法检查 + M0–M3.3 testbench（27 个，默认跑 26，fail-fast）
│   └── tools/                       # BMP 生成/检查 + output_bmp/
├── doc/                             # 设计文档 + SVG 框图
├── out/                             # bit 与综合/时序报告
└── README.md
```

> **路径约束**：`SD/sdram.v` 与 `include/sdr_init_ref.enc.v` 用
> `` `include "../user_source/hdl_source/include/global_def.v" ``（相对 TD 工程目录），
> 所以 `src/td_project/` 必须与 `src/user_source/` 保持同级，加密核与 Vendor RTL 不得移动。

---

## 4. 快速开始

1. 使用 **Anlogic TD** 打开主线工程 `project/src/td_project/main_project.al`；
2. 综合 → 布局布线 → 下载 `.bit`（或烧写 QSPI Flash）；
3. TF 卡：用 [`src/tools/README.md`](src/tools/README.md) 的工具链生成 `sd_card.img` 并写到物理卡（`bmp_convert → check_bmp → sd_pack → Win32DiskImager/balenaEtcher`）；
   当前主 bit 支持 **160×120~1920×1080、24bit、非压缩、bottom-up**（预载时缩放到 640×480）；
4. HDMI 接带喇叭/音频输出的显示器；
5. 上电约 1~4s（取决于素材大小）后进入第 1 张图；K1 切图、K2 自动轮播（4s）、K3 切换溶解/滑动/直切、
   K4 一键开关「参数黑条 + Logo + 右侧波形/频谱」、K5–K8 亮度/对比度、K9 音源（L1/L2）、K10 音色、
   K12 参数复位、K13 开关滚动字幕、K14 切换风格化滤镜（8 模式）。

---

## 5. 架构红线

1. **零处理器**：禁用软核 MCU 或外挂处理器，全部控制与算法纯 RTL 实现；
2. **加密 IP 只黑盒例化**：不修改 `sdr_*.enc.v` 与 `hdmi_1_4b_*.enc.v`；
3. **运行期只读**：上电预载 4 个槽，运行期只切换 `disp_buf_idx`，永不写 SDRAM；
4. **换帧与参数更新只在场消隐期（`vs`）生效**：严禁在有效扫描行内切换缓冲或突变 Alpha；
5. **流水线严格锁步**：24-bit 视频链每一级必须同步延迟 `rgb[23:0] / hs / vs / de / x / y`；
6. **单 bitstream + QSPI 固化上电自启**：基础要求与全部扩展要求集成于同一镜像。
