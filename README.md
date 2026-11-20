# ✦ GeminiPet · 哈基米 macOS 透明悬浮桌宠

一款专为 **macOS** 打造的原生轻量级透明悬浮桌面宠物，以中文社区经典 **Gemini 娘（哈基米猫娘）** 为灵感制作，深度对标 **ChatGPT Desktop Pet** 的交互体验：小巧克制、点击桌面不隐藏、顶部常态显示工作区与任务状态栏、支持多任务组并行切换与对话内直接修改、语音对话、看屏幕提问、Mini 模式以及全局 **Antigravity** 实时任务联动。

![6 套 Q 版透明表情预览](./sprites_preview.png)

## ✨ 核心功能

- **顶部常态工作区与任务状态栏（Persistent Task & Workspace Bar）**：
  - 桌宠上方常态显示当前工作区名、任务组计数（如 `运行 1/3`、`新完成 1`）以及正在执行的实时步骤与耗时计时，不再只是闪一下就消失的气泡。
  - 点击任务栏或按全局快捷键 **`Option + G`** 展开统一浮窗，可在多个任务/对话线程之间自由切换（支持 `+ 新任务` 并行开多个对话）。
- **任务对话内直接追问与修改（Inline Modify）**：
  - 选中任意桌宠任务或 Antigravity 实时任务，可直接查看实时执行步骤与最新回复预览，并在下方输入框里直接继续修改或追问；也可一键 `去AGY` 复制指令并跳转回 Antigravity 主窗口。
- **点击桌面仍常驻前台**：
  - 采用 macOS `.stationary` + `.statusBar` 窗口层级，点击桌面壁纸「显示桌面」时不会被推到屏幕外，像 ChatGPT 桌宠一样稳稳留在前台。
- **悬停快捷控制栏（Hover Controls）**：
  - **💬 工作区与任务组（`⌥G` / 双击桌宠）**
  - **🎙 语音对话模式（Voice Mode）**：录音交由 Gemini 多模态理解，并通过 **Gemini TTS** 语音播报回复。
  - **📸 看屏幕提问（Screen Context）**：静音截屏并附带到当前对话或语音提问中。
  - **➕ 新建并行任务**：一键创建独立对话线程。
- **极简右键 + 原生设置窗口**：
  - 右键桌宠仅保留「设置…」和「隐藏桌宠」2 项；尺寸（默认 **112px**）、动效风格（默认「克制微动」）、对话模型（`Flash Lite` / `Gemini 4`）、Mini 纯快捷栏模式、常态任务栏开关等统一收进独立原生设置窗口。
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
