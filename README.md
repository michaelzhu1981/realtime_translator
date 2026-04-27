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

ASR 模型默认使用 `mlx-community/whisper-large-v3-turbo`。模型默认缓存到 `~/Library/Caches/RealtimeTranslator/huggingface`，也可以在 App 设置中改为其他目录。

## 工作机制

整体流程由 `TranslationPipeline` 串联：启动时先拉起 ASR 服务，再检查 LM Studio 连接，最后开始捕获 Safari 音频。运行中，ScreenCaptureKit 输出的音频样本会被写成短 WAV 分片，每个分片依次送入 ASR 服务转写；转写文本经过简单去重和稳定化后，再发给 LM Studio 做流式翻译，翻译增量会实时更新到悬浮字幕窗。

```text
Safari 窗口音频
  -> ScreenCaptureKit
  -> 16 kHz 单声道 PCM
  -> WAV 音频分片
  -> 本地 MLX Whisper ASR 服务
  -> 源语言文本
  -> LM Studio OpenAI-compatible API
  -> 流式译文
  -> 悬浮字幕窗
```

### 音频捕获

音频捕获由 `SafariAudioCapture` 负责，使用 macOS `ScreenCaptureKit` 捕获 Safari 窗口的系统音频，而不是麦克风输入。启动时会先检查屏幕录制/系统音频录制权限，然后从当前可见窗口中寻找 Safari 应用和对应窗口；如果 Safari 未打开、窗口不可见或权限未授权，App 会直接给出错误提示。

捕获配置会启用 `capturesAudio`，排除当前 App 自身音频，并请求 16 kHz、单声道音频。虽然 ScreenCaptureKit 需要一个视频捕获目标，实际视频尺寸只设置为极小的 `2 x 2`，App 只消费音频输出。捕获到的 `CMSampleBuffer` 会通过后台队列交给音频处理逻辑。

App 还会监听 Safari 窗口位置变化，每约 250 ms 刷新一次窗口 frame，用于让字幕窗跟随浏览器窗口。若捕获启动后 5 秒内没有收到音频样本，会提示用户检查 Safari 是否正在播放有声音的视频，以及系统权限是否完整。

### 音频分片

`AudioChunkWriter` 会把 ScreenCaptureKit 输出的音频样本转换为 ASR 更适合处理的格式：16 kHz、单声道、Float32 PCM。输入格式不匹配时使用 `AVAudioConverter` 重采样和转换声道，然后写入临时 WAV 文件。

分片默认每 1 秒生成一段，由 `chunkDurationSeconds` 控制。为了避免每段音频之间缺少上下文，写入分片时会把最近的上下文音频一起拼进去；默认上下文窗口是 3 秒，由 `contextWindowSeconds` 控制。因此实际送给 ASR 的 WAV 文件通常包含“上一小段上下文 + 当前 1 秒新音频”。

为了减少静音带来的无效识别，分片前会做一个简单的能量检测：音频 RMS 低于阈值时认为没有有效语音，直接跳过。生成的 WAV 文件位于用户缓存目录下的 `RealtimeTranslator/audio-chunks`，处理完成后会被删除；App 启动音频分片器时也会清理上次残留的 WAV 缓存。

### 语音识别

ASR 由 App 启动一个常驻 Python 服务完成，而不是每次分片都单独执行 Python 命令。`ASRServiceManager` 会使用设置里的 ASR Python Path 启动 `scripts/asr/asr_service.py`，并传入模型名、输入语言、监听地址、端口、请求超时时间和本次 App 实例的 owner token。

服务启动后，App 会轮询 `/health`，确认服务可用且 owner token 匹配，避免误连到旧进程或其他占用同一端口的服务。启动前如果发现同端口已有旧的 `asr_service.py`，会尝试清理；如果 Python、脚本、模型缓存目录或 `ffmpeg` 不可用，会在启动阶段报错。

Python 服务内部使用 `ThreadingHTTPServer` 暴露两个接口：

- `GET /health` 返回模型、进程 ID、启动时间和 owner token。
- `POST /transcribe` 接收 `audio_path`、`language` 和 `request_id`，调用 `mlx_whisper.transcribe()` 返回文本、识别语言、耗时和 segments。

服务进程启动后会先加载 `mlx_whisper`，后续请求复用同一个运行时，避免每个音频分片重复初始化模型。请求会进入单个后台 worker 队列顺序处理，保证 MLX Whisper 推理不会被多个分片并发打爆。若一次转写超过 `asrRequestTimeoutSeconds`，服务返回 504，App 会重启 ASR 服务并等待下一段音频。

输入语言默认是 `auto`。当设置为具体语言时，App 会把该语言传给 ASR 服务，服务再传入 `mlx_whisper.transcribe()`；当为 `auto` 时则交给 Whisper 自动识别。

### 翻译

翻译由 `LMStudioTranslator` 通过 LM Studio 的 OpenAI-compatible API 完成。启动管线时，App 会先请求 `{Base URL}/models` 验证 LM Studio 是否可连接；实际翻译时请求 `{Base URL}/chat/completions`。

每次 ASR 返回文本后，`SourceTextStabilizer` 会优先用最近已提交源文或上一条 ASR 假设，在当前 ASR 窗口中定位最长重叠片段，并切出其后的新增尾部。新增源文不会立刻翻译，而是进入 `SentenceCommitter`：遇到句末标点、较长短语、约 800 ms 停顿或约 1.8 秒缓冲超时时，才把完整句子或语义短语提交给翻译。这样音频分片仍然可以携带重叠上下文，但翻译层消费的是更稳定的语义单元，减少重复字幕和半句反复改写。

翻译请求使用系统提示词约束模型：只翻译新增文本，最近源文和最近译文只作为上下文；输出目标语言字幕，保持简洁，不解释、不输出源文，也不进行逐步思考。默认 temperature 为 `0.2`，`max_tokens` 为 `96`，目标语言来自设置里的 `targetLanguage`。

实时运行时优先使用流式响应，App 会解析 Server-Sent Events 形式的 `data:` 行，持续累积 `delta.content` 并把部分译文立刻推送到字幕窗。如果流式请求中途失败但已经拿到部分译文，会直接使用这部分内容；如果完全没有有效输出，则自动退回到非流式请求。

### 队列和字幕更新

音频分片进入 `TranslationPipeline` 后会进入内存队列顺序处理：一个分片完成 ASR 和翻译后，才处理下一个分片。为了降低堆积延迟，队列只保留最新的少量待处理分片，过期分片会被丢弃；由于每个新分片本身带有上下文，后续 ASR 仍能覆盖被丢弃分片中的语音内容。

字幕窗由 App 状态层接收管线事件更新：ASR 完成时记录源文本和 ASR 延迟；翻译流式增量到达时立即刷新字幕；最终译文返回时记录翻译延迟。管线内部会保留最近译文作为后续翻译上下文，但悬浮字幕窗只显示本次最新译文，不重复显示历史字幕。停止翻译时，管线会停止接收新分片、清理尚未处理的临时文件、停止 ScreenCaptureKit 捕获，并终止 ASR 子进程。

## 开发说明

- 详细设计见 `design/MACOS_REALTIME_TRANSLATOR_DESIGN.md`。
- ASR 服务脚本位于 `scripts/asr/asr_service.py`。
- App 设置默认值位于 `RealtimeTranslator/Settings/AppSettings.swift`。
- 当前项目面向本地自用开发，不包含 App Store 分发配置。

## License

MIT License. See `LICENSE` for details.
