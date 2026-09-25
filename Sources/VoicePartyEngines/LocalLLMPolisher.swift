import Foundation
import VoicePartyCore

/// Cleanup through a local model server speaking the OpenAI chat-completions API
/// (llama.cpp `llama-server`, LM Studio, Ollama, `mlx_lm.server`).
///
/// Privacy: only loopback hosts are accepted, so text can never leave the Mac through this client.
public final class LocalLLMPolisher: TextPolisher, @unchecked Sendable {
    /// How requests are phrased: a general instruction model with our prompt and examples, or
    /// Superwhisper's S1-mini, which needs its own fixed system prompt and control line.
    public enum Format: String, Sendable { case instruct, s1mini }

    public let id: String
    public let format: Format
    public let baseURL: URL
    public let model: String
    private let session: URLSession
    private let longSession: URLSession
    private let apiKey: String?
    /// Prompt used for `.instruct` models.
    public var promptConfig: CleanupPrompt.Config = CleanupPrompt.standard

    public enum LocalLLMError: Error, LocalizedError {
        case notLoopback(String)
        case badResponse(Int, String)
        case emptyResponse

        public var errorDescription: String? {
            switch self {
            case .notLoopback(let host): "Refusing to send text to \(host): only 127.0.0.1/localhost model servers are allowed."
            case .badResponse(let code, let body): "Local model server error \(code): \(body.prefix(200))"
            case .emptyResponse: "The local model returned nothing."
            }
        }
    }

    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// - Parameter baseURL: e.g. `http://127.0.0.1:8791` (the `/v1/chat/completions` path is appended).
    public init(baseURL: URL, model: String, format: Format = .instruct, apiKey: String? = nil, timeout: TimeInterval = 8) throws {
        guard Self.isLoopback(baseURL) else { throw LocalLLMError.notLoopback(baseURL.host ?? baseURL.absoluteString) }
        self.baseURL = baseURL
        self.model = model
        self.format = format
        self.apiKey = apiKey
        id = "local-llm:\(model)"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.connectionProxyDictionary = [:] // never route through a proxy
        config.urlCache = nil
        // Whatever answers on this port may not send the text elsewhere: redirects are refused.
        session = URLSession(configuration: config, delegate: RefuseRedirects.shared, delegateQueue: nil)
        // Transforms, answers and meeting notes write much more than a cleanup; the reply only arrives when
        // it's complete, so allow minutes, not seconds.
        let long = URLSessionConfiguration.ephemeral
        long.timeoutIntervalForRequest = 180
        long.connectionProxyDictionary = [:]
        long.urlCache = nil
        longSession = URLSession(configuration: long, delegate: RefuseRedirects.shared, delegateQueue: nil)
    }

    public func prewarm() async {
        // Load the model and cache the long, fixed prefix (system prompt + examples).
        let request = PolishRequest(text: "ok", level: .light, style: .formal, category: .other)
        _ = try? await complete(messages: messages(for: request), maxTokens: 1)
    }

    func messages(for request: PolishRequest) -> [(role: String, content: String)] {
        switch format {
        case .instruct:
            return CleanupPrompt.messages(for: request, config: promptConfig)
        case .s1mini:
            return [("system", S1MiniFormat.systemPrompt),
                    ("user", S1MiniFormat.userMessage(transcript: request.text, style: request.style, category: request.category))]
        }
    }

    public func polish(_ request: PolishRequest) async throws -> String {
        let words = TextTools.wordCount(request.text)
        let output = try await complete(messages: messages(for: request), maxTokens: min(2048, words * 2 + 40))
        switch format {
        case .instruct: return CleanupPrompt.stripWrapping(output)
        case .s1mini: return S1MiniFormat.postProcess(output.trimmingCharacters(in: .whitespacesAndNewlines), raw: request.text)
        }
    }

    public func transform(_ text: String, instructions: String) async throws -> String {
        let messages: [(role: String, content: String)] = [
            ("system", "You rewrite text according to the user's instructions. Reply with the rewritten text only: no preamble, no quotes, no explanations."),
            ("user", "Instructions: \(instructions)\n\n<text>\n\(text)\n</text>"),
        ]
        return CleanupPrompt.stripWrapping(try await complete(messages: messages, maxTokens: min(3000, TextTools.wordCount(text) * 4 + 200), long: true))
    }

    public func answer(_ question: String, context: String?) async throws -> String {
        var prompt = question
        if let context, !context.isEmpty { prompt = "Context from the screen:\n\(context.suffix(1500))\n\nQuestion: \(question)" }
        return try await complete(messages: [("system", "Answer helpfully and concisely."), ("user", prompt)], maxTokens: 700, long: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the server answers at all (used for status and fallbacks).
    public func isReachable() async -> Bool {
        // /health answers without the API key once the model is loaded (503 while loading).
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func complete(messages: [(role: String, content: String)], maxTokens: Int, long: Bool = false) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": 0,
            "max_tokens": maxTokens,
            "stream": false,
            "cache_prompt": true,
            "stop": ["</transcript>", "<transcript>"],
            // Qwen3-style reasoning models: answer directly.
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await (long ? longSession : session).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LocalLLMError.badResponse(status, String(decoding: data, as: UTF8.self)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              var content = message["content"] as? String else { throw LocalLLMError.emptyResponse }
        // Strip any <think>…</think> block a reasoning model may still emit.
        if let range = content.range(of: "</think>") { content = String(content[range.upperBound...]) }
        return content
    }
}

/// A loopback model server never redirects; if something on that port tries (say another process took the port
/// after ours stopped), the request stops rather than following it, with your text, to another address.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RefuseRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
