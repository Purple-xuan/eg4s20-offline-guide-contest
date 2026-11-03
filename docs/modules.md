# 工程模块说明

`src/top/top_tf_hdmi_audio.v` 定义顶层模块 `top`，连接时钟、按键与触摸输入、
SD 卡与 FAT32 文件系统、常驻图像存储、画面显示、屏幕叠加显示（OSD）、音频及 HDMI 输出。

## 主要功能与源码对应关系

| 功能 | 主要文件 |
| --- | --- |
| SD 卡访问与文件查找 | `src/storage/sd_card_bmp.v`、`src/filesystem/fat32_volume_scanner.v`、`src/filesystem/fat32_file_streamer.v` |
| 常驻图像传输 | `src/memory/resident_image_uploader.v`、`src/memory/resident_slot_writer.v`、`src/memory/resident_row_reader.v` |
| 画面显示与转场 | `src/image/resident_display_engine.v`、`src/image/resident_line_buffers.v`、`src/video/navigation_transition_effect.v` |
| 导航与输入处理 | `src/control/input_event_router.v`、`src/control/tjc_touch_uart.v` |
| 音频读取与淡入淡出 | `src/audio/wav_file_stream_reader.v`、`src/audio/audio_fade_gain.v` |
| HDMI 输出 | `src/hdmi/hdmi_phy_warpper.v`、`src/hdmi/hdmi_1_4b_transmitter_core_wrapper.enc.v` |

## 工程整理说明

本工程保留原有模块层次关系及源码编译顺序。
`source_manifest.csv` 记录了每个原始源码路径与提交包中模块化路径的对应关系。
完整目录说明、构建方法及仿真入口见工程根目录的 `README.md`。
