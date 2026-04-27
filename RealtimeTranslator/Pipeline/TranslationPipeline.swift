import AVFoundation
import CoreGraphics
import Foundation

final class TranslationPipeline {
    enum PipelineError: LocalizedError {
        case audioChunkWriterUnavailable

        var errorDescription: String? {
            switch self {
            case .audioChunkWriterUnavailable:
                return "无法初始化音频分片缓存目录"
            }
        }
    }

    enum Event {
        case sourceText(String, latencyMS: Int)
        case translationPartial(String)
        case translation(String, latencyMS: Int)
        case status(AppState.RunState)
        case statusMessage(String)
        case browserWindowFrame(CGRect)
        case error(String)
    }

    private let settings: AppSettings
    private let eventHandler: @Sendable (Event) -> Void
    private let asr: ASRServiceManager
    private let translator: LMStudioTranslator
    private let chunkWriter: AudioChunkWriter?
    private let textStabilizer = SourceTextStabilizer()
    private var capture: SafariAudioCapture?
    private let queueLock = NSLock()
    private var pendingChunks: [AudioChunkWriter.Chunk] = []
    private var isProcessingQueue = false
    private var isAcceptingChunks = false

    init(settings: AppSettings, eventHandler: @escaping @Sendable (Event) -> Void) {
        self.settings = settings
        self.eventHandler = eventHandler
        self.asr = ASRServiceManager(settings: settings)
        self.translator = LMStudioTranslator(settings: settings)
        self.chunkWriter = try? AudioChunkWriter(settings: settings)
    }

    func start() async throws {
        guard chunkWriter != nil else {
            throw PipelineError.audioChunkWriterUnavailable
        }
        setAcceptingChunks(true)

        eventHandler(.statusMessage("正在启动 ASR 服务..."))
        try await asr.startIfNeeded()

        eventHandler(.statusMessage("正在连接 LM Studio..."))
        try await translator.testConnection()

        eventHandler(.statusMessage("正在请求 Safari 音频捕获权限..."))

        let capture = SafariAudioCapture(
            audioHandler: { [weak self] sampleBuffer in
                self?.handle(sampleBuffer: sampleBuffer)
            },
            diagnosticsHandler: { [eventHandler] message in
                eventHandler(.error(message))
            },
            windowFrameHandler: { [eventHandler] frame in
                eventHandler(.browserWindowFrame(frame))
            }
        )
        self.capture = capture
        try await capture.start()
    }

    func stop() async {
        let chunksToRemove = stopAcceptingChunksAndDrainQueue()
        chunksToRemove.forEach { chunkWriter?.remove($0) }
        await capture?.stop()
        capture = nil
        asr.stop()
    }

    private func handle(sampleBuffer: CMSampleBuffer) {
        do {
            guard let chunkWriter else { return }
            guard let chunk = try chunkWriter.append(sampleBuffer) else { return }
            guard enqueue(chunk) else {
                chunkWriter.remove(chunk)
                return
            }
        } catch {
            eventHandler(.error(error.localizedDescription))
        }
    }

    private func enqueue(_ chunk: AudioChunkWriter.Chunk) -> Bool {
        queueLock.lock()
        defer { queueLock.unlock() }

        guard isAcceptingChunks else { return false }
        pendingChunks.append(chunk)

        guard !isProcessingQueue else { return true }
        isProcessingQueue = true
        Task {
            await processQueuedChunks()
        }
        return true
    }

    private func processQueuedChunks() async {
        while let chunk = dequeue() {
            await process(chunk)
        }

        queueLock.lock()
        isProcessingQueue = false
        let shouldRestart = isAcceptingChunks && !pendingChunks.isEmpty
        if shouldRestart {
            isProcessingQueue = true
        }
        queueLock.unlock()

        if shouldRestart {
            await processQueuedChunks()
        }
    }

    private func dequeue() -> AudioChunkWriter.Chunk? {
        queueLock.lock()
        defer { queueLock.unlock() }

        guard isAcceptingChunks, !pendingChunks.isEmpty else {
            return nil
        }
        return pendingChunks.removeFirst()
    }

    private func process(_ chunk: AudioChunkWriter.Chunk) async {
        defer {
            chunkWriter?.remove(chunk)
        }

        let asrStart = ContinuousClock.now
        do {
            let transcription = try await asr.transcribe(audioURL: chunk.url, requestID: chunk.id)
            guard let sourceText = textStabilizer.accept(transcription.text) else { return }

            let measuredASRLatency = asrStart.duration(to: .now).milliseconds
            eventHandler(.sourceText(sourceText, latencyMS: max(transcription.durationMS, measuredASRLatency)))

            let translationStart = ContinuousClock.now
            let output = try await translator.translateStreaming(sourceText) { [eventHandler] partial in
                eventHandler(.translationPartial(partial))
            }
            eventHandler(.translation(output, latencyMS: translationStart.duration(to: .now).milliseconds))
        } catch ASRServiceManager.ASRError.transcriptionTimedOut(let seconds) {
            eventHandler(.statusMessage("ASR 超过 \(Int(seconds)) 秒未返回，已自动重启，等待下一段音频..."))
        } catch {
            eventHandler(.error(error.localizedDescription))
        }
    }

    private func setAcceptingChunks(_ isAccepting: Bool) {
        queueLock.lock()
        isAcceptingChunks = isAccepting
        queueLock.unlock()
    }

    private func stopAcceptingChunksAndDrainQueue() -> [AudioChunkWriter.Chunk] {
        queueLock.lock()
        defer { queueLock.unlock() }

        isAcceptingChunks = false
        let chunks = pendingChunks
        pendingChunks.removeAll()
        return chunks
    }

    func translateFixtureText(_ sourceText: String) async {
        let start = ContinuousClock.now
        do {
            let output = try await translator.translate(sourceText)
            let elapsed = start.duration(to: .now).milliseconds
            eventHandler(.translation(output, latencyMS: elapsed))
        } catch {
            eventHandler(.error(error.localizedDescription))
        }
    }
}

private final class SourceTextStabilizer {
    private let maxRecentCount = 8
    private let minimumCharacterCount = 2
    private let duplicateSimilarityThreshold = 0.92
    private var recentNormalizedTexts: [String] = []

    func accept(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacterCount else {
            return nil
        }

        let normalized = Self.normalize(trimmed)
        guard !normalized.isEmpty else {
            return nil
        }

        guard !isDuplicate(normalized) else {
            return nil
        }

        recentNormalizedTexts.append(normalized)
        if recentNormalizedTexts.count > maxRecentCount {
            recentNormalizedTexts.removeFirst(recentNormalizedTexts.count - maxRecentCount)
        }

        return trimmed
    }

    private func isDuplicate(_ normalized: String) -> Bool {
        recentNormalizedTexts.contains { previous in
            previous == normalized || Self.similarity(previous, normalized) >= duplicateSimilarityThreshold
        }
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters.union(.symbols))
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs {
            return 1
        }

        let lhsBigrams = bigrams(lhs)
        let rhsBigrams = bigrams(rhs)
        guard !lhsBigrams.isEmpty, !rhsBigrams.isEmpty else {
            return 0
        }

        let intersectionCount = lhsBigrams.intersection(rhsBigrams).count
        return Double(2 * intersectionCount) / Double(lhsBigrams.count + rhsBigrams.count)
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count > 1 else {
            return Set(characters.map(String.init))
        }

        var output = Set<String>()
        for index in 0..<(characters.count - 1) {
            output.insert(String(characters[index...index + 1]))
        }
        return output
    }
}

private extension Duration {
    var milliseconds: Int {
        let components = components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
