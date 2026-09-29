import AppKit
import SwiftUI

/// 左栏的原文输入框。用 AppKit 的 NSTextView 自己实现（而不是 SwiftUI 的 TextEditor），
/// 这样才能接住"粘贴图片"和"拖入图片"，并关掉会悄悄改动原文的智能引号、自动纠错。
struct SourceTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var lineSpacing: CGFloat
    var onImages: ([CGImage]) -> Void
    /// 输入法正在组字（拼音还没上屏）时为 true，外面据此隐藏占位提示。
    var onComposingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ImageAwareTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = .zero
        textView.delegate = context.coordinator
        textView.onImages = onImages
        textView.onComposingChange = onComposingChange
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // 接鼠标时系统会常显滚动条轨道，看着像一条空栏；不显示滚动条也照样能用滚轮/触控板滚动。
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView

        context.coordinator.applyStyle(to: textView, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ImageAwareTextView else { return }
        context.coordinator.parent = self
        textView.onImages = onImages
        textView.onComposingChange = onComposingChange
        // 正在用输入法打字时不要覆盖内容，否则候选词会被打断。
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            // 整段被程序替换（清空、识别截图、快捷键取词）后，旧的撤销记录对不上新内容，
            // 留着会让 ⌘Z 删错字甚至失灵，所以清掉。
            textView.undoManager?.removeAllActions()
            context.coordinator.applyStyle(to: textView, force: true)
        } else {
            context.coordinator.applyStyle(to: textView, force: false)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceTextView
        private var appliedFont: NSFont?
        private var appliedColor: NSColor?
        private var appliedSpacing: CGFloat?

        init(_ parent: SourceTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, parent.text != textView.string else { return }
            parent.text = textView.string
        }

        /// 字体、颜色、行距变了（或内容被整体替换）时，重新套到全文和之后输入的文字上。
        func applyStyle(to textView: NSTextView, force: Bool) {
            let changed = appliedFont != parent.font || appliedColor != parent.textColor || appliedSpacing != parent.lineSpacing
            guard force || changed else { return }
            // 换了字体或配色后，撤销恢复出来的文字会带着旧样式（深色主题的浅色字放到浅色主题上就看不见了）。
            if changed { textView.undoManager?.removeAllActions() }
            appliedFont = parent.font
            appliedColor = parent.textColor
            appliedSpacing = parent.lineSpacing

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = parent.lineSpacing
            let attributes: [NSAttributedString.Key: Any] = [
                .font: parent.font,
                .foregroundColor: parent.textColor,
                .paragraphStyle: paragraph,
            ]
            textView.font = parent.font
            textView.textColor = parent.textColor
            textView.insertionPointColor = parent.textColor
            textView.defaultParagraphStyle = paragraph
            textView.typingAttributes = attributes
            if let storage = textView.textStorage, storage.length > 0 {
                storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            }
        }
    }
}

/// 能接住图片的文本框：粘贴或拖入图片时交给 onImages 去识别文字，其余照常。
final class ImageAwareTextView: NSTextView {
    var onImages: (([CGImage]) -> Void)?
    var onComposingChange: ((Bool) -> Void)?

    override func paste(_ sender: Any?) {
        // 按住 ⌘V 不放时只处理第一下，免得一次发起一堆识别。
        if NSApp.currentEvent?.isARepeat == true, ImageText.containsImage(.general) { return }
        let images = ImageText.images(from: .general)
        if images.isEmpty {
            super.paste(sender)
        } else {
            onImages?(images)
        }
    }

    // 纯文本框默认认为"剪贴板里只有图片时不能粘贴"，会把粘贴菜单变灰、根本不调用 paste:。
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), ImageText.containsImage(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onComposingChange?(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onComposingChange?(false)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onComposingChange?(hasMarkedText())
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageText.containsImage(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageText.containsImage(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = ImageText.images(from: sender.draggingPasteboard)
        guard !images.isEmpty else { return super.performDragOperation(sender) }
        onImages?(images)
        return true
    }
}
