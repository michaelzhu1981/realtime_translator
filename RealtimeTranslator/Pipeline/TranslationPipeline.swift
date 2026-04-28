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
        case targetWindowFrame(CGRect)
        case error(String)
    }

    private let settings: AppSettings
    private let captureTarget: CaptureTarget
    private let eventHandler: @Sendable (Event) -> Void
    private let asr: ASRServiceManager
    private let translator: LMStudioTranslator
    private let chunkWriter: AudioChunkWriter?
    private let textStabilizer = SourceTextStabilizer()
    private let sentenceCommitter = SentenceCommitter()
    private var capture: WindowAudioCapture?
    private let queueLock = NSLock()
    private let maxPendingChunks = 2
    private var pendingChunks: [AudioChunkWriter.Chunk] = []
    private var isProcessingQueue = false
    private var isAcceptingChunks = false
    private var committedTranslationText = ""

    init(settings: AppSettings, captureTarget: CaptureTarget, eventHandler: @escaping @Sendable (Event) -> Void) {
        self.settings = settings
        self.captureTarget = captureTarget
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

        eventHandler(.statusMessage("正在请求窗口音频捕获权限..."))

        let capture = WindowAudioCapture(
            target: captureTarget,
            audioHandler: { [weak self] sampleBuffer in
                self?.handle(sampleBuffer: sampleBuffer)
            },
            diagnosticsHandler: { [eventHandler] message in
                eventHandler(.error(message))
            },
            windowFrameHandler: { [eventHandler] frame in
                eventHandler(.targetWindowFrame(frame))
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
        guard isAcceptingChunks else {
            queueLock.unlock()
            return false
        }

        pendingChunks.append(chunk)
        let staleChunks = drainStaleQueuedChunks()

        let shouldStartProcessing = !isProcessingQueue
        if shouldStartProcessing {
            isProcessingQueue = true
        }
        queueLock.unlock()

        staleChunks.forEach { chunkWriter?.remove($0) }
        if shouldStartProcessing {
            Task {
                await processQueuedChunks()
            }
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

    private func drainStaleQueuedChunks() -> [AudioChunkWriter.Chunk] {
        guard pendingChunks.count > maxPendingChunks else {
            return []
        }

        let staleCount = pendingChunks.count - maxPendingChunks
        let staleChunks = Array(pendingChunks.prefix(staleCount))
        pendingChunks.removeFirst(staleCount)
        return staleChunks
    }

    private func process(_ chunk: AudioChunkWriter.Chunk) async {
        defer {
            chunkWriter?.remove(chunk)
        }

        let asrStart = ContinuousClock.now
        do {
            let transcription = try await asr.transcribe(audioURL: chunk.url, requestID: chunk.id)
            guard let sourceUpdate = textStabilizer.accept(transcription.text) else { return }

            let measuredASRLatency = asrStart.duration(to: .now).milliseconds
            eventHandler(.sourceText(sourceUpdate.newText, latencyMS: max(transcription.durationMS, measuredASRLatency)))

            let commits = sentenceCommitter.accept(sourceUpdate.newText)
            for commit in commits {
                try await translateCommittedSourceText(commit.text, sourceContext: sourceUpdate.contextText)
            }
        } catch ASRServiceManager.ASRError.transcriptionTimedOut(let seconds) {
            eventHandler(.statusMessage("ASR 超过 \(Int(seconds)) 秒未返回，已自动重启，等待下一段音频..."))
        } catch {
            eventHandler(.error(error.localizedDescription))
        }
    }

    private func translateCommittedSourceText(_ sourceText: String, sourceContext: String) async throws {
        let translationStart = ContinuousClock.now
        let context = LMStudioTranslator.TranslationContext(
            recentSourceText: sourceContext,
            recentTranslationText: Self.recentContext(from: committedTranslationText)
        )
        let output = try await translator.translateStreaming(sourceText, context: context) { [eventHandler] partial in
            eventHandler(.translationPartial(partial))
        }
        committedTranslationText = Self.mergeSubtitle(committedTranslationText, output)
        eventHandler(.translation(output, latencyMS: translationStart.duration(to: .now).milliseconds))
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

    private static func joinSubtitle(_ existing: String, _ addition: String) -> String {
        let existing = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let addition = addition.trimmingCharacters(in: .whitespacesAndNewlines)

        if existing.isEmpty {
            return addition
        }
        if addition.isEmpty {
            return existing
        }
        return "\(existing)\n\(addition)"
    }

    private static func mergeSubtitle(_ existing: String, _ addition: String) -> String {
        let existing = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let addition = addition.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !existing.isEmpty, !addition.isEmpty else {
            return joinSubtitle(existing, addition)
        }

        var lines = existing
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let lastLine = lines.last else {
            return addition
        }

        if subtitlesAreSimilar(lastLine, addition) {
            lines[lines.count - 1] = preferredSubtitleLine(current: lastLine, replacement: addition)
            return lines.joined(separator: "\n")
        }

        lines.append(addition)
        return lines.joined(separator: "\n")
    }

    private static func preferredSubtitleLine(current: String, replacement: String) -> String {
        if replacement.count >= current.count {
            return replacement
        }
        return current
    }

    private static func subtitlesAreSimilar(_ lhs: String, _ rhs: String) -> Bool {
        let lhsNormalized = normalizedSubtitle(lhs)
        let rhsNormalized = normalizedSubtitle(rhs)
        guard !lhsNormalized.isEmpty, !rhsNormalized.isEmpty else {
            return false
        }
        if lhsNormalized == rhsNormalized {
            return true
        }
        if lhsNormalized.contains(rhsNormalized) || rhsNormalized.contains(lhsNormalized) {
            return true
        }

        return characterBigramSimilarity(lhsNormalized, rhsNormalized) >= 0.72
    }

    private static func normalizedSubtitle(_ text: String) -> String {
        text
            .lowercased()
            .unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.punctuationCharacters.contains(scalar)
                    && !CharacterSet.symbols.contains(scalar)
            }
            .map(String.init)
            .joined()
    }

    private static func characterBigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsBigrams = characterBigrams(lhs)
        let rhsBigrams = characterBigrams(rhs)
        guard !lhsBigrams.isEmpty, !rhsBigrams.isEmpty else {
            return 0
        }

        let intersectionCount = lhsBigrams.intersection(rhsBigrams).count
        return Double(2 * intersectionCount) / Double(lhsBigrams.count + rhsBigrams.count)
    }

    private static func characterBigrams(_ text: String) -> Set<String> {
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

    private static func visibleSubtitleText(_ text: String, maxLines: Int) -> String {
        tailLines(from: text, maxLines: max(1, maxLines))
    }

    private static func recentContext(from text: String) -> String {
        let recentLines = tailLines(from: text, maxLines: 6)
        if recentLines.count <= 1_000 {
            return recentLines
        }

        return String(recentLines.suffix(1_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tailLines(from text: String, maxLines: Int) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .suffix(maxLines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    struct Update {
        let newText: String
        let committedText: String
        let contextText: String
    }

    private struct Token: Equatable {
        let text: String
        let normalized: String
    }

    private let maxCommittedContextTokens = 80
    private let minimumCharacterCount = 2
    private var previousHypothesisTokens: [Token] = []
    private var committedTokens: [Token] = []

    func accept(_ text: String) -> Update? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacterCount else {
            return nil
        }

        let currentTokens = Self.tokens(from: trimmed)
        guard !currentTokens.isEmpty else {
            return nil
        }

        let newTokens = fastNewTokens(from: currentTokens) ?? agreementNewTokens(from: currentTokens)
        previousHypothesisTokens = currentTokens

        let newText = Self.render(newTokens)
        guard newText.count >= minimumCharacterCount else {
            return nil
        }

        committedTokens.append(contentsOf: newTokens)

        return Update(
            newText: newText,
            committedText: Self.render(committedTokens),
            contextText: Self.render(Array(committedTokens.suffix(maxCommittedContextTokens)))
        )
    }

    private func fastNewTokens(from currentTokens: [Token]) -> [Token]? {
        guard !currentTokens.isEmpty else {
            return []
        }
        guard !committedTokens.isEmpty else {
            return currentTokens
        }

        if Self.containsContiguousSequence(currentTokens, in: committedTokens) {
            return []
        }

        let recentCommittedTokens = Array(committedTokens.suffix(maxCommittedContextTokens))
        if let overlapEndIndex = Self.bestOverlapEndIndex(
            anchors: recentCommittedTokens,
            in: currentTokens,
            minimumLength: 2
        ) {
            return Array(currentTokens[overlapEndIndex...])
        }

        if let overlapEndIndex = Self.bestOverlapEndIndex(
            anchors: previousHypothesisTokens,
            in: currentTokens,
            minimumLength: 2
        ) {
            return Array(currentTokens[overlapEndIndex...])
        }

        let overlap = Self.longestSuffixPrefixOverlap(committedTokens, currentTokens)
        if overlap > 0 {
            return Array(currentTokens.dropFirst(overlap))
        }

        let previousOverlap = Self.longestSuffixPrefixOverlap(previousHypothesisTokens, currentTokens)
        if previousOverlap > 0 {
            return Array(currentTokens.dropFirst(previousOverlap))
        }

        return nil
    }

    private func agreementNewTokens(from currentTokens: [Token]) -> [Token] {
        guard !previousHypothesisTokens.isEmpty else {
            return []
        }

        let stableTokens = Self.longestCommonContiguousTokens(previousHypothesisTokens, currentTokens)
        if let newTokens = fastNewTokens(from: stableTokens) {
            return newTokens
        }

        if !Self.containsContiguousSequence(stableTokens, in: committedTokens),
           !Self.tokenSequencesAreSimilar(stableTokens, Array(committedTokens.suffix(maxCommittedContextTokens))) {
            return stableTokens
        }

        return []
    }

    private static func tokens(from text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""

        func flushCurrent() {
            let normalized = normalizeToken(current)
            if !normalized.isEmpty {
                tokens.append(Token(text: current, normalized: normalized))
            }
            current = ""
        }

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                flushCurrent()
            } else if CharacterSet.punctuationCharacters.contains(scalar) {
                flushCurrent()
                tokens.append(Token(text: String(scalar), normalized: String(scalar).lowercased()))
            } else if Self.isCJKScalar(scalar) {
                flushCurrent()
                tokens.append(Token(text: String(scalar), normalized: String(scalar).lowercased()))
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        flushCurrent()

        return tokens
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value))
            || (0x3040...0x30FF).contains(Int(scalar.value))
            || (0xAC00...0xD7AF).contains(Int(scalar.value))
    }

    private static func normalizeToken(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined()
    }

    private static func render(_ tokens: [Token]) -> String {
        tokens.reduce(into: "") { output, token in
            if output.isEmpty {
                output = token.text
            } else if shouldJoinWithoutSpace(previous: output, next: token.text) {
                output += token.text
            } else {
                output += " " + token.text
            }
        }
    }

    private static func shouldJoinWithoutSpace(previous: String, next: String) -> Bool {
        guard let previousScalar = previous.unicodeScalars.last,
              let nextScalar = next.unicodeScalars.first
        else {
            return false
        }

        return isCJKScalar(previousScalar)
            || isCJKScalar(nextScalar)
            || CharacterSet.punctuationCharacters.contains(nextScalar)
    }

    private static func longestCommonContiguousTokens(_ lhs: [Token], _ rhs: [Token]) -> [Token] {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return []
        }

        var lengths = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        var bestLength = 0
        var bestEndIndex = 0

        for lhsIndex in 1...lhs.count {
            for rhsIndex in 1...rhs.count {
                guard lhs[lhsIndex - 1].normalized == rhs[rhsIndex - 1].normalized else {
                    continue
                }

                let length = lengths[lhsIndex - 1][rhsIndex - 1] + 1
                lengths[lhsIndex][rhsIndex] = length
                if length > bestLength || (length == bestLength && rhsIndex > bestEndIndex) {
                    bestLength = length
                    bestEndIndex = rhsIndex
                }
            }
        }

        guard bestLength > 0 else {
            return []
        }

        return Array(rhs[(bestEndIndex - bestLength)..<bestEndIndex])
    }

    private static func longestSuffixPrefixOverlap(_ suffixSource: [Token], _ prefixSource: [Token]) -> Int {
        let maxLength = min(suffixSource.count, prefixSource.count)
        guard maxLength > 0 else {
            return 0
        }

        for length in stride(from: maxLength, through: 1, by: -1) {
            let suffix = suffixSource.suffix(length).map(\.normalized)
            let prefix = prefixSource.prefix(length).map(\.normalized)
            if Array(suffix) == Array(prefix) {
                return length
            }
        }

        return 0
    }

    private static func longestCommittedSuffixEndIndex(_ committed: [Token], in current: [Token]) -> Int? {
        let maxLength = min(committed.count, current.count)
        guard maxLength > 0 else {
            return nil
        }

        for length in stride(from: maxLength, through: 1, by: -1) {
            let suffix = committed.suffix(length).map(\.normalized)
            if let endIndex = lastEndIndex(of: suffix, in: current.map(\.normalized)) {
                return endIndex
            }
        }

        return nil
    }

    private static func bestOverlapEndIndex(anchors: [Token], in current: [Token], minimumLength: Int) -> Int? {
        guard !anchors.isEmpty, !current.isEmpty else {
            return nil
        }

        var lengths = Array(repeating: Array(repeating: 0, count: current.count + 1), count: anchors.count + 1)
        var bestLength = 0
        var bestEndIndex = 0

        for anchorIndex in 1...anchors.count {
            for currentIndex in 1...current.count {
                guard anchors[anchorIndex - 1].normalized == current[currentIndex - 1].normalized else {
                    continue
                }

                let length = lengths[anchorIndex - 1][currentIndex - 1] + 1
                lengths[anchorIndex][currentIndex] = length
                if length > bestLength || (length == bestLength && currentIndex > bestEndIndex) {
                    bestLength = length
                    bestEndIndex = currentIndex
                }
            }
        }

        guard bestLength >= minimumLength else {
            return nil
        }

        return bestEndIndex
    }

    private static func lastEndIndex(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else {
            return nil
        }

        for startIndex in stride(from: haystack.count - needle.count, through: 0, by: -1) {
            let endIndex = startIndex + needle.count
            if Array(haystack[startIndex..<endIndex]) == needle {
                return endIndex
            }
        }

        return nil
    }

    private static func containsContiguousSequence(_ needle: [Token], in haystack: [Token]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else {
            return false
        }

        for startIndex in 0...(haystack.count - needle.count) {
            let endIndex = startIndex + needle.count
            let candidate = haystack[startIndex..<endIndex].map(\.normalized)
            if candidate == needle.map(\.normalized) {
                return true
            }
        }

        return false
    }

    private static func tokenSequencesAreSimilar(_ lhs: [Token], _ rhs: [Token]) -> Bool {
        let lhsText = lhs.map(\.normalized).joined(separator: " ")
        let rhsText = rhs.map(\.normalized).joined(separator: " ")
        return characterBigramSimilarity(lhsText, rhsText) >= 0.82
    }

    private static func characterBigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsBigrams = characterBigrams(lhs)
        let rhsBigrams = characterBigrams(rhs)
        guard !lhsBigrams.isEmpty, !rhsBigrams.isEmpty else {
            return 0
        }

        let intersectionCount = lhsBigrams.intersection(rhsBigrams).count
        return Double(2 * intersectionCount) / Double(lhsBigrams.count + rhsBigrams.count)
    }

    private static func characterBigrams(_ text: String) -> Set<String> {
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

private final class SentenceCommitter {
    struct Commit {
        let text: String
    }

    private let pauseCommitThreshold: Duration = .milliseconds(800)
    private let maxBufferAge: Duration = .milliseconds(1_800)
    private let maxTokenCount = 28
    private let weakPunctuationMinimumTokenCount = 8
    private let minimumCharacterCount = 2
    private var buffer = ""
    private var bufferStartedAt: ContinuousClock.Instant?
    private var lastAppendAt: ContinuousClock.Instant?

    func accept(_ text: String, now: ContinuousClock.Instant = .now) -> [Commit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacterCount else {
            return []
        }

        var commits: [Commit] = []
        if shouldCommitForPause(now: now), let commit = drainBuffer() {
            commits.append(commit)
        }

        append(trimmed, now: now)
        commits.append(contentsOf: drainStrongSentences(now: now))

        if shouldCommitWeakClause(), let commit = drainBuffer() {
            commits.append(commit)
        } else if shouldCommitForAge(now: now) || shouldCommitForLength(), let commit = drainBuffer() {
            commits.append(commit)
        }

        lastAppendAt = now
        return commits
    }

    private func append(_ text: String, now: ContinuousClock.Instant) {
        if bufferStartedAt == nil {
            bufferStartedAt = now
        }

        if buffer.isEmpty {
            buffer = text
        } else if Self.shouldJoinWithoutSpace(buffer, text) {
            buffer += text
        } else {
            buffer += " " + text
        }
    }

    private func shouldCommitForPause(now: ContinuousClock.Instant) -> Bool {
        guard !buffer.isEmpty, let lastAppendAt else {
            return false
        }

        return lastAppendAt.duration(to: now) >= pauseCommitThreshold
    }

    private func shouldCommitForAge(now: ContinuousClock.Instant) -> Bool {
        guard !buffer.isEmpty, let bufferStartedAt else {
            return false
        }

        return bufferStartedAt.duration(to: now) >= maxBufferAge
    }

    private func shouldCommitForLength() -> Bool {
        Self.tokenCount(buffer) >= maxTokenCount
    }

    private func shouldCommitWeakClause() -> Bool {
        guard let lastScalar = buffer.unicodeScalars.last, Self.weakTerminators.contains(lastScalar) else {
            return false
        }

        return Self.tokenCount(buffer) >= weakPunctuationMinimumTokenCount
    }

    private func drainStrongSentences(now: ContinuousClock.Instant) -> [Commit] {
        var commits: [Commit] = []

        while let endIndex = Self.firstStrongTerminatorEndIndex(in: buffer) {
            let sentence = String(buffer[..<endIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[endIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count >= minimumCharacterCount {
                commits.append(Commit(text: sentence))
            }
        }

        if buffer.isEmpty {
            bufferStartedAt = nil
        } else if !commits.isEmpty {
            bufferStartedAt = now
        }

        return commits
    }

    private func drainBuffer() -> Commit? {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        bufferStartedAt = nil

        guard text.count >= minimumCharacterCount else {
            return nil
        }

        return Commit(text: text)
    }

    private static func firstStrongTerminatorEndIndex(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let nextIndex = text.index(after: index)
            let scalarText = String(text[index])
            if scalarText.unicodeScalars.contains(where: { strongTerminators.contains($0) }) {
                return nextIndex
            }
            index = nextIndex
        }

        return nil
    }

    private static func tokenCount(_ text: String) -> Int {
        var count = 0
        var isInsideWord = false

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                isInsideWord = false
            } else if isCJKScalar(scalar) {
                count += 1
                isInsideWord = false
            } else if !isInsideWord {
                count += 1
                isInsideWord = true
            }
        }

        return count
    }

    private static func shouldJoinWithoutSpace(_ existing: String, _ addition: String) -> Bool {
        guard let last = existing.unicodeScalars.last, let first = addition.unicodeScalars.first else {
            return false
        }

        return isCJKScalar(last) || isCJKScalar(first)
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value))
            || (0x3040...0x30FF).contains(Int(scalar.value))
            || (0xAC00...0xD7AF).contains(Int(scalar.value))
    }

    private static let strongTerminators = Set("。！？.!?".unicodeScalars)
    private static let weakTerminators = Set("，,；;：:、".unicodeScalars)
}

private extension Duration {
    var milliseconds: Int {
        let components = components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
