import AppKit

Defaults.register()

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}

/// 命令行自检：`QuickTrans.app/Contents/MacOS/QuickTrans --selftest`
/// 用当前设置把四种"方向 × 风格"各跑一遍，打印首字延迟和译文。
enum SelfTest {
    static func run() -> Never {
        let samples: [(Direction, Style, String)] = [
            (.toEnglish, .normal, "今天天气很好，我们去公园散步吧。"),
            (.toEnglish, .academic, "实验结果表明，该方法在三个公开数据集上均优于现有基线。"),
            (.toChinese, .normal, "Could you send me the slides before the meeting tomorrow?"),
            (.toChinese, .academic, "Deep neural networks are prone to overfitting when\ntraining data is scarce [12]."),
        ]
        Task {
            var allPassed = true
            for (direction, style, text) in samples {
                let start = Date()
                var firstChunk: TimeInterval?
                var output = ""
                do {
                    let config = try APIConfig.current(direction: direction, style: style)
                    for try await piece in TranslationService.stream(text: text, config: config) {
                        if firstChunk == nil, !piece.isEmpty { firstChunk = Date().timeIntervalSince(start) }
                        output += piece
                    }
                    let total = Date().timeIntervalSince(start)
                    print(String(format: "[%@ · %@] 首字 %.2fs，总计 %.2fs", direction.label, style.label, firstChunk ?? -1, total))
                    print(output)
                    print("")
                    if output.isEmpty { allPassed = false }
                } catch {
                    allPassed = false
                    print("[\(direction.label) · \(style.label)] 失败：\(TranslationService.describe(error))")
                }
            }
            exit(allPassed ? 0 : 1)
        }
        dispatchMain()
    }
}
