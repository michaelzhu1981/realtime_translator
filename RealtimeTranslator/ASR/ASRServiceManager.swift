import Darwin
import Foundation

final class ASRServiceManager {
    enum ASRError: LocalizedError {
        case pythonMissing(String)
        case serviceScriptMissing
        case modelCacheUnavailable(String, String)
        case ffmpegMissing
        case badResponse(Int, String)
        case startupTimedOut
        case serviceOwnershipMismatch
        case transcriptionTimedOut(Double)
        case noAvailablePort

        var errorDescription: String? {
            switch self {
            case .pythonMissing(let path):
                return "ASR Python 不存在：\(path)"
            case .serviceScriptMissing:
                return "未找到 asr_service.py"
            case .modelCacheUnavailable(let path, let reason):
                return "无法创建 ASR 模型缓存目录：\(path)。\(reason)"
            case .ffmpegMissing:
                return "ASR 需要 ffmpeg，但未找到。请安装 Homebrew ffmpeg，或确认 /opt/homebrew/bin/ffmpeg 可执行。"
            case .badResponse(let statusCode, let message):
                return "ASR 服务返回错误：HTTP \(statusCode)。\(message)"
            case .startupTimedOut:
                return "ASR 服务启动超时"
            case .serviceOwnershipMismatch:
                return "ASR 服务端口被旧进程占用，请退出 RealtimeTranslator 后重试"
            case .transcriptionTimedOut(let seconds):
                return "ASR 转写超过 \(Int(seconds)) 秒未返回，已重启 ASR 服务"
            case .noAvailablePort:
                return "无法启动 ASR 服务：没有可用的本地端口"
            }
        }
    }

    struct TranscriptionResponse: Decodable {
        let text: String
        let language: String?
        let durationMS: Int

        enum CodingKeys: String, CodingKey {
            case text
            case language
            case durationMS = "duration_ms"
        }
    }

    private struct HealthResponse: Decodable {
        let ok: Bool
        let ownerToken: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case ownerToken = "owner_token"
        }
    }

    private let settings: AppSettings
    private var process: Process?
    private var ownerToken = UUID().uuidString
    private var selectedASRPort: Int?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func startIfNeeded() async throws {
        guard process == nil else { return }
        ownerToken = UUID().uuidString

        let pythonPath = settings.expandedASRPythonPath
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw ASRError.pythonMissing(pythonPath)
        }
        guard Self.ffmpegPath() != nil else {
            throw ASRError.ffmpegMissing
        }

        guard let scriptPath = Self.findServiceScriptPath() else {
            throw ASRError.serviceScriptMissing
        }
        let modelCachePath = settings.resolvedASRModelCachePath(relativeTo: Self.projectRoot(forServiceScriptAt: scriptPath))
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: modelCachePath),
                withIntermediateDirectories: true
            )
        } catch {
            throw ASRError.modelCacheUnavailable(modelCachePath, error.localizedDescription)
        }
        await terminateStaleServiceIfNeeded(port: AppSettings.defaultASRPort)
        let selectedASRPort = try Self.availablePort(
            host: settings.asrHost,
            startingAt: AppSettings.defaultASRPort,
            attempts: 100
        )
        self.selectedASRPort = selectedASRPort

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            scriptPath,
            "--model", settings.asrModel,
            "--language", settings.inputLanguage,
            "--host", settings.asrHost,
            "--port", String(selectedASRPort),
            "--owner-token", ownerToken,
            "--request-timeout", String(settings.asrRequestTimeoutSeconds)
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HOME"] = modelCachePath
        environment["HUGGINGFACE_HUB_CACHE"] = URL(fileURLWithPath: modelCachePath)
            .appendingPathComponent("hub", isDirectory: true)
            .path
        environment["PATH"] = Self.asrEnvironmentPath(from: environment["PATH"])
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        self.process = process
        AppLogger.asr.info("Started ASR service")

        try await waitUntilHealthy()
    }

    func stop() {
        terminateProcess()
        process = nil
        selectedASRPort = nil
    }

    func transcribe(audioURL: URL, requestID: String) async throws -> TranscriptionResponse {
        do {
            return try await performTranscription(audioURL: audioURL, requestID: requestID)
        } catch ASRError.transcriptionTimedOut(_) {
            AppLogger.asr.error("ASR transcription timed out; restarting service")
            stop()
            try await startIfNeeded()
            throw ASRError.transcriptionTimedOut(settings.asrRequestTimeoutSeconds)
        } catch let error as URLError where error.code == .timedOut {
            AppLogger.asr.error("ASR request timed out; restarting service")
            stop()
            try await startIfNeeded()
            throw ASRError.transcriptionTimedOut(settings.asrRequestTimeoutSeconds)
        }
    }

    private static func errorMessage(from data: Data) -> String {
        struct ErrorResponse: Decodable {
            let error: String
        }

        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            return decoded.error
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return "响应体为空"
    }

    private func waitUntilHealthy() async throws {
        let url = try asrServiceURL().appendingPathComponent("health")
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))

        while ContinuousClock.now < deadline {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 2
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }

                let health = try JSONDecoder().decode(HealthResponse.self, from: data)
                if health.ok, health.ownerToken == ownerToken {
                    return
                }
                if process?.isRunning == false {
                    throw ASRError.serviceOwnershipMismatch
                }
            } catch ASRError.serviceOwnershipMismatch {
                throw ASRError.serviceOwnershipMismatch
            } catch {
                try await Task.sleep(for: .milliseconds(500))
            }
        }

        throw ASRError.startupTimedOut
    }

    private func terminateStaleServiceIfNeeded(port: Int) async {
        guard await isServiceResponding(port: port) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = [
            "-f",
            "asr_service.py.*--port \(port)"
        ]

        do {
            try process.run()
            process.waitUntilExit()
            try? await Task.sleep(for: .milliseconds(500))
        } catch {
            AppLogger.asr.error("Failed to terminate stale ASR service: \(error.localizedDescription)")
        }
    }

    private func isServiceResponding(port: Int) async -> Bool {
        let url = Self.asrServiceURL(host: settings.asrHost, port: port).appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 1

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func performTranscription(audioURL: URL, requestID: String) async throws -> TranscriptionResponse {
        let url = try asrServiceURL().appendingPathComponent("transcribe")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(1, settings.asrRequestTimeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "audio_path": audioURL.path,
            "language": settings.inputLanguage,
            "request_id": requestID
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ASRError.badResponse(-1, "响应不是 HTTP 响应")
        }
        guard httpResponse.statusCode == 200 else {
            let message = Self.errorMessage(from: data)
            if httpResponse.statusCode == 504 || message.localizedCaseInsensitiveContains("timed out") {
                throw ASRError.transcriptionTimedOut(settings.asrRequestTimeoutSeconds)
            }
            throw ASRError.badResponse(httpResponse.statusCode, message)
        }
        return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    }

    private func asrServiceURL() throws -> URL {
        guard let selectedASRPort else {
            throw ASRError.noAvailablePort
        }

        return Self.asrServiceURL(host: settings.asrHost, port: selectedASRPort)
    }

    private static func asrServiceURL(host: String, port: Int) -> URL {
        URL(string: "http://\(host):\(port)")!
    }

    private func terminateProcess() {
        guard let process else { return }

        if process.isRunning {
            process.terminate()
        }
    }

    private static func availablePort(host: String, startingAt startPort: Int, attempts: Int) throws -> Int {
        let firstPort = max(1, startPort)
        let lastPort = min(65535, firstPort + max(0, attempts - 1))

        for port in firstPort...lastPort {
            if canBind(host: host, port: port) {
                return port
            }
        }

        throw ASRError.noAvailablePort
    }

    private static func canBind(host: String, port: Int) -> Bool {
        let socketFileDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFileDescriptor >= 0 else { return false }
        defer { Darwin.close(socketFileDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            return false
        }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(socketFileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.stride)) == 0
            }
        }
    }

    private static func asrEnvironmentPath(from currentPath: String?) -> String {
        let requiredPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existingPaths = currentPath?
            .split(separator: ":")
            .map(String.init) ?? []

        return (requiredPaths + existingPaths)
            .reduce(into: [String]()) { paths, path in
                if !paths.contains(path) {
                    paths.append(path)
                }
            }
            .joined(separator: ":")
    }

    private static func ffmpegPath() -> String? {
        [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func findServiceScriptPath() -> String? {
        if let bundled = Bundle.main.path(forResource: "asr_service", ofType: "py") {
            return bundled
        }

        let developmentPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/asr/asr_service.py")
            .path
        if FileManager.default.fileExists(atPath: developmentPath) {
            return developmentPath
        }

        return nil
    }

    private static func projectRoot(forServiceScriptAt scriptPath: String) -> URL? {
        let scriptURL = URL(fileURLWithPath: scriptPath)
        let projectRoot = scriptURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        guard FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("RealtimeTranslator.xcodeproj").path) else {
            return nil
        }

        return projectRoot
    }
}
