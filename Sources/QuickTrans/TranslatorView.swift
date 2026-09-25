import AppKit
import SwiftUI

/// 主窗口内容：顶栏背景（画在工具栏和红绿灯下面）+ 权限提示 + 左右两栏。
struct MainView: View {
    @ObservedObject var model: TranslatorModel
    @ObservedObject var hotkeys: HotkeyManager
    @AppStorage(Keys.theme) private var themeID = Theme.defaultID

    var body: some View {
        let theme = Theme.named(themeID)
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if !hotkeys.isTrusted {
                    PermissionBanner(theme: theme)
                }
                TranslatorPanes(model: model, theme: theme)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

/// 放在工具栏里的方向、风格切换。
struct HeaderControls: View {
    @ObservedObject var model: TranslatorModel
    @AppStorage(Keys.theme) private var themeID = Theme.defaultID

    var body: some View {
        let theme = Theme.named(themeID)
        HStack(spacing: 14) {
            ThemedSegmented(options: Direction.allCases, label: \.label, selection: $model.direction, theme: theme)
                .help("选择输出语言")
            ThemedSegmented(options: Style.allCases, label: \.label, selection: $model.style, theme: theme)
                .help("正常 / 学术")
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
    @State private var copied = false

    var body: some View {
        let font = AppFont.font(latin: fontLatin, cjk: fontCJK, size: fontSize)
        if theme.cards {
            HStack(spacing: 14) {
                sourcePane(font).modifier(Card(theme: theme, background: theme.sourceBackground))
                targetPane(font).modifier(Card(theme: theme, background: theme.targetBackground))
            }
            .padding(16)
        } else {
            HStack(spacing: 0) {
                // 背景色默认会延伸进工具栏区域、盖住顶栏，这里不让它延伸。
                sourcePane(font).background(theme.sourceBackground, ignoresSafeAreaEdges: [])
                Rectangle().fill(theme.divider).frame(width: 1)
                targetPane(font).background(theme.targetBackground, ignoresSafeAreaEdges: [])
            }
        }
    }

    private var lineSpacing: CGFloat { fontSize * 0.28 }

    private func sourcePane(_ font: Font) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.source)
                .font(font)
                .lineSpacing(lineSpacing)
                .foregroundStyle(theme.text)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never) // 接鼠标时系统会常显滚动条轨道，看着像一条空栏
                .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 34))

            if model.source.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("输入或粘贴文本进行翻译")
                        .font(.system(size: fontSize + 5, weight: .light))
                    Text("或选中任意文字，按 \(HotkeyManager.displayName(mode: hotkeyMode, customDisplay: customDisplay)) 快速翻译")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func targetPane(_ font: Font) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                targetContent
                    .font(font)
                    .lineSpacing(lineSpacing)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(EdgeInsets(top: 16, leading: 21, bottom: 16, trailing: 21))
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var targetContent: some View {
        if let error = model.errorMessage {
            Text(error)
                .foregroundStyle(theme.error)
                .textSelection(.enabled)
        } else if model.target.isEmpty {
            Text(model.isTranslating ? "翻译中…" : "")
                .foregroundStyle(theme.secondaryText)
        } else {
            Text(model.target)
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isTranslating {
                ProgressView().controlSize(.small)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(theme.notice)
                    .lineLimit(2)
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
