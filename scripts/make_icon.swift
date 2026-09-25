// 生成 1024×1024 的 app 图标 PNG：蓝色圆角方块 + 白色"译"字。
// 用法：swiftc make_icon.swift -o make_icon && ./make_icon out.png
import AppKit

let canvas: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("无法创建位图") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS 图标规范：内容区约 824×824，四周留白。
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor(red: 0.13, green: 0.32, blue: 0.85, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(
    starting: NSColor(red: 0.25, green: 0.52, blue: 1.00, alpha: 1),
    ending: NSColor(red: 0.10, green: 0.25, blue: 0.75, alpha: 1)
)?.draw(in: shape, angle: -90)

let font = NSFont(name: "PingFangSC-Semibold", size: 540) ?? NSFont.systemFont(ofSize: 540, weight: .semibold)
let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
let glyph = NSAttributedString(string: "译", attributes: attributes)
let size = glyph.size()
glyph.draw(at: NSPoint(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2 + 12))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 编码失败") }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
