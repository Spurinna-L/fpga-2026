# 归档区 legacy/

> 本目录存放 **已弃用的历史工程**，仅作回溯参考，**不参与编译、不再维护**。
> 当前唯一主线工程：`project/src/td_project/main_project.al`。

---

## 1. 归档清单

| 目录 | 原位置 | 内容 | 弃用原因 |
|:--|:--|:--|:--|
| `hdmi_test_720p/` | `hdmi_test/` | 720p + DVI 实验工程（`hdmi_test.al`、`rtl/`、`ip/hdmi/` VHDL DVI 核、`constraints/`） | 分辨率与色深不符赛题，且 DVI 无音频数据岛 |
| `audio_test1/` | `audio_test1/` | R-2R DAC / WAV 音频实验 | 已被 HDMI 内嵌音频 + 板载合成取代 |
| `project_legacy_720p/` | `project/`（旧骨架） | 旧 720p / 16-bit RGB565 骨架（`rtl/`、`ip/`、`constraints/`、旧 `main_project.al`） | 4 端口 16-bit SDRAM + DVI 路线已废弃 |
| `hdmi_test_base/` | `hdmi_test/base/` | **M0 已验证基线快照**（合并前原样保留，含 `base_Runs/best_result/base.bit`） | 源码已迁入 `project/src/`，此处仅作回退备份 |

---

## 2. 使用建议

- **不要**在本目录内继续开发；
- 若主线工程出现无法定位的回归，可对比 `hdmi_test_base/` 中的原始实现；
- `hdmi_test_base/src/td_project/base_Runs/best_result/base.bit` 是 M0 上板验证通过的比特流，可作应急回退；
- 目录内的 `*_Runs/`、`log/` 等为 TD 生成物，已在 `.gitignore` 中忽略，不随仓库提交。
