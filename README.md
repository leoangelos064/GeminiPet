# ✦ GeminiPet · 哈基米 macOS 透明悬浮桌宠

一款专为 **macOS** 打造的原生轻量级透明悬浮桌面宠物，以中文社区经典 **Gemini 娘（哈基米猫娘）** 为灵感制作，对标 **ChatGPT Desktop Pet** 的交互体验：**单桌宠同时监控 Antigravity + Gemini 桌面端（Gemini.app）**，支持视频生成进度追踪、流式对话状态同步、多任务组来源区分、API 快捷对话与语音模式、看屏幕提问以及双宿主生命周期联动。

![6 套 Q 版透明表情预览](./sprites_preview.png)

## ✨ 核心功能

- **双端统一实时监控（Antigravity + Gemini.app）**：
  - **Antigravity / Antigravity IDE / Gemini 内置 Agent**：通过全局生命周期 Hook 自动识别父进程来源，实时同步思考、文件编辑、命令执行与完成状态。
  - **Gemini.app 原生任务监控（只读增量日志尾读）**：自动追踪 `~/Library/Caches/com.google.GeminiMacOS/Logs/diagnostic*.log` 新增日志（支持日志轮转、不回放旧历史）：
    - **视频生成进度**：实时识别 `VideoGeneration` 开始、轮询中、波动重试与完成状态，耗时较长的视频生成完成后立刻弹出庆祝提示。
    - **流式对话状态**：识别 `RobinProcessQueryStreamer` 流式回复（带 2 秒防抖，且不会覆盖高优先级的视频生成进度），支持 `endOfData` 完成与 `AbortGeneration` 取消，并内置超时归档与 `Gemini.app` 退出清理。
- **清晰的任务来源与额度池区分**：
  - 任务胶囊与下拉任务组均附带彩色来源徽章，一眼区分不同额度池：
    - `Antigravity` / `AGY IDE`（紫蓝色徽章，点击 `↗` 跳回 Antigravity）
    - `Gemini · 视频` / `Gemini · 对话` / `Gemini · Agent`（天蓝色徽章，点击 `↗` 跳回 Gemini.app）
    - `API 快捷对话`（青绿色徽章，通过本机 `gemini-api` CLI 对话）
  - 支持多端并发任务（如一边 Antigravity 写代码、一边 Gemini 生成视频），全部完成才回到待机。
- **双宿主生命周期联动**：
  - 默认「随 Antigravity / Gemini 全部退出自动关闭」：同时监测 `com.google.antigravity`、`com.google.antigravity-ide`、`com.google.GeminiMacOS`，仅当这些宿主应用**全部退出**时才自动关闭桌宠（只开 Gemini 做视频、关掉 Antigravity 时不会误退）。
  - 菜单栏与设置面板均提供「打开 Antigravity」与「打开 Gemini」双快捷入口。
- **鼠标悬停打招呼与视线微跟随**：
  - 采用 macOS 原生 `NSTrackingArea(.activeAlways)`，即使在后台，鼠标一移到哈基米身上也会瞬间弹出开心笑脸、按时段打招呼、亮起柔和微光并随光标微微偏头。
- **单行极简任务胶囊（带 `✕` 关闭）+ 悬停快捷栏**：
  - 平时空闲时头顶完全干净；仅在任务进行中或刚完成时浮现单行胶囊，完成后可点 `✕` 关闭或自动收起。
  - 悬停脚下浮出快捷按钮：**💬 任务组与快捷对话（`⌥G`）**、**🎙 语音模式（含 Gemini TTS 语音播报）**、**📸 看屏幕提问**。
- **点击桌面仍常驻前台 & 极简右键**：
  - `.stationary` + `.statusBar` 层级确保点击桌面壁纸「显示桌面」时稳固留在前台。
  - 右键桌宠仅保留「设置…」和「隐藏桌宠」2 项；默认 **136px** 尺寸 + **活泼动画**（自动记忆选择），完整配置统一收进独立原生设置窗口。
- **6 套透明底 512×512 Q 版表情包**：内置于 [`stickers/`](./stickers) 目录并随应用打包。

## 🚀 快速安装与构建

### 方式一：直接下载 Release 成品包
前往 [Releases](https://github.com/leoangelos065/GeminiPet/releases) 下载最新的 `GeminiPet-macOS.zip`，解压后将 `GeminiPet.app` 拖入 `/Applications/` 双击运行即可。

### 方式二：从源码一键编译

```bash
git clone https://github.com/leoangelos065/GeminiPet.git
cd GeminiPet
chmod +x scripts/build_app.sh
./scripts/build_app.sh
cp -R GeminiPet.app /Applications/
open /Applications/GeminiPet.app
```

> 环境要求：macOS 13.0+（含 `swiftc`）。如需使用 **API 快捷对话 / 语音模式 / 看屏幕提问**，请先安装并登录 [`gemini-api`](https://github.com/google-gemini/gemini-api-cli) CLI。

## 🔗 全局 Antigravity / Gemini Agent Hook 配置

将以下配置写入 `~/.gemini/config/hooks.json`，即可让桌宠同时接收 Antigravity、Antigravity IDE 与 Gemini.app 内置 Agent 的实时任务状态（自动识别来源）：

```json
{
  "gemini-pet-status": {
    "SessionStart": [
      {
        "type": "command",
        "command": "python3 \"/Applications/GeminiPet.app/Contents/Resources/agy_pet_hook.py\"",
        "timeout": 5
      }
    ],
    "PreInvocation": [
      {
        "type": "command",
        "command": "python3 \"/Applications/GeminiPet.app/Contents/Resources/agy_pet_hook.py\"",
        "timeout": 5
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"/Applications/GeminiPet.app/Contents/Resources/agy_pet_hook.py\"",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "type": "command",
        "command": "python3 \"/Applications/GeminiPet.app/Contents/Resources/agy_pet_hook.py\"",
        "timeout": 5
      }
    ]
  }
}
```

## 📁 目录结构

```text
GeminiPet/
├── src/
│   ├── GeminiPetApp.swift          # macOS 原生 SwiftUI + AppKit 桌宠主程序
│   └── GeminiAppLogMonitor.swift   # Gemini.app 增量日志监控器与双宿主生命周期策略
├── scripts/
│   ├── build_app.sh                # 一键编译并打包独立自包含的 GeminiPet.app
│   ├── pet_ai_bridge.py            # 调用 gemini-api 的快捷对话 / 语音 / 识图桥接脚本
│   ├── agy_pet_hook.py             # Antigravity / Gemini 双端来源识别 Hook 脚本
│   ├── cutout.py                   # 绿幕抠图与 512×512 透明素材规范化脚本
│   └── make_variants.py            # 扩展状态素材生成与预览图合成脚本
├── tests/
│   ├── test_dual_host.py           # Hook 来源识别与隔离端到端测试
│   └── test_log_monitor.swift      # GeminiAppLogMonitor 与双宿主退出策略原生测试
├── sprites/                        # 应用内置的 6 套透明底 Q 版状态图
├── stickers/                       # 导出的 6 张独立透明 PNG 表情包
└── sprites_preview.png             # 全套素材总览图
```

## 🎨 致谢

- 角色外观设定灵感参考中文社区 **ZipZipPipe** 创作的 Gemini 娘（蓝紫渐变长发、猫耳猫尾、异色瞳、四芒星发饰）。
- 交互理念参考 **ChatGPT Desktop Pet** 的任务胶囊、悬停控制条与 Mini 模式设计。
