# 主工程源码说明（`project/src/`）

> 本目录是 **M0/M1 唯一主线工程**，由 `legacy/hdmi_test_base/` 全量迁入，并按 `video/ audio/ hdmi/ control/` 归档自研模块。
> 功能：TF 卡 640×480 BMP → SDRAM 双缓冲 → **640×480@60 HDMI 1.4b 音视频输出**（48kHz 测试音）。
> 官方基线：`lab_ex5_i2s`（APUG092 HDMI 1.4b + SD/）。
> 模块包含关系图：`../doc/模块层次图.svg`（谁例化了谁）；每个模块的功能/接口见对应 `.v` 顶部注释。

---

## 1. 打开方式

```
Anlogic TD → 打开：
project/src/td_project/main_project.al
```

- 顶层模块：`top`（`user_source/hdl_source/top_tf_hdmi_audio.v`）
- 器件：`EG4S20BG256`，TD 版本 ≥ 6.2
- 约束：`user_source/constraints_source/pin.adc` + `timing.sdc`

> 历史工程已归档到仓库根目录 `legacy/`，**不要混淆**。

---

## 2. 目录结构

```
project/src/
├── td_project/
│   ├── main_project.al            # TD 主工程（顶层 = top）
│   └── al_ip/PLL_HDMI_AUDIO.*     # 12.288MHz 音频 PLL
├── user_source/
│   ├── hdl_source/
│   │   ├── top_tf_hdmi_audio.v    # 顶层
│   │   ├── SD/                    # SD/BMP + frame_read_write_dual / frame_fifo_read_arb / rd_arbiter + sdram
│   │   ├── include/               # global_def.v + sdr_as_ram / sdr_init_ref / sdr_wrrd 加密核（位置固定）
│   │   ├── video/                 # test_pattern / video_rgb_to_axis（M2 增 transition/video_proc/osd）
│   │   ├── audio/                 # L1 测试音 / I2S_receiver / ACR（M3 增 synth_player/audio_viz）
│   │   ├── hdmi/                  # HDMI 1.4b 加密核（黑盒）+ PHY + 10:1 串行化
│   │   ├── control/               # keyboard_scan / key_filter / seg_led*
│   │   └── ip/                    # sys_pll / video_pll / afifo（TD IP）
│   └── constraints_source/
│       ├── pin.adc                # 本板引脚
│       └── timing.sdc             # 时钟约束
├── sim/                           # iverilog 语法检查 + 时序/音频 tb
└── tools/                         # BMP 生成/检查 + 输出图
```

### 2.1 代码注释规范

每个**自研** `.v` 文件开头统一使用同一块注释，依次给出：

```
//===== 文件名 — 一句话功能 =====
// 功能：      这个模块解决什么问题、数据怎么流动
// 时钟/复位：  各端口的时钟频率 / 复位极性
// 接口：      in/out 关键信号，位宽与含义
// 参数/常量：  parameter 与状态机编码（S_xxx）
// 内部例化：  本文件例化了哪些子模块
// 备注：      跨域处理、时序修复点、已知限制
```

- 新增模块请沿用该格式；
- **厂商加密核**（`include/sdr_*.enc.v`）与 **TD 生成的 IP**（`ip/*.v`、`al_ip/*`）只在文件头注明用途和配置，正文不要手改，重新生成会覆盖；
- 头注释只写“设计与契约”，不要复制代码逻辑。

> **路径约束**：`SD/sdram.v` 与 `include/sdr_init_ref.enc.v` 内部使用
> `` `include "../user_source/hdl_source/include/global_def.v" ``（相对 TD 工程目录）。
> 因此 `td_project/` 必须与 `user_source/` 保持同级，**不要随意上移工程文件**，
> 否则加密核与 Vendor RTL 的 include 会失效。

---

## 3. 引脚 / 交互

### HDMI
| 信号 | 引脚 |
|:--|:--|
| `HDMI_CLK_P` | P1 |
| `HDMI_D0_P` | N1 |
| `HDMI_D1_P` | P4 |
| `HDMI_D2_P` | J3 |

> 本板 **无 DDC/EDID**：`I_edid_read_trig=0`，DDC 引脚接内部线。

### TF 卡
| 信号 | 引脚 |
|:--|:--|
| `sd_ncs` | F13 |
| `sd_dclk` | F15 |
| `sd_mosi` | F14 |
| `sd_miso` | D14 |

### 键盘 / 数码管 / LED
- 4×4 矩阵：`kb_row=D9/F9/C10/E10`，`kb_col=E11/D11/C11/F10`
- `key_deb[0]`（第 4 行第 1 列）= **下一张**：只切换显示槽（瞬间完成，不加载）
- `key_deb[1]`（第 4 行第 2 列）= **自动轮播开关**（同样只切换槽）
- 其余按键：参数寄存器（亮度/对比度/转场/OSD/音源/可视化），M2/M3 使用；K11 参数复位
- 数码管（4 位，高位在左）：`[SD状态码][图片序号][转场/OSD][音源/可视化]`
- LED：
  - `led[0]` 音频 PLL 锁定
  - `led[1]` SDRAM 初始化完成
  - `led[2]` 首图已显示（4 槽预载完成）
  - `led[3]` 当前显示槽号最低位
  - `led[4]` 恒 0
  - `led[5]` 当前写入槽号最低位（预载完成后固定）
  - `led[6]` HDMI 视频锁定
  - `led[7]` 1Hz 心跳（0.5s 翻转）

---

## 4. 上板步骤

1. TF 卡格式化为 **FAT32**；
2. 根目录放 **`01.bmp`…`04.bmp`**（640×480、24bit、非压缩，文件连续）；
3. HDMI 接 **带喇叭/音频输出** 的显示器或电视；
4. TD 打开 `main_project.al` → 综合 → 布局布线 → 下载；
5. 上电后：首图显示 + 测试音（do/re/mi…）；`key1` 切下一张，`key2` 开关自动轮播（1Hz）。

---

## 5. 预期现象

| 项 | 预期 |
|:--|:--|
| 画面 | 640×480，稳定，无撕裂 |
| 音频 | 音阶测试音，循环 |
| 上电 | 约 1.2s 彩条（预载 4 张图），随后显示第 1 张 |
| 切图 | key1 **瞬间**切换到下一槽（无加载、无彩条） |
| 轮播 | key2 开启后 1Hz 切换（只改槽号） |
| 数码管 | `[SD状态][图片号][转场/OSD][音源/可视化]` |

---

## 6. 排查

| 现象 | 检查 |
|:--|:--|
| 全黑 | `audio_pll_lock`、`por_done`、HDMI 核复位、显示器输入源 |
| 有图无声 | 显示器音量/静音、HDMI 是否接对、`audio_valid` |
| 花屏 | SDRAM 初始化、`ext_mem_clk`/`clk_sft`、时序约束 |
| 读卡失败 | SD 引脚、FAT32、卡容量、`state_code` |
| 图片错位/颜色错 | BMP 是否 640×480/24bit、`WRITE_V_FLIP` |
| 无图但有彩条 | HDMI/PHY 正常，问题在 SD/BMP |

### 6.1 彩条诊断

`display_valid=0` 时输出 **8 条竖彩条 + 白边框**（`test_pattern_640x480.v`）。

| 现象 | 结论 |
|:--|:--|
| 有彩条 | HDMI/PHY/显示器链路正常 → 问题在 SD/BMP |
| 无彩条（黑屏/无信号） | HDMI/PHY/显示器链路本身有问题 |

### 6.2 数码管 `state_code`

| 值 | 含义 | 下一步 |
|:--|:--|:--|
| 0 | SD 未初始化 | 查卡是否插好、SPI 引脚、卡是否上电 |
| 1 | 空闲/就绪 | 等 `sd_card_bmp` 发起扫描 |
| 2 | 正在扫描/读 BMP 头 | 卡内没有符合要求的 BMP，或文件不连续 |
| 3 | 已找到 BMP，等写握手 | 查 `frame_read_write`/SDRAM 写口 |
| 4 | 正在写像素 | 写路径卡住/帧未完成 |

> `bmp_read` 匹配条件：**BM 头 + 640×480 + 24bit + compression=0**；top-down BMP 不匹配。

### 6.3 SDRAM 自检工具（源码保留，不参与综合）

`SD/sdram_selftest.v` 是定位“某个地址没更新”时写的调试工具，M1 封档时已从顶层和 `main_project.al` 移除，**不占用资源**。

需要复测存储时：把它重新接回 `App_wr_*` / `App_rd_*`（并给它一个按键触发），即可写唯一图案 307200 字再读回比对，报告首个错误地址与错误数。配套仿真为 `sim/tb_selftest.v`。

> M1 实测结论：该自检独占总线时 307200 字几乎全对（仅启动瞬间 4 字毛刺），说明 SDRAM 存储本身没有问题。

### 6.4 4 槽预载：开机只写、运行只读（M1 最终方案）

**实测结论**：只要“显示读”和“帧写入”同时在跑，写入就会丢字（静态横带）；加 burst 间隔保护无效，属于加密控制器内部行为。

最终方案：**把写从“运行期”挪到“开机期”**。

| 阶段 | 总线活动 | 屏幕 |
|:--|:--|:--|
| 开机预载（约 1.2s） | 只写（4 张图依次写入槽 0..3） | 彩条（加载提示） |
| 运行 / 切换 / 转场 | **只读** | 正常画面，切换瞬间完成 |

- SDRAM 槽位：`BUF0=0 / BUF1=307200 / BUF2=614400 / BUF3=921600`（4 槽共 1.2M 字 < 2M 字）；
- `sd_card_bmp` 在 `scan_done` 后按 `loaded_slot` 顺序预载，全部 `write_finish` 后才 `display_valid=1`；
- K1 / 自动轮播只改 `disp_buf_idx`，读引擎在下一帧边界换基地址 → **平滑、无撕裂、无加载提示**；
- 预载期间 `display_valid=0`，`fb_read_req` 被门控，保证“写的时候绝不在读”。

> M2 的双读/转场必须遵守同一原则：**运行期只读**。转场时读两个槽（A/B），正好复用这个 4 槽结构。

---

## 7. 本地验证

```powershell
cd project/src
powershell -ExecutionPolicy Bypass -File sim/run_syntax.ps1
powershell -ExecutionPolicy Bypass -File sim/run_sim.ps1
```

> 需要 `D:\iverilog\bin\iverilog.exe`；加密核/PLL/SDRAM 用 `sim/base_stubs.v` 空壳替代。

| 验证 | 方法 | 结果 |
|:--|:--|:--|
| 纯 RTL 语法 | `sim/run_syntax.ps1` | ✅ SYNTAX OK（仅 FIFO 位宽 warning） |
| 640×480 时序 | `sim/tb_timing.v` | ✅ 525 行/帧、307,200 像素/帧 |
| 音频链路 | `sim/tb_audio.v` | ✅ 20ms 内 `audio_valid≈960`、`acr_valid≈20` |
| 双读引擎（参考，不综合） | `sim/tb_fb_dual.v` | ✅ 2 帧连读，A/B 各 2048 字、0 错误、0 越界 |
| 16 键 / 数码管 / 1Hz | `sim/tb_regs.v` | ✅ 参数、转场、OSD、音源、复位、时间戳全通过 |
| TD 综合/布线 | `main_project.al` | ✅ **Setup WNS +0.289ns / Hold WNS +0.011ns，0 失败端点**；LUT 3,905（19.92%）、REG 3,833、BRAM9K 18、DSP 0 |

---

## 8. 后续演进（M1–M4）

- **M1（已完成并封档，tag `m1-final`）**：**4 槽预载 + 运行期只读**；顶层只例化 `frame_read_write`（1 写 1 读）；双读源码保留但不参与综合；`video_delay` 双 RGB + `x/y`；`control/regs` 16 键/1Hz/数码管；
- **M2**：24-bit `transition`（溶解 + 水平滑动）、`video_proc`（亮度/对比度）、`osd_composer`（64 字中文 + 安路 Logo + `MM:SS` + 参数回显）；
- **M3**：L2 多谐波/双音伴奏波表合成 `synth_player` + `audio_viz`（声波曲线 + 8 段频谱）；
- **M4**：`timing.sdc` 最终复测、QSPI 固化、2h 烤机（复位同步/写 FSM 打拍已在 M1 完成）。
