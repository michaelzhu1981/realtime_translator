import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum RunState: Equatable {
        case idle
        case checkingBackends
        case capturingAudio
        case running
        case stopping
        case error(String)

        var label: String {
            switch self {
            case .idle:
                return "未运行"
            case .checkingBackends:
                return "检查后端中"
            case .capturingAudio:
                return "正在捕获"
            case .running:
                return "正在翻译"
            case .stopping:
                return "停止中"
            case .error(let message):
                return "错误：\(message)"
            }
        }
    }

    @Published var settings = AppSettings.load()
    @Published private(set) var runState: RunState = .idle
    @Published var subtitleText = "等待开始翻译"
    @Published var lastSourceText = ""
    @Published var lastASRLatencyMS: Int?
    @Published var lastTranslationLatencyMS: Int?

    private let subtitleWindow = SubtitlePanelController()
    private lazy var pipeline = TranslationPipeline(settings: settings) { [weak self] event in
        Task { @MainActor in
            self?.handle(event)
        }
    }

    var isRunning: Bool {
        if case .idle = runState {
            return false
        }
        if case .error = runState {
            return false
        }
        return true
    }

    func start() {
        guard !isRunning else { return }
        runState = .checkingBackends
        subtitleText = "正在启动翻译..."
        subtitleWindow.show(text: subtitleText, settings: settings)

        pipeline = TranslationPipeline(settings: settings) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        Task {
            do {
                runState = .capturingAudio
                try await pipeline.start()
                runState = .running
                subtitleText = "已启动，等待 Safari 音频"
                subtitleWindow.update(text: subtitleText, settings: settings)
            } catch {
                runState = .error(error.localizedDescription)
                subtitleText = "启动失败：\(error.localizedDescription)"
                subtitleWindow.update(text: subtitleText, settings: settings)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        runState = .stopping
        Task {
            await pipeline.stop()
            runState = .idle
            subtitleText = "已停止"
            subtitleWindow.update(text: subtitleText, settings: settings)
        }
    }

    func toggleSubtitleWindow() {
        subtitleWindow.toggle(text: subtitleText, settings: settings)
    }

    func toggleWindowLock() {
        settings.subtitleMousePassthrough.toggle()
        saveSettings()
        subtitleWindow.update(text: subtitleText, settings: settings)
    }

    func clearSubtitle() {
        subtitleText = ""
        lastSourceText = ""
        subtitleWindow.update(text: subtitleText, settings: settings)
    }

    func saveSettings() {
        settings.save()
        subtitleWindow.update(text: subtitleText, settings: settings)
    }

    private func handle(_ event: TranslationPipeline.Event) {
        switch event {
        case .sourceText(let text, let latencyMS):
            lastSourceText = text
            lastASRLatencyMS = latencyMS
        case .translationPartial(let text):
            subtitleText = text
            subtitleWindow.update(text: text, settings: settings)
        case .translation(let text, let latencyMS):
            subtitleText = text
            lastTranslationLatencyMS = latencyMS
            subtitleWindow.update(text: text, settings: settings)
        case .status(let state):
            runState = state
        case .statusMessage(let message):
            subtitleText = message
            subtitleWindow.update(text: message, settings: settings)
        case .browserWindowFrame(let frame):
            subtitleWindow.updateTargetWindowFrame(frame)
            subtitleWindow.update(text: subtitleText, settings: settings)
        case .error(let message):
            runState = .error(message)
            subtitleText = message
            subtitleWindow.update(text: message, settings: settings)
        }
    }
}
