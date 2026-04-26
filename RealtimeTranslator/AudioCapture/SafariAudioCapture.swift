import AVFoundation
import Foundation
import ScreenCaptureKit

final class SafariAudioCapture: NSObject {
    typealias AudioHandler = @Sendable (CMSampleBuffer) -> Void

    enum CaptureError: LocalizedError {
        case safariNotFound

        var errorDescription: String? {
            switch self {
            case .safariNotFound:
                return "未找到可捕获的 Safari 应用，请先打开 Safari 并播放视频。"
            }
        }
    }

    private let audioHandler: AudioHandler
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "RealtimeTranslator.SafariAudioCapture")

    init(audioHandler: @escaping AudioHandler) {
        self.audioHandler = audioHandler
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let safari = content.applications.first(where: { app in
            app.bundleIdentifier == "com.apple.Safari" || app.applicationName.localizedCaseInsensitiveContains("Safari")
        }) else {
            throw CaptureError.safariNotFound
        }

        guard let safariWindow = content.windows.first(where: { $0.owningApplication?.processID == safari.processID }) else {
            throw CaptureError.safariNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: safariWindow)
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: SCStreamOutputType.audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
        AppLogger.capture.info("Started Safari audio capture")
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            AppLogger.capture.error("Failed to stop capture: \(error.localizedDescription)")
        }
        self.stream = nil
    }
}

extension SafariAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        audioHandler(sampleBuffer)
    }
}
