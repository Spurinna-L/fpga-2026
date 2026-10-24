# 测试图片制作与检查（一步到位）

> 目标：做出一张 **FPGA 一定能识别** 的 BMP：
> `BM` 头 + **640×480** + **24bit** + **非压缩** + **高度为正（bottom-up）** + 文件连续。

---

## 1. 最快路径：先用"已知正确"的测试图

本目录自带生成脚本，直接产出 4 张标准 BMP：

```powershell
cd D:\fpga_2026\project\src\tools
python gen_test_bmp.py
```

输出：

```
output_bmp/
├── 00_bars.bmp        # 8 条竖彩条 + 白边框
├── 01_gradient.bmp    # 横向渐变 + 竖线
├── 02_checker.bmp     # 40×40 棋盘格
└── 03_text.bmp        # FPGA / 640x480 / BMP TEST
```

每张都是 `921,654` 字节、`BM`、640×480、24bit、compression=0。
**先用这组图测试**，可以排除"自己图片有问题"。

---

## 2. 转换自己的图片

官方脚本：

```
D:\fpga_2026\EG4S20开发板\lab_ex5_i2s\doc\convert\convert_images_to_bmp.py
```

### 单张

```powershell
python convert_images_to_bmp.py  my.jpg  01.bmp
```

### 批量

1. 把图片放进 `input_images/`；
2. 运行 `python convert_images_to_bmp.py`；
3. 结果在 `output_bmp/`。

> 脚本会：转 RGB（去 alpha）、LANCZOS 缩放到 640×480、保存为 24bit 非压缩 BMP。

---

## 3. 上卡前必须检查

```powershell
python check_bmp.py output_bmp
```

期望输出：

```
[PASS] 00_bars.bmp  size=921654 sig=b'BM' w=640 h=480 bpp=24 comp=0 off=54 ...
ALL PASS
```

### 常见 FAIL 原因

| 报错 | 原因 | 解决 |
|:--|:--|:--|
| `签名不是 BM` | PNG/JPG 改后缀 | 用转换脚本 |
| `宽=xxx` | 不是 640 | 缩放 |
| `高=-480` | **top-down BMP** | 用官方转换脚本（Pillow 默认 bottom-up） |
| `位深=32` | 带 alpha | 转 RGB |
| `位深=8` | 调色板 BMP | 转 24bit |
| `压缩=1/2` | RLE 压缩 | 存非压缩 |
| `文件长度=xxx，期望 921654` | 行对齐/截断 | 用转换脚本 |

> `bmp_read.v` 的匹配条件是：
> `header_0=='B' && header_1=='M' && width[15:0]==640 && height[15:0]==480 && bit_count==24 && compression==0`。
> **高度为负**（top-down）会直接不匹配。

---

## 4. 写入 TF 卡（不要直接拖拽！）

官方脚本：

```
D:\fpga_2026\EG4S20开发板\lab_ex5_i2s\doc\convert\sync_to_sd.py
```

```powershell
# 假设 TF 卡是 E:
python sync_to_sd.py E: -s "D:\fpga_2026\project\src\tools\output_bmp" -n 4
```

它会：

1. 把卡上旧 BMP 的 `BM` 头改成 `XX`（防止 FPGA 扫到旧图）；
2. 删除卡上可见文件；
3. 把最多 4 张 BMP 连续写入根目录，并加 `00_`…`03_` 前缀。

然后：

1. 安全弹出；
2. 插到板子；
3. **再上电**（不要热插拔后直接跑）。

---

## 5. 为什么不能直接复制？

`bmp_read` **不读文件系统**，它是：

```
从 sector 0 开始，逐扇区扫 0x42 0x4D（'BM'）
找到后按 header 里的 file_len 直接跳扇区读像素
```

所以：

- **文件名不重要**，但 **文件必须连续**（不能碎片化）；
- **不能有旧图残留**（旧 BMP 的 `BM` 还在，会被扫到）；
- 文件头必须在 **扇区边界**（`sync_to_sd.py` 写入根目录，通常是 cluster 对齐）。

直接拖拽/删除旧图，很容易残留旧 `BM` 或产生碎片 → FPGA 读到旧图/错图/卡死。

---

## 6. 卡的建议

| 项 | 建议 |
|:--|:--|
| 容量 | 4–16GB（≤32GB） |
| 格式 | FAT32 |
| 目录 | 根目录 |
| 图片 | ≤4 张 |
| 插入 | 上电前插好 |

> `bmp_read` 的扫描范围是 sector 0–131071（约 64MB）；
> 图片放在根目录且连续写入时，通常几 MB 内就能扫到。
> 如果卡很大、碎片多，扫描可能较慢（10–20s）。

---

## 7. 一页命令汇总

```powershell
# 1) 生成已知正确的测试图
cd D:\fpga_2026\project\src\tools
python gen_test_bmp.py

# 2) 检查
python check_bmp.py output_bmp

# 3) 写入 TF 卡（E: 改成你的盘符）
python "D:\fpga_2026\EG4S20开发板\lab_ex5_i2s\doc\convert\sync_to_sd.py" E: -s "D:\fpga_2026\project\src\tools\output_bmp" -n 4

# 4) 安全弹出 → 插板 → 上电
```
