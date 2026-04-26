# Realtime Translator

一个自用开发版 macOS 菜单栏 App，用于捕获 Safari 视频音频，使用本地 MLX Whisper 做语音识别，再通过 LM Studio 的 OpenAI-compatible API 翻译，并在独立悬浮字幕窗中显示译文。

## 功能概览

- 菜单栏常驻 App，支持开始/停止实时翻译。
- 使用 ScreenCaptureKit 捕获 Safari 音频。
- 通过常驻 Python ASR 服务调用 MLX Whisper，避免每个音频片段重复加载模型。
- 通过 LM Studio 本地模型接口进行翻译。
- 使用 SwiftUI + AppKit 显示透明置顶字幕窗。
- 支持输入语言、目标语言、字幕样式、ASR 服务地址等基础设置。

## 项目结构

```text
RealtimeTranslator/          macOS App 源码
RealtimeTranslator.xcodeproj Xcode 工程
scripts/asr/                 MLX Whisper ASR 服务
design/                      设计文档
models/                      本地模型缓存目录，默认不提交
```

## 环境要求

- macOS，建议使用较新的系统版本。
- Xcode。
- Python 3.11+，用于运行 ASR 服务。
- Apple Silicon Mac，MLX Whisper 依赖 MLX 生态。
- LM Studio，并开启本地 OpenAI-compatible server。

默认翻译服务配置在 App 设置中，可按需修改：

- Base URL: `http://192.168.4.181:1234/v1`
- Model: `qwen/qwen3-4b-2507`

## ASR 环境准备

App 默认会从 `~/local-asr/mlx-whisper/.venv/bin/python` 启动 ASR 服务。可以使用下面的方式创建虚拟环境：

```sh
cd /path/to/realtime_translator
REPO_ROOT="$(pwd)"
mkdir -p ~/local-asr/mlx-whisper
cd ~/local-asr/mlx-whisper
python3 -m venv .venv
source .venv/bin/activate
pip install -r "$REPO_ROOT/scripts/asr/requirements.txt"
```

如果虚拟环境放在其他位置，请在 App 设置里修改 ASR Python Path。

## 运行方式

1. 用 Xcode 打开 `RealtimeTranslator.xcodeproj`。
2. 确认 LM Studio 已启动本地 API 服务，并加载配置的模型。
3. 确认 ASR Python Path 指向已安装 `mlx-whisper` 的虚拟环境。
4. 运行 App，首次使用时按系统提示授予屏幕录制/音频捕获相关权限。
5. 从菜单栏选择开始翻译 Safari。

ASR 模型默认使用 `mlx-community/whisper-large-v3-turbo`。模型会下载到 `models/huggingface`，该目录体积较大，不应提交到 Git。

## 开发说明

- 详细设计见 `design/MACOS_REALTIME_TRANSLATOR_DESIGN.md`。
- ASR 服务脚本位于 `scripts/asr/asr_service.py`。
- App 设置默认值位于 `RealtimeTranslator/Settings/AppSettings.swift`。
- 当前项目面向本地自用开发，不包含 App Store 分发配置。

## License

MIT License. See `LICENSE` for details.
