# hdmi_test — HDMI 实验与基础通路

本目录有**两个工程**，用途不同，别打开错：

| 工程 | 打开文件 | 内容 | 状态 |
|:--|:--|:--|:--|
| **基础通路（当前主线）** | `base/src/td_project/base.al` | TF 卡 BMP → SDRAM 双缓冲 → **640×480 HDMI 1.4b（视频+音频）** | ✅ **2026-10-23 已上板验证**（正合并至 `project/`） |
| 720p 实验（已弃用） | `hdmi_test.al` | 自研 720p 时序 + 测试图 + **DVI** HDMI（无音频） | ❌ 已弃用（仅留作历史参考） |

> 基础通路基于官方 `lab_ex5_i2s`（APUG092 HDMI 1.4b + SD/），
> 引脚已改为我们板（无 DDC/EDID）；详见 `base/README.md`。

---

## 1. 快速开始

### 基础通路

1. TD 打开 `base/src/td_project/base.al`；
2. TF 卡 FAT32，根目录放 `01.bmp`…`04.bmp`（640×480、24bit、非压缩）；
3. HDMI 接带喇叭的显示器；
4. 综合 → 布局布线 → 下载；
5. 首图显示 + 测试音；key1 切图，key2 自动轮播。

### 720p 实验（只看历史/回退）

1. TD 打开 `hdmi_test.al`；
2. 综合下载；
3. 显示测试图/帧缓冲实验。

---

## 2. 目录

```
hdmi_test/
├── base/                 # ★ 基础通路（新）
│   ├── src/td_project/base.al
│   ├── src/user_source/hdl_source/...
│   ├── src/user_source/constraints_source/pin.adc
│   ├── src/sim/          # 语法检查 + stubs
│   └── README.md
├── rtl/                  # 720p 实验 RTL（旧）
├── ip/                   # 旧 DVI IP（720p 实验）
├── constraints/          # 720p 实验引脚
├── sim/                  # 720p 实验仿真 + 帧缓冲记录
├── hdmi_test.al          # 720p 实验工程
└── README.md             # 本文件
```

---

## 3. 与 v3.3 最终方案文档的关系

- `project/doc/总体方案_v3.2.md` 是**最终方案（v3.3）**；
- `base/` 是当前**唯一有效主线基线**，后续将直接迁移合并至 `project/` 作为发布工程；
- M1/M2 直接复用 `base` 已验证的 `frame_read_write` + `sdram (sdr_as_ram)` 架构，在 `frame_read_write` 内扩充第 2 路读通道（`rfifo_b` + `frame_fifo_read_b`）实现 A/B 交叉溶解与滑动转场，并接入 24-bit `video_proc` 与多图层 OSD（64字中文+安路Logo+时间戳+参数回显）；
- M3 合入 `synth_player`（L2 多谐波波表合成）+ `audio_viz`（实时声波曲线 + 8 段频谱柱）；
- M4 统一修复跨时钟域时序违例并完成 QSPI 固化。

---

## 4. 注意

- **本板 HDMI 无 DDC/EDID**：基础通路 `I_edid_read_trig=0`；若 HDMI 1.4b 核不出图/不出声，优先排查这一项。
- 旧 720p 工程用的是 **DVI IP**，没有音频；不要拿它当赛题基础通路。
- 加密 IP 只黑盒例化，不改 `.enc.v`。
