// 生成 1024×1024 的 app 图标 PNG：青色渐变底，两个叠压的对话气泡，分别写"文"和"A"。
// 用法：swiftc -O make_icon.swift -o make_icon && ./make_icon out.png
import AppKit
import CoreGraphics
import CoreText

// ---------- helpers ----------
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Apple-style continuous-curvature rounded rect (squircle corners).
/// Coordinates are y-up. Corner offsets follow the widely used iOS 7+ reverse-engineered curve.
func continuousRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let k: CGFloat = 1.52866483
    let r = min(radius, min(rect.width, rect.height) / 2 / k)
    // corners traversed counter-clockwise (y-up): BR, TR, TL, BL
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    let p = CGMutablePath()
    for (i, (c, din, dout)) in corners.enumerated() {
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: c.x - din.dx * u * r + dout.dx * v * r,
                    y: c.y - din.dy * u * r + dout.dy * v * r)
        }
        if i == 0 { p.move(to: pt(k, 0)) } else { p.addLine(to: pt(k, 0)) }
        p.addCurve(to: pt(0.66993427, 0.06549600), control1: pt(1.08849323, 0), control2: pt(0.86840689, 0))
        p.addLine(to: pt(0.63149399, 0.07491100))
        p.addCurve(to: pt(0.07491100, 0.63149399), control1: pt(0.37282392, 0.16905899), control2: pt(0.16905899, 0.37282392))
        p.addLine(to: pt(0.06549600, 0.66993427))
        p.addCurve(to: pt(0, k), control1: pt(0, 0.86840689), control2: pt(0, 1.08849323))
    }
    p.closeSubpath()
    return p
}

/// Speech bubble = continuous rounded body + curved tail at a bottom corner.
/// side: -1 = tail at bottom-left, +1 = tail at bottom-right.
func bubble(_ body: CGRect, radius: CGFloat, side: CGFloat) -> CGPath {
    let bodyPath = continuousRect(body, radius: radius)
    let w = body.width, h = body.height
    // work in a local frame where x grows away from the tail-side edge
    let edgeX = side < 0 ? body.minX : body.maxX
    func P(_ dx: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: edgeX - side * dx, y: y) }
    let base = body.minY
    let tail = CGMutablePath()
    let mid = base + 0.5 * h                         // vertical tangent point of the side edge
    tail.move(to: P(0.40 * w, mid))                  // deep inside body (guarantees clean union)
    tail.addLine(to: P(0, mid))
    // outer edge continues the side of the bubble straight down into the tip
    tail.addCurve(to: P(0.02 * w, base - 0.19 * h), control1: P(0, base + 0.14 * h), control2: P(0.004 * w, base - 0.06 * h))
    // concave inner edge sweeping back to the bottom edge
    tail.addCurve(to: P(0.33 * w, base), control1: P(0.09 * w, base - 0.10 * h), control2: P(0.19 * w, base - 0.005 * h))
    tail.addLine(to: P(0.40 * w, base + 0.2 * h))
    tail.closeSubpath()
    return bodyPath.union(tail, using: .winding)
}

func drawGlyph(_ ctx: CGContext, _ text: String, font: NSFont, color: CGColor, center: CGPoint, stroke: CGFloat = 0) {
    var attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color)!,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    if stroke > 0 {
        attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -stroke / font.pointSize * 100
        attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color
    }
    let s = NSAttributedString(string: text, attributes: attrs)
    let line = CTLineCreateWithAttributedString(s)
    ctx.saveGState()
    ctx.textMatrix = .identity
    let ink = CTLineGetImageBounds(line, ctx)     // true glyph ink bounds, relative to origin
    ctx.textPosition = CGPoint(x: center.x - ink.midX, y: center.y - ink.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
    return base
}

// ---------- 配色 ----------
let backFill: [UInt32] = [0xE4FAFB, 0xC9F1F3]   // 后面"A"气泡的渐变（上 -> 下）
let aColor: UInt32 = 0x0A7F90
let gap: CGFloat = 20                           // 前后两个气泡之间的缝

// ---------- canvas ----------
let S = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let iconPath = continuousRect(iconRect, radius: 185.4)

// drop shadow of the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.28))
ctx.addPath(iconPath)
ctx.setFillColor(rgb(0x12A6B2))
ctx.fillPath()
ctx.restoreGState()

// tile gradient (top-left light -> bottom-right deep)
ctx.saveGState()
ctx.addPath(iconPath)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x1CC3CB), rgb(0x17B8C1), rgb(0x0B8C9E)] as CFArray,
                    locations: [0, 0.35, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 240, y: 924), end: CGPoint(x: 784, y: 100), options: [])
// soft top highlight
let hl = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(hl, startCenter: CGPoint(x: 380, y: 900), startRadius: 0,
                       endCenter: CGPoint(x: 380, y: 900), endRadius: 620, options: [])
ctx.restoreGState()

// ---------- bubbles ----------
// front: "文", upper-left, tail bottom-left.  back: "A", lower-right, tail bottom-right.
let frontBody = CGRect(x: 206, y: 506, width: 372, height: 302)
let backBody  = CGRect(x: 446, y: 278, width: 372, height: 302)
let frontPath = bubble(frontBody, radius: 104, side: -1)
let backPath  = bubble(backBody, radius: 104, side: 1)
let shadowTeal = rgb(0x04414C, 0.30)

// back bubble (+ its glyph) in its own layer so the gap can be cut
ctx.saveGState()
ctx.addPath(iconPath)
ctx.clip()
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: shadowTeal)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.addPath(backPath)
ctx.clip()
let bgBack = CGGradient(colorsSpace: cs, colors: backFill.map { rgb($0) } as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bgBack, start: CGPoint(x: 0, y: backBody.maxY), end: CGPoint(x: 0, y: backBody.minY - 70), options: [])
ctx.endTransparencyLayer()
ctx.restoreGState()
drawGlyph(ctx, "A", font: roundedFont(214, .bold), color: rgb(aColor),
          center: CGPoint(x: backBody.midX + 14, y: backBody.midY - 8))
if gap > 0 {
    ctx.setBlendMode(.clear)
    ctx.addPath(frontPath)
    ctx.setLineWidth(gap * 2)
    ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
    ctx.setBlendMode(.normal)
}
ctx.endTransparencyLayer()
ctx.restoreGState()

// front bubble with soft shadow falling on the back bubble
ctx.saveGState()
ctx.addPath(iconPath)
ctx.clip()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: shadowTeal)
ctx.addPath(frontPath)
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()
// very subtle vertical sheen on the white bubble
ctx.addPath(frontPath)
ctx.clip()
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xE9F7F8)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: frontBody.maxY), end: CGPoint(x: 0, y: frontBody.minY - 70), options: [])
ctx.restoreGState()

let wenFont = NSFont(name: "STYuanti-SC-Bold", size: 212) ?? NSFont.systemFont(ofSize: 206, weight: .bold)
drawGlyph(ctx, "文", font: wenFont, color: rgb(0x0B8C9E), center: CGPoint(x: frontBody.midX, y: frontBody.midY + 2), stroke: 4)

// ---------- save ----------
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
