# base — TF 卡 BMP + HDMI 1.4b 音视频基础通路

> 这是 **M0/M1 基础通路**工程：从 TF 卡读取 640×480 BMP，经 SDRAM 双缓冲，
> 以 640×480@60 HDMI 1.4b 输出，并内嵌 48kHz 测试音。
> 官方基线：`lab_ex5_i2s`（APUG092 HDMI 1.4b + SD/）。

---

## 1. 打开方式

```
Anlogic TD → 打开：
hdmi_test/base/src/td_project/base.al
```

顶层模块：`top`（`top_tf_hdmi_audio.v`）

> 旧工程 `hdmi_test/hdmi_test.al` 是 720p + DVI 的实验，保留作参考，**不要混淆**。

---

## 2. 目录

```
base/src/
├── td_project/
│   ├── base.al                 # TD 工程（本文件）
│   └── al_ip/PLL_HDMI_AUDIO.*  # 12.288MHz 音频 PLL
├── user_source/
│   ├── hdl_source/
│   │   ├── top_tf_hdmi_audio.v # 顶层
│   │   ├── SD/                 # SD/FAT32/BMP/帧缓存（官方）
│   │   ├── include/            # global_def + SDRAM 加密核
│   │   ├── hdmi1.4b_transmitter_core/  # HDMI 1.4b 加密核
│   │   ├── ip/                 # sys_pll/video_pll/afifo
│   │   ├── keyboard_scan.v     # 4×4 矩阵扫描（自研）
│   │   ├── key_filter.v        # 20ms 消抖
│   │   ├── seg_led.v           # 4 位数码管
│   │   └── ...
│   └── constraints_source/
│       ├── pin.adc             # 我们板引脚
│       └── timing.sdc          # 时钟约束
└── sim/
    ├── base_stubs.v            # 仅 iverilog 语法检查用
    └── run_syntax.ps1          # 语法检查脚本
```

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
- `key_deb[0]`（第 4 行第 1 列）= **下一张**
- `key_deb[1]`（第 4 行第 2 列）= **自动轮播开关**
- 数码管：显示 `state_code`（最低位）
- LED：
  - `led[0]` 音频 PLL 锁定
  - `led[1]` SDRAM 初始化完成
  - `led[2]` 首图已显示
  - `led[3]` 当前显示缓冲（A/B）
  - `led[4]` 帧写完成
  - `led[5]` 当前写缓冲
  - `led[6]` HDMI 视频锁定
  - `led[7]` 常亮（心跳）

---

## 4. 上板步骤

1. TF 卡格式化为 **FAT32**；
2. 根目录放 **`01.bmp`…`04.bmp`**（640×480、24bit、非压缩）；
   - 建议用官方 `doc/convert/convert_images_to_bmp.py` + `sync_to_sd.py`；
3. HDMI 接 **带喇叭/音频输出** 的显示器或电视；
4. TD 打开 `base.al` → 综合 → 布局布线 → 下载；
5. 上电后：
   - 首图加载完成前黑屏（正常）；
   - 首图显示 + 测试音（do/re/mi…）；
   - `key1` 切下一张，`key2` 开关自动轮播（1Hz）。

---

## 5. 预期现象

| 项 | 预期 |
|:--|:--|
| 画面 | 640×480，稳定，无撕裂 |
| 音频 | 音阶测试音，循环 |
| 切图 | key1 立即切下一张（双缓冲） |
| 轮播 | key2 开启后 1Hz 切换 |
| 数码管 | `state_code`（0/1/2/3/4…） |

---

## 6. 排查

| 现象 | 检查 |
|:--|:--|
| 全黑 | `audio_pll_lock`、`por_done`、HDMI 核复位、显示器输入源 |
| 有图无声 | 显示器音量/静音、HDMI 是否接对、`audio_valid` |
| 花屏 | SDRAM 初始化、`ext_mem_clk`/`clk_sft`、时序约束 |
| 读卡失败 | SD 引脚、FAT32、卡容量、`state_code` |
| 图片错位/颜色错 | BMP 是否 640×480/24bit、`WRITE_V_FLIP` |
| 无 EDID 相关异常 | 本板无 DDC；若核不出图，先查 `I_edid_read_trig` 是否确实为 0 |

---

## 7. 后续演进说明（M1–M4 合并至 `project/`）

- **帧缓存升级**：直接复用本工程已验证的 `frame_read_write` + `sdram (sdr_as_ram)` 架构（保留 32-bit 与 `WRITE_V_FLIP=1`），在 `frame_read_write` 内扩充第二路读通道（`rfifo_b` + `frame_fifo_read_b`）实现双读锁步输出；
- **视频与 OSD 扩展（M2）**：合入 24-bit `transition`（A/B 交叉溶解 + 水平滑动）、24-bit `video_proc`（亮度/对比度）、`osd_composer`（64字中文滚动标语 + 安路 Logo + 动态时间戳 `MM:SS` + 实时参数回显）；
- **音频与可视化扩展（M3）**：合入 L2 多谐波/双音伴奏波表合成（`synth_player`）+ 实时示波器声波曲线与 8 段频谱能量柱（`audio_viz`）；
- **时序收敛与固化（M4）**：统一添加各时钟域 `reset_sync`、完善 `timing.sdc` 并对 `frame_fifo_write` 打拍，完成 QSPI 固化。

---

## 8. 语法检查

```powershell
cd hdmi_test/base/src
powershell -ExecutionPolicy Bypass -File sim/run_syntax.ps1
```

> 需要 `D:\iverilog\bin\iverilog.exe`。该检查只验证纯 RTL 语法，加密核/PLL/SDRAM 用 `sim/base_stubs.v` 空壳替代。

---

## 9. 已完成的本地验证

| 验证 | 方法 | 结果 |
|:--|:--|:--|
| 纯 RTL 语法 | `sim/run_syntax.ps1` | ✅ SYNTAX OK（仅 FIFO 位宽 warning） |
| 640×480 时序 | `sim/tb_timing.v` | ✅ **525 行/帧、307,200 像素/帧**（连续 3 帧） |
| 音频链路 | `sim/tb_audio.v` | ✅ 20ms 内 `audio_valid=959`（≈48kHz）、`acr_valid=19`（≈20 次） |

运行：

```powershell
cd hdmi_test/base/src
powershell -ExecutionPolicy Bypass -File sim/run_sim.ps1
```

> 说明：SD/FAT32/BMP 与 HDMI 加密核无法在 iverilog 中完整仿真；
> 这两段沿用官方已验证实现，上板重点验证"HDMI 1.4b 核在本板无 EDID 时能否出图/出声"。

---

## 10. 上板诊断（先看这三样）

### 10.1 无图时的彩条

`display_valid=0` 时，画面输出 **8 条竖彩条 + 白边框**（`test_pattern_640x480.v`）。

| 现象 | 结论 |
|:--|:--|
| 有彩条 | HDMI/PHY/显示器链路正常 → 问题在 SD/BMP |
| 无彩条（黑屏/无信号） | HDMI/PHY/显示器链路本身有问题（即使 `led[6]` 亮） |

### 10.2 数码管 `state_code`

| 值 | 含义 | 下一步 |
|:--|:--|:--|
| 0 | SD 未初始化 | 查卡是否插好、SPI 引脚、卡是否上电 |
| 1 | 空闲/就绪 | 等 `sd_card_bmp` 发起扫描 |
| 2 | 正在扫描/读 BMP 头 | 若长时间停 2：卡内没有符合要求的 BMP，或文件不连续 |
| 3 | 已找到 BMP，等写握手 | 查 `frame_read_write`/SDRAM 写口 |
| 4 | 正在写像素 | 若长时间停 4：写路径卡住/帧未完成 |

> `bmp_read` 的匹配条件很严：**BM 头 + 640×480 + 24bit + 非压缩（compression=0）**。
> 高度为负（top-down BMP）不匹配；请用官方 `convert_images_to_bmp.py` 生成。

### 10.3 LED

| LED | 含义 | 正常 |
|:--|:--|:--|
| 0 | 音频 PLL 锁定 | 亮 |
| 1 | SDRAM 初始化完成 | 亮 |
| 2 | **首图已显示** | 有图后亮 |
| 3 | 当前显示缓冲 | 随切图变化 |
| 4 | 帧写完成 | 每加载一张闪一下 |
| 5 | 当前写缓冲 | 随切图变化 |
| 6 | HDMI 视频锁定 | 亮 |
| 7 | 心跳 | 亮 |

### 10.4 TF 卡检查清单

- [ ] FAT32（或至少文件连续；`bmp_read` 是**按扇区扫 BM 头**，不依赖文件系统）
- [ ] 根目录 `01.bmp`…`04.bmp`
- [ ] 640×480、24-bit、**非压缩**
- [ ] 文件**连续**（用官方 `sync_to_sd.py`，不要直接在电脑上删旧图）
- [ ] 卡插好后再上电
- [ ] 若卡很大，扫描 0–64MB 可能较慢，先等 10–20s

> 快速生成/检查：
> `python tools/gen_test_bmp.py` 生成 4 张已知正确的图；
> `python tools/check_bmp.py output_bmp` 检查；
> 写卡用官方 `sync_to_sd.py`。详见 `src/tools/README.md`。
