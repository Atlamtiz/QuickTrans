import AppKit
import SwiftUI

/// 翻译窗口的状态：原文、译文、方向、风格。
@MainActor
final class TranslatorModel: ObservableObject {
    static let shared = TranslatorModel()

    @Published var source = "" {
        didSet { if source != oldValue { sourceDidChange() } }
    }
    @Published private(set) var target = ""
    @Published private(set) var isTranslating = false
    @Published private(set) var errorMessage: String?
    /// 取词相关的提示，例如"没有取到选中的文字"。
    @Published private(set) var notice: String?

    @Published var direction: Direction {
        didSet {
            guard direction != oldValue else { return }
            UserDefaults.standard.set(direction.rawValue, forKey: Keys.direction)
            translateNow()
        }
    }
    @Published var style: Style {
        didSet {
            guard style != oldValue else { return }
            UserDefaults.standard.set(style.rawValue, forKey: Keys.style)
            translateNow()
        }
    }

    private var debounceTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var requestID = 0
    /// 当前请求是否已收到服务端的任何数据（含思考过程）。
    private var receivedAny = false
    private var loadingProgrammatically = false
    /// 最近一次发出（或已完成）的请求，避免同样的内容重复请求。
    private var lastRequestKey: String?

    private init() {
        let defaults = UserDefaults.standard
        direction = Direction(rawValue: defaults.string(forKey: Keys.direction) ?? "") ?? .toEnglish
        style = Style(rawValue: defaults.string(forKey: Keys.style) ?? "") ?? .normal
    }

    /// 快捷键取到文字后调用：填入原文并立即翻译（不等防抖）。
    func load(_ text: String) {
        notice = nil
        loadingProgrammatically = true
        source = text
        loadingProgrammatically = false
        translateNow()
    }

    func showNotice(_ message: String) {
        notice = message
    }

    func clear() {
        source = ""
    }

    func copyTarget() {
        guard !target.isEmpty else { return }
        HotkeyManager.shared.cancelPendingRestore()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(target, forType: .string)
    }

    func translateNow(force: Bool = false) {
        debounceTask?.cancel()
        let text = source
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reset()
            return
        }
        let key = "\(direction.rawValue)|\(style.rawValue)|\(text)"
        if !force, key == lastRequestKey, errorMessage == nil { return }

        translateTask?.cancel()
        watchdogTask?.cancel()
        let config: APIConfig
        do {
            config = try APIConfig.current(direction: direction, style: style)
        } catch {
            fail(error)
            return
        }

        requestID += 1
        let id = requestID
        lastRequestKey = key
        target = ""
        errorMessage = nil
        notice = nil
        isTranslating = true
        receivedAny = false
        translateTask = Task { [weak self] in
            do {
                for try await piece in TranslationService.stream(text: text, config: config) {
                    try Task.checkCancellation()
                    self?.receivedAny = true
                    if !piece.isEmpty { self?.target += piece }
                }
                try Task.checkCancellation()
                self?.finish()
            } catch TranslationError.incomplete(let reason) {
                guard !Task.isCancelled else { return }
                self?.finishIncomplete(TranslationError.incomplete(reason))
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
        // 服务端排队时只发保活信号、不发数据，连接不会超时；20 秒还没收到任何数据就放弃。
        // （开着思考模式时，思考过程也算数据，不会被误杀。）
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.requestID == id, self.isTranslating, !self.receivedAny else { return }
            self.translateTask?.cancel()
            self.fail(TranslationError.noResponse)
        }
    }

    private func sourceDidChange() {
        notice = nil
        guard !loadingProgrammatically else { return }
        debounceTask?.cancel()
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reset()
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.translateNow()
        }
    }

    private func finish() {
        watchdogTask?.cancel()
        isTranslating = false
        if target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "模型没有返回内容，请重试。"
            lastRequestKey = nil
        }
    }

    /// 译文被截断：保留已有译文，只加提示，并允许再次请求。一个字都没有就按出错处理。
    private func finishIncomplete(_ error: Error) {
        if target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail(error)
            return
        }
        watchdogTask?.cancel()
        isTranslating = false
        notice = TranslationService.describe(error)
        lastRequestKey = nil
    }

    private func fail(_ error: Error) {
        watchdogTask?.cancel()
        translateTask?.cancel()
        translateTask = nil
        isTranslating = false
        target = ""
        errorMessage = TranslationService.describe(error)
        lastRequestKey = nil
    }

    private func reset() {
        debounceTask?.cancel()
        watchdogTask?.cancel()
        translateTask?.cancel()
        translateTask = nil
        lastRequestKey = nil
        target = ""
        errorMessage = nil
        isTranslating = false
    }
}
