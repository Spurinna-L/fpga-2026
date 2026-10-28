# 图片转换、校验与 SD 卡打包工具链

> 目标：把任意图片变成 FPGA **一定能读对** 的 24-bit BMP，并生成
> **连续扇区、无碎片、可复现** 的 SD 卡镜像。
>
> 当前 RTL 不解析 FAT32：`bmp_read.v` 从 sector 0 开始逐扇区扫 `'BM'`，
> 命中后按 BMP 头里的 `file_len` 连续读取。因此 **BMP 文件必须连续**。
> Windows 直接拖拽复制不保证连续，官方 `sync_to_sd.py` 也只是“顺序复制”，
> 不能作为最终可靠方案。

---

## 1. 一页流程

```powershell
cd D:\fpga_2026\project\src\tools

# 0) 先确认板上 bit：
#    main_project_m3_scale.bit → 支持 160×120~1920×1080（缩放）
#    main_project_m2_scroll.bit → 只支持 640×480（必须加 --strict-640x480）

# 1) 图片转 24-bit bottom-up BMP（把 input_images 换成你的素材目录）
python bmp_convert.py input_images -o output_bmp

# 2) 校验（M3 缩放 bit 用默认范围；M2 bit 加 --strict-640x480）
python check_bmp.py output_bmp

# 3) 打包成 64MB 原始镜像
python sd_pack.py output_bmp\00_bars.bmp output_bmp\01_gradient.bmp `
                  output_bmp\02_checker.bmp output_bmp\03_text.bmp `
                  -o output_sd\sd_card.img --sha256

# 4) 模拟 RTL 扫描，确认镜像能被识别
python sd_verify.py output_sd\sd_card.img --expect 4

# 5) 用 Win32DiskImager / balenaEtcher 写到物理 SD 卡
#    注意：写到 PhysicalDrive，不是 D:/E: 盘符
```

写完后插卡、上电。Windows 若提示“需要格式化”，**不要格式化**。

---

## 2. 脚本一览

| 脚本 | 作用 | 依赖 |
|:--|:--|:--|
| `bmp_convert.py` | PNG/JPG/WebP/TIFF → 24-bit bottom-up BMP | Pillow |
| `check_bmp.py` | 检查 BMP 头、尺寸、位深、压缩、行填充、文件长度 | 无 |
| `sd_pack.py` | 1~4 张 BMP → 连续扇区原始 `.img` + manifest | 无 |
| `sd_verify.py` | 按 RTL 的方式扫描镜像/物理卡，确认能找到 BMP | 无 |
| `gen_test_bmp.py` | 生成 4 张 640×480 已知正确测试图 | Pillow |
| `gen_scale_test_bmp.py` | 生成 M3 多尺寸测试图（320/640/1280/1920/奇数宽/竖图） | Pillow |
| `test_tools.py` | 工具链冒烟测试（转换/校验/打包/扫描） | Pillow |

> `check_bmp.py`、`sd_pack.py`、`sd_verify.py` 可以互相导入，建议始终在本目录下运行。

---

## 3. BMP 硬性规范

| 项 | M2 bit（`m2_scroll`） | M3 bit（`m3_scale`） |
|:--|:--|:--|
| 分辨率 | **640×480** | **160×120 ~ 1920×1080** |
| 输出到屏幕 | 640×480 | 640×480（RTL 缩放 + 黑边） |
| 位深 | 24-bit | 24-bit |
| 压缩 | `BI_RGB=0` | `BI_RGB=0` |
| 行序 | bottom-up（高度为正） | bottom-up（高度为正） |
| 行对齐 | 4 字节 | 4 字节 |
| 文件长度 | 921,654 字节 | 随尺寸变化 |
| 数量 | 最多 4 张 | 最多 4 张 |

**不支持**：

- PNG/JPG 直接改后缀；
- 8-bit 调色板、16-bit、32-bit（带 alpha）；
- RLE 压缩；
- top-down（高度为负）BMP；
- 超过 1920×1080 的源图（先缩小）。

> `main_project_m3_scale.bit` 的 `bmp_read.v` 只检查 **24bit / 非压缩 / 正高度 / 宽高 ≤1920×1080**，
> 行填充由 RTL 跳过；`main_project_m2_scroll.bit` 仍硬匹配 `width==640 && height==480`，
> 用 M2 bit 时所有检查/打包命令都要加 `--strict-640x480`。

---

## 4. `bmp_convert.py`

```powershell
# 单张：输出到 output_bmp/<原名>.bmp
python bmp_convert.py photo.jpg

# 单张：指定输出文件
python bmp_convert.py photo.jpg -o output_bmp\01.bmp

# 批量：输入目录 → 输出目录
python bmp_convert.py input_images -o output_bmp

# 限制最大尺寸（默认 1920×1080，只缩小不放大）
python bmp_convert.py photo.jpg --max 1280x720

# 保留原始尺寸（超过 RTL 上限时 check_bmp 会报错）
python bmp_convert.py photo.jpg --no-resize

# 透明 PNG 合成背景色（默认黑色）
python bmp_convert.py logo.png --bg FFFFFF
```

行为：

- 自动按 EXIF 方向旋转手机照片；
- 去 alpha，统一转 RGB；
- 只缩小、不放大，保持比例；
- 保存为 BMP 后自动用 `check_bmp` 的逻辑复检；
- 输出始终是 24-bit、非压缩、bottom-up。

---

### 4.1 M3 缩放测试图

```powershell
python gen_scale_test_bmp.py
```

输出到 `output_scale_bmp/`：

| 文件 | 用途 |
|:--|:--|
| `10_640x480.bmp` | 1:1 旁路，必须与 M2 逐像素一致 |
| `11_320x240.bmp` | 2 倍放大 |
| `12_160x120.bmp` | 4 倍放大（M3 下限） |
| `13_1280x720.bmp` | 16:9 → 上下黑边 |
| `14_1920x1080.bmp` | 16:9 → 上下黑边（M3 上限） |
| `15_641x481.bmp` | 奇数宽度 → 行填充 1 字节 |
| `16_540x960.bmp` | 竖图 → 左右黑边 |

每张图都有白框、中心十字、网格和四角纯色块，方向/比例/黑边错了很容易看出来。

---

## 5. `check_bmp.py`

```powershell
# M3 默认范围：160×120 ~ 1920×1080
python check_bmp.py output_bmp

# M2 当前 bit：必须 640×480
python check_bmp.py output_bmp --strict-640x480

# 检查单张，并自定义范围
python check_bmp.py 01.bmp --min 320x240 --max 1280x720
```

输出示例：

```text
[PASS] 00_bars.bmp   921654 B  640x480  24bpp  stride=1920  pad=0  bottom-up=True
[WARN] 每行有 1 字节填充（奇数宽度/非 4 倍数宽度）
ALL PASS
```

会检查：

- `BM` 签名、DIB 头、planes；
- 24bpp、compression=0；
- 高度为正（bottom-up）；
- `file_size` 与实际文件长度一致；
- `offset + stride*height <= 文件长度`；
- 行填充 `stride = (W*3 + 3) & ~3`；
- 尺寸是否在 M2/M3 范围内。

退出码：`0` 全部通过，`2` 有失败。

---

## 6. `sd_pack.py`

```powershell
# 4 张图，按参数顺序对应 SDRAM 槽 0..3
python sd_pack.py 01.bmp 02.bmp 03.bmp 04.bmp

# 从目录取（按文件名排序）
python sd_pack.py output_bmp -o output_sd\sd_card.img

# M2 当前 bit
python sd_pack.py output_bmp -o output_sd\sd_card.img --strict-640x480

# 不足 4 张时补纯黑 640×480，保证 4 个槽位都有确定内容
python sd_pack.py 01.bmp 02.bmp --fill-missing

# 覆盖旧镜像
python sd_pack.py output_bmp -o output_sd\sd_card.img --force
```

默认行为：

| 项 | 默认值 |
|:--|:--|
| 镜像大小 | **64MB**（正好覆盖 RTL 的 `SCAN_MAX_SECTOR=131071`） |
| 起始 LBA | **2048**（1MB 偏移） |
| 对齐 | 512 字节扇区 |
| 文件顺序 | 参数顺序 / 目录内文件名排序 |
| 回读校验 | 默认开启 |
| manifest | 默认生成 `<镜像名>.manifest.txt` |

输出示例：

```text
  idx  name                      lba      sectors      bytes    WxH
    0  01.bmp                    2048         1801     921654    640x480
    1  02.bmp                    3849          451     230454    320x240
    2  03.bmp                    4300         5401    2764854   1280x720
    3  04.bmp                    9701        12151    6220854   1920x1080
```

manifest 记录每张图的 `LBA / 起始字节 / 扇区数 / 字节数 / W×H / stride / padding / SHA256`，
可用于复现和排查。

### 为什么默认 64MB？

`sd_card_bmp.v` 的 `SCAN_MAX_SECTOR = 131071`，即只扫描前 **64MB**。
4 张 1920×1080 约 25MB，64MB 足够；如果以后要放更多/更大的图，
需要同时改 RTL 的 `SCAN_MAX_SECTOR` 和打包的 `--size-mb`。

---

## 7. 写卡

### 推荐：Win32DiskImager / balenaEtcher

1. 插入 SD 卡（读卡器）；
2. 打开 Win32DiskImager / balenaEtcher；
3. 选择 `output_sd\sd_card.img`；
4. 目标选择 **物理磁盘**（如 `PhysicalDrive2`），不是 `E:` 盘符；
5. 写入；
6. 安全弹出，插板，上电。

> 镜像是原始磁盘镜像，没有 FAT32 分区表，Windows 可能提示“需要格式化”。
> **不要格式化**，否则会把镜像结构破坏。

Linux/macOS 等价命令（把 `/dev/sdX` 换成整卡设备，不要带分区号）：

```bash
sudo dd if=sd_card.img of=/dev/sdX bs=4M status=progress conv=fsync
```

### 不推荐：直接拖拽

- 文件可能碎片化；
- 旧 BMP 的 `BM` 头可能残留；
- 文件系统元数据可能让扫描变慢；
- 换图后无法保证下次仍然连续。

### 官方 `sync_to_sd.py` 能用吗？

它能做“破坏旧 BMP 头 + 清空可见文件 + 顺序复制”，适合快速试 640×480，
但：

- 不保证新建文件在物理扇区上连续；
- 不检查尺寸/行填充；
- 不支持 M3 的混合尺寸；
- 没有 manifest，出问题无法定位。

所以：**开发期可以用它快速试；最终演示和混合尺寸测试用 `sd_pack.py` + 原始镜像。**

---

## 8. `sd_verify.py`

```powershell
# 校验镜像
python sd_verify.py output_sd\sd_card.img --expect 4 --strict-640x480

# 校验已经写好的物理卡（需要管理员 PowerShell）
python sd_verify.py "\\.\PhysicalDrive2" --expect 4 --strict-640x480
```

它完全模拟 `bmp_read.v`：

- 从 LBA 0 逐扇区找 `BM`；
- 校验宽高/24bpp/非压缩/文件长度；
- 命中后跳到 `LBA + ceil(file_len/512)`；
- 输出每张图的 LBA、尺寸、扇区数、与上一张的空洞。

如果这里能找到 4 张，RTL 基本就能找到。

---

## 9. 常见问题

| 现象 | 原因 | 处理 |
|:--|:--|:--|
| `签名不是 BM` | PNG/JPG 改后缀 | 用 `bmp_convert.py` |
| `位深=32` | 带 alpha 的 BMP | 用 `bmp_convert.py` 转 RGB |
| `高=-480` | top-down BMP | 用 `bmp_convert.py` 重新保存 |
| `像素数据不完整` | 文件截断/行对齐错 | 重新转换 |
| `尺寸 320x240 ... M2 要求 640x480` | 当前 bit 还没合入缩放 | 加 `--strict-640x480` 或等 M3 bit |
| `只找到 N 张` | 镜像没写对/LBA 不对/旧数据干扰 | 用 `sd_pack.py` 重新生成并重写 |
| 写卡后 Windows 要格式化 | 原始镜像没有分区表 | 不要格式化；这是正常现象 |
| 卡在 PC 上不可浏览 | 原始镜像不是 FAT32 | 正常；换图请重新打包 |

---

## 10. 卡与目录建议

| 项 | 建议 |
|:--|:--|
| 容量 | 4–16GB（≤32GB） |
| 写卡方式 | 原始镜像写到物理磁盘 |
| 图片数量 | 1–4 张，按参数顺序对应槽 0..3 |
| 图片位置 | 打包进镜像，不需要 FAT32 根目录 |
| 换图 | 重新 `bmp_convert → check → sd_pack → 写卡` |
| 备份 | 保留 `sd_card.img` + manifest；不要只留卡上的文件 |

---

## 11. 依赖

```powershell
python -m pip install pillow
```

`check_bmp.py`、`sd_pack.py`、`sd_verify.py` 只用 Python 标准库；
只有 `bmp_convert.py` 和 `gen_*_bmp.py` 需要 Pillow。

工具链改完后跑一次冒烟测试：

```powershell
python test_tools.py
```
