import Foundation

final class ASRServiceManager {
    enum ASRError: LocalizedError {
        case pythonMissing(String)
        case serviceScriptMissing
        case badResponse
        case startupTimedOut

        var errorDescription: String? {
            switch self {
            case .pythonMissing(let path):
                return "ASR Python 不存在：\(path)"
            case .serviceScriptMissing:
                return "未找到 asr_service.py"
            case .badResponse:
                return "ASR 服务返回无效响应"
            case .startupTimedOut:
                return "ASR 服务启动超时"
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

    private let settings: AppSettings
    private var process: Process?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func startIfNeeded() async throws {
        guard process == nil else { return }

        let pythonPath = settings.expandedASRPythonPath
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw ASRError.pythonMissing(pythonPath)
        }

        guard let scriptPath = Self.findServiceScriptPath() else {
            throw ASRError.serviceScriptMissing
        }
        let modelCachePath = settings.resolvedASRModelCachePath(relativeTo: Self.projectRoot(forServiceScriptAt: scriptPath))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: modelCachePath),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            scriptPath,
            "--model", settings.asrModel,
            "--language", settings.inputLanguage,
            "--host", settings.asrHost,
            "--port", String(settings.asrPort)
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HOME"] = modelCachePath
        environment["HUGGINGFACE_HUB_CACHE"] = URL(fileURLWithPath: modelCachePath)
            .appendingPathComponent("hub", isDirectory: true)
            .path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        self.process = process
        AppLogger.asr.info("Started ASR service")

        try await waitUntilHealthy()
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    func transcribe(audioURL: URL, requestID: String) async throws -> TranscriptionResponse {
        let url = settings.asrServiceURL.appendingPathComponent("transcribe")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "audio_path": audioURL.path,
            "language": settings.inputLanguage,
            "request_id": requestID
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ASRError.badResponse
        }
        return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    }

    private func waitUntilHealthy() async throws {
        let url = settings.asrServiceURL.appendingPathComponent("health")
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))

        while ContinuousClock.now < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    return
                }
            } catch {
                try await Task.sleep(for: .milliseconds(500))
            }
        }

        throw ASRError.startupTimedOut
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
