# 纯 RTL 零处理器 HDMI 多媒体展陈终端（v3.3）

> 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 选题一
> 平台：安路 **EG4S20BG256**（大拇指 DMZ_EG4S20 核心板 + 综合底板，已验证符合参赛标准；片内 8MB SDRAM）
> 架构：**纯 RTL、零处理器** · 输出：**640×480@60 HDMI 1.4b（24-bit 视频 + 48kHz 音频）**

---

## 1. 当前工程状态与合并说明

> **工程基线声明**：
> - 当前**唯一主线工程**为 `hdmi_test/base/src/td_project/base.al`（已于 2026-10-23 上板跑通 M0 基础通路）；
> - 仓库内其余旧工程（`hdmi_test/hdmi_test.al` 720p 实验、`audio_test1`、`project/` 下旧 720p/16-bit 骨架）**均已弃用**；
> - **M1 第一步**即将 `hdmi_test/base/` 的全部已验证 RTL 与 IP 迁移合并至本目录 `project/`，作为最终发布的唯一工程。

| 模块 / 里程碑 | 状态 | 说明 |
|:--|:--|:--|
| **基础通路（M0）** | ✅ **已上板通过** | TF 卡 BMP + SDRAM 双缓冲 + 640×480 HDMI 1.4b + 48kHz 测试音 |
| 开发板合规性验证 | ✅ **已确认** | 大拇指 EG4S20 开发板已验证完全符合参赛标准 |
| **一写双读帧缓存（M1）** | 🟡 **进行中** | 复用 `frame_read_write` 架构扩展双读通道（`rfifo_a` + `rfifo_b`），保留 `WRITE_V_FLIP=1` |
| **A/B 溶解 + 滑动转场（M2）** | ⚪ 待合入 | 24-bit RGB888 `transition` + `swap_ctrl` |
| **中文滚动字幕 + 安路 Logo + 时间戳（M2）** | ⚪ 待合入 | 64 汉字 16×16 + ASCII 8×16 + 安路 Logo + `MM:SS` 时间戳 |
| **亮度/对比度调节 + 参数 OSD（M2）** | ⚪ 待合入 | 24-bit `video_proc` + OSD 实时参数回显 |
| **L2 多谐波波表合成 + 声波/频谱（M3）** | ⚪ 待合入 | 多谐波/伴奏合成 + 实时示波器声波曲线 + 8 段频谱能量柱 |
| **时序统一收敛 + QSPI 固化（M4）** | ⚪ 待合入 | 跨时钟域复位同步 + `frame_fifo_write` 打拍 + 单镜像固化 |

---

## 2. 文档索引（按阅读顺序）

| 顺序 | 文档 | 内容 |
|:--:|:--|:--|
| 1 | [`../项目计划.md`](../项目计划.md) | 项目目标、范围、资源评估、11月4日倒排计划 |
| 2 | [`doc/总体方案_v3.2.md`](doc/总体方案_v3.2.md) | **唯一真源**：冻结决策、一写双读帧缓存、扩展方案、资源核算 |
| 3 | [`doc/进度看板.md`](doc/进度看板.md) | **做到哪一步了**：M0–M4 进度、实测资源与增量预算 |
| 4 | [`doc/音频合成方案.md`](doc/音频合成方案.md) | L1 测试音 + L2 多谐波/复调波表合成 + 声波/频谱可视化 |
| 5 | [`doc/顶层框图.svg`](doc/顶层框图.svg) | 系统顶层数据流与控制流总图 |
| 6 | [`doc/框架说明.md`](doc/框架说明.md) | 模块层次、时钟复位、一写双读机制、24-bit 视频流水线、CDC |
| 7 | [`doc/接口对接表.md`](doc/接口对接表.md) | I1–I8 接口定义、双读帧缓存接口、寄存器与 OSD 映射 |
| 8 | [`doc/模块清单与分工.md`](doc/模块清单与分工.md) | 合并后的目录结构、模块状态、弃用清单 |
| 9 | [`doc/验证与里程碑.md`](doc/验证与里程碑.md) | M0–M4 验收清单、时序修复项、QSPI 固化流程 |
| 10 | [`doc/素材与字库规范.md`](doc/素材与字库规范.md) | BMP 规范、64 字中文字库、安路 Logo、TF 卡制作工具 |
| 11 | [`doc/引脚与硬件.md`](doc/引脚与硬件.md) | 引脚分配表、板卡硬件说明、3 PLL 配置 |
| 12 | [`doc/决策记录.md`](doc/决策记录.md) | 关键技术决策变更留痕（含复用 `frame_read_write` 决策） |

---

## 3. 目标目录结构（`base` 合并至 `project/` 后）

```
project/
├── rtl/
│   ├── top_tf_hdmi_audio.v          # 顶层（合并自 base，集成全部扩展）
│   ├── common/                      # por_gen / reset_sync / vpipe_delay
│   ├── SD/                          # 官方 SD/BMP + 一写双读 frame_read_write + sdram
│   ├── include/                     # global_def + sdr_as_ram 加密核
│   ├── video/                       # 24-bit transition / video_proc / test_pattern / axis
│   ├── osd/                         # text_layer / font_rom_cn / logo_rom / osd_layer
│   ├── audio/                       # tone_i2s / synth_player / audio_mux / audio_viz / I2S_rx / acr
│   ├── hdmi/                        # hdmi_1_4b_transmitter_core_wrapper / hdmi_phy_wrapper
│   ├── control/                     # keyboard_scan / key_filter / regs / seg_led
│   └── ip/                          # sys_pll / video_pll / PLL_HDMI_AUDIO / afifo
├── constraints/
│   ├── pin.adc                      # 引脚约束
│   └── timing.sdc                   # 时序约束（M4 完善异步时钟组与复位伪路径）
├── doc/                             # 全套设计文档 + 顶层框图.svg + tools/
├── main_project.al                  # TD 工程文件
└── README.md
```

---

## 4. 快速开始

1. 使用 **Anlogic TD** 打开主线工程（当前为 `hdmi_test/base/src/td_project/base.al`，合并后为 `project/main_project.al`）；
2. 综合 → 布局布线 → 下载 `.bit`（或烧写 QSPI Flash）；
3. TF 卡：格式化为 **FAT32**，根目录放入 `01.bmp`…`04.bmp`（640×480、24-bit RGB、非压缩）；
4. HDMI 接带喇叭/音频输出的显示器；
5. 上电即自动扫描图片、输出画面与 48kHz 音频；通过 4×4 矩阵键盘切换图片、自动轮播、转场模式、亮度/对比度、OSD 与音源。

---

## 5. 架构红线

1. **零处理器**：禁用软核 MCU 或外挂处理器，全部控制与算法纯 RTL 实现；
2. **加密 IP 只黑盒例化**：不修改 `sdr_*.enc.v` 与 `hdmi_1_4b_*.enc.v`；
3. **复用 `frame_read_write` 架构**：保持 32-bit 数据通路与 `WRITE_V_FLIP=1`，扩充双读通道实现转场；
4. **换帧与参数更新只在场消隐期（`vs`）生效**：严禁在有效扫描行内切换缓冲或突变 Alpha；
5. **流水线严格锁步**：24-bit 视频链每一级必须同步延迟 `rgb[23:0] / hs / vs / de / x / y`；
6. **单 bitstream + QSPI 固化上电自启**：基础要求与全部扩展要求集成于同一镜像。
