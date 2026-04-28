import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct CaptureTarget: Identifiable, Equatable {
    let windowID: CGWindowID
    let applicationName: String
    let bundleIdentifier: String?
    let windowTitle: String
    let frame: CGRect

    var id: CGWindowID { windowID }

    var displayName: String {
        if windowTitle.isEmpty {
            return applicationName
        }
        return "\(applicationName) - \(windowTitle)"
    }
}

enum CaptureTargetProvider {
    private static let allowedBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
        "com.apple.QuickTimePlayerX",
        "org.videolan.vlc",
        "com.colliderli.iina",
        "io.mpv",
        "com.movist.Movist",
        "com.firecore.infuse"
    ]

    private static let allowedApplicationNameFragments = [
        "Safari",
        "Chrome",
        "Firefox",
        "Edge",
        "Brave",
        "Arc",
        "Opera",
        "Vivaldi",
        "Chromium",
        "QuickTime",
        "VLC",
        "IINA",
        "mpv",
        "Movist",
        "Infuse"
    ]

    enum ProviderError: LocalizedError {
        case screenRecordingDenied

        var errorDescription: String? {
            switch self {
            case .screenRecordingDenied:
                return "未获得屏幕录制权限。请在系统设置 > 隐私与安全性 > 屏幕与系统音频录制中允许 RealtimeTranslator，然后重启 App。"
            }
        }
    }

    static func availableTargets(includeAllWindows: Bool = false) async throws -> [CaptureTarget] {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ProviderError.screenRecordingDenied
        }

        let currentProcessID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: !includeAllWindows
        )

        return content.windows
            .compactMap { window -> CaptureTarget? in
                guard let application = window.owningApplication,
                      application.processID != currentProcessID,
                      isAllowedCaptureApplication(application),
                      window.frame.width > 0,
                      window.frame.height > 0
                else {
                    return nil
                }

                let windowTitle = normalizedTitle(window.title)
                    ?? windowTitleFromWindowServer(windowID: window.windowID)
                    ?? ""

                guard includeAllWindows || !windowTitle.isEmpty else {
                    return nil
                }

                return CaptureTarget(
                    windowID: window.windowID,
                    applicationName: application.applicationName,
                    bundleIdentifier: application.bundleIdentifier,
                    windowTitle: windowTitle,
                    frame: window.frame
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private static func isAllowedCaptureApplication(_ application: SCRunningApplication) -> Bool {
        if allowedBundleIdentifiers.contains(application.bundleIdentifier) {
            return true
        }

        return allowedApplicationNameFragments.contains { fragment in
            application.applicationName.localizedCaseInsensitiveContains(fragment)
        }
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else {
            return nil
        }
        return title
    }

    private static func windowTitleFromWindowServer(windowID: CGWindowID) -> String? {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            windowID
        ) as? [[String: Any]],
            let title = windowInfoList.first?[kCGWindowName as String] as? String
        else {
            return nil
        }

        return normalizedTitle(title)
    }
}

final class WindowAudioCapture: NSObject {
    typealias AudioHandler = @Sendable (CMSampleBuffer) -> Void
    typealias DiagnosticsHandler = @Sendable (String) -> Void
    typealias WindowFrameHandler = @Sendable (CGRect) -> Void

    enum CaptureError: LocalizedError {
        case screenRecordingDenied
        case targetWindowNotFound(String)

        var errorDescription: String? {
            switch self {
            case .screenRecordingDenied:
                return "未获得屏幕录制权限。请在系统设置 > 隐私与安全性 > 屏幕与系统音频录制中允许 RealtimeTranslator，然后重启 App。"
            case .targetWindowNotFound(let targetName):
                return "未找到可捕获的窗口：\(targetName)。请确认目标播放器窗口仍在当前屏幕上可见。"
            }
        }
    }

    private let target: CaptureTarget
    private let audioHandler: AudioHandler
    private let diagnosticsHandler: DiagnosticsHandler
    private let windowFrameHandler: WindowFrameHandler
    private var stream: SCStream?
    private var windowFrameMonitorTask: Task<Void, Never>?
    private let outputQueue = DispatchQueue(label: "RealtimeTranslator.WindowAudioCapture")
    private let sampleStateLock = NSLock()
    private var hasReceivedAudioSample = false

    init(
        target: CaptureTarget,
        audioHandler: @escaping AudioHandler,
        diagnosticsHandler: @escaping DiagnosticsHandler,
        windowFrameHandler: @escaping WindowFrameHandler
    ) {
        self.target = target
        self.audioHandler = audioHandler
        self.diagnosticsHandler = diagnosticsHandler
        self.windowFrameHandler = windowFrameHandler
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.screenRecordingDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let targetWindow = content.windows.first(where: { window in
            window.windowID == target.windowID && window.frame.width > 0 && window.frame.height > 0
        }) else {
            throw CaptureError.targetWindowNotFound(target.displayName)
        }

        let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
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
        windowFrameHandler(targetWindow.frame)
        monitorWindowFrame(windowID: targetWindow.windowID)
        monitorAudioStartup()
        AppLogger.capture.info("Started window audio capture for \(self.target.displayName)")
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
            self.diagnosticsHandler("已启动 \(self.target.displayName) 捕获，但 5 秒内没有收到音频。请确认目标窗口正在播放有声音的视频，且系统已允许屏幕与系统音频录制。")
        }
    }

    private func monitorWindowFrame(windowID: CGWindowID) {
        windowFrameMonitorTask?.cancel()
        windowFrameMonitorTask = Task { [weak self] in
            var lastFrame: CGRect?

            while !Task.isCancelled {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    if let window = content.windows.first(where: { $0.windowID == windowID }) {
                        let frame = window.frame
                        if frame != lastFrame {
                            lastFrame = frame
                            self?.windowFrameHandler(frame)
                        }
                    }
                } catch {
                    AppLogger.capture.error("Failed to refresh target window frame: \(error.localizedDescription)")
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

extension WindowAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        markAudioSampleReceived()
        audioHandler(sampleBuffer)
    }
}
