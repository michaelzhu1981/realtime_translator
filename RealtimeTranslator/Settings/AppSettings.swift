import Foundation
import SwiftUI

struct AppSettings: Codable, Equatable {
    static let defaultASRModelCachePath = "~/Library/Caches/RealtimeTranslator/huggingface"

    var lmStudioBaseURL = "http://192.168.4.181:1234/v1"
    var lmStudioModel = "qwen/qwen3-4b-2507"
    var asrPythonPath = "~/local-asr/mlx-whisper/.venv/bin/python"
    var asrModel = "mlx-community/whisper-large-v3-turbo"
    var asrModelCachePath = Self.defaultASRModelCachePath
    var inputLanguage = "auto"
    var targetLanguage = "Simplified Chinese"
    var asrHost = "127.0.0.1"
    var asrPort = 8765
    var asrRequestTimeoutSeconds = 30.0
    var chunkDurationSeconds = 1.0
    var contextWindowSeconds = 3.0
    var translationTimeoutSeconds = 60.0
    var subtitleFontSize = 36.0
    var subtitleOpacity = 0.82
    var subtitleMaxLines = 2
    var subtitleMousePassthrough = true

    static let defaultsKey = "RealtimeTranslator.AppSettings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return AppSettings()
        }

        do {
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            if settings.asrModelCachePath == "models/huggingface" {
                settings.asrModelCachePath = Self.defaultASRModelCachePath
            }
            if settings.translationTimeoutSeconds == 5.0 {
                settings.translationTimeoutSeconds = 60.0
            }
            return settings
        } catch {
            return AppSettings()
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    var expandedASRPythonPath: String {
        (asrPythonPath as NSString).expandingTildeInPath
    }

    func resolvedASRModelCachePath(relativeTo baseDirectory: URL?) -> String {
        let expanded = (asrModelCachePath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }

        let baseDirectory = baseDirectory ?? Self.defaultWritableCacheDirectory
        return baseDirectory.appendingPathComponent(expanded).standardizedFileURL.path
    }

    var asrServiceURL: URL {
        URL(string: "http://\(asrHost):\(asrPort)")!
    }

    private static var defaultWritableCacheDirectory: URL {
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return caches.appendingPathComponent("RealtimeTranslator", isDirectory: true)
        }

        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RealtimeTranslator", isDirectory: true)
    }
}
