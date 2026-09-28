import AppKit
import Network
import SwiftUI
import Translation

/// 离线翻译：苹果系统自带的翻译（Translation 框架），不联网、不要 API Key。
/// macOS 15 上这个框架只能从界面里拿到翻译会话，所以由主窗口里一个看不见的 OfflineTranslationHost 承载。
enum OfflineTranslation {
    static func languages(for direction: Direction) -> (source: Locale.Language, target: Locale.Language) {
        let chinese = Locale.Language(identifier: "zh-Hans")
        let english = Locale.Language(identifier: "en")
        return direction == .toEnglish ? (chinese, english) : (english, chinese)
    }

    /// 中英离线语言包是否已下载。
    static func isInstalled(_ direction: Direction) async -> Bool {
        let pair = languages(for: direction)
        return await LanguageAvailability().status(from: pair.source, to: pair.target) == .installed
    }

    /// allowDownload 为 false 时，语言包没下载就直接报错，不弹下载窗口（自动模式悄悄换引擎时用）。
    @MainActor
    static func translate(_ text: String, direction: Direction, allowDownload: Bool) async throws -> String {
        if !allowDownload, !(await isInstalled(direction)) {
            throw OfflineTranslationError.notInstalled
        }
        // 查询期间可能已经有了新请求，旧请求就别再排队、挤掉新请求。
        try Task.checkCancellation()
        let pair = languages(for: direction)
        return try await OfflineTranslator.shared.translate(unwrapHardLineBreaks(text), from: pair.source, to: pair.target)
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? OfflineTranslationError { return error.errorDescription ?? "\(error)" }
        return "离线翻译出错：\(error.localizedDescription)"
    }

    /// 从 PDF 复制的文字常在句子中间硬换行。离线翻译没有提示词可以交代，只能先在这里把句子接起来。
    /// 只接"明显是被版面折断"的行：下一行以小写英文字母开头，或上一行够长（接近本段最长行，
    /// 且至少约 30 个英文字符宽）；同时上一行不以句末标点结尾、下一行不是列表项。
    /// 其余短行（关键词、标题、表格）保留换行。
    /// 行尾连字符只在拼回后是真单词时才去掉（"conver-/gence"），否则保留（"self-/attention"）。
    @MainActor
    static func unwrapHardLineBreaks(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // 每段（空行之间）最长一行的显示宽度。
        var paragraphWidth = [Int](repeating: 0, count: lines.count)
        var start = 0
        for index in 0...lines.count where index == lines.count || lines[index].isEmpty {
            let width = lines[start..<index].map(displayWidth).max() ?? 0
            for line in start..<index { paragraphWidth[line] = width }
            start = index + 1
        }

        var result = ""
        var previous: (text: String, index: Int)?
        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else {
                if previous != nil { result += "\n\n" }
                previous = nil
                continue
            }
            if let previous {
                let width = Double(displayWidth(previous.text))
                // 下一行以小写英文字母开头，基本可以断定是句子被折断了，不看行长。
                let continuesLowercase = line.first.map { $0.isLowercase && $0.isASCII } ?? false
                let wrapped = continuesLowercase || width >= max(30, 0.8 * Double(paragraphWidth[previous.index]))
                if !wrapped || endsSentence(previous.text) || startsListItem(line) {
                    result += "\n"
                } else if previous.text.hasSuffix("-"), previous.text.dropLast().last?.isLetter == true {
                    if isWord(lastWordPart(of: previous.text) + firstWord(of: line)) {
                        result.removeLast() // "conver-" + "gence" -> "convergence"
                    }
                } else if !(isCJK(previous.text.last) || isCJK(line.first)) {
                    result += " "
                }
            }
            result += line
            previous = (line, index)
        }
        return result
    }

    /// 行尾最后一个词里、连字符前的那一截："prone to conver-" -> "conver"，"state-of-the-" -> "the"。
    private static func lastWordPart(of line: String) -> String {
        let token = line.split(separator: " ").last.map(String.init) ?? ""
        let trimmed = token.hasSuffix("-") ? String(token.dropLast()) : token
        return trimmed.split(separator: "-").last.map(String.init) ?? trimmed
    }

    private static func firstWord(of line: String) -> String {
        String(line.prefix { $0.isLetter })
    }

    @MainActor
    private static func isWord(_ word: String) -> Bool {
        guard word.count > 1 else { return false }
        let range = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        )
        return range.location == NSNotFound
    }

    /// 汉字按两个英文字符宽计算。
    private static func displayWidth(_ line: String) -> Int {
        line.reduce(0) { $0 + (isCJK($1) ? 2 : 1) }
    }

    private static func endsSentence(_ line: String) -> Bool {
        guard let last = line.last else { return true }
        return "。！？!?.:：;；”\"')）】".contains(last)
    }

    private static func startsListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") { return true }
        return line.range(of: #"^(\d+|[a-zA-Z])[.)、]\s"#, options: .regularExpression) != nil
    }

    private static func isCJK(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        return (0x3000...0x303F).contains(scalar.value)   // 中文标点
            || (0x4E00...0x9FFF).contains(scalar.value)   // 常用汉字
            || (0xFF00...0xFFEF).contains(scalar.value)   // 全角符号
    }
}

enum OfflineTranslationError: LocalizedError {
    case notInstalled
    case noResponse

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "离线语言包还没下载（设置 → 接口 → 离线语言包 → 下载）。"
        case .noResponse:
            return "离线翻译没有响应，请按 ⌘↩ 重试。"
        }
    }
}

/// 把"翻译这段文字"的请求交给界面里的翻译会话，再把结果传回来。
@MainActor
final class OfflineTranslator: ObservableObject {
    static let shared = OfflineTranslator()

    /// 界面监听这个配置：配置一变（或被 invalidate），就拿到新的翻译会话来处理排队的请求。
    @Published fileprivate(set) var configuration: TranslationSession.Configuration?
    private var job: (text: String, continuation: CheckedContinuation<String, Error>)?

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // 还没开始处理的旧请求直接作废。
            job?.continuation.resume(throwing: CancellationError())
            job = (text, continuation)
            if configuration?.source == source, configuration?.target == target {
                configuration?.invalidate()
            } else {
                configuration = TranslationSession.Configuration(source: source, target: target)
            }
        }
    }

    fileprivate func run(_ session: TranslationSession) async {
        guard let current = job else { return }
        job = nil
        do {
            let response = try await session.translate(current.text)
            current.continuation.resume(returning: response.targetText)
        } catch {
            current.continuation.resume(throwing: error)
        }
    }
}

/// 放在主窗口里、看不见的承载视图。语言包没下载时，系统会在这个窗口上弹出下载提示。
struct OfflineTranslationHost: View {
    @ObservedObject private var translator = OfflineTranslator.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(translator.configuration) { session in
                await translator.run(session)
            }
    }
}

/// 设置页里的"离线语言包"一行：显示是否已下载，没下载时可以一键下载。
struct OfflineLanguageRow: View {
    @State private var installed: Bool?
    @State private var downloadConfiguration: TranslationSession.Configuration?
    @State private var message: String?

    var body: some View {
        LabeledContent("离线语言包（中文 ⇄ 英文）") {
            VStack(alignment: .trailing, spacing: 4) {
                switch installed {
                case .none:
                    ProgressView().controlSize(.small)
                case .some(true):
                    Label("已下载", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .some(false):
                    Button("下载") {
                        message = nil
                        if downloadConfiguration == nil {
                            let pair = OfflineTranslation.languages(for: .toEnglish)
                            downloadConfiguration = TranslationSession.Configuration(source: pair.source, target: pair.target)
                        } else {
                            downloadConfiguration?.invalidate()
                        }
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .translationTask(downloadConfiguration) { session in
            do {
                try await session.prepareTranslation()
            } catch {
                message = "没有完成下载：\(error.localizedDescription)"
            }
            await refresh()
        }
        .task { await refresh() }
    }

    private func refresh() async {
        let toEnglish = await OfflineTranslation.isInstalled(.toEnglish)
        let toChinese = await OfflineTranslation.isInstalled(.toChinese)
        installed = toEnglish && toChinese
    }
}

/// 记录当前有没有网络连接，自动模式据此在没网时直接用离线翻译，不白等超时。
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.online = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "QuickTrans.NetworkMonitor"))
    }
}
