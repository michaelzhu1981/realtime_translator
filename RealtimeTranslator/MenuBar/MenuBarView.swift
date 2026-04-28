import AppKit
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

            Button(appState.isRunning ? "停止翻译" : "开始翻译所选窗口") {
                appState.isRunning ? appState.stop() : appState.start()
            }
            .keyboardShortcut("t", modifiers: [.control, .option, .command])
            .disabled(!appState.isRunning && appState.selectedCaptureTarget == nil)

            Divider()

            HStack {
                Text("捕获窗口")
                Spacer()
                Button("刷新") {
                    appState.refreshCaptureTargets()
                }
                .disabled(appState.isRefreshingCaptureTargets || appState.isRunning)
            }

            Button(appState.showsAllCaptureTargets ? "隐藏辅助/无标题窗口" : "显示全部可捕获窗口") {
                appState.toggleShowsAllCaptureTargets()
            }
            .disabled(appState.isRefreshingCaptureTargets || appState.isRunning)

            if let selected = appState.selectedCaptureTarget {
                Text("当前：\(selected.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("请先选择一个可捕获窗口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.availableCaptureTargets.isEmpty {
                Text("暂无窗口。打开播放器窗口后点击刷新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.availableCaptureTargets) { target in
                    Button("\(appState.selectedCaptureTarget?.id == target.id ? "✓ " : "")\(target.displayName)") {
                        appState.selectCaptureTarget(target)
                    }
                    .disabled(appState.isRunning)
                }
            }

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
                bringSettingsWindowToFront()
            }

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 300)
    }

    private func bringSettingsWindowToFront() {
        DispatchQueue.main.async {
            NSApplication.shared.activate()

            NSApplication.shared.windows
                .filter { $0.canBecomeKey && !$0.isMiniaturized }
                .forEach { window in
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
        }
    }
}
