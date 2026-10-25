# 主工程源码说明（`project/src/`）

> 本目录是 **M0/M1/M2 唯一主线工程**，由 `legacy/hdmi_test_base/` 全量迁入，并按 `video/ audio/ hdmi/ control/` 归档自研模块。
> 功能：TF 卡 640×480 BMP → SDRAM 4 槽预载（运行期只读）→ 按行取 A/B → 行缓冲/溶解/滑动 → **640×480@60 HDMI 1.4b 音视频输出**（48kHz 测试音）。
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
│   │   ├── SD/                    # SD/BMP + frame_read_write + sdr_refresh_sweep + sdram（含未综合的双读实验源码）
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
  - `led[4]` 恒 0（预留）
  - `led[5]` 恒 0（预留）
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

> M2 的 A/B 转场必须遵守同一原则：**运行期只读**。转场时读两个槽（A/B），正好复用这个 4 槽结构。

### 6.5 闲置槽噪点与后台顺序扫描（M1 补丁）

**现象**：刚上电四张都干净；同一张图静止若干分钟后，切到其它槽会出现稀疏、固定位置的单像素噪点（彩色小点，密度随闲置时间增加）。

**定位结论**：

1. 正在显示的槽**始终干净**——它每帧被顺序读满 307200 字；
2. 闲置槽靠控制器自动刷新，但实测**保持不住**；把 `SELF_REFRESH_INTERVAL` 提高 4 倍、单独关闭控制器自刷新，都未能消除；
3. 按 128 字步长“点读”整片 SDRAM **完全无效**；说明这颗硬核只把“**顺序整段读**”当作有效访问。

**解决**：`sdr_refresh_sweep` 在每帧消隐期（`read_finish` 之后、下一个 `vs` 之前）顺序读 4 个槽的地址空间：

- **M1 实际窗口**：`read_finish` 发生在第 479 行末尾（`v_cnt≈524`），下一帧 `vs` 下降沿（`video_read_req`）发生在 `v_cnt=9`（即 `V_FP=10` 行 ≈ `320µs` ≈ `40k` 字/帧），跨帧连续推进，4 槽（1,228,800 字）约 31 帧读完一轮（≈0.52s）；
- **M2 窗口扩展与排空注意**：
  1. `color_bar.v` 中 `v_active` 在 `v_cnt==44 && h_cnt==15` 置起，但该行有效像素期间 `v_cnt` 已递增为 45；距首个有效像素（`h_cnt≈160`）仅 `5.8µs`，而 A+B 两行 1280 字最少需 `10.24µs`；因此 M2 首行 `y=0` 必须在 **`v_cnt=44`** 提前一整行（~`37.8µs`）开始预取，最后一行 `y=479` 在第 478 行（`v_cnt=523`）内即取完，随后到下一帧 `v_cnt=44` 之间约 44 行（`1.4ms`）全部空闲，轻松跑满 `150k` 字/帧；
  2. **M2 交接四步链**：**`最后一行取完 → 启动扫描 → 到 v_cnt=44 停止发 en → 排空 12~16 拍（保持 active=1） → 行读取接管`**，防止约 10 拍在途 `Sdr_rd_en` 污染无 `fifo_aclr` 的 BRAM 行缓冲（M2.0 先用 `tb_timing` 打出 `v_cnt/h_cnt/v_active/de` 波形核准延迟）；
- 读数据不写入 `rfifo`，对显示无任何影响；
- 实测静止 15 分钟以上切图无噪点。

> 代价：消隐期占用总线，LUT +89；不影响帧率、加载时间或画面。

### 6.6 M2 行缓冲 + 转场（已上板验证）

M2 读路径已从“整帧 FIFO”改为“按行 A/B”：

```
SDRAM → frame_line_read（每行 640 A + 640 B，计满 1280 个返回）
      → line_buffer A/B（各 2 bank，640×24 乒乓）
      → mixer（溶解 / 水平滑动）
      → video_post（亮度/对比度/OSD 挂载点，当前直通）
      → AXIS → HDMI
```

- `line_sched`：`v_cnt=44` 预取第 0 行，`45..523` 取第 1..479 行；提前一整行，留约 37.8µs；
- `frame_line_read`：A/B 各 640 字连续读，按 `Sdr_rd_en` 返回计数写行缓冲，杜绝行尾串道；
- `disp_ctrl`：`cur_idx/next_idx` 在 vs 锁存，64 帧（≈1.07s）完成一次转场；K3=0 溶解、1 滑动、2 直切；
- 后台扫描：最后一行取完后启动，下一帧首行预取前停止；停止后 `sdr_refresh_sweep` 保持 16 拍排空；
- 当前 bit：`project/out/main_project_m2_mixer.bit`（OSD/亮度仍为直通，队友后续接入 `video_post`）。

> **上板踩坑**：`frame_line_read` 最初在 `Sdr_busy` 时暂停发命令，一行 1280 字被拆成不连续小段，控制器返回节奏变化导致行内像素错位（纵向梳齿/短横虚线）。改为连续发完整 1280 个读命令后修复；与 M1 `frame_fifo_read` 的做法一致。

> 注意：自动轮播间隔已从 1s 改为 4s（`sd_card_bmp.AUTO_PERIOD_S=4`），否则 1s 转场会连续不断。


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
| M2 行读取 | `sim/tb_line_read.v` | ✅ 1280 字、A/B 地址与 sel/bank 全对 |
| M2 混合 | `sim/tb_mixer.v` | ✅ 溶解 0/128/255、滑动 dx=0/320/640 |
| M2 转场控制 | `sim/tb_disp_ctrl.v` | ✅ 溶解/滑动/直切进度 |
| M2 行调度 | `sim/tb_line_sched.v` | ✅ 44 预取、480 次 toggle |
| M2 行缓冲 | `sim/tb_line_buffer.v` | ✅ 双时钟 2048 字读写 |
| M2 视频链路 | `sim/tb_chain.v` | ✅ 480 行/帧、A→B 溶解后输出切换 |
| TD 综合/布线 | `main_project.al` | ✅ **Setup WNS +0.544ns / Hold WNS +0.003ns，0 失败端点**；LUT 4,216（21.51%）、REG 3,873、BRAM9K 28、DSP 2 |

---

## 8. 后续演进（M1–M4）

- **M1（已完成并封档，tag `m1-final`；噪点修复 tag `m1-patch`）**：**4 槽预载 + 运行期只读**；顶层只例化 `frame_read_write`（1 写 1 读）；双读源码保留但不参与综合；`video_delay` 双 RGB + `x/y`；`control/regs` 16 键/1Hz/数码管；`sdr_refresh_sweep` 消隐期顺序扫描 4 槽；
- **M2（行缓冲/转场已上板验证）**：`frame_line_read` + 2-bank 行缓冲 + `mixer`（溶解/滑动）+ `disp_ctrl`；亮度/对比度/OSD 留在 `video_post` 由队友接入；
- **M3**：L2 多谐波/双音伴奏波表合成 `synth_player` + `audio_viz`（声波曲线 + 8 段频谱）；
- **M4**：`timing.sdc` 最终复测、QSPI 固化、2h 烤机（复位同步/写 FSM 打拍已在 M1 完成）。
