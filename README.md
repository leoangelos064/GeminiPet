# ✦ GeminiPet · 哈基米 macOS 透明悬浮桌宠

一款专为 **macOS** 打造的原生轻量级透明悬浮桌面宠物，以中文社区经典 **Gemini 娘（哈基米猫娘）** 为灵感制作，深度对标 **ChatGPT Desktop Pet** 的交互体验：小巧克制、点击桌面不隐藏、顶部常态显示工作区与任务状态栏、支持多任务组并行切换与对话内直接修改、语音对话、看屏幕提问、Mini 模式以及全局 **Antigravity** 实时任务联动。

![6 套 Q 版透明表情预览](./sprites_preview.png)

## ✨ 核心功能

- **鼠标悬停打招呼与视线微跟随**：
  - 采用 macOS 原生 `NSTrackingArea(.activeAlways)`，即使处于后台，鼠标一移到哈基米身上也会瞬间弹出开心笑脸、按时段打招呼、亮起柔和微光，并随光标左右微微偏头互动。
- **单行极简任务胶囊（仅干活时浮现，带 `✕` 关闭）**：
  - 平时空闲时头顶完全干净；仅在任务运行中或刚完成时浮现单行胶囊（如 `● 测试 · 当前步骤 0:08 ✕`），完成后可随时点 `✕` 关闭或 12 秒自动收起。
  - 点击胶囊或按 **`Option + G`** 弹出 320px 极简对话与任务卡，支持下拉切换多个任务组、直接在当前对话内继续修改/追问。
- **随 Antigravity 自动唤醒与自动退出**：
  - 打开 Antigravity 开启新会话时自动在后台静默唤醒桌宠；退出 Antigravity 时桌宠自动同步退出（可在设置中开关）。
- **点击桌面仍常驻前台**：
  - 采用 macOS `.stationary` + `.statusBar` 窗口层级，点击桌面壁纸「显示桌面」时不会被推到屏幕外。
- **悬停快捷控制栏（Hover Controls）**：
  - **💬 快捷对话与任务（`⌥G` / 双击桌宠）**
  - **🎙 语音对话模式（Voice Mode）**：录音交由 Gemini 多模态理解，并通过 **Gemini TTS** 语音播报回复。
  - **📸 看屏幕提问（Screen Context）**：静音截屏并附带到当前对话或语音提问中。
- **极简右键 + 完整原生设置窗口**：
  - 右键桌宠仅保留「设置…」和「隐藏桌宠」2 项；默认 **136px** 尺寸与 **活泼动画**（均自动记忆选择），设置内支持尺寸、动效风格、手动切换表情、对话模型（`Flash Lite` / `Gemini 4`）、Mini 模式、开机自启等完整开关。
- **6 套透明底 512×512 Q 版表情包**：内置于 [`stickers/`](./stickers) 目录，并已随应用打包。

## 🚀 快速构建与安装

### 环境要求
- macOS 13.0+（需安装 Xcode Command Line Tools 自带的 `swiftc`）
- 如需使用快捷对话、语音对话与看屏幕提问功能，请先安装并登录 [`gemini-api`](https://github.com/google-gemini/gemini-api-cli) CLI（确保 `~/.local/bin/gemini-api` 已通过 `gemini-api configure` 或 `GEMINI_API_KEY` 完成认证）。

### 一键编译并安装到「应用程序」

```bash
git clone https://github.com/leoangelos065/GeminiPet.git
cd GeminiPet
chmod +x scripts/build_app.sh
./scripts/build_app.sh
cp -R GeminiPet.app /Applications/
open /Applications/GeminiPet.app
```

## 🔗 全局 Antigravity 实时任务联动

将以下配置写入 `~/.gemini/config/hooks.json`（对所有工作区生效），桌面上的哈基米就会实时显示每个工作区正在运行的任务、工具步骤和最新回复：

```json
{
  "gemini-pet-status": {
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
│   └── GeminiPetApp.swift      # macOS 原生 SwiftUI + AppKit 桌宠主程序
├── scripts/
│   ├── build_app.sh            # 一键编译并打包独立自包含的 GeminiPet.app
│   ├── pet_ai_bridge.py        # 调用 gemini-api 的快捷对话 / 语音 / 识图桥接脚本
│   ├── agy_pet_hook.py         # Antigravity 全局多任务与工作区状态同步 Hook
│   ├── cutout.py               # 绿幕抠图与 512×512 透明素材规范化脚本
│   └── make_variants.py        # 扩展状态素材生成与预览图合成脚本
├── sprites/                    # 应用内置的 6 套透明底 Q 版状态图
├── stickers/                   # 导出的 6 张独立透明 PNG 表情包
└── sprites_preview.png         # 全套素材总览图
```

## 🎨 致谢

- 角色外观设定灵感参考中文社区 **ZipZipPipe** 创作的 Gemini 娘（蓝紫渐变长发、猫耳猫尾、异色瞳、四芒星发饰）。
- 交互理念参考 **ChatGPT Desktop Pet** 的常驻任务栏、工作区任务组、悬停控制条与 Mini 模式设计。
