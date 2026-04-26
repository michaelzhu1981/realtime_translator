import Foundation

final class LMStudioTranslator {
    enum TranslationError: LocalizedError {
        case invalidBaseURL
        case badResponse(Int)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "LM Studio Base URL 无效"
            case .badResponse(let code):
                return "LM Studio 返回错误：HTTP \(code)"
            case .emptyOutput:
                return "LM Studio 返回空译文"
            }
        }
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message?
        }

        let choices: [Choice]
    }

    private struct StreamingChatResponse: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }

            let delta: Delta?
        }

        let choices: [Choice]
    }

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func testConnection() async throws {
        guard let url = URL(string: settings.lmStudioBaseURL)?.appendingPathComponent("models") else {
            throw TranslationError.invalidBaseURL
        }
        let (_, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranslationError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    func translate(_ sourceText: String) async throws -> String {
        guard let url = chatCompletionsURL() else {
            throw TranslationError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.translationTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(chatRequest(sourceText: sourceText, stream: false))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranslationError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let output = decoded.choices.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, !output.isEmpty else {
            throw TranslationError.emptyOutput
        }
        return output
    }

    func translateStreaming(
        _ sourceText: String,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let url = URL(string: settings.lmStudioBaseURL)?.appendingPathComponent("chat/completions") else {
            throw TranslationError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = settings.translationTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(chatRequest(sourceText: sourceText, stream: true))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranslationError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        var output = ""
        for try await line in bytes.lines {
            guard let payload = Self.streamingPayload(from: line) else {
                continue
            }
            if payload == "[DONE]" {
                break
            }

            guard let data = payload.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(StreamingChatResponse.self, from: data),
                  let content = decoded.choices.first?.delta?.content,
                  !content.isEmpty
            else {
                continue
            }

            output += content
            let partial = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                onPartial(partial)
            }
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranslationError.emptyOutput
        }
        return trimmed
    }

    private func chatCompletionsURL() -> URL? {
        URL(string: settings.lmStudioBaseURL)?.appendingPathComponent("chat/completions")
    }

    private func chatRequest(sourceText: String, stream: Bool) -> ChatRequest {
        let systemPrompt = """
        You are a real-time subtitle translator.
        Translate the user's input into natural \(settings.targetLanguage).
        Only output the translated subtitle.
        Keep it concise and suitable for on-screen subtitles.
        Do not explain.
        Do not include the source text.
        """

        return ChatRequest(
            model: settings.lmStudioModel,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: sourceText)
            ],
            temperature: 0.2,
            stream: stream
        )
    }

    private static func streamingPayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else {
            return nil
        }

        return line
            .dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
