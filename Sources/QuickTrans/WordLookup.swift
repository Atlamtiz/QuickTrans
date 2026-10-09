import AppKit
import AVFoundation
import CoreServices
import SwiftUI

/// 双击英文单词后的查词：先秒出系统词典（音标 + 释义），再让大模型结合所在句子说明"在这里是什么意思"。
@MainActor
final class WordLookup: ObservableObject {
    static let shared = WordLookup()

    enum ContextState: Equatable {
        case loading
        case done
        /// 没查上下文释义的原因（离线模式、没联网、出错等）。
        case note(String)
    }

    @Published private(set) var word: String?
    @Published private(set) var entry: DictionaryEntry?
    @Published private(set) var contextText = ""
    @Published private(set) var contextState = ContextState.loading

    private var sentence = ""
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    var isVisible: Bool { word != nil }

    func lookup(_ word: String, in sentence: String) {
        // 同一句里的同一个词已经在查或查好了就不重复；上次没查成（显示了原因）就允许再查。
        if word.lowercased() == self.word?.lowercased(), sentence == self.sentence {
            if case .note = contextState {} else { return }
        }
        task?.cancel()
        watchdog?.cancel()
        self.word = word
        self.sentence = sentence
        entry = DictionaryEntry.lookup(word)
        contextText = ""
        startContextLookup(word: word, sentence: sentence)
    }

    func close() {
        task?.cancel()
        watchdog?.cancel()
        word = nil
        entry = nil
        contextText = ""
    }

    private static let prompt = #"""
    你是英语词汇助手。用户会给出一个英文单词和它所在的句子。请用简体中文简洁回答，不要寒暄、不要给音标：
    第 1 行：词性 + 这个词在这句话里的意思。
    第 2 行：其他常见意思（1～2 个，用分号隔开；没有其他常见意思就省略这一行）。
    第 3 行：一个常见搭配或短例句（英文，后面括号附中文）。
    总共不超过 100 字。
    """#

    private func startContextLookup(word: String, sentence: String) {
        let mode = EngineMode.current
        if mode == .offline {
            contextState = .note("离线模式：只显示词典释义")
            return
        }
        let config: APIConfig
        do {
            config = try APIConfig.current(direction: .toChinese, style: .normal).replacingPrompt(Self.prompt)
        } catch {
            contextState = .note(TranslationService.shortReason(error))
            return
        }
        if mode == .auto, !NetworkMonitor.shared.isOnline {
            contextState = .note("没有联网，只显示词典释义")
            return
        }

        contextState = .loading
        let message = "单词：\(word)\n句子：\(sentence)"
        task = Task { [weak self] in
            do {
                for try await piece in TranslationService.stream(text: message, config: config) {
                    try Task.checkCancellation()
                    self?.watchdog?.cancel()
                    if !piece.isEmpty { self?.contextText += piece }
                }
                try Task.checkCancellation()
                guard let self else { return }
                self.contextState = self.contextText.isEmpty ? .note("大模型没有返回内容") : .done
            } catch {
                guard !Task.isCancelled else { return }
                self?.contextState = .note(TranslationService.shortReason(error))
            }
        }
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(EngineMode.autoFallbackTimeout))
            guard let self, !Task.isCancelled, self.contextState == .loading, self.contextText.isEmpty else { return }
            self.task?.cancel()
            self.contextState = .note("大模型 \(Int(EngineMode.autoFallbackTimeout)) 秒没有响应")
        }
    }
}

/// macOS 自带词典查到的条目，整理成好读的样子。
struct DictionaryEntry: Equatable {
    /// 例如 "美 /roʊˈbəst/  英 /rə(ʊ)ˈbʌst/"
    let phonetic: String?
    let definition: String

    static func lookup(_ word: String) -> DictionaryEntry? {
        let records = EnglishChineseDictionary.records(for: word) ?? fallbackRecord(for: word).map { [$0] } ?? []
        guard !records.isEmpty else { return nil }
        var phonetic: String?
        var bodies: [String] = []
        for record in records {
            let parsed = parse(record)
            if phonetic == nil { phonetic = parsed.phonetic }
            if !parsed.body.isEmpty { bodies.append(parsed.body) }
        }
        guard !bodies.isEmpty else { return nil }
        return DictionaryEntry(phonetic: phonetic, definition: String(bodies.joined(separator: "\n").prefix(800)))
    }

    /// 拿不到词典条目接口时的退路：系统公开的查词接口。它会在所有启用的词典里按顺序找，
    /// 像 run、can 这种拼写和拼音一样的词，常常返回汉语词条（"闰 rùn"），这种结果直接丢掉。
    private static func fallbackRecord(for word: String) -> String? {
        let range = CFRange(location: 0, length: (word as NSString).length)
        guard let raw = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String? else { return nil }
        let head = raw.components(separatedBy: " | ").first ?? raw
        guard head.range(of: #"\p{Han}"#, options: .regularExpression) == nil, head.first?.isASCII == true, head.first?.isLetter == true else {
            return nil
        }
        return raw
    }

    /// 一条词条的原始格式大致是：词头 | 音标 | 词性 ① 释义 ② 释义 ▸ 例句……
    private static func parse(_ raw: String) -> (phonetic: String?, body: String) {
        var parts = raw.components(separatedBy: " | ")
        var phonetic: String?
        if parts.count >= 3, parts[1].count < 80, parts[1].range(of: #"\p{Han}"#, options: .regularExpression) == nil {
            let american = firstMatch(#"AmE ([^,|]+)"#, in: parts[1])
            let british = firstMatch(#"BrE ([^,|]+)"#, in: parts[1])
            if american != nil || british != nil {
                phonetic = [american.map { "美 /\($0)/" }, british.map { "英 /\($0)/" }].compactMap { $0 }.joined(separator: "  ")
            } else {
                phonetic = "/\(parts[1].trimmingCharacters(in: .whitespaces))/"
            }
            parts.removeFirst(2)
        } else if parts.count >= 2 {
            parts.removeFirst()
        }
        return (phonetic, tidy(parts.joined(separator: " ")))
    }

    /// 去掉汉字后面的拼音，词性换成中文，每个义项、例句另起一行。
    private static func tidy(_ text: String) -> String {
        var s = text
        // 拼音：带声调符号的音节，或常见的轻声音节（de、le、men……）。没有声调的普通英文词（如 figurative）不动。
        let toned = "[a-zü']*[āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜńňǹ][a-zāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜüńňǹ']*"
        let neutral = "(?:de|le|men|me|ne|ba|ma|la|ya|zi|zhe|ge)"
        s = s.replacingOccurrences(of: #"(?<=[\p{Han}）])(?:\s+(?:\#(toned)|\#(neutral))\b)+"#, with: "", options: .regularExpression)
        let labels: [(String, String)] = [
            ("transitive verb", "及物动词"), ("intransitive verb", "不及物动词"), ("modal verb", "情态动词"),
            ("adjective", "形容词"), ("adverb", "副词"), ("noun", "名词"), ("verb", "动词"), ("preposition", "介词"),
            ("conjunction", "连词"), ("pronoun", "代词"), ("exclamation", "感叹词"),
        ]
        for (english, chinese) in labels {
            // "A. noun"、"B. intransitive verb" 这种分大类的写法，以及后面紧跟义项编号的写法。
            s = s.replacingOccurrences(of: #"\b([A-H])\.\s+\#(english)\b"#, with: "\n$1. 【\(chinese)】", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\b\#(english)\b(?=\s+(uncountable|countable|[①-⑳]|\())"#,
                                       with: "\n【\(chinese)】", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\buncountable\b(?=\s+([①-⑳]|\())"#, with: "不可数", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\bcountable\b(?=\s+([①-⑳]|\())"#, with: "可数", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*([①-⑳])"#, with: "\n$1 ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*▸\s*"#, with: "\n    ▸ ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return text[range].trimmingCharacters(in: .whitespaces)
    }
}

/// 直接查"牛津英汉汉英词典"里的英文词条。
/// 系统公开接口只返回第一个匹配，双向词典会把 run 当拼音查成"闰 rùn"；这里改用词典服务里列出全部匹配条目的接口
/// （没有公开文档，用 dlsym 动态取，取不到就返回 nil，调用方退回公开接口），只留词头是英文的那几条。
enum EnglishChineseDictionary {
    private typealias CopyDictionaries = @convention(c) () -> Unmanaged<CFSet>?
    private typealias GetName = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFString>?
    private typealias CopyRecords = @convention(c) (UnsafeRawPointer, CFString, UnsafeRawPointer?, UnsafeRawPointer?) -> Unmanaged<CFArray>?
    private typealias GetHeadword = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFString>?
    private typealias CopyData = @convention(c) (UnsafeRawPointer, Int) -> Unmanaged<CFString>?

    private struct API {
        let dictionary: AnyObject
        let copyRecords: CopyRecords
        let headword: GetHeadword
        let copyData: CopyData
    }

    private static let api: API? = {
        let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, as _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let copyDictionaries = symbol("DCSCopyAvailableDictionaries", as: CopyDictionaries.self),
              let getName = symbol("DCSDictionaryGetName", as: GetName.self),
              let copyRecords = symbol("DCSCopyRecordsForSearchString", as: CopyRecords.self),
              let headword = symbol("DCSRecordGetHeadword", as: GetHeadword.self),
              let copyData = symbol("DCSRecordCopyData", as: CopyData.self),
              let all = copyDictionaries()?.takeRetainedValue() as NSSet? else { return nil }
        let names = ["牛津英汉汉英词典", "Oxford Chinese Dictionary"]
        guard let dictionary = all.first(where: { item in
            let name = getName(Unmanaged.passUnretained(item as AnyObject).toOpaque())?.takeUnretainedValue() as String?
            return names.contains(name ?? "")
        }) else { return nil }
        return API(dictionary: dictionary as AnyObject, copyRecords: copyRecords, headword: headword, copyData: copyData)
    }()

    /// 返回 nil 表示接口不可用；返回空数组表示词典里没有这个英文词。
    static func records(for word: String) -> [String]? {
        guard let api else { return nil }
        let dictionary = Unmanaged.passUnretained(api.dictionary).toOpaque()
        let records = (api.copyRecords(dictionary, word as CFString, nil, nil)?.takeRetainedValue() as? [AnyObject]) ?? []
        return records.compactMap { record -> String? in
            let pointer = Unmanaged.passUnretained(record).toOpaque()
            guard let head = api.headword(pointer)?.takeUnretainedValue() as String?,
                  head.first?.isASCII == true, head.first?.isLetter == true,
                  head.range(of: #"\p{Han}"#, options: .regularExpression) == nil else { return nil }
            return api.copyData(pointer, 3)?.takeRetainedValue() as String?  // 3 = 纯文本
        }
        .prefix(3)
        .map { $0 }
    }
}

/// 朗读：用系统自带语音（离线）。单词用美音；整段朗读时逐句判断中英文，分别用中文、英文语音读。
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    @Published private(set) var isReadingParagraph = false
    private let synthesizer = AVSpeechSynthesizer()
    /// 本次朗读排队中的语句。被打断的旧语句可能晚一点才回调"读完"，按身份核对，免得把新朗读的状态弄乱。
    private var pending = Set<ObjectIdentifier>()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speakWord(_ word: String) {
        stop()
        speak([(word, "en-US")])
    }

    func toggleParagraph(_ text: String) {
        if isReadingParagraph {
            stop()
            return
        }
        stop()
        let parts = Self.segments(text)
        guard !parts.isEmpty else { return }
        isReadingParagraph = true
        speak(parts)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        pending.removeAll()
        isReadingParagraph = false
    }

    private func speak(_ parts: [(text: String, language: String)]) {
        for part in parts {
            let utterance = AVSpeechUtterance(string: part.text)
            utterance.voice = Self.voice(for: part.language)
            pending.insert(ObjectIdentifier(utterance))
            synthesizer.speak(utterance)
        }
    }

    /// 优先用下载过的增强/高级音质语音，没有就用这种语言的系统默认语音（避开"怪声"类趣味语音）。
    private static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let better = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language && $0.quality != .default }
        return better.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }

    /// 按句切开，相邻的同语言句子合并，每段配一种语音。
    private static func segments(_ text: String) -> [(text: String, language: String)] {
        var result: [(text: String, language: String)] = []
        let string = text as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
            let language = Direction.detect(sentence) == .toEnglish ? "zh-CN" : "en-US"
            if let last = result.last, last.language == language {
                result[result.count - 1].text += " " + sentence
            } else {
                result.append((sentence, language))
            }
        }
        return result
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard pending.remove(id) != nil else { return }
        if pending.isEmpty { isReadingParagraph = false }
    }
}

/// 窗口底部的查词面板。
struct WordLookupPanel: View {
    @ObservedObject var lookup: WordLookup
    let theme: Theme

    var body: some View {
        if let word = lookup.word {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(word)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .textSelection(.enabled)
                    Button {
                        Speaker.shared.speakWord(word)
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.accent)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("发音（美音）")
                    if let phonetic = lookup.entry?.phonetic {
                        Text(phonetic)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.secondaryText)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("在词典中打开") {
                        if let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                           let url = URL(string: "dict://\(encoded)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(theme.accent)
                    Button {
                        lookup.close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("关闭（Esc）")
                }

                HStack(alignment: .top, spacing: 16) {
                    column(title: "词典") {
                        Text(lookup.entry?.definition ?? "系统词典里没有这个词。")
                            .foregroundStyle(lookup.entry == nil ? theme.secondaryText : theme.text)
                    }
                    Rectangle().fill(theme.divider).frame(width: 1)
                    column(title: "在这句话里") {
                        switch lookup.contextState {
                        case .loading where lookup.contextText.isEmpty:
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在问大模型…").foregroundStyle(theme.secondaryText)
                            }
                        case .note(let reason) where lookup.contextText.isEmpty:
                            Text(reason).foregroundStyle(theme.secondaryText)
                        default:
                            Text(lookup.contextText).foregroundStyle(theme.text)
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 12))
            .frame(height: 200)
            .background(theme.targetBackground)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func column<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            ScrollView {
                content()
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
