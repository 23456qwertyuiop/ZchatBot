# ZchatBot

一款极简、跨平台的 AI 对话客户端，基于 Flutter 构建，支持 **Web**、**Android** 与 **macOS**。

界面遵循「目标简单、架构简单、设计简单、实现简单」的设计原则，去除多余标语与次要干扰，专注于流畅的多模型对话、跨对话记忆与轻量 Agent 体验。

## 核心特性

- **多厂商 API 接入**
  - 一键快捷添加 **DeepSeek**、OpenAI、Anthropic、Google Gemini、xAI Grok、Mistral、Groq、OpenRouter
  - 完整支持主流国内模型：**通义千问**、**Kimi**、**智谱 GLM**、**豆包**、**MiniMax**、**文心一言**、**腾讯混元**、**阶跃星辰**、**硅基流动**
  - 支持本地 **Ollama** 与任意 OpenAI 兼容 / Anthropic 自定义接口，支持在线拉取模型列表
- **跨对话记忆（Memory）**
  - 长期记忆在所有对话间共享，可由 Agent 自动提炼保存，也可在设置中手动增删与清空
- **内置 Agent 工具（支持最多 8 步自主调用）**
  - `remember`：自动记录用户的长期偏好、背景与目标
  - `forget`：按记忆 ID 清理过时或错误的记忆
  - `search_chats`：跨历史对话全文检索相关上下文
  - `read_url`：抓取并清洗网页正文供模型分析
  - 界面实时展示工具调用状态，支持点击查看参数与返回结果，并可随时在设置中开关
- **附件与多模态**
  - 支持多选图片（PNG/JPG/WebP/GIF）与文本/代码文件，兼容 OpenAI 视觉格式与 Anthropic 多模态格式
- **全量数据迁移**
  - 支持一键导出为 JSON 备份（包含服务商配置、API Key、记忆库与全部历史对话），并可在 Web / Android / macOS 间导入恢复
- **响应式布局**
  - 桌面 / 平板端：左侧常驻历史面板 + 右侧对话区
  - 手机端：全屏对话与侧滑历史面板

## 本地运行

```bash
flutter pub get
flutter run -d web-server --web-port 8080 --web-hostname 127.0.0.1
```

## 多端构建（GitHub Actions）

仓库已配置 [`.github/workflows/build.yml`](.github/workflows/build.yml)（当前为手动触发 `workflow_dispatch`），可在云端自动构建以下产物：

- **Web**：`zchatbot-web`
- **Android APK**：`zchatbot-android-apk`
- **macOS**：`zchatbot-macos`

## 项目结构

```text
lib/
├── core/
│   ├── models.dart      # 数据模型（Provider、Settings、Message、Attachment、Memory）
│   ├── presets.dart     # 国内外 AI 厂商预设
│   ├── llm.dart         # OpenAI 兼容 / Anthropic 流式请求与 Tool Calling
│   ├── tools.dart       # 内置 Agent 工具（remember、forget、search_chats、read_url）
│   └── store.dart       # 全局状态管理、持久化与备份导入导出
└── ui/
    ├── home.dart        # 响应式主对话界面与附件交互
    ├── history_panel.dart # 历史对话列表与搜索
    ├── settings_page.dart # 快捷添加 API、模型管理、记忆/Agent 开关与数据迁移
    ├── markdown.dart    # Markdown 与代码块渲染
    └── common.dart      # 通用弹窗与页面转场
```
