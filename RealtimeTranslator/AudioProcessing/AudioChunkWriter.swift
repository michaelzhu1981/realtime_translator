import AVFoundation
import CoreMedia
import Foundation

final class AudioChunkWriter {
    enum ChunkError: LocalizedError {
        case invalidSampleFormat
        case copyFailed(OSStatus)
        case converterUnavailable
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidSampleFormat:
                return "无法读取音频样本格式"
            case .copyFailed(let status):
                return "复制音频样本失败：\(status)"
            case .converterUnavailable:
                return "无法创建音频格式转换器"
            case .conversionFailed(let message):
                return "音频转换失败：\(message)"
            }
        }
    }

    struct Chunk {
        let url: URL
        let id: String
        let durationMS: Int
    }

    private let targetFormat: AVAudioFormat
    private let framesPerChunk: AVAudioFramePosition
    private let framesPerContext: AVAudioFramePosition
    private let cacheDirectory: URL
    private let energyThreshold: Float = 0.003

    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFramePosition = 0
    private var contextBuffers: [AVAudioPCMBuffer] = []
    private var contextFrames: AVAudioFramePosition = 0
    private var chunkIndex = 0

    init(settings: AppSettings) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw ChunkError.invalidSampleFormat
        }

        self.targetFormat = format
        self.framesPerChunk = AVAudioFramePosition(settings.chunkDurationSeconds * format.sampleRate)
        self.framesPerContext = AVAudioFramePosition(max(0, settings.contextWindowSeconds) * format.sampleRate)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = caches.appendingPathComponent("RealtimeTranslator/audio-chunks", isDirectory: true)

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try cleanCacheDirectory()
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws -> Chunk? {
        let inputBuffer = try makePCMBuffer(from: sampleBuffer)
        let buffer = try convertToTargetFormat(inputBuffer)

        guard hasSpeech(in: buffer) else {
            return nil
        }

        pendingBuffers.append(try copyBuffer(buffer))
        pendingFrames += AVAudioFramePosition(buffer.frameLength)

        guard pendingFrames >= framesPerChunk else {
            return nil
        }

        return try finishCurrentChunk()
    }

    private func finishCurrentChunk() throws -> Chunk? {
        guard pendingFrames > 0 else {
            pendingBuffers.removeAll()
            pendingFrames = 0
            return nil
        }

        let buffers = contextBuffers + pendingBuffers
        let url = nextChunkURL()
        let file = try AVAudioFile(forWriting: url, settings: targetFormat.settings)
        for buffer in buffers where buffer.frameLength > 0 {
            try file.write(from: buffer)
        }

        let totalFrames = buffers.reduce(AVAudioFramePosition(0)) { partialResult, buffer in
            partialResult + AVAudioFramePosition(buffer.frameLength)
        }
        let durationMS = Int(Double(totalFrames) / targetFormat.sampleRate * 1_000)
        let id = url.deletingPathExtension().lastPathComponent

        appendPendingToContext()
        pendingBuffers.removeAll()
        pendingFrames = 0

        return Chunk(url: url, id: id, durationMS: durationMS)
    }

    func remove(_ chunk: Chunk) {
        try? FileManager.default.removeItem(at: chunk.url)
    }

    private func nextChunkURL() -> URL {
        chunkIndex += 1
        let filename = String(format: "chunk-%06d.wav", chunkIndex)
        return cacheDirectory.appendingPathComponent(filename)
    }

    private func appendPendingToContext() {
        guard framesPerContext > 0 else {
            contextBuffers.removeAll()
            contextFrames = 0
            return
        }

        contextBuffers.append(contentsOf: pendingBuffers)
        contextFrames += pendingFrames

        while contextFrames > framesPerContext, let first = contextBuffers.first {
            contextFrames -= AVAudioFramePosition(first.frameLength)
            contextBuffers.removeFirst()
        }
    }

    private func cleanCacheDirectory() throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )
        for url in urls where url.pathExtension == "wav" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            let format = AVAudioFormat(streamDescription: streamDescription)
        else {
            throw ChunkError.invalidSampleFormat
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ChunkError.invalidSampleFormat
        }
        buffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw ChunkError.copyFailed(status)
        }

        return buffer
    }

    private func convertToTargetFormat(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if input.format.sampleRate == targetFormat.sampleRate,
           input.format.channelCount == targetFormat.channelCount,
           input.format.commonFormat == targetFormat.commonFormat {
            return input
        }

        guard let converter = AVAudioConverter(from: input.format, to: targetFormat) else {
            throw ChunkError.converterUnavailable
        }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw ChunkError.invalidSampleFormat
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error {
            throw ChunkError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
        }

        return output
    }

    private func copyBuffer(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: source.frameLength) else {
            throw ChunkError.invalidSampleFormat
        }
        copy.frameLength = source.frameLength

        guard let sourceChannels = source.floatChannelData,
              let copyChannels = copy.floatChannelData
        else {
            throw ChunkError.invalidSampleFormat
        }

        let frameLength = Int(source.frameLength)
        for channel in 0..<Int(targetFormat.channelCount) {
            copyChannels[channel].update(from: sourceChannels[channel], count: frameLength)
        }

        return copy
    }

    private func hasSpeech(in buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else {
            return true
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return false }

        var sum: Float = 0
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for frame in 0..<frameLength {
                let sample = data[frame]
                sum += sample * sample
            }
        }

        let mean = sum / Float(frameLength * max(channelCount, 1))
        return sqrt(mean) >= energyThreshold
    }
}
