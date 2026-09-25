import Foundation

/// 一次请求需要的全部配置，发请求时从设置里现读。
struct APIConfig {
    let endpoint: URL
    let apiKey: String
    let model: String
    let disableThinking: Bool
    let systemPrompt: String

    static func current(direction: Direction, style: Style, defaults: UserDefaults = .standard) throws -> APIConfig {
        let key = (defaults.string(forKey: Keys.apiKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranslationError.missingKey }

        let rawBase = (defaults.string(forKey: Keys.baseURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = rawBase.isEmpty ? Defaults.baseURL : rawBase
        guard let endpoint = TranslationService.endpoint(from: base) else {
            throw TranslationError.badURL(base)
        }

        let model = (defaults.string(forKey: Keys.model) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = defaults.string(forKey: Keys.prompt(direction, style)) ?? Defaults.prompt(direction, style)

        return APIConfig(
            endpoint: endpoint,
            apiKey: key,
            model: model.isEmpty ? Defaults.model : model,
            disableThinking: defaults.bool(forKey: Keys.disableThinking),
            systemPrompt: prompt
        )
    }
}

enum TranslationError: LocalizedError {
    case missingKey
    case badURL(String)
    case http(Int, String)
    case server(String)
    /// 流正常结束，但模型不是自然写完的（例如达到长度上限被截断）。
    case incomplete(String)
    /// 迟迟收不到第一个字（服务端排队时只发保活信号）。
    case noResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "还没有填写 API Key。请打开设置（⌘,）填写。"
        case .badURL(let url):
            return "接口地址无效：\(url)"
        case .http(let code, let message):
            let hint: String
            switch code {
            case 401: hint = "API Key 无效，请在设置里检查。"
            case 402: hint = "账户余额不足。"
            case 404: hint = "接口地址或模型名不对，请在设置里检查。"
            case 429: hint = "请求太频繁，请稍后再试。"
            case 500...599: hint = "服务端暂时出错，请稍后重试。"
            default: hint = ""
            }
            return "请求失败（HTTP \(code)）。\(hint)\n\(message)"
        case .server(let message):
            return "服务端返回错误：\(message)"
        case .incomplete(let reason):
            switch reason {
            case "length": return "译文可能不完整：输出达到长度上限被截断。"
            case "early_end": return "译文可能不完整：连接提前结束。"
            case "content_filter": return "内容被服务端过滤，译文可能不完整。"
            default: return "译文可能不完整（结束原因：\(reason)）。"
            }
        case .noResponse:
            return "服务繁忙，长时间没有返回内容，请稍后重试（⌘↩）。"
        }
    }
}

enum TranslationService {
    /// 允许用户填 `https://api.deepseek.com`、`.../v1`，或完整的 `.../chat/completions`。
    static func endpoint(from base: String) -> URL? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasSuffix("/chat/completions") { s += "/chat/completions" }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    /// 流式返回译文片段（OpenAI 兼容的 SSE 格式）。
    /// 每收到一个有效数据块都会产出一次；没有正文的块（例如思考过程）产出空字符串，调用方可据此判断"服务端有响应"。
    static func stream(text: String, config: APIConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(text: text, config: config)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 8_000 { break }
                        }
                        throw TranslationError.http(status, errorMessage(from: data))
                    }
                    // 自己按 \n 字节切行：Foundation 的 lines 会把 U+2028 等字符也当成换行，拆坏 JSON。
                    var finishReason: String?
                    var sawDone = false
                    var producedText = false
                    var buffer: [UInt8] = []
                    func handleLine(_ bytes: [UInt8]) throws -> Bool {
                        let line = String(decoding: bytes, as: UTF8.self)
                        guard line.hasPrefix("data:") else { return true }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            sawDone = true
                            return false
                        }
                        guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: Data(payload.utf8)) else {
                            return true
                        }
                        if let message = chunk.error?.message { throw TranslationError.server(message) }
                        if let choice = chunk.choices?.first {
                            let piece = choice.delta?.content ?? ""
                            if !piece.isEmpty { producedText = true }
                            continuation.yield(piece)
                            if let reason = choice.finishReason { finishReason = reason }
                        }
                        return true
                    }
                    reading: for try await byte in bytes {
                        if byte == 0x0A {
                            if buffer.last == 0x0D { buffer.removeLast() }
                            let keepGoing = try handleLine(buffer)
                            buffer.removeAll(keepingCapacity: true)
                            if !keepGoing { break reading }
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty { _ = try handleLine(buffer) }
                    if let finishReason, ["length", "content_filter", "insufficient_system_resource"].contains(finishReason) {
                        throw TranslationError.incomplete(finishReason)
                    }
                    if producedText, !sawDone, finishReason == nil {
                        throw TranslationError.incomplete("early_end")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 给用户看的错误说明。
    static func describe(_ error: Error) -> String {
        if let error = error as? TranslationError {
            return error.errorDescription ?? "\(error)"
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "网络连接不可用，请检查网络。"
            case .timedOut:
                return "请求超时，请稍后重试。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "连不上接口地址，请检查设置里的接口地址。"
            case .appTransportSecurityRequiresSecureConnection:
                return "接口地址需要以 https:// 开头（本机地址除外）。"
            default:
                return "网络错误：\(error.localizedDescription)"
            }
        }
        return error.localizedDescription
    }

    private static func makeRequest(text: String, config: APIConfig) throws -> URLRequest {
        var request = URLRequest(url: config.endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": [
                ["role": "system", "content": config.systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        if config.disableThinking {
            body["thinking"] = ["type": "disabled"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func errorMessage(from data: Data) -> String {
        if let parsed = try? JSONDecoder().decode(StreamChunk.self, from: data), let message = parsed.error?.message {
            return message
        }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(raw.prefix(300))
    }
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    struct APIError: Decodable {
        let message: String?
    }
    let choices: [Choice]?
    let error: APIError?
}
