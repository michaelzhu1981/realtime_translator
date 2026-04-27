import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

final class SafariAudioCapture: NSObject {
    typealias AudioHandler = @Sendable (CMSampleBuffer) -> Void
    typealias DiagnosticsHandler = @Sendable (String) -> Void
    typealias WindowFrameHandler = @Sendable (CGRect) -> Void

    enum CaptureError: LocalizedError {
        case screenRecordingDenied
        case safariNotFound
        case safariWindowNotFound

        var errorDescription: String? {
            switch self {
            case .screenRecordingDenied:
                return "未获得屏幕录制权限。请在系统设置 > 隐私与安全性 > 屏幕与系统音频录制中允许 RealtimeTranslator，然后重启 App。"
            case .safariNotFound:
                return "未找到可捕获的 Safari 应用，请先打开 Safari 并播放视频。"
            case .safariWindowNotFound:
                return "未找到可捕获的 Safari 窗口，请确认 Safari 窗口在当前屏幕上可见。"
            }
        }
    }

    private let audioHandler: AudioHandler
    private let diagnosticsHandler: DiagnosticsHandler
    private let windowFrameHandler: WindowFrameHandler
    private var stream: SCStream?
    private var windowFrameMonitorTask: Task<Void, Never>?
    private let outputQueue = DispatchQueue(label: "RealtimeTranslator.SafariAudioCapture")
    private let sampleStateLock = NSLock()
    private var hasReceivedAudioSample = false

    init(
        audioHandler: @escaping AudioHandler,
        diagnosticsHandler: @escaping DiagnosticsHandler,
        windowFrameHandler: @escaping WindowFrameHandler
    ) {
        self.audioHandler = audioHandler
        self.diagnosticsHandler = diagnosticsHandler
        self.windowFrameHandler = windowFrameHandler
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.screenRecordingDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let safari = content.applications.first(where: { app in
            app.bundleIdentifier == "com.apple.Safari" || app.applicationName.localizedCaseInsensitiveContains("Safari")
        }) else {
            throw CaptureError.safariNotFound
        }

        guard let safariWindow = content.windows.first(where: { window in
            window.owningApplication?.processID == safari.processID && window.frame.width > 0 && window.frame.height > 0
        }) else {
            throw CaptureError.safariWindowNotFound
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
        windowFrameHandler(safariWindow.frame)
        monitorWindowFrame(windowID: safariWindow.windowID)
        monitorAudioStartup()
        AppLogger.capture.info("Started Safari audio capture")
    }

    func stop() async {
        windowFrameMonitorTask?.cancel()
        windowFrameMonitorTask = nil

        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            AppLogger.capture.error("Failed to stop capture: \(error.localizedDescription)")
        }
        self.stream = nil
    }

    private func markAudioSampleReceived() {
        sampleStateLock.lock()
        hasReceivedAudioSample = true
        sampleStateLock.unlock()
    }

    private func hasReceivedAudio() -> Bool {
        sampleStateLock.lock()
        defer { sampleStateLock.unlock() }
        return hasReceivedAudioSample
    }

    private func monitorAudioStartup() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !self.hasReceivedAudio() else { return }
            self.diagnosticsHandler("已启动 Safari 捕获，但 5 秒内没有收到音频。请确认 Safari 正在播放有声音的视频，且系统已允许屏幕与系统音频录制。")
        }
    }

    private func monitorWindowFrame(windowID: CGWindowID) {
        windowFrameMonitorTask?.cancel()
        windowFrameMonitorTask = Task { [weak self] in
            var lastFrame: CGRect?

            while !Task.isCancelled {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    if let window = content.windows.first(where: { $0.windowID == windowID }) {
                        let frame = window.frame
                        if frame != lastFrame {
                            lastFrame = frame
                            self?.windowFrameHandler(frame)
                        }
                    }
                } catch {
                    AppLogger.capture.error("Failed to refresh Safari window frame: \(error.localizedDescription)")
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

extension SafariAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        markAudioSampleReceived()
        audioHandler(sampleBuffer)
    }
}
