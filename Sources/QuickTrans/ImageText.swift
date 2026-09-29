import AppKit
import UniformTypeIdentifiers
import Vision

/// 截图取字：用 macOS 自带的文字识别（Vision），在本机完成，图片不上传。
enum ImageText {
    /// 一次最多识别几张（选中一堆图片复制时防止卡很久）。
    static let maxImages = 10

    /// 从剪贴板或拖入的内容里取图片：图片文件（可多张），或截图工具放进来的图片数据。
    /// 同时带文字的（例如从网页、Word 复制的内容常附带一张图）按文字处理，这里返回空。
    static func images(from pasteboard: NSPasteboard) -> [CGImage] {
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL]) ?? []
        if !urls.isEmpty {
            return urls.prefix(maxImages).compactMap { NSImage(contentsOf: $0).flatMap(cgImage) }
        }
        guard pasteboard.string(forType: .string) == nil,
              pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = NSImage(pasteboard: pasteboard).flatMap(cgImage) else { return [] }
        return [image]
    }

    /// 只看类型、不读图片内容的快速判断（拖动过程中会被反复调用）。
    static func containsImage(_ pasteboard: NSPasteboard) -> Bool {
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: fileOptions) { return true }
        return pasteboard.string(forType: .string) == nil && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// 识别用的串行队列：Vision 同时开太多任务会卡死，所以一张一张来，也不占用 Swift 的并发线程。
    private static let queue = DispatchQueue(label: "QuickTrans.TextRecognition", qos: .userInitiated)

    /// 识别多张图片里的中英文，按行返回，图片之间空一行。
    static func recognize(_ images: [CGImage]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let parts = try images.map { try recognizeLines(in: $0).joined(separator: "\n") }.filter { !$0.isEmpty }
                    let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        continuation.resume(throwing: ImageTextError.noText)
                    } else {
                        continuation.resume(returning: text)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Vision 对特别长的图（例如手机长截图，高度上万像素）会直接返回空，
    /// 所以超过一定高度就切成上下略有重叠的几段分别识别，再拼回去、去掉重叠处重复的行。
    private static func recognizeLines(in image: CGImage) throws -> [String] {
        let tileHeight = 3000, overlap = 200
        guard image.height > 4000 else { return try recognizeTile(image) }
        var lines: [String] = []
        var top = 0
        while top < image.height {
            let height = min(tileHeight, image.height - top)
            guard let tile = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: height)) else { break }
            var tileLines = try recognizeTile(tile)
            // 重叠区里的行在上一段末尾已经出现过，去掉。
            if let overlapStart = (0..<min(5, tileLines.count)).last(where: { lines.suffix(8).contains(tileLines[$0]) }) {
                tileLines.removeFirst(overlapStart + 1)
            }
            lines += tileLines
            if top + height >= image.height { break }
            top += tileHeight - overlap
        }
        return lines
    }

    private static func recognizeTile(_ image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? ImageTextError { return error.errorDescription ?? "\(error)" }
        return "识别图片失败：\(error.localizedDescription)"
    }

    private static func cgImage(_ image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

enum ImageTextError: LocalizedError {
    case noText

    var errorDescription: String? {
        switch self {
        case .noText: return "图片里没有认出文字。"
        }
    }
}
