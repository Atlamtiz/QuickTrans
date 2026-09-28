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
    /// 这次用的是哪个引擎，例如"在线"、"离线（没有联网）"。
    @Published private(set) var engineNote: String?
    /// 是否是自动模式下从在线退到了离线（界面上用提醒色显示）。
    @Published private(set) var engineFellBack = false
    /// 退到离线的完整原因（鼠标悬停在引擎提示上时显示）。
    @Published private(set) var engineDetail: String?

    @Published var directionChoice: DirectionChoice {
        didSet {
            guard directionChoice != oldValue else { return }
            UserDefaults.standard.set(directionChoice.rawValue, forKey: Keys.direction)
            translateNow()
        }
    }
    /// 这次实际用的方向（选"自动"时由原文判断出来）。
    @Published private(set) var activeDirection: Direction?
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
        directionChoice = DirectionChoice(rawValue: defaults.string(forKey: Keys.direction) ?? "") ?? .auto
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
        let mode = EngineMode.current
        let direction = directionChoice.resolve(for: text)
        let key = "\(mode.rawValue)|\(directionChoice.rawValue)|\(direction.rawValue)|\(style.rawValue)|\(text)"
        if !force, key == lastRequestKey, errorMessage == nil { return }

        translateTask?.cancel()
        watchdogTask?.cancel()
        requestID += 1
        let id = requestID
        lastRequestKey = key
        target = ""
        errorMessage = nil
        notice = nil
        engineNote = nil
        engineFellBack = false
        engineDetail = nil
        activeDirection = direction
        isTranslating = true

        switch mode {
        case .online:
            startOnline(text, direction: direction, id: id, fallBackToOffline: false)
        case .offline:
            startOffline(text, direction: direction, id: id, reason: nil, detail: nil)
        case .auto:
            // 没网或没填 Key 时，不必先去试在线。
            if (UserDefaults.standard.string(forKey: Keys.apiKey) ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                startOffline(text, direction: direction, id: id, reason: "没有填 API Key", detail: nil)
            } else if !NetworkMonitor.shared.isOnline {
                startOffline(text, direction: direction, id: id, reason: "没有联网", detail: nil)
            } else {
                startOnline(text, direction: direction, id: id, fallBackToOffline: true)
            }
        }
    }

    /// 在线翻译（DeepSeek 等大模型，流式显示）。fallBackToOffline 为 true 时，出错、超时或没返回译文就改用离线翻译。
    private func startOnline(_ text: String, direction: Direction, id: Int, fallBackToOffline: Bool) {
        let config: APIConfig
        do {
            config = try APIConfig.current(direction: direction, style: style)
        } catch {
            if fallBackToOffline {
                fallBack(text, direction: direction, id: id, error: error)
            } else {
                fail(error)
            }
            return
        }

        receivedAny = false
        translateTask = Task { [weak self] in
            do {
                for try await piece in TranslationService.stream(text: text, config: config) {
                    try Task.checkCancellation()
                    self?.receivedAny = true
                    if !piece.isEmpty { self?.target += piece }
                }
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                if fallBackToOffline, self.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.startOffline(text, direction: direction, id: id, reason: "在线没有返回译文", detail: nil)
                } else {
                    self.finish(engine: "在线")
                }
            } catch TranslationError.incomplete(let reason) {
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                let error = TranslationError.incomplete(reason)
                // 一个字都没拿到（例如服务繁忙）就退到离线；已有部分译文就保留并提示。
                if fallBackToOffline, self.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.fallBack(text, direction: direction, id: id, error: error)
                } else {
                    self.finishIncomplete(error)
                }
            } catch {
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                if fallBackToOffline {
                    self.fallBack(text, direction: direction, id: id, error: error)
                } else {
                    self.fail(error)
                }
            }
        }
        // 服务端排队时只发保活信号、不发数据，连接不会超时，所以要自己计时。
        // 收到任何数据（开着思考模式时，思考过程也算）就不再计时。
        let timeout = fallBackToOffline ? EngineMode.autoFallbackTimeout : 20
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled, self.requestID == id, self.isTranslating, !self.receivedAny else { return }
            self.translateTask?.cancel()
            if fallBackToOffline {
                self.startOffline(text, direction: direction, id: id, reason: "在线 \(Int(timeout)) 秒没有响应", detail: nil)
            } else {
                self.fail(TranslationError.noResponse)
            }
        }
    }

    private func fallBack(_ text: String, direction: Direction, id: Int, error: Error) {
        startOffline(text, direction: direction, id: id,
                     reason: TranslationService.shortReason(error), detail: TranslationService.describe(error))
    }

    /// 离线翻译（系统自带）。reason 不为空表示是自动模式从在线退下来的，这时不弹下载语言包的窗口。
    private func startOffline(_ text: String, direction: Direction, id: Int, reason: String?, detail: String?) {
        watchdogTask?.cancel()
        target = ""
        isTranslating = true
        let allowDownload = reason == nil
        let academic = style == .academic
        translateTask = Task { [weak self] in
            do {
                let result = try await OfflineTranslation.translate(text, direction: direction, allowDownload: allowDownload)
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.target = result
                if let reason {
                    self.engineFellBack = true
                    self.engineDetail = detail ?? reason
                    self.finish(engine: "离线（\(reason)）" + (academic ? " · 离线不分正常/学术" : ""))
                    // 这次是退下来的：再取同一段文字时，重新先试在线。
                    self.lastRequestKey = nil
                } else {
                    self.finish(engine: "离线")
                }
            } catch {
                // 只看是不是旧请求；当前请求的任何错误（包括取消下载）都要给出提示，不能一直转圈。
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                let offlineMessage = OfflineTranslation.describe(error)
                self.fail(message: reason.map { "在线翻译不可用（\($0)），离线翻译也没成功：\(offlineMessage)" } ?? offlineMessage)
            }
        }
        // 离线翻译平时很快；弹着下载语言包的窗口时，要给你留出点击的时间。
        let timeout: Double = allowDownload ? 180 : 20
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled, self.requestID == id, self.isTranslating else { return }
            self.translateTask?.cancel()
            self.fail(message: OfflineTranslation.describe(OfflineTranslationError.noResponse))
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

    private func finish(engine: String) {
        watchdogTask?.cancel()
        isTranslating = false
        engineNote = engine
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
        engineNote = "在线"
        notice = TranslationService.describe(error)
        lastRequestKey = nil
    }

    private func fail(_ error: Error) {
        fail(message: TranslationService.describe(error))
    }

    private func fail(message: String) {
        watchdogTask?.cancel()
        translateTask?.cancel()
        translateTask = nil
        isTranslating = false
        target = ""
        engineNote = nil
        engineDetail = nil
        errorMessage = message
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
        engineNote = nil
        engineFellBack = false
        engineDetail = nil
        activeDirection = nil
        isTranslating = false
    }
}
