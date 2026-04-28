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
    @Published private(set) var availableCaptureTargets: [CaptureTarget] = []
    @Published private(set) var selectedCaptureTarget: CaptureTarget?
    @Published private(set) var isRefreshingCaptureTargets = false
    @Published private(set) var showsAllCaptureTargets = false

    private let subtitleWindow = SubtitlePanelController()
    private var pipeline: TranslationPipeline?
    private var subtitleAutoClearTask: Task<Void, Never>?

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
        guard let selectedCaptureTarget else {
            subtitleText = "请先选择要翻译的播放器窗口"
            subtitleWindow.update(text: subtitleText, settings: settings)
            refreshCaptureTargets()
            return
        }

        runState = .checkingBackends
        subtitleText = "正在启动翻译..."
        subtitleWindow.show(text: subtitleText, settings: settings)

        let pipeline = TranslationPipeline(settings: settings, captureTarget: selectedCaptureTarget) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
        self.pipeline = pipeline

        Task {
            do {
                runState = .capturingAudio
                try await pipeline.start()
                runState = .running
                subtitleText = "已启动，等待 \(selectedCaptureTarget.displayName) 音频"
                subtitleWindow.update(text: subtitleText, settings: settings)
            } catch {
                runState = .error(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        runState = .stopping
        subtitleAutoClearTask?.cancel()
        Task {
            await pipeline?.stop()
            pipeline = nil
            runState = .idle
            subtitleText = "已停止"
            subtitleWindow.update(text: subtitleText, settings: settings)
        }
    }

    func refreshCaptureTargets() {
        guard !isRefreshingCaptureTargets else { return }
        isRefreshingCaptureTargets = true

        Task {
            do {
                let targets = try await CaptureTargetProvider.availableTargets(includeAllWindows: showsAllCaptureTargets)
                availableCaptureTargets = targets

                if let selectedCaptureTarget,
                   let refreshedSelection = targets.first(where: { $0.id == selectedCaptureTarget.id }) {
                    self.selectedCaptureTarget = refreshedSelection
                } else {
                    selectedCaptureTarget = targets.first
                }

                if targets.isEmpty {
                    subtitleText = "未发现可捕获窗口，请先打开并显示播放器窗口"
                    subtitleWindow.update(text: subtitleText, settings: settings)
                }
            } catch {
                runState = .error(error.localizedDescription)
            }

            isRefreshingCaptureTargets = false
        }
    }

    func selectCaptureTarget(_ target: CaptureTarget) {
        selectedCaptureTarget = target
        subtitleWindow.updateTargetWindowFrame(target.frame)
        subtitleWindow.update(text: subtitleText, settings: settings)
    }

    func toggleShowsAllCaptureTargets() {
        showsAllCaptureTargets.toggle()
        refreshCaptureTargets()
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
        subtitleAutoClearTask?.cancel()
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
            scheduleSubtitleAutoClear(for: text)
        case .translation(let text, let latencyMS):
            subtitleText = text
            lastTranslationLatencyMS = latencyMS
            subtitleWindow.update(text: text, settings: settings)
            scheduleSubtitleAutoClear(for: text)
        case .status(let state):
            runState = state
        case .statusMessage(let message):
            subtitleText = message
            subtitleWindow.update(text: message, settings: settings)
        case .targetWindowFrame(let frame):
            subtitleWindow.updateTargetWindowFrame(frame)
            subtitleWindow.update(text: subtitleText, settings: settings)
        case .error(let message):
            runState = .error(message)
        }
    }

    private func scheduleSubtitleAutoClear(for text: String) {
        subtitleAutoClearTask?.cancel()
        guard !text.isEmpty else { return }

        subtitleAutoClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.subtitleText == text else { return }
                self.subtitleText = ""
                self.subtitleWindow.update(text: self.subtitleText, settings: self.settings)
            }
        }
    }
}
