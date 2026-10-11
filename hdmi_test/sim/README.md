# hdmi_test/sim — 720p 视频链仿真（软件版 M1）

不上板，用 **iverilog + GTKWave** 把 `video_timing_720p + test_pattern` 跑起来，
产出 **一张图片** 和 **两份波形**，用于理解"一帧画面是怎么被扫描出来的"。

## 怎么跑

```powershell
cd D:\fpga_2026\hdmi_test\sim
.\run.ps1
```

## 产物

| 文件 | 是什么 | 怎么看 |
| :--- | :--- | :--- |
| `frame.bmp` | 仿真"算"出来的 1280×720 画面（24bit BMP） | 双击打开 |
| `wave_detail.vcd` | 前 60000 周期（约 36 行）的**像素级**波形（含 x/y/rgb） | GTKWave |
| `wave_frame.vcd` | **整帧**的**结构**波形（只含 hs/vs/de/y 等慢速信号） | GTKWave |

打开波形：

```powershell
& 'D:\iverilog\bin\gtkwave.exe' wave_detail.vcd
& 'D:\iverilog\bin\gtkwave.exe' wave_frame.vcd
```

## 该看什么（重点）

**在 `wave_detail.vcd` 里**看"一个像素/一行"是怎么走的：

1. **`de`（data enable）**：只在有效像素期间为 1，其余为消隐期。
2. **`x`**：`de=1` 时从 0 数到 ~1279，行末归 0 —— 这就是"逐像素扫描"。
3. **`y`**：每扫完一行加 1，从 0 到 719 —— 这就是"逐行扫描"。
4. **`hs`**：每行末尾一个窄脉冲（行同步）。
5. **`rgb`**：`de=1` 的每一拍，`test_pattern` 用当前 `(x,y)` 算出的颜色。

**在 `wave_frame.vcd` 里**看"一整帧"的节奏：`vs` 每帧末尾一个脉冲，`y` 锯齿上升。

> 图与波形互相印证：图里左边是白色窄边，正是 `x<4` 时 `border=1` 的结果。

## 仿真发现的三个小问题（都是教学点，不影响 M1 显示）

1. **`x` 比 `de` 慢一拍**：`video_timing_720p` 里 `hs/vs/de` 是**组合**产生，而 `x/y` 是
   **寄存器**输出。结果 `x(n)=h_cnt(n-1)`，比 `de` 晚一拍。肉眼看彩条无碍，但**像素级取址**
   （帧缓冲 `地址=y*1280+x`）必须与 `de` 对齐，后续要统一（建议 `x/y` 也做成组合，
   或把 `de/hs/vs/x/y` 一起打拍）。
2. **彩条只有 5 段，不是注释说的 8 段**：`bar_idx = x[10:8]` 每段 256 像素，
   而 1280 像素只有 0~4 共 5 段。注释"8 段×160"与代码不符。
3. **最左一列重复**：由第 1 点的偏移导致（`x=-1` 被夹成 0）。

## 依赖

- `D:\iverilog\bin\iverilog.exe`
- `D:\iverilog\bin\vvp.exe`
- `D:\iverilog\bin\gtkwave.exe`
