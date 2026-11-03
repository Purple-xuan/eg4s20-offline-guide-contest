# 基于 EG4S20 的 FPGA 离线交互式导览终端

面向展馆导览场景的 FPGA 工程，采用安路 **EG4S20BG256**，在本地完成图像读取、画面交互、音频讲解及 HDMI 音视频输出。本仓库为比赛提交的独立工程仓库。

**交付版本：2026-11-03，布局种子 50，已完成板级功能验证。**

[工程使用说明](docs/工程使用说明.md) · [模块说明](docs/modules.md) · [资源占用与验证结果](docs/验证与资源.md)

## 主要功能

- **离线图文与音频导览**：从 FAT32 格式的 TF 卡读取 BMP 图像和 WAV 音频，通过 HDMI 输出画面和声音。
- **交互操作**：支持按键及串口触摸屏输入，提供页面切换、缩略图浏览、热点选择与局部区域放大。
- **导览辅助**：提供路线叠加、字幕显示、应急页面切换及故障提示。
- **显示与音频调节**：支持转场效果、亮度与对比度调节、音量调节及音频淡入淡出。

## 快速开始

1. 下载仓库 ZIP 并解压，或使用 Git 克隆。建议使用纯英文目录（如 `C:/FPGA/eg4s20-offline-guide-contest`），避免 TD 命令行工具的中文路径编码问题：

   ```powershell
   git clone https://github.com/Purple-xuan/eg4s20-offline-guide-contest.git
   cd eg4s20-offline-guide-contest
   ```

2. 在 **Tang Dynasty 6.2.168116** 中打开 [`prj/official_example.al`](prj/official_example.al)，目标器件为 `EG4S20BG256`，顶层为 `top`。
3. 按 [`prj/official_example.adc`](prj/official_example.adc) 核对硬件引脚连接。已验证位流位于 [`bitstream/official_example.bit`](bitstream/official_example.bit)，使用 TD 配套下载工具加载。
4. 将 [`assets/TF`](assets/TF) 内的参考素材复制到 FAT32 格式 TF 卡的根目录，保留文件名与扩展名。
5. 触摸屏工程为 [`touch_panel/museum_touch_480x272.HMI`](touch_panel/museum_touch_480x272.HMI)，对应固件为 [`touch_panel/museum_touch_480x272.tft`](touch_panel/museum_touch_480x272.tft)。屏幕串口与 FPGA 端口对应关系见顶层源码和引脚约束。

## 工程结构

| 目录 | 内容 |
| --- | --- |
| [`src`](src) | 104 个源文件及配套文件，按顶层、控制、存储、图像、视频、音频等模块归类 |
| [`prj`](prj) | TD 工程入口及原始 ADC、SDC 约束 |
| [`constraints`](constraints) | 实现阶段使用的裕量约束 |
| [`sim`](sim) | 显示引擎、返回转场、普通擦除转场回归仿真 |
| [`scripts`](scripts) | 文件校验、设计展开、综合、布局布线及位流生成脚本 |
| [`bitstream`](bitstream) | 已板测位流 |
| [`implementation`](implementation) | 对应该位流的布线后数据库 |
| [`reports`](reports) | 工具原始资源、时序与仿真报告 |
| [`touch_panel`](touch_panel) | 触摸屏 HMI 工程、TFT 固件及生成脚本 |
| [`assets/TF`](assets/TF) | TF 卡参考图像与音频素材 |
| [`docs`](docs) | 中文工程使用说明、模块说明及验证结果 |

## 资源与时序

| 项目 | 使用量 / 总量 | 占用率 |
| --- | --- | --- |
| LUT | 17,885 / 19,600 | 91.25% |
| REG | 10,897 / 19,600 | 55.60% |
| BRAM9K | 63 / 64 | 98.44% |
| BRAM32K | 12 / 16 | 75.00% |
| MSLICE | 4,771 / 4,900 | 97.37% |
| LSLICE | 4,768 / 4,900 | 97.31% |
| DSP | 11 / 29 | 37.93% |
| PLL | 3 / 4 | 75.00% |
| IO | 45 / 188 | 23.94% |

布线后重载原始 SDC，完成慢角与快角双角静态时序检查：

| 检查项 | 结果 |
| --- | --- |
| 建立时间最差裕量（Setup WNS） | **+0.374 ns** |
| 保持时间最差裕量（Hold WNS） | **+0.022 ns** |
| 建立 / 保持时间总负裕量（TNS） | **0.000 / 0.000 ns** |
| 静态时序分析覆盖率 | **99.97%** |

已约束路径的建立与保持时序均为正裕量。原始证据见 [`reports/official_example_checked.timing`](reports/official_example_checked.timing) 及 [`reports/official_example_checked.area`](reports/official_example_checked.area)。

## 逻辑优化与低功耗设计措施

共享毫秒消抖节拍并精简握手跨时钟域传输中的冗余寄存器，以控制逻辑面积；通过转场几何计算流水化与擦除源选择提前寄存改善关键路径。图像按需读行，空闲时保持相关数据，减少无效数据翻转。这些内容描述设计措施，尚无功耗实测数值。

## 校验、重建与仿真

在仓库根目录执行：

```powershell
python scripts/verify_package.py
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Mode check
```

完整重建依次执行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Mode synthesis
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Mode route
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Mode rebuilt_bitgen
```

如 TD 安装路径与脚本默认值不同，在命令末尾追加 `-TdExe "实际路径/td_commands_prompt.exe"`。

ModelSim 回归入口：

```powershell
vsim -c -do sim/run_display.do
vsim -c -do sim/run_return.do
vsim -c -do sim/run_normal_wipe.do
```

详细操作见[工程使用说明](docs/工程使用说明.md)。完整重建可能改变布局布线结果，需重新核验时序。

## 交付一致性

RTL、IP、头文件、工程约束、已板测位流和布线后数据库与中文说明版源码交付包一致。源码原路径与提交路径的映射见 [`source_manifest.csv`](source_manifest.csv)，已验证构建记录见 [`release.json`](release.json)，仓库文件校验清单见 [`package_manifest.json`](package_manifest.json)。本仓库新增中文首页、验证说明和自动校验配置。
