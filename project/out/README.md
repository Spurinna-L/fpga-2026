# project/out — 交付物与历史 bit

> 本目录**只放交付物与各里程碑的 bit / 时序报告**；SD 卡镜像、缩放测试图、仿真日志等
> 中间产物已在封档时移除（可用 `src/tools/` 里的脚本重新生成，见文末）。

## 1. 交付 bit

| 文件 | 说明 | 大小 | SHA256（前 8 位） |
|:--|:--|--:|:--|
| **`main_project_m3_merged.bit`** | **主交付**：图片缩放 + L2 合成 + 音频可视化 + 风格化滤镜 | 630,788 B | `CAAC1D47` |
| `main_project_m3_release.bit` | 已上板确认：图片缩放 + 斜切根治 + 字幕透明（无音视频新功能） | 629,624 B | `B6E39F44` |
| `main_project_m3_phasefix.bit` | 上板确认「画面笔直、边缘干净」的相位修复版 | 629,624 B | — |

主交付 bit 的实测（TD 6.2.1，2026-11-01）：

```
Setup +0.344ns / Hold +0.019ns，0 失败端点
LUT 12,116 (61.82%)  REG 6,557  BRAM9K 50 (78.12%)  DSP 12  IO 39
```

## 2. 版本链（按时间顺序，供答辩讲“怎么一步步走到这里”）

| bit | 里程碑 |
|:--|:--|
| `main_project_m1_final.bit` / `main_project_m1_patch.bit` | M1：4 槽预载 + 运行期只读；闲置槽噪点修复 |
| `main_project_m2_mixer/clean/proc/osd/scroll.bit` | M2：行缓冲/转场 → 亮度/对比度 → 参数 OSD → Logo → 滚动字幕 |
| `main_project_m2_bisect.bit` | M2 兜底组合（配 PC 预缩放卡），缩放出问题时的退路 |
| `main_project_m3_scale.bit` / `m3_fix2.bit` | M3 图片缩放（含两个上板 bug 修复） |
| `main_project_m3_rowlock.bit` / `m3_phasefix.bit` | 斜切根治（行锁定 + 字节相位修复，已上板确认） |
| `main_project_m3_release.bit` | 删诊断 + 字幕透明（已上板确认） |
| **`main_project_m3_merged.bit`** | 合并 branch2：L2 / 可视化 / 滤镜（**当前主交付**） |

## 3. 时序/面积报告

`*_timing.rpt` / `*_area.rpt` 为各里程碑 TD 导出的原始报告（M1/M2/M3），文档里引用的数字都出自这里。

## 4. 已移除的中间产物（可重新生成）

| 内容 | 生成方式 |
|:--|:--|
| `sd_card_m3_a.img` / `sd_card_m3_b.img` 等 SD 镜像（每个 64MB） | `python src/tools/sd_pack.py <bmp目录> -o sd_card.img`（见 `src/tools/README.md`） |
| `scale_test_bmp/`（多尺寸缩放测试图） | `python src/tools/gen_scale_test_bmp.py` |
| `src/sim/*.log`、`*.out`（仿真日志/可执行） | `sim/run_sim.ps1` 重新产生 |
| `src/td_project/main_project_Runs/`（TD 构建库） | 用 TD 打开 `main_project.al` 重新综合/布线 |

> `tb_sd_bmp` 依赖 `project/out/sd_card_m3_a.img`；镜像不存在时回归脚本会**自动跳过**该项
> （`run_sim.ps1` 里已有判断），不影响其它 25 项。
