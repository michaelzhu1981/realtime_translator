import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实时字幕翻译")
                .font(.headline)

            Divider()

            Text("状态：\(appState.runState.label)")
                .lineLimit(2)

            Button(appState.isRunning ? "停止翻译" : "开始翻译 Safari") {
                appState.isRunning ? appState.stop() : appState.start()
            }
            .keyboardShortcut("t", modifiers: [.control, .option, .command])

            Button("显示/隐藏字幕窗") {
                appState.toggleSubtitleWindow()
            }
            .keyboardShortcut("s", modifiers: [.control, .option, .command])

            Button(appState.settings.subtitleMousePassthrough ? "解锁字幕窗" : "锁定字幕窗") {
                appState.toggleWindowLock()
            }
            .keyboardShortcut("l", modifiers: [.control, .option, .command])

            Button("清空当前字幕") {
                appState.clearSubtitle()
            }
            .keyboardShortcut("c", modifiers: [.control, .option, .command])

            Divider()

            Text("ASR：mlx-whisper")
            Text("LM Studio：\(appState.settings.lmStudioBaseURL)")
                .lineLimit(1)
                .truncationMode(.middle)

            if !appState.lastSourceText.isEmpty {
                Divider()
                Text("ASR 原文：\(appState.lastSourceText)")
                    .lineLimit(2)
                if let asr = appState.lastASRLatencyMS {
                    Text("ASR 延迟：\(asr) ms")
                }
                if let translation = appState.lastTranslationLatencyMS {
                    Text("翻译延迟：\(translation) ms")
                }
            }

            Divider()

            Button("设置...") {
                openSettings()
            }

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 300)
    }
}
