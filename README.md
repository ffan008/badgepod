# 吧唧录音库 BadgePod

[![macOS 26](https://img.shields.io/badge/macOS-26-black)](#环境要求) [![MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

一个原生 macOS App（另有 iPhone 版），用来管理录音：把录音拉到本地、转成文字、整理成纪要和待办，之后可以直接对录音库提问。转写在本机完成，录音不上传。

本项目 fork 自 [andyhuo520/beanpod](https://github.com/andyhuo520/beanpod)（豆仓），功能完整保留，在此之上做我们自己的品牌与设备整合：

- **我们的 ESP32 吧唧录音卡**：吧唧边录边传到 Mac，接收端（`badge_receiver.py`，随吧唧固件包分发）把录音投进本 App 的 Inbox 目录，自动转写、整理。
- **Anker 录音豆**（soundcore D3200）：蓝牙连接、拉取录音并解密成本地文件。
- **得到 AI 录音卡**（GetSeed）：蓝牙同步。
- **iPhone 版**：不在 Mac 旁边时，可先经 iPhone 收录音、看录音库与知识库。

## 能做什么

- **录音管理**：设备同步、Mac 自录、文件导入、链接导入（小宇宙、Apple 播客、B 站、YouTube 等）
- **本机转写**：Qwen3-ASR 0.6B 本地模型，带时间戳；也可接云端 ASR
- **纪要整理**：场景纪要、待办提取、标签与项目归类、回收站
- **知识库问答**：对全部录音内容提问、搜索
- **语音输入**：全局听写、听写历史
- **英语学习**：单句循环、高亮跟读、单词分级、短语与难句解析
- **飞书同步**、**刘海面板**、**MCP 服务与命令行**（`beanpod` CLI：search / get / list_todos / list_topics / add_note / add_audio）
- **做视频**：经 Renoise 把纪要生成视频（可选）

## 环境要求

- macOS 26（iPhone 版：iOS 18+）
- Xcode 26 + [XcodeGen](https://github.com/yonaskolb/XcodeGen)（工程文件由 `project.yml` 生成）

## 构建

```sh
xcodegen generate
open BeanPod.xcodeproj   # 选择 BeanPod（Mac）或 BeanPodMobile（iOS）target 构建
```

命令行工具在 `Sources/beanpod`，库在 `Sources/BeanKit`，可用 SwiftPM 单独构建。

## 数据在哪

- 数据目录：`~/Library/Application Support/BadgePod/`（录音、模型、索引都在这里）
- **Inbox**：`~/Library/Application Support/BadgePod/Inbox/` —— 把音频文件放进这个目录，App 会自动导入并转写整理（吧唧接收端就是投到这里）
- Bundle ID：`com.ffan008.badgepod`（CLI：`com.ffan008.badgepod.cli`，iOS：`com.ffan008.badgepod.mobile`）

## 致谢

- 原项目：[andyhuo520/beanpod](https://github.com/andyhuo520/beanpod)（豆仓），本项目为其 fork，遵循 MIT 协议（见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)）。
- 录音豆通信协议由 [tacshi](https://github.com/tacshi) 整理（[tacshi/Soundcore](https://github.com/tacshi/Soundcore)）；得到录音卡协议由 [Shawn-TKD](https://github.com/Shawn-TKD) 抓包分析（[Shawn-TKD/getseed-ble-protocol](https://github.com/Shawn-TKD/getseed-ble-protocol)）。

> 非官方项目，与设备厂商没有关系，仅用于管理你自己设备上的你自己的录音。产品名和商标归各自所有者。
