# 主工程源码说明（`project/src/`）

> 本目录是 **M0–M3 唯一主线工程**，由 `legacy/hdmi_test_base/` 全量迁入，并按 `video/ audio/ hdmi/ control/` 归档自研模块。
> 功能：TF 卡 BMP（源图 160×120~1920×1080）→ `bmp_scale` 双线性适配 640×480 → SDRAM 4 槽预载（运行期只读）→ 按行取 A/B → 行缓冲/溶解/滑动 → 亮度/对比度 + 参数 OSD + Logo + 11 字滚动字幕 → **640×480@60 HDMI 1.4b 音视频输出**（48kHz 测试音）。
> 官方基线：`lab_ex5_i2s`（APUG092 HDMI 1.4b + SD/）。
> 模块包含关系图：`../doc/模块层次图.svg`（M1 基线；M2/M3 增量见 `../doc/框架说明.md` §2.2）；每个模块的功能/接口见对应 `.v` 顶部注释。

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
│   │   ├── SD/                    # SD/BMP + bmp_scale + frame_read_write + sdr_refresh_sweep + sdram（含未综合的双读实验源码）
│   │   ├── include/               # global_def.v + sdr_as_ram / sdr_init_ref / sdr_wrrd 加密核（位置固定）
│   │   ├── video/                 # 行读取/行缓冲/mixer/video_post/video_proc/OSD/Logo
│   │   ├── audio/                 # L1 测试音 / L2 synth_player / I2S_receiver / ACR
│   │   ├── hdmi/                  # HDMI 1.4b 加密核（黑盒）+ PHY + 10:1 串行化
│   │   ├── control/               # keyboard_scan / key_filter / regs / seg_led* / reset_sync
│   │   └── ip/                    # sys_pll / video_pll / afifo（TD IP）
│   └── constraints_source/
│       ├── pin.adc                # 本板引脚
│       └── timing.sdc             # 时钟约束
├── sim/                           # iverilog 语法检查 + 全部 M0–M3.3 testbench（27 项，fail-fast）
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
- 其余按键：K3 转场模式、K4 一键开关【参数黑条 + Logo + 右侧波形/频谱】、K5/K6 亮度 ±8、K7/K8 对比度 ±16、
  K9 音源（L1/L2）、K10 音色（L2）、K12 参数复位、K13 滚动字幕开关、K14 风格化滤镜循环（K11 预留）；
- 数码管（4 位，高位在左）：`[SD状态码][图片序号][转场/OSD][音源/可视化(0/1)]`
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

1. 用 [`tools/README.md`](tools/README.md) 的工具链生成 `sd_card.img` 并写到物理卡（`bmp_convert → check_bmp → sd_pack → Win32DiskImager/balenaEtcher`）；
2. **bit 与图片规范要匹配**：`main_project_m3_scale.bit` 接受 **160×120~1920×1080、24bit、非压缩、bottom-up**（行填充自动跳过，保持比例 + 黑边）；`main_project_m2_scroll.bit` 仍只认 **640×480**（打包时加 `--strict-640x480`）；镜像内按参数顺序对应槽 0..3；
3. 现成的 M3 上板镜像（4 张不同尺寸，已回读校验）：
   - `project/out/sd_card_m3_a.img`：640×480（旁路）/ 160×120 / 1920×1080 / 540×960
   - `project/out/sd_card_m3_b.img`：641×481（行填充）/ 1280×720 / 320×240 / 640×480
4. HDMI 接 **带喇叭/音频输出** 的显示器或电视；
5. TD 打开 `main_project.al` → 综合 → 布局布线 → 下载；
6. 上电后：首图显示 + 测试音（do/re/mi…）；`key1` 切下一张，`key2` 开关自动轮播（周期 4s）；右上角参数面板、左上角 Logo、底部滚动字幕默认显示。

---

## 5. 预期现象

| 项 | 预期 |
|:--|:--|
| 画面 | 640×480，稳定，无撕裂 |
| 音频 | 音阶测试音，循环 |
| 上电 | 彩条期间预载 4 张图（640×480 约 1.2s；含大图约 3~4s），随后显示第 1 张 |
| 切图 | key1 **瞬间**切换到下一槽（无加载、无彩条） |
| 轮播 | key2 开启后 4s 切换（只改槽号） |
| 参数 OSD | 右上角两行：TIME/IMG/BRT/CNT/TR；K4 开关 |
| 滚动字幕 | 底部红字（背景透明）11 字循环；K13 开关 |
| Logo | 左上角 32×32，与 OSD 同步开关 |
| 数码管 | `[SD状态][图片号][转场/OSD][音源/可视化]` |

---

## 6. 排查

| 现象 | 检查 |
|:--|:--|
| 全黑 | `audio_pll_lock`、`por_done`、HDMI 核复位、显示器输入源 |
| 有图无声 | 显示器音量/静音、HDMI 是否接对、`audio_valid` |
| 花屏 | SDRAM 初始化、`ext_mem_clk`/`clk_sft`、时序约束 |
| 读卡失败 | SD 引脚、镜像是否写对、图片是否连续、卡容量、`state_code` |
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

> `bmp_read` 匹配条件：**BM 头 + 24bit + compression=0 + 正高度 + 宽高 ≤1920×1080**；top-down BMP 不匹配。行填充由 `bmp_read` 跳过，`bmp_scale` 输出固定 640×480。

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
      → video_post（video_proc 亮度/对比度 + 参数 OSD + Logo + 滚动字幕）
      → AXIS → HDMI
```

- `line_sched`：`v_cnt=44` 预取第 0 行，`45..523` 取第 1..479 行；提前一整行，留约 37.8µs；
- `frame_line_read`：A/B 各 640 字连续读，按 `Sdr_rd_en` 返回计数写行缓冲，杜绝行尾串道；
- `disp_ctrl`：`cur_idx/next_idx` 在 vs 锁存，64 帧（≈1.07s）完成一次转场；K3=0 溶解、1 滑动、2 直切；
- 后台扫描：最后一行取完后启动，下一帧首行预取前停止；停止后 `sdr_refresh_sweep` 保持 16 拍排空；
- M2 行缓冲/转场 bit：`project/out/main_project_m2_mixer.bit`（完整版见 §6.7）。

> **上板踩坑**：`frame_line_read` 最初在 `Sdr_busy` 时暂停发命令，一行 1280 字被拆成不连续小段，控制器返回节奏变化导致行内像素错位（纵向梳齿/短横虚线）。改为连续发完整 1280 个读命令后修复；与 M1 `frame_fifo_read` 的做法一致。

> 注意：自动轮播间隔已从 1s 改为 4s（`sd_card_bmp.AUTO_PERIOD_S=4`），否则 1s 转场会连续不断。

### 6.7 M2 亮度/对比度 + 参数 OSD + Logo（✅ 已上板）

- `video_proc`：24-bit 三通道 `clamp((c-128)*contrast/128 + 128 + brightness, 0, 255)`，2 级流水；亮度 -64..+64（K5/K6），对比度 64..192（K7/K8，128 = 1.0x）；
- `video_param_latch`：38-bit 参数总线 2FF + 连续 8 拍稳定检测 + vs 下降沿整组锁存，避免多位中间码；
- `osd_composer` + `font_ascii_8x16`：右上角 160×34 面板：

  ```text
  TIME 00:00 IMG:1/4
  BRT:+00 CNT:128 TR:0
  ```

  字形纯白，非字形像素每通道 >>1（半透明黑底），面板外/行间空隙直通；
- `logo_overlay` + `logo_data_32x32`：左上角 32×32 Logo（RGB555 + 1bit opaque），透明区逐位直通；
- K4 同时开关参数面板与 Logo；OSD 默认开启；
- 源选择提前到 `video_post` 之前：无图彩条也会叠加亮度/OSD/Logo；
- 该阶段 bit：`project/out/main_project_m2_osd.bit`（无字幕版，Setup +0.346ns / Hold +0.011ns）。

### 6.8 M2 底部中文滚动字幕（✅ 已上板）

- `scroll_text_overlay`：16×16 红字位于 `y=448..463`，**背景透明**（只画字形像素）；纯组合，0 拍；
- 文案：`逐逻辑而行，赴创新之约` 共 **11 字**（`gen_cn_font_v.py` 生成，支持 1~16 字）；
- `font_cn_16x16`：11×16×16 = 2,816 bit，组合 LUT ROM，**0 BRAM**；
- 滚动：vs 下降沿 `pos-1`（1px/帧 ≈ 59.5px/s），整条 880px 循环约 14.8s；关闭时冻结；
- 开关：**K13**，与 K4（参数面板/Logo）独立，默认开；
- 当前主 bit：`project/out/main_project_m3_scale.bit`（含缩放，见 §6.9）
  （Setup +0.508ns / Hold +0.003ns；LUT 5,082、REG 4,212、BRAM9K 28、DSP 3）。

### 6.9 M3 图片缩放（✅ 已上板）

- **写通路**：`bmp_read`（真实 W/H、跳行填充、`src_ready` 反压）→ `bmp_scale`（双线性 → 640×480）→ `frame_read_write`；
  运行期读链路（`frame_line_read`/`mixer`/`video_post`）完全不变；
- **规格**：源图 160×120~1920×1080、24bit、非压缩、bottom-up；保持比例 + 黑边；640×480 走逐像素旁路；
- **行缓冲**：2×2048×24，带**行号标签**（只覆盖已被输出消费的行，缩小 ≥2 不死锁）；11 拍/像素；
- **容错**：`src_eof` 后不足 307200 像素时**补黑到满帧**（板端实测会少 450~510 个）；
- **诊断**：`top` 的 `localparam DEBUG_SEG`（默认 0）→ 1 时数码管显示 `[state][found][差额]`，LED4/5 = finish/bypass；
  诊断 bit：`project/out/main_project_m3_pad.bit`；
- **主 bit**：`project/out/main_project_m3_scale.bit`（Setup +0.110ns / Hold +0.011ns；LUT 7,379、REG 5,268、BRAM9K 43、DSP 11）；
- **测试镜像**：`project/out/sd_card_m3_a.img` / `sd_card_m3_b.img`（4 张不同尺寸，已回读校验）。


---

## 7. 本地验证

```powershell
cd project/src
powershell -ExecutionPolicy Bypass -File sim/run_syntax.ps1
powershell -ExecutionPolicy Bypass -File sim/run_sim.ps1
```

> 需要 `D:\iverilog\bin\iverilog.exe`；加密核/PLL/SDRAM 用 `sim/base_stubs.v` 空壳替代（脚本自动加 `-D SIM_STUBS`）。`run_sim.ps1` 在编译失败、仿真非零退出或 testbench 打印 `FAIL/TIMEOUT/ERR` 时立即终止，避免假通过。

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
| M2 亮度/对比度 | `sim/tb_video_proc.v` | ✅ 86 项，含 ±64 / 64/192 饱和 |
| M2 参数跨域 | `sim/tb_param_latch.v` | ✅ 9 项：稳定检测、vs 锁存、字符码 |
| M2 参数 OSD | `sim/tb_osd.v` | ✅ 37,527 项：面板坐标/字形/直通区 |
| M2 Logo | `sim/tb_logo_overlay.v` | ✅ 13,834 项：透明区直通、像素映射 |
| M2 滚动字幕 | `sim/tb_scroll_text.v` | ✅ 209 项：字库/位置/滚动/颜色/回绕 |
| M2 后处理集成 | `sim/tb_video_post.v` | ✅ 20 项：OSD 关断逐像素直通 + 2 拍边带 |
| M3 缩放读取/行填充 | `sim/tb_bmp_read.v` | ✅ 5×3 行填充、像素顺序、config/sop/eof |
| M3 缩放几何/黑边 | `sim/tb_bmp_scale.v` | ✅ 1:1/2×/16:9/竖图/奇数宽 |
| M3 源不足补黑 | `sim/tb_pad.v` | ✅ 只送 306700 像素仍输出 307200、补齐为黑 |
| M3 预载联调 | `sim/tb_bmp_pipeline.v` | ✅ 高速送数 + 反压，恰好 307200 像素 |
| M3 真卡回放 | `sim/tb_sd_bmp.v` | ✅ `sd_card_m3_a.img` 4 帧 × 307200 字 → `display_valid=1` |
| TD 综合/布线 | `main_project.al` | ✅ **Setup +0.110ns / Hold +0.011ns，0 失败**；LUT 7,379（37.65%）、REG 5,268、BRAM9K 43、DSP 11 |

> 说明：`tb_chain` 跑 9 个完整帧（约 151ms 仿真时间），iverilog 下约 4–5 分钟；`tb_sd_bmp` 约 4–6 分钟；其余 testbench 秒级完成。
> `run_sim.ps1 -Full` 额外跑大尺寸遍历 `tb_scale_fast`（约 10 分钟）。

---

## 8. 后续演进（M1–M4）

- **M1（已完成并封档，tag `m1-final`；噪点修复 tag `m1-patch`）**：**4 槽预载 + 运行期只读**；顶层只例化 `frame_read_write`（1 写 1 读）；双读源码保留但不参与综合；`video_delay` 双 RGB + `x/y`；`control/regs` 16 键/1Hz/数码管；`sdr_refresh_sweep` 消隐期顺序扫描 4 槽；
- **M2（✅ 已上板）**：`frame_line_read` + 2-bank 行缓冲 + `mixer`（溶解/滑动）+ `disp_ctrl` + `video_post`（亮度/对比度 + 参数 OSD + Logo + 11 字滚动字幕）；
- **M3（✅ 已上板 + 已合并）**：图片缩放（`bmp_read`/`bmp_scale` + `src_sop` 行锁定 + 斜切根治 + 补黑兜底）、L2 `synth_player`（K9/K10）、`audio_viz`（右侧竖带声波+8 段频谱，随 K4）、`video_fx`（K14 八模式滤镜）、字幕透明背景；
- **M4**：QSPI 固化、2h 烤机、演示视频/报告（`timing.sdc` 的 `audio_mclk ↔ clk` 异步组已在 M3 合并时补齐）。
