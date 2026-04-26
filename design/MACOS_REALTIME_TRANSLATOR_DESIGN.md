# macOS Safari 实时字幕翻译 App 设计方案

## 1. 目标

构建一个自用开发版 macOS App，用于实时读取 Safari 中网页视频播放产生的音频，使用本地 ASR 识别语音，再调用 LM Studio 本地大模型翻译为目标语言，最后通过独立悬浮字幕窗显示译文。

本阶段不做 Safari 插件。Safari 只作为被捕获的目标应用，字幕通过 macOS 悬浮窗覆盖显示。

## 2. 已确认需求

- 平台：macOS。
- 最低系统版本：最新 macOS，按当前开发机系统能力实现，不兼容旧系统。
- 技术路线：Xcode 原生 macOS App，使用 SwiftUI + AppKit。
- 目标使用场景：Safari 中任意可播放视频的网站。
- App 形态：菜单栏常驻 App + 设置窗口 + 独立悬浮字幕窗。
- 音频来源：
  - MVP 优先捕获 Safari 窗口或 Safari 应用音频。
  - 如果 Safari 应用级捕获不稳定，再增加系统音频捕获模式。
- ASR：本地运行，使用 MLX Whisper，并且必须走 Python 虚拟环境。
- ASR 调用方式：从第一版开始使用常驻 ASR 服务，避免每个片段重复启动 Python 和加载模型。
- 翻译：LM Studio，OpenAI-compatible API。
  - Base URL: `http://192.168.4.181:1234/v1`
  - Model: `qwen/qwen3-4b-2507`
- 输入语言：设置菜单可选，默认自动检测。
- 目标语言：设置菜单可选，默认简体中文。
- 字幕内容：仅显示译文。
- 延迟目标：接近同传。
- 字幕历史保存：MVP 不需要。
- 登录自启动：MVP 不需要。
- 快捷键：需要。
- 调试信息：主字幕只显示译文，调试面板允许显示 ASR 原文、ASR 延迟、翻译延迟等。

## 3. 非目标

MVP 阶段不做以下内容：

- Safari Web Extension。
- App Store 分发。
- iOS / iPadOS 支持。
- 云端 ASR 或云端翻译。
- 多浏览器通用适配。
- 字幕文件导出，例如 `.srt` / `.txt`。
- 多视频源同时翻译。
- DRM 网站可用性承诺。
- 精准逐字时间轴对齐。

## 4. 总体架构

```text
Safari 视频播放
  -> ScreenCaptureKit 捕获 Safari 音频
  -> 音频缓冲与分片
  -> VAD 人声检测
  -> MLX Whisper Python 虚拟环境执行 ASR
  -> 文本稳定策略
  -> LM Studio 流式翻译为目标语言
  -> 字幕状态管理
  -> 透明置顶悬浮字幕窗
```

核心原则：

- macOS App 是主控，负责权限、音频采集、进程管理、翻译管线和 UI。
- MLX Whisper 作为本地 ASR 后端，通过虚拟环境里的 Python 常驻服务调用。
- LM Studio 作为翻译后端，通过 HTTP streaming API 调用。
- 字幕窗只承担显示职责，不参与 ASR 或翻译逻辑。

## 5. 模块划分

### 5.1 菜单栏 App

菜单栏图标提供快速控制入口：

```text
实时字幕翻译
----------------
状态：未运行 / 正在捕获 / 正在翻译 / 错误
开始翻译 Safari
停止翻译
显示/隐藏字幕窗
锁定/解锁字幕窗
----------------
ASR：mlx-whisper
LM Studio：已连接 / 未连接
----------------
设置...
退出
```

职责：

- 启动和停止翻译任务。
- 展示当前运行状态。
- 打开设置窗口。
- 控制字幕窗显示、锁定和鼠标穿透。

### 5.2 设置窗口

设置项：

- LM Studio
  - Base URL，默认 `http://192.168.4.181:1234/v1`
  - Model，默认 `qwen/qwen3-4b-2507`
  - 连接测试
- ASR
  - Python 可执行文件路径，默认 `~/local-asr/mlx-whisper/.venv/bin/python`
  - MLX Whisper 模型名，默认 `mlx-community/whisper-large-v3-turbo`
  - 备选模型 `mlx-community/whisper-small-mlx`
  - 输入语言，默认 `auto`
  - 常用输入语言选项：自动检测、英语、中文、粤语、日语、韩语、法语、德语、西班牙语、葡萄牙语、俄语
  - 高级输入语言选项：允许手动输入 Whisper 语言代码，例如 `en`、`zh`、`yue`、`ja`
  - ASR 调用超时
- 翻译语言
  - 目标语言，默认 `Simplified Chinese`
  - 常用选项：简体中文、繁体中文、英文、日文、韩文、法文、德文、西班牙文
  - 高级选项：允许手动输入目标语言名称
- 音频
  - 捕获模式：Safari 应用音频 / 系统音频
  - 采样率，默认 16 kHz 或由 ASR 适配层转换
  - 分片窗口，默认 1.0 秒
  - 滚动上下文窗口，默认 3.0 秒
- 字幕
  - 字号
  - 透明度
  - 最大显示行数
  - 窗口位置
  - 鼠标穿透开关
- 快捷键
  - 开始/停止翻译
  - 显示/隐藏字幕窗
  - 锁定/解锁字幕窗
  - 清空当前字幕
- 调试
  - 显示 ASR 原文
  - 显示 ASR 延迟
  - 显示翻译延迟
  - 显示当前音频电平

### 5.3 悬浮字幕窗

使用透明、无边框、置顶的 `NSPanel` 或等价 AppKit 窗口实现。

行为：

- 默认置顶。
- 默认鼠标穿透，避免影响 Safari 操作。
- 可通过快捷键解锁，解锁后允许拖动和调整位置。
- 主字幕只显示目标语言译文。
- 支持短时间内更新最后一条字幕，用于降低 ASR 增量识别带来的抖动。

建议样式：

- 半透明深色背景。
- 白色或浅色字幕文本。
- 最多显示 1-2 行。
- 字幕区域宽度默认为屏幕宽度的 60%-80%。
- 字幕位置默认靠近屏幕底部，但不要贴边。

### 5.4 音频捕获

优先使用 ScreenCaptureKit。

MVP 路线：

1. 枚举可捕获内容，找到 Safari 应用或 Safari 窗口。
2. 创建 `SCContentFilter`。
3. 配置 `SCStreamConfiguration`：
   - `capturesAudio = true`
   - 优先排除当前 App 自身音频，避免反馈。
4. 接收 `.audio` 类型的 `CMSampleBuffer`。
5. 转换为 ASR 需要的 PCM 格式。

风险：

- Safari 应用级音频捕获在不同 macOS 版本上需要实测。
- 某些 DRM 内容可能不能被正常捕获或识别。
- 如果应用级捕获不稳定，需要提供系统音频模式作为兜底。

### 5.5 音频处理与 VAD

目标是减少无声片段进入 ASR，并尽可能降低延迟。

建议流程：

```text
CMSampleBuffer
  -> PCM 归一化
  -> 重采样到 16 kHz mono
  -> 环形缓冲区
  -> VAD 判断
  -> 生成 0.8-1.5 秒音频片段
  -> 附带最近 2-3 秒上下文
```

VAD 选型：

- MVP 可先使用简单能量阈值，降低实现复杂度。
- 后续可接入 WebRTC VAD 或 Silero VAD，提高人声检测准确率。

### 5.6 ASR 后端

使用 MLX Whisper，通过 Python 虚拟环境中的常驻 ASR 服务调用。

默认路径：

```text
~/local-asr/mlx-whisper/.venv/bin/python
```

默认模型：

```text
mlx-community/whisper-large-v3-turbo
```

备选模型：

```text
mlx-community/whisper-small-mlx
```

ASR 服务方式：

- Swift App 启动或连接一个 Python 常驻 ASR 服务。
- ASR 服务启动时加载 MLX Whisper 模型，并在整个翻译会话中复用模型。
- Swift App 将音频片段写入临时 WAV 文件，或在后续优化中通过本地 socket/stdin 传输 PCM。
- Swift App 向 ASR 服务发送转写请求。
- ASR 服务返回 JSON。
- Swift App 解析 JSON 并进入翻译阶段。

ASR 服务启动命令建议：

```bash
python asr_service.py \
  --model mlx-community/whisper-large-v3-turbo \
  --language auto \
  --host 127.0.0.1 \
  --port 8765
```

ASR 请求示例：

```json
{
  "audio_path": "~/Library/Caches/RealtimeTranslator/audio-chunks/chunk.wav",
  "language": "auto",
  "request_id": "chunk-0001"
}
```

返回 JSON 示例：

```json
{
  "text": "recognized source text",
  "language": "en",
  "duration_ms": 820,
  "segments": []
}
```

后续优化：

- 使用 stdin 或本地 socket 直接传输 PCM，减少临时文件开销。
- 引入稳定文本策略，只翻译 ASR 结果中稳定的前缀。

### 5.7 文本稳定策略

实时 ASR 会频繁修正尾部文本。为了避免字幕闪烁，需要区分稳定文本和临时文本。

MVP 策略：

- 保留最近一次 ASR 文本。
- 与本次 ASR 文本做最长公共前缀比较。
- 只将连续出现 2 次或超过一定长度的文本送入翻译。
- 对很短的片段做合并，例如少于 4 个字符或少于 1 秒的语音不立即翻译。

示例：

```text
ASR 1: I think this
ASR 2: I think this is
ASR 3: I think this is very important

稳定前缀: I think this is
送翻译: I think this is
暂存尾部: very important
```

### 5.8 翻译后端

使用 LM Studio OpenAI-compatible API。

默认配置：

```text
Base URL: http://192.168.4.181:1234/v1
Model: qwen/qwen3-4b-2507
Endpoint: /chat/completions
```

请求方式：

- 使用 streaming response。
- 输入为 ASR 稳定文本。
- 输出只允许目标语言译文。

系统提示词建议：

```text
You are a real-time subtitle translator.
Translate the user's input into natural {target_language}.
Only output the translated subtitle.
Keep it concise and suitable for on-screen subtitles.
Do not explain.
Do not include the source text.
```

用户消息：

```text
<source text>
```

上下文策略：

- 保留最近 3-5 条原文和译文作为上下文。
- 控制 prompt 长度，优先低延迟。
- 不让模型输出解释、标点说明或格式包装。

错误处理：

- LM Studio 不可达：菜单栏显示错误，字幕窗显示一次短错误提示。
- 模型不存在：设置页连接测试提示具体模型名。
- 请求超时：跳过当前片段，不阻塞后续 ASR。

### 5.9 快捷键

建议默认快捷键：

- 开始/停止翻译：`Control + Option + Command + T`
- 显示/隐藏字幕窗：`Control + Option + Command + S`
- 锁定/解锁字幕窗：`Control + Option + Command + L`
- 清空字幕：`Control + Option + Command + C`

实现可使用 Carbon hot key API 或 macOS 全局快捷键封装库。自用开发版可以优先选择实现成本低、稳定性好的方案。

## 6. 状态机

```text
Idle
  -> CheckingPermissions
  -> CheckingBackends
  -> CapturingAudio
  -> Transcribing
  -> Translating
  -> Running
  -> Stopping
  -> Idle

AnyState
  -> Error
  -> Idle
```

关键状态：

- `Idle`：未运行。
- `CheckingPermissions`：检查屏幕录制/音频捕获权限。
- `CheckingBackends`：检查 MLX Whisper 虚拟环境和 LM Studio。
- `CapturingAudio`：正在捕获音频。
- `Running`：ASR 和翻译管线正常运行。
- `Error`：权限、音频、ASR 或 LM Studio 出错。

## 7. 权限与运行前检查

启动翻译前检查：

- ScreenCaptureKit 所需的屏幕录制权限。
- 是否能枚举 Safari 应用或窗口。
- Python 路径是否存在。
- `mlx_whisper` 是否能 import。
- LM Studio `/v1/models` 或 chat completions 是否可用。
- 临时目录是否可写。

权限提示：

- 如果缺少屏幕录制权限，显示设置引导。
- 自用开发版可使用明确的错误说明，不需要 App Store 级别的完整引导流程。

## 8. 延迟预算

目标端到端延迟：

- 理想：1.5-2 秒。
- MVP 可接受：2-3 秒。
- 超过 5 秒需要优化。

预算拆分：

```text
音频分片: 0.8-1.5 秒
VAD/音频处理: < 100 ms
ASR: 300-1200 ms，取决于模型和片段长度
翻译首 token: 100-800 ms，取决于 LM Studio 模型和网络
字幕渲染: < 50 ms
```

主要优化方向：

- ASR 服务内音频传输从临时 WAV 优化为流式 PCM。
- 减少音频片段长度。
- 使用 streaming 翻译。
- 降低 prompt 上下文长度。
- 当 `large-v3-turbo` 延迟过高时切换到 `small-mlx`。

## 9. 本地数据与运行时路径

设置保存：

- 使用 `UserDefaults` 保存用户设置。
- 保存内容包括 LM Studio 地址、模型名、ASR Python 路径、ASR 模型名、输入语言、目标语言、字幕样式、快捷键和字幕窗位置。

临时音频文件：

```text
~/Library/Caches/RealtimeTranslator/audio-chunks/
```

要求：

- 仅作为 ASR 服务输入中转。
- App 启动时清理上次残留。
- 运行中按时间或数量滚动清理，避免长期占用磁盘。

日志文件：

```text
~/Library/Logs/RealtimeTranslator/app.log
```

日志内容：

- App 启停。
- 权限检查结果。
- ScreenCaptureKit 捕获状态。
- ASR 服务启动、停止和错误。
- ASR 请求耗时。
- LM Studio 连接和翻译耗时。
- 字幕渲染状态。

登录自启动：

- MVP 不实现。
- 后续如需要，可在设置页增加开关。

## 10. 推荐目录结构

后续实现可使用以下结构：

```text
realtime_translator/
  RealtimeTranslator.xcodeproj
  RealtimeTranslator/
    App/
    MenuBar/
    Settings/
    SubtitleWindow/
    AudioCapture/
    AudioProcessing/
    ASR/
    Translation/
    Hotkeys/
    Diagnostics/
  scripts/
    asr/
      asr_service.py
      requirements.txt
  design/
    MACOS_REALTIME_TRANSLATOR_DESIGN.md
```

## 11. 实施阶段

### 阶段 1：技术验证

目标：证明端到端链路可行。

任务：

- 创建最小 macOS App。
- 使用 ScreenCaptureKit 捕获 Safari 音频。
- 启动 MLX Whisper 常驻 ASR 服务。
- 将捕获音频保存为短 WAV，并发送给 ASR 服务转写。
- 调用 LM Studio 翻译。
- 在简单置顶窗口显示译文。

验收标准：

- 能捕获 Safari 播放视频的音频。
- 能启动并复用常驻 ASR 服务。
- 能得到 ASR 原文。
- 能得到目标语言译文，默认简体中文。
- 端到端延迟有可观测数据。

### 阶段 2：MVP

目标：形成可日常使用的自用版。

任务：

- 菜单栏常驻。
- 设置窗口。
- 悬浮字幕窗。
- 快捷键。
- 基础错误处理。
- ASR/翻译延迟指标。
- 简单 VAD。

验收标准：

- 从菜单栏一键开始/停止。
- 字幕窗可显示仅译文字幕。
- Safari 视频播放时可连续翻译。
- LM Studio 或 ASR 出错时不会导致 App 崩溃。

### 阶段 3：低延迟优化

目标：接近同传体验。

任务：

- ASR 常驻进程。
- 更细粒度音频流传输。
- 文本稳定策略。
- 翻译 streaming 显示。
- 模型延迟对比：`large-v3-turbo` vs `small-mlx`。

验收标准：

- 常见视频场景端到端延迟稳定在 2-3 秒以内。
- 字幕闪烁和重复明显减少。

### 阶段 4：体验增强

目标：提高长期使用舒适度。

任务：

- 字幕窗位置记忆。
- 多显示器支持。
- 更完善的权限引导。
- 更详细诊断面板。
- 系统音频捕获兜底模式。

## 12. 主要风险

### Safari 应用音频捕获不稳定

风险：ScreenCaptureKit 对 Safari 应用音频捕获的实际表现可能受 macOS 版本、权限、播放内容影响。

应对：

- 阶段 1 优先验证。
- 保留系统音频捕获模式。

### MLX Whisper 服务延迟过高

风险：即使使用常驻服务，模型大小、片段长度和临时 WAV 文件 I/O 仍可能导致延迟不可接受。

应对：

- 第一版即使用常驻 ASR 服务，避免重复加载模型。
- 当 `large-v3-turbo` 延迟过高时切换到 `small-mlx`。
- 后续将临时 WAV 文件传输改为流式 PCM。

### 翻译模型延迟波动

风险：LM Studio 所在机器是 `192.168.4.181`，网络和模型推理都会影响延迟。

应对：

- 该地址是固定局域网服务地址，默认认为长期可达。
- 使用 streaming response。
- 设置请求超时。
- 限制上下文长度。
- 在调试面板显示翻译首 token 延迟和总延迟。

### ASR 增量文本抖动

风险：Whisper 对短片段尾部识别不稳定，导致翻译重复或频繁修正。

应对：

- 引入稳定前缀策略。
- 短片段合并。
- 最后一条字幕允许轻微更新，但避免频繁全量刷新。

## 13. 推荐默认配置

```text
App Mode: Menu bar app
Project Type: Xcode macOS App
UI Stack: SwiftUI + AppKit
Minimum macOS: latest macOS on development machine
Target App: Safari
Capture Mode: Safari app/window audio
Fallback Capture Mode: System audio
Input Language: auto
Target Language: Simplified Chinese
Subtitle Display: Translation only
ASR Python: ~/local-asr/mlx-whisper/.venv/bin/python
ASR Mode: persistent local service
ASR Service: 127.0.0.1:8765
ASR Model: mlx-community/whisper-large-v3-turbo
ASR Fallback Model: mlx-community/whisper-small-mlx
LM Studio Base URL: http://192.168.4.181:1234/v1
LM Studio Model: qwen/qwen3-4b-2507
Settings Store: UserDefaults
Audio Chunk Cache: ~/Library/Caches/RealtimeTranslator/audio-chunks/
Log File: ~/Library/Logs/RealtimeTranslator/app.log
Launch at Login: disabled / not implemented in MVP
Chunk Duration: 1.0 s
Context Window: 3.0 s
Translation Timeout: 5 s
Subtitle Lines: 1-2
Mouse Passthrough: enabled by default
```
