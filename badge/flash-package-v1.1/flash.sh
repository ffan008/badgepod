#!/bin/bash
# Muse badge v1.1 一键烧录（在 Mac 上运行）
# 用法：先把开发板用 USB-C 数据线接上 Mac，然后在本文件夹打开终端执行：bash flash.sh
set -e
cd "$(dirname "$0")"

PORT=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
if [ -z "$PORT" ]; then
  echo "没找到开发板串口。请确认 USB 线已接好（要用数据线，不能是纯充电线），板子已开机。"
  exit 1
fi
echo "找到开发板：$PORT"

# 找一个带 esptool 的 python：优先系统 python，其次本地 venv（Homebrew 的 python 不让直接装包，PEP 668）
PY="python3"
if ! python3 -m esptool version >/dev/null 2>&1; then
  if [ ! -x .venv/bin/python ]; then
    echo "首次使用，创建本地虚拟环境并安装 esptool..."
    python3 -m venv .venv
    .venv/bin/pip install -q esptool
  fi
  PY=".venv/bin/python"
fi

if [ ! -f littlefs.bin ]; then
  echo "解压动画素材包..."
  gunzip -k littlefs.bin.gz
fi

"$PY" -m esptool --chip esp32s3 --port "$PORT" --baud 921600 write_flash \
  0x0 bootloader.bin \
  0x8000 partitions.bin \
  0xe000 boot_app0.bin \
  0x10000 firmware.bin \
  0x810000 littlefs.bin

echo ""
echo "烧录完成！板子会自动重启，屏幕上应该出现吉祥物待机动画。"
echo "操作：短按 BOOT 切换状态；长按 BOOT 1.2 秒开始/停止录音（Opus，最长 2 小时，录音 3 秒后自动熄屏，短按可唤醒查看）。首次开机需先配网，见 README。"
