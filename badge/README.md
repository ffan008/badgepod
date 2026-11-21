# 吧唧（ESP32 录音卡）

微雪 ESP32-S3-Touch-AMOLED-1.75C（466×466 圆屏、双麦、带电池版）做的 Muse 电子吧唧＋录音卡：屏幕循环播放 Muse 吉祥物的 6 个状态动画；长按录音（Opus 压缩）并经 Wi-Fi 边录边传到 Mac，录完自动投进「吧唧录音库」的 Inbox 转写整理。

## 目录

- `firmware/` —— PlatformIO 固件工程（Arduino 框架）。`src/main.cpp` 为当前 v1.1（`main_v1.cpp.bak` 是 v1 存档）；`data/` 是 6 个状态动画的 MJPEG 素材（烧录时写入 LittleFS）；`lib/opus/` 是内置的 libopus 源码（Xiph.org，BSD 许可，见其 COPYING）。
- `receiver/badge_receiver.py` —— Mac 接收端（纯 Python 标准库）：接收吧唧推流，落盘为 .ogg，录完自动投递 `~/Library/Application Support/BadgePod/Inbox/`。
- `flash-package-v1.1/` —— v1.1 成品烧录包：预编译 bin＋`flash.sh` 一键烧录＋使用说明（README.md 内含配网、操作与验收清单）。不想编译时直接用这个。

## 固件要点（v1.1）

- 录音：双麦下混单声道，Opus 16kbps 存 Ogg（本地主本，上限 2 小时），Wi-Fi 边录边传（UDP 发现＋TCP 推流）
- 录音开始 3 秒后自动熄屏，短按 BOOT 唤醒看 3 秒
- Wi-Fi 配网：无凭据时开热点 `MuseBadge-Setup`，网页表单填一次存板内；开机长按 BOOT 约 2 秒清凭据
- 操作：BOOT 短按切动画状态，长按 1.2 秒开始/停止录音

构建：`cd firmware && pio run`（烧录：`pio run -t upload` 与 `pio run -t uploadfs`，或用烧录包的 flash.sh）。
