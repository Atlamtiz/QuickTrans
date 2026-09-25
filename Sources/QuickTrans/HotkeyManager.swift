import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum CaptureResult {
    case text(String)
    case nothingSelected
    /// 剪贴板内容被标记为敏感（密码管理器复制的密码等），不读取、不发送。
    case sensitive
    case needsPermission
}

/// 负责两种取词方式：
/// - 连按两下 ⌘C：在后台线程上"看"键盘（原样放行，不拦截），第二次 ⌘C 后读剪贴板。
/// - 自定义组合键：用系统热键注册；按下后替用户执行一次 ⌘C，读完再恢复剪贴板。
/// 两种方式都只需要"辅助功能"权限。
@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    /// 取词结果。
    var onTrigger: ((CaptureResult) -> Void)?

    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var registrationError: String?

    private var keyTap: KeyTap?
    private var globalMonitor: Any?
    private var fallbackDetector = DoublePressDetector()
    private var hotKeyRef: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?
    private var trustTimer: Timer?
    private var suspended = false
    private var capturing = false
    /// 自定义键没取到文字后，等"复制得慢的 app"写入再恢复剪贴板的任务，以及要恢复的原内容。
    private var pendingRestore: (task: Task<Void, Never>, saved: [NSPasteboardItem])?

    var mode: HotkeyMode {
        HotkeyMode(rawValue: UserDefaults.standard.string(forKey: Keys.hotkeyMode) ?? "") ?? .doubleCmdC
    }

    /// 给界面显示的快捷键说明。
    static func displayName(mode: String, customDisplay: String) -> String {
        if mode == HotkeyMode.custom.rawValue {
            return customDisplay.isEmpty ? "快捷键（未设置）" : customDisplay
        }
        return "⌘C C"
    }

    func start() {
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrust() }
        }
        if !isTrusted { promptForAccessibility() }
        reload()
    }

    /// 按当前设置重新安装监听。设置变化、权限变化后调用。
    func reload() {
        teardown()
        registrationError = nil
        guard !suspended else { return }
        switch mode {
        case .doubleCmdC: installKeyListener()
        case .custom: registerCustomHotkey()
        }
    }

    /// 录制新快捷键期间暂停一切监听。
    func suspend() {
        suspended = true
        teardown()
    }

    func resume() {
        suspended = false
        reload()
    }

    func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 权限

    private func refreshTrust() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        reload()
    }

    // MARK: - 连按两下 ⌘C

    private func installKeyListener() {
        guard isTrusted else { return }
        let tap = KeyTap { [weak self] press in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.doubleCommandC(press) }
            }
        }
        if tap.start() {
            keyTap = tap
            return
        }
        // 退路：建不了事件监听时，用 NSEvent 的全局监听（同样依赖辅助功能权限）。
        // 这种监听收到事件时前台 app 可能已经复制完了，所以基准点可能偏晚，但第二次复制仍会让剪贴板变化。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let isCommandC = Int(event.keyCode) == kVK_ANSI_C && flags == .command
            let isRepeat = event.isARepeat
            MainActor.assumeIsolated {
                guard let self, !isRepeat else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if let press = self.fallbackDetector.feed(isCommandC: isCommandC, now: now,
                                                          changeCount: { NSPasteboard.general.changeCount }) {
                    self.doubleCommandC(press)
                }
            }
        }
    }

    private func doubleCommandC(_ press: DoublePress) {
        guard !suspended, mode == .doubleCmdC else { return }
        // 在本 app 自己的窗口里连按 ⌘C 只是普通复制。
        guard !NSApp.isActive else { return }
        let pasteboard = NSPasteboard.general
        // 至少等到第一次 ⌘C 后 0.9 秒、第二次后 0.35 秒，给复制得慢的 app 留时间。
        let now = ProcessInfo.processInfo.systemUptime
        let timeout = max(press.firstPressTime + 0.9 - now, 0.35)
        Task { @MainActor [weak self] in
            // 从第一次 ⌘C 之前算起，剪贴板一直没变 = 没有选中文字（或这个 app 的 ⌘C 不复制）。
            // 这时绝不能去读剪贴板，否则会把之前复制的内容（可能是密码）发出去。
            guard await Self.waitForChange(pasteboard, from: press.baseline, timeout: timeout) else {
                self?.onTrigger?(.nothingSelected)
                return
            }
            self?.onTrigger?(await Self.capture(pasteboard))
        }
    }

    // MARK: - 自定义组合键

    private func registerCustomHotkey() {
        let defaults = UserDefaults.standard
        let keyCode = defaults.integer(forKey: Keys.customKeyCode)
        let modifiers = defaults.integer(forKey: Keys.customModifiers)
        guard modifiers != 0 else {
            registrationError = "还没有录制快捷键。"
            return
        }
        installCarbonHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5154_524E), id: 1) // 'QTRN'
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            registrationError = "快捷键注册失败（可能已被其他 app 占用），请换一个。"
        }
    }

    private func installCarbonHandlerIfNeeded() {
        guard carbonHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), carbonHotkeyCallback, 1, &spec, refcon, &carbonHandler)
    }

    fileprivate func customHotkeyPressed() {
        guard !suspended, mode == .custom else { return }
        guard AXIsProcessTrusted() else {
            promptForAccessibility()
            onTrigger?(.needsPermission)
            return
        }
        // 上一次取词还没结束就忽略，免得两次互相覆盖剪贴板。
        guard !capturing else { return }
        capturing = true
        // 上一次没取到、还在等着恢复剪贴板：取消它，并沿用它保存的原内容。
        let inherited = pendingRestore?.saved
        cancelPendingRestore()
        Task { @MainActor [weak self] in
            defer { self?.capturing = false }
            // 用户可能还按着 ⌥/⌃/⇧，先等松开，免得模拟出来的变成 ⌥⌘C 之类。
            await Self.waitForModifierRelease(timeout: 0.4)
            let pasteboard = NSPasteboard.general
            let saved = inherited ?? Self.snapshot(pasteboard)
            let startCount = pasteboard.changeCount
            Self.postCommandC()
            guard await Self.waitForChange(pasteboard, from: startCount, timeout: 1.0) else {
                self?.onTrigger?(.nothingSelected)
                self?.scheduleLateRestore(saved: saved, from: startCount)
                return
            }
            let result = await Self.capture(pasteboard)
            Self.restore(pasteboard, saved)
            self?.onTrigger?(result)
        }
    }

    /// 有的 app 复制得慢：超时后再盯一会儿，一旦它写进来就把用户原来的剪贴板还回去。
    private func scheduleLateRestore(saved: [NSPasteboardItem], from count: Int) {
        let task = Task { @MainActor [weak self] in
            let pasteboard = NSPasteboard.general
            if await Self.waitForChange(pasteboard, from: count, timeout: 1.5) {
                try? await Task.sleep(for: .milliseconds(50))
                if !Task.isCancelled { Self.restore(pasteboard, saved) }
            }
            if !Task.isCancelled { self?.pendingRestore = nil }
        }
        pendingRestore = (task, saved)
    }

    /// 本 app 自己要写剪贴板（例如"复制译文"）时调用，免得被迟到的恢复覆盖。
    func cancelPendingRestore() {
        pendingRestore?.task.cancel()
        pendingRestore = nil
    }

    // MARK: - 清理

    private func teardown() {
        keyTap?.stop()
        keyTap = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        fallbackDetector = DoublePressDetector()
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    // MARK: - 剪贴板工具

    private static func waitForChange(_ pasteboard: NSPasteboard, from count: Int, timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if pasteboard.changeCount != count { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return pasteboard.changeCount != count
    }

    /// 密码管理器等会用这两个标记告诉别的 app"别记录这段内容"（nspasteboard.org 约定）。
    private static let sensitiveTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    /// 读出剪贴板里的文字。剪贴板"先清空、再写入"是两步，刚变化时可能还读不到内容，稍微重试几次。
    private static func capture(_ pasteboard: NSPasteboard) async -> CaptureResult {
        for attempt in 0..<8 {
            if let types = pasteboard.types, !sensitiveTypes.isDisjoint(with: types) { return .sensitive }
            if let text = pasteboard.string(forType: .string), !text.isEmpty { return .text(text) }
            if attempt < 7 { try? await Task.sleep(for: .milliseconds(20)) }
        }
        return .nothingSelected
    }

    private static func waitForModifierRelease(timeout: TimeInterval) async {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let blocking: CGEventFlags = [.maskAlternate, .maskControl, .maskShift]
        while ProcessInfo.processInfo.systemUptime < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(blocking).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_C)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ pasteboard: NSPasteboard, _ items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}

// MARK: - 连按判定

struct DoublePress: Sendable {
    /// 第一次 ⌘C 时的剪贴板计数，作为"是否真的复制了"的基准。
    let baseline: Int
    let firstPressTime: TimeInterval
}

/// 两次 ⌘C 间隔不超过 0.5 秒即算连按。
struct DoublePressDetector {
    static let interval: TimeInterval = 0.5

    private var lastPress: TimeInterval = 0
    private var baseline = 0

    mutating func feed(isCommandC: Bool, now: TimeInterval, changeCount: () -> Int) -> DoublePress? {
        guard isCommandC else {
            lastPress = 0
            return nil
        }
        if lastPress > 0, now - lastPress <= Self.interval {
            let press = DoublePress(baseline: baseline, firstPressTime: lastPress)
            lastPress = 0
            return press
        }
        lastPress = now
        baseline = changeCount()
        return nil
    }
}

// MARK: - 键盘监听线程

/// 在独立线程上运行的键盘事件监听。
/// 用"可拦截"类型的监听（只需辅助功能权限），但每个事件都原样放行；
/// 放在独立线程上，主线程卡顿时不会拖慢全系统的键盘输入。
private final class KeyTap: @unchecked Sendable {
    private let onDoublePress: @Sendable (DoublePress) -> Void
    // 以下状态只在监听线程上读写（start 之前的初始化除外）。
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var detector = DoublePressDetector()

    init(onDoublePress: @escaping @Sendable (DoublePress) -> Void) {
        self.onDoublePress = onDoublePress
    }

    /// 建立监听；失败（通常是没有权限）返回 false。
    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let mask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: keyTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.tap = tap
            self.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "QuickTrans.KeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return tap != nil
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        tap = nil
        runLoop = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            let flags = event.flags
            let commandOnly = flags.contains(.maskCommand)
                && !flags.contains(.maskShift)
                && !flags.contains(.maskAlternate)
                && !flags.contains(.maskControl)
            let isCommandC = commandOnly && Int(event.getIntegerValueField(.keyboardEventKeycode)) == kVK_ANSI_C
            // 事件还没送到前台 app，这时读到的剪贴板计数正好是"复制之前"。
            let press = detector.feed(isCommandC: isCommandC, now: ProcessInfo.processInfo.systemUptime) {
                autoreleasepool { NSPasteboard.general.changeCount }
            }
            if let press { onDoublePress(press) }
        default:
            break
        }
    }
}

// C 回调。

private func keyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

private func carbonHotkeyCallback(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { manager.customHotkeyPressed() }
    return noErr
}

// MARK: - 快捷键显示

enum KeyNames {
    /// 只带 ⌘ 时不允许录制的键：这些是常用的系统/编辑快捷键，被全局占用后别的 app 会失灵。
    static let reservedCommandKeys: Set<Int> = [
        kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_S, kVK_ANSI_Q,
        kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_F,
        kVK_ANSI_T, kVK_Tab, kVK_Space, kVK_ANSI_Comma,
    ]

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.shift) { result |= shiftKey }
        return result
    }

    static func display(flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + keyName(event)
    }

    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        if let name = special[Int(event.keyCode)] { return name }
        let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?"
        return characters.uppercased()
    }
}
