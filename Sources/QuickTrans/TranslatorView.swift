import AppKit
import SwiftUI

/// 主窗口内容：顶栏背景（画在工具栏和红绿灯下面）+ 权限提示 + 左右两栏。
struct MainView: View {
    @ObservedObject var model: TranslatorModel
    @ObservedObject var hotkeys: HotkeyManager
    @ObservedObject private var lookup = WordLookup.shared
    @AppStorage(Keys.theme) private var themeID = Theme.defaultID

    var body: some View {
        let theme = Theme.named(themeID)
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if !hotkeys.isTrusted {
                    PermissionBanner(theme: theme)
                }
                TranslatorPanes(model: model, theme: theme)
                if lookup.isVisible {
                    lookupPanel(theme)
                }
            }
            .animation(.easeOut(duration: 0.2), value: lookup.isVisible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OfflineTranslationHost())
            .background(alignment: .top) {
                // 窗口顶部的安全区就是工具栏的高度，把顶栏背景往上挪进去。
                VStack(spacing: 0) {
                    Rectangle().fill(theme.headerFill)
                        .frame(height: geometry.safeAreaInsets.top)
                    if let rule = theme.headerRule {
                        rule.frame(height: 1)
                    }
                }
                .offset(y: -geometry.safeAreaInsets.top)
            }
            .background(theme.canvas.ignoresSafeArea())
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    @ViewBuilder
    private func lookupPanel(_ theme: Theme) -> some View {
        if theme.cards {
            WordLookupPanel(lookup: lookup, theme: theme)
                .modifier(Card(theme: theme, background: theme.targetBackground))
                .padding([.horizontal, .bottom], 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            VStack(spacing: 0) {
                Rectangle().fill(theme.divider).frame(height: 1)
                WordLookupPanel(lookup: lookup, theme: theme)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// 放在工具栏里的方向、风格切换。
struct HeaderControls: View {
    @ObservedObject var model: TranslatorModel
    @AppStorage(Keys.theme) private var themeID = Theme.defaultID
    @AppStorage(Keys.engineMode) private var engineMode = EngineMode.auto.rawValue

    var body: some View {
        let theme = Theme.named(themeID)
        HStack(spacing: 14) {
            ThemedSegmented(options: DirectionChoice.allCases, label: \.label, selection: $model.directionChoice, theme: theme)
                .help("自动：按原文以中文还是英文为主判断方向；也可以手动指定输出语言")
            // 离线翻译没有提示词，不区分正常 / 学术。
            let offlineOnly = engineMode == EngineMode.offline.rawValue
            ThemedSegmented(options: Style.allCases, label: \.label, selection: $model.style, theme: theme)
                .disabled(offlineOnly)
                .opacity(offlineOnly ? 0.45 : 1)
                .help(offlineOnly ? "离线翻译不区分正常 / 学术" : "正常 / 学术")
        }
        .fixedSize()
    }
}

/// 工具栏右侧的设置按钮。
struct HeaderSettingsButton: View {
    var action: () -> Void
    @AppStorage(Keys.theme) private var themeID = Theme.defaultID

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.named(themeID).headerText)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("设置（⌘,）")
    }
}

/// 可换配色的分段按钮（系统自带的分段控件改不了颜色）。
struct ThemedSegmented<Value: Hashable & Identifiable>: View {
    let options: [Value]
    let label: KeyPath<Value, String>
    @Binding var selection: Value
    let theme: Theme
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = option }
                } label: {
                    Text(option[keyPath: label])
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? theme.segmentSelectedText : theme.segmentText)
                        .padding(.horizontal, 13)
                        .frame(height: 26)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(theme.segmentFill)
                                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.segmentTrack))
    }
}

/// 没有辅助功能权限时顶部的提示条。
struct PermissionBanner: View {
    let theme: Theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.notice)
            VStack(alignment: .leading, spacing: 2) {
                Text("快捷键取词需要「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能，打开 QuickTrans。")
                    .font(.callout)
                    .foregroundStyle(theme.text)
                Text("如果那里已经是打开的（常见于重新安装之后），请选中 QuickTrans 点「−」删除，再点「+」重新添加。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Button("打开系统设置") { HotkeyManager.openAccessibilitySettings() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(theme.notice.opacity(0.12), ignoresSafeAreaEdges: [])
    }
}

/// 左原文、右译文。
struct TranslatorPanes: View {
    @ObservedObject var model: TranslatorModel
    let theme: Theme

    // 占位提示里的快捷键说明、正文字体都跟着设置变化。
    @AppStorage(Keys.hotkeyMode) private var hotkeyMode = HotkeyMode.doubleCmdC.rawValue
    @AppStorage(Keys.customDisplay) private var customDisplay = ""
    @AppStorage(Keys.fontLatin) private var fontLatin = ""
    @AppStorage(Keys.fontCJK) private var fontCJK = ""
    @AppStorage(Keys.fontSize) private var fontSize = Defaults.fontSize
    @AppStorage(Keys.splitRatio) private var splitRatio = 0.5
    @ObservedObject private var speaker = Speaker.shared
    @State private var copied = false
    @State private var composing = false
    @State private var hoveringSplit = false

    private static let ratioRange = 0.2...0.8

    var body: some View {
        let font = AppFont.font(latin: fontLatin, cjk: fontCJK, size: fontSize)
        let gap: CGFloat = theme.cards ? 14 : 1
        let inset: CGFloat = theme.cards ? 16 : 0
        GeometryReader { geometry in
            let available = max(geometry.size.width - inset * 2 - gap, 1)
            let ratio = clampedRatio(splitRatio, available: available)
            HStack(spacing: 0) {
                styled(sourcePane(font), background: theme.sourceBackground)
                    .frame(width: available * ratio)
                splitHandle(gap: gap, available: available)
                    .zIndex(1)
                styled(targetPane(font), background: theme.targetBackground)
                    .frame(maxWidth: .infinity)
            }
            .coordinateSpace(.named("panes"))
            .padding(inset)
        }
    }

    private var lineSpacing: CGFloat { fontSize * 0.28 }

    /// 比例限制在 20%–80%，同时每栏至少留 260pt，窗口窄时不至于把底栏挤坏。
    private func clampedRatio(_ ratio: Double, available: CGFloat) -> Double {
        let minimum = 260 / Double(available)
        let lower = max(Self.ratioRange.lowerBound, minimum)
        let upper = min(Self.ratioRange.upperBound, 1 - minimum)
        guard lower <= upper else { return 0.5 }
        return min(max(ratio, lower), upper)
    }

    private var paneFont: NSFont { AppFont.nsFont(latin: fontLatin, cjk: fontCJK, size: CGFloat(fontSize)) }

    @ViewBuilder
    private func styled(_ pane: some View, background: Color) -> some View {
        if theme.cards {
            pane.modifier(Card(theme: theme, background: background))
        } else {
            // 背景色默认会延伸进工具栏区域、盖住顶栏，这里不让它延伸。
            pane.background(background, ignoresSafeAreaEdges: [])
        }
    }

    /// 中间的分隔：拖动调整左右宽度（20%–80%，会记住），双击恢复一半一半。
    private func splitHandle(gap: CGFloat, available: CGFloat) -> some View {
        ZStack {
            if theme.cards {
                Capsule().fill(theme.secondaryText.opacity(0.35)).frame(width: 4, height: 36)
                    .opacity(hoveringSplit ? 1 : 0)
            } else {
                Rectangle().fill(hoveringSplit ? theme.accent.opacity(0.6) : theme.divider).frame(width: 1)
            }
        }
        .frame(width: gap)
        .frame(maxHeight: .infinity)
        .overlay {
            Color.clear
                .frame(width: max(gap, 10))
                .contentShape(Rectangle())
                .pointerStyle(.columnResize)
                .onHover { hoveringSplit = $0 }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("panes"))
                        .onChanged { value in
                            splitRatio = clampedRatio((value.location.x - gap / 2) / available, available: available)
                        }
                )
                .onTapGesture(count: 2) { splitRatio = 0.5 }
                .help("拖动调整左右宽度；双击恢复一半一半")
        }
        .animation(.easeOut(duration: 0.15), value: hoveringSplit)
    }

    private func sourcePane(_ font: Font) -> some View {
        ZStack(alignment: .topLeading) {
            PaneTextView(
                text: $model.source,
                font: paneFont,
                textColor: NSColor(theme.text),
                lineSpacing: lineSpacing,
                onImages: { model.recognizeImages($0) },
                onComposingChange: { composing = $0 },
                onWordSelected: { WordLookup.shared.lookup($0, in: $1) }
            )
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 44, trailing: 34))

            if model.source.isEmpty && !composing {
                VStack(alignment: .leading, spacing: 10) {
                    Text("输入或粘贴文本进行翻译")
                        .font(.system(size: fontSize + 5, weight: .light))
                    Text("或选中任意文字，按 \(HotkeyManager.displayName(mode: hotkeyMode, customDisplay: customDisplay)) 快速翻译")
                        .font(.system(size: 13))
                    Text("也可以粘贴截图（⌘V）或把图片拖进来，自动识别其中的文字")
                        .font(.system(size: 13))
                }
                .foregroundStyle(theme.secondaryText.opacity(0.85))
                .padding(.leading, 21)
                .padding(.top, 16)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !model.source.isEmpty {
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .help("清空")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    speaker.toggleParagraph(model.source)
                } label: {
                    Image(systemName: speaker.isReadingParagraph ? "stop.circle.fill" : "speaker.wave.2")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .help(speaker.isReadingParagraph ? "停止朗读" : "朗读原文")
            }
        }
        // 原文变了，正在读的那段就作废了。
        .onChange(of: model.source) {
            speaker.stop()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func targetPane(_ font: Font) -> some View {
        VStack(spacing: 0) {
            if !model.isRecognizing, model.errorMessage == nil, !model.target.isEmpty {
                // 译文用只读的文本框显示：可以选中复制，双击英文单词能查词。
                PaneTextView(
                    text: .constant(model.target),
                    isEditable: false,
                    font: paneFont,
                    textColor: NSColor(theme.text),
                    lineSpacing: lineSpacing,
                    onWordSelected: { WordLookup.shared.lookup($0, in: $1) }
                )
                .padding(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
            } else {
                ScrollView {
                    targetStatus
                        .font(font)
                        .lineSpacing(lineSpacing)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(EdgeInsets(top: 16, leading: 21, bottom: 16, trailing: 21))
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 没有译文时显示的状态：识别中 / 出错 / 翻译中。
    @ViewBuilder
    private var targetStatus: some View {
        if model.isRecognizing {
            Text("正在识别图片中的文字…")
                .foregroundStyle(theme.secondaryText)
        } else if let error = model.errorMessage {
            Text(error)
                .foregroundStyle(theme.error)
                .textSelection(.enabled)
        } else {
            Text(model.isTranslating ? "翻译中…" : "")
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isTranslating || model.isRecognizing {
                ProgressView().controlSize(.small)
            }
            if model.directionChoice == .auto, let direction = model.activeDirection {
                Text("自动 · \(direction.arrow)")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .help("按原文以中文还是英文为主自动判断；不合意可在顶部手动选「译成英文 / 译成中文」")
            }
            if let engineNote = model.engineNote {
                Text(engineNote)
                    .font(.caption)
                    .foregroundStyle(model.engineFellBack ? theme.notice : theme.secondaryText)
                    .lineLimit(1)
                    .help(model.engineFellBack
                          ? "自动模式：在线翻译不可用，这次用了系统自带的离线翻译。\n原因：\(model.engineDetail ?? "-")"
                          : "这次用的翻译引擎")
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(theme.notice)
                    .lineLimit(2)
                    .help(notice)
            }
            Spacer()
            Button {
                model.translateNow(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help("重新翻译（⌘↩）")
            .disabled(model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                model.copyTarget()
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Label(copied ? "已复制" : "复制译文", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(theme.accent.opacity(theme.isDark ? 0.18 : 0.1)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.target.isEmpty || model.errorMessage != nil)
            .opacity(model.target.isEmpty || model.errorMessage != nil ? 0.45 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// 卡片样式：圆角、细边框、轻阴影。
private struct Card: ViewModifier {
    let theme: Theme
    let background: Color

    func body(content: Content) -> some View {
        content
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.divider, lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.06), radius: 10, y: 3)
    }
}
