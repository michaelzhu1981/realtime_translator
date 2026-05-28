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
    private var activeTranslationText = ""
    private var activeTranslationStartedAt: Date?
    private var activeTranslationIsFinal = false
    private var retainedTranslationLines: [String] = []

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
            resetTranslationDisplayState()
            subtitleText = "请先选择要翻译的播放器窗口"
            subtitleWindow.update(text: subtitleText, settings: settings)
            refreshCaptureTargets()
            return
        }

        runState = .checkingBackends
        resetTranslationDisplayState()
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
                resetTranslationDisplayState()
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
            resetTranslationDisplayState()
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
                    resetTranslationDisplayState()
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
        resetTranslationDisplayState()
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
            displayTranslation(text, isFinal: false)
        case .translation(let text, let latencyMS):
            lastTranslationLatencyMS = latencyMS
            displayTranslation(text, isFinal: true)
        case .status(let state):
            runState = state
        case .statusMessage(let message):
            resetTranslationDisplayState()
            subtitleText = message
            subtitleWindow.update(text: message, settings: settings)
        case .targetWindowFrame(let frame):
            subtitleWindow.updateTargetWindowFrame(frame)
            subtitleWindow.update(text: subtitleText, settings: settings)
        case .error(let message):
            runState = .error(message)
        }
    }

    private func displayTranslation(_ text: String, isFinal: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if subtitlesAreExactlyEqual(text, activeTranslationText) {
            AppLogger.translation.info("subtitle.display action=dedupeExact isFinal=\(isFinal, privacy: .public) text=\(Self.logText(text), privacy: .public)")
            activeTranslationIsFinal = activeTranslationIsFinal || isFinal
            let visibleText = visibleTranslationText()
            subtitleText = visibleText
            subtitleWindow.update(text: visibleText, settings: settings)
            scheduleSubtitleAutoClear(for: visibleText)
            return
        }

        if activeTranslationText.isEmpty {
            AppLogger.translation.info("subtitle.display action=start isFinal=\(isFinal, privacy: .public) text=\(Self.logText(text), privacy: .public)")
            beginTranslationSegment(text)
        } else if subtitleIsExpansion(text, of: activeTranslationText) {
            AppLogger.translation.info("subtitle.display action=replaceExpansion isFinal=\(isFinal, privacy: .public) previous=\(Self.logText(self.activeTranslationText), privacy: .public) next=\(Self.logText(text), privacy: .public)")
            activeTranslationText = text
        } else if activeTranslationIsFinal {
            let action = shouldRetainActiveTranslation() ? "retain+append" : "replace"
            AppLogger.translation.info("subtitle.display action=\(action, privacy: .public) isFinal=\(isFinal, privacy: .public) previous=\(Self.logText(self.activeTranslationText), privacy: .public) next=\(Self.logText(text), privacy: .public)")
            beginNextTranslationSegment(text)
        } else {
            AppLogger.translation.info("subtitle.display action=updatePartial isFinal=\(isFinal, privacy: .public) previous=\(Self.logText(self.activeTranslationText), privacy: .public) next=\(Self.logText(text), privacy: .public)")
            activeTranslationText = text
        }

        activeTranslationIsFinal = isFinal
        let visibleText = visibleTranslationText()
        subtitleText = visibleText
        subtitleWindow.update(text: visibleText, settings: settings)
        scheduleSubtitleAutoClear(for: visibleText)
    }

    private func beginTranslationSegment(_ text: String) {
        retainedTranslationLines = []
        activeTranslationText = text
        activeTranslationStartedAt = Date()
        activeTranslationIsFinal = false
    }

    private func beginNextTranslationSegment(_ text: String) {
        if shouldRetainActiveTranslation() {
            retainedTranslationLines.append(activeTranslationText)
            retainedTranslationLines = tailLines(retainedTranslationLines, maxLines: max(0, settings.subtitleMaxLines - 1))
        } else {
            retainedTranslationLines = []
        }

        activeTranslationText = text
        activeTranslationStartedAt = Date()
        activeTranslationIsFinal = false
    }

    private func shouldRetainActiveTranslation() -> Bool {
        guard let activeTranslationStartedAt else { return false }

        let minimumVisibleSeconds = max(0, settings.subtitleMinimumVisibleSeconds)
        return Date().timeIntervalSince(activeTranslationStartedAt) < minimumVisibleSeconds
    }

    private func visibleTranslationText() -> String {
        tailLines(retainedTranslationLines + [activeTranslationText], maxLines: settings.subtitleMaxLines)
            .joined(separator: "\n")
    }

    private func subtitlesAreExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhs == rhs {
            return true
        }

        let lhsNormalized = Self.normalizedSubtitleForExpansion(lhs)
        let rhsNormalized = Self.normalizedSubtitleForExpansion(rhs)
        return !lhsNormalized.isEmpty && lhsNormalized == rhsNormalized
    }

    private func subtitleIsExpansion(_ candidate: String, of existing: String) -> Bool {
        let candidate = Self.normalizedSubtitleForExpansion(candidate)
        let existing = Self.normalizedSubtitleForExpansion(existing)
        guard !candidate.isEmpty, !existing.isEmpty, candidate.count > existing.count else {
            return false
        }

        return candidate.hasPrefix(existing)
    }

    private static func normalizedSubtitleForExpansion(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.punctuationCharacters.contains(scalar)
                    && !CharacterSet.symbols.contains(scalar)
            }
            .map(String.init)
            .joined()
    }

    private static func logText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 300
        guard trimmed.count > maxLength else {
            return "\(trimmed) [chars=\(trimmed.count)]"
        }

        return "\(String(trimmed.prefix(maxLength)))... [chars=\(trimmed.count)]"
    }

    private func tailLines(_ lines: [String], maxLines: Int) -> [String] {
        guard maxLines > 0 else { return [] }
        return Array(lines.suffix(maxLines))
    }

    private func resetTranslationDisplayState() {
        activeTranslationText = ""
        activeTranslationStartedAt = nil
        activeTranslationIsFinal = false
        retainedTranslationLines = []
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
