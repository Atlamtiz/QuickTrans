import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsTab()
                .tabItem { Label("外观", systemImage: "paintpalette") }
            APISettingsTab()
                .tabItem { Label("接口", systemImage: "network") }
            HotkeySettingsTab()
                .tabItem { Label("快捷键", systemImage: "command") }
            PromptSettingsTab()
                .tabItem { Label("提示词", systemImage: "text.quote") }
        }
        .frame(width: 680, height: 600)
    }
}

// MARK: - 外观

private struct AppearanceSettingsTab: View {
    @AppStorage(Keys.theme) private var themeID = Theme.defaultID
    @AppStorage(Keys.fontLatin) private var fontLatin = ""
    @AppStorage(Keys.fontCJK) private var fontCJK = ""
    @AppStorage(Keys.fontSize) private var fontSize = Defaults.fontSize
    /// 先显示常用字体，完整列表在后台扫描完再补上；每次打开都重扫，新装的字体能马上出现。
    @State private var fonts = FontCatalog.featured()

    var body: some View {
        Form {
            Section("配色") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    ForEach(Theme.all) { theme in
                        Button {
                            themeID = theme.id
                        } label: {
                            ThemeCard(theme: theme, selected: theme.id == themeID)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(theme.name)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("英文字体", selection: $fontLatin) {
                    Section {
                        ForEach(withMissing(fonts.latinFeatured, others: fonts.latinOthers, selected: fontLatin), id: \.family) {
                            Text($0.label).tag($0.family)
                        }
                    }
                    Section("全部字体") {
                        ForEach(fonts.latinOthers, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("中文字体", selection: $fontCJK) {
                    Section {
                        ForEach(withMissing(fonts.cjkFeatured, others: fonts.cjkOthers, selected: fontCJK), id: \.family) {
                            Text($0.label).tag($0.family)
                        }
                    }
                    Section("其他含汉字的字体") {
                        ForEach(fonts.cjkOthers, id: \.self) { Text($0).tag($0) }
                    }
                }
                LabeledContent("字号") {
                    HStack(spacing: 10) {
                        Slider(value: $fontSize, in: Defaults.fontSizeRange, step: 1)
                            .frame(width: 220)
                        Text("\(Int(fontSize))")
                            .monospacedDigit()
                            .frame(width: 24, alignment: .trailing)
                    }
                }
                FontPreview(themeID: themeID, latin: fontLatin, cjk: fontCJK, size: fontSize)
            } header: {
                Text("正文字体")
            } footer: {
                Text("英文用「英文字体」显示，汉字自动用「中文字体」。在翻译窗口里也可以用 ⌘+ / ⌘− 调字号，⌘0 恢复默认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            fonts = await Task.detached(priority: .userInitiated) { FontCatalog.full() }.value
        }
    }

    /// 已选的字体不在列表里（被卸载了，或完整列表还没扫完）时补一项，免得菜单显示空白。
    private func withMissing(_ featured: [FontCatalog.Entry], others: [String], selected: String) -> [FontCatalog.Entry] {
        guard !selected.isEmpty, !featured.contains(where: { $0.family == selected }), !others.contains(selected) else {
            return featured
        }
        let installed = NSFontManager.shared.availableFontFamilies.contains(selected)
        return featured + [FontCatalog.Entry(family: selected, label: installed ? selected : "\(selected)（未安装）")]
    }
}

/// 配色缩略图：顶栏 + 两栏。
private struct ThemeCard: View {
    let theme: Theme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                ZStack {
                    Rectangle().fill(theme.headerFill)
                    HStack(spacing: 5) {
                        Capsule().fill(theme.segmentFill).frame(width: 30, height: 9)
                        Capsule().fill(theme.segmentTrack).frame(width: 30, height: 9)
                    }
                }
                .frame(height: 24)
                if let rule = theme.headerRule { rule.frame(height: 1) }
                HStack(spacing: theme.cards ? 6 : 0) {
                    miniPane(theme.sourceBackground, lines: [0.9, 0.7, 0.8])
                    if !theme.cards { theme.divider.frame(width: 1) }
                    miniPane(theme.targetBackground, lines: [0.85, 0.6])
                }
                .padding(theme.cards ? 6 : 0)
                .background(theme.canvas)
            }
            .frame(height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2.5 : 1)
            )
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
                Text(theme.name).font(.callout)
            }
        }
        .contentShape(Rectangle())
    }

    private func miniPane(_ background: Color, lines: [CGFloat]) -> some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, fraction in
                    Capsule().fill(theme.text.opacity(0.28)).frame(width: geometry.size.width * fraction * 0.8, height: 4)
                }
            }
            .padding(8)
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: theme.cards ? 4 : 0, style: .continuous))
    }
}

/// 用当前配色和字体预览一段中英混排的文字。
private struct FontPreview: View {
    let themeID: String
    let latin: String
    let cjk: String
    let size: Double

    var body: some View {
        let theme = Theme.named(themeID)
        Text("A good translation reads like the original.\n好的译文，读起来就像原文。")
            .font(AppFont.font(latin: latin, cjk: cjk, size: size))
            .lineSpacing(size * 0.28)
            .foregroundStyle(theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(theme.sourceBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.divider))
    }
}

// MARK: - 接口

private struct APISettingsTab: View {
    @AppStorage(Keys.baseURL) private var baseURL = Defaults.baseURL
    @AppStorage(Keys.apiKey) private var apiKey = ""
    @AppStorage(Keys.model) private var model = Defaults.model
    @AppStorage(Keys.disableThinking) private var disableThinking = true
    @State private var revealKey = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testSucceeded = false

    var body: some View {
        Form {
            Section {
                TextField("接口地址", text: $baseURL, prompt: Text(Defaults.baseURL))
                LabeledContent("API Key") {
                    HStack(spacing: 6) {
                        Group {
                            if revealKey {
                                TextField("API Key", text: $apiKey)
                            } else {
                                SecureField("API Key", text: $apiKey)
                            }
                        }
                        .labelsHidden()
                        Button {
                            revealKey.toggle()
                        } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealKey ? "隐藏" : "显示")
                    }
                }
                TextField("模型名", text: $model, prompt: Text(Defaults.model))
                Toggle("关闭思考模式（更快）", isOn: $disableThinking)
            } header: {
                Text("翻译接口（OpenAI 兼容格式）")
            } footer: {
                Text("关闭思考模式时，请求里会带上 thinking: {\"type\": \"disabled\"}。如果换成不认识这个参数的服务商而报错，就把它关掉。修改后立即生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(alignment: .top, spacing: 12) {
                    Button(testing ? "测试中…" : "测试连接") { runTest() }
                        .disabled(testing)
                    if let testResult {
                        Text(testResult)
                            .foregroundStyle(testSucceeded ? .green : .red)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task { @MainActor in
            let start = Date()
            do {
                let config = try APIConfig.current(direction: .toEnglish, style: .normal)
                var output = ""
                for try await piece in TranslationService.stream(text: "你好，世界", config: config) {
                    output += piece
                }
                let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
                testSucceeded = true
                testResult = "连接成功，用时 \(seconds) 秒：\(output)"
            } catch {
                testSucceeded = false
                testResult = TranslationService.describe(error)
            }
            testing = false
        }
    }
}

// MARK: - 快捷键

private struct HotkeySettingsTab: View {
    @AppStorage(Keys.hotkeyMode) private var mode = HotkeyMode.doubleCmdC.rawValue
    @ObservedObject private var hotkeys = HotkeyManager.shared

    private var isCustom: Bool { mode == HotkeyMode.custom.rawValue }

    var body: some View {
        Form {
            Section("取词快捷键") {
                Picker("方式", selection: $mode) {
                    Text("连按两下 ⌘C（默认）").tag(HotkeyMode.doubleCmdC.rawValue)
                    Text("自定义组合键").tag(HotkeyMode.custom.rawValue)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: mode) { hotkeys.reload() }

                if isCustom {
                    LabeledContent("组合键") { HotkeyRecorder() }
                    if let error = hotkeys.registrationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Text(isCustom
                     ? "选中文字后按下组合键。app 会替你执行一次复制来读取选中的文字，读完后恢复你原来的剪贴板内容。"
                     : "选中文字后，按住 ⌘ 快速连点两下 C。选中的文字会进入剪贴板（和普通复制一样）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("权限") {
                LabeledContent("辅助功能") {
                    if hotkeys.isTrusted {
                        Label("已允许", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack {
                            Label("未允许", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Button("打开系统设置") { HotkeyManager.openAccessibilitySettings() }
                        }
                    }
                }
                Text("读取选中的文字需要这个权限。如果已经打开但快捷键仍然没反应（常见于重新安装之后），请在列表里选中 QuickTrans，点「−」删除，再点「+」重新添加并打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 点一下开始录制，按下新的组合键即保存；Esc 取消。
private struct HotkeyRecorder: View {
    @AppStorage(Keys.customDisplay) private var display = ""
    @State private var recording = false
    @State private var monitor: Any?
    @State private var recordingWindow: NSWindow?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(recording ? "请按下新的组合键…（Esc 取消）" : (display.isEmpty ? "点击录制" : display)) {
                recording ? stop() : start()
            }
            .frame(minWidth: 180)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        // 切到别的窗口或别的 app、关掉设置窗口，都结束录制并恢复快捷键。
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if (note.object as? NSWindow) === recordingWindow { stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func start() {
        hint = nil
        recording = true
        HotkeyManager.shared.suspend()
        // 只接收设置窗口里的按键；别的窗口照常打字、粘贴。
        let window = NSApp.keyWindow
        recordingWindow = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window else { return event }
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.intersection([.command, .option, .control]).isEmpty {
            hint = "至少要包含 ⌘、⌥、⌃ 中的一个。"
            return
        }
        if flags == .command && event.keyCode == UInt16(kVK_ANSI_C) {
            hint = "⌘C 是复制。想用连按两下 ⌘C，请选上面的默认方式。"
            return
        }
        if flags == .command && KeyNames.reservedCommandKeys.contains(Int(event.keyCode)) {
            hint = "这是常用的系统快捷键，占用后别的 app 会失灵。请加上 ⌥ 或 ⌃ 换一个。"
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(Int(event.keyCode), forKey: Keys.customKeyCode)
        defaults.set(KeyNames.carbonModifiers(flags), forKey: Keys.customModifiers)
        display = KeyNames.display(flags: flags, event: event)
        hint = nil
        stop()
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recordingWindow = nil
        if recording {
            recording = false
            HotkeyManager.shared.resume()
        }
    }
}

// MARK: - 提示词

private struct PromptSettingsTab: View {
    @State private var direction: Direction = .toEnglish
    @State private var style: Style = .normal
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("方向", selection: $direction) {
                    ForEach(Direction.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("风格", selection: $style) {
                    ForEach(Style.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("恢复默认") { text = Defaults.prompt(direction, style) }
            }

            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Text("共四条提示词（方向 × 风格），上面切换要编辑哪一条。修改自动保存，下次翻译生效；想马上看效果，在翻译窗口点 ↻ 重新翻译。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear { load() }
        .onChange(of: direction) { load() }
        .onChange(of: style) { load() }
        .onChange(of: text) { save() }
    }

    private func load() {
        text = UserDefaults.standard.string(forKey: Keys.prompt(direction, style)) ?? Defaults.prompt(direction, style)
    }

    private func save() {
        let key = Keys.prompt(direction, style)
        if UserDefaults.standard.string(forKey: key) != text {
            UserDefaults.standard.set(text, forKey: key)
        }
    }
}
