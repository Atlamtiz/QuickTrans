import AppKit
import SwiftUI

/// 界面配色。每套主题决定顶栏、分段按钮、左右两栏和强调色。
struct Theme: Identifiable {
    let id: String
    let name: String
    let isDark: Bool
    /// 顶栏渐变（从左到右）；只有一个颜色就是纯色。
    let header: [Color]
    let headerText: Color
    /// 顶栏下方的细线（可选）。
    let headerRule: Color?
    let segmentTrack: Color
    let segmentSelected: [Color]
    let segmentSelectedText: Color
    let segmentText: Color
    /// 卡片式布局时，卡片外面的底色。
    let canvas: Color
    let sourceBackground: Color
    let targetBackground: Color
    let text: Color
    let secondaryText: Color
    let divider: Color
    let accent: Color
    let notice: Color
    let error: Color
    /// true：左右两栏是带圆角和阴影的卡片；false：像 DeepL 那样平铺、中间一条分隔线。
    let cards: Bool

    var headerFill: LinearGradient {
        LinearGradient(colors: header.count > 1 ? header : [header[0], header[0]],
                       startPoint: .leading, endPoint: .trailing)
    }

    var segmentFill: LinearGradient {
        LinearGradient(colors: segmentSelected.count > 1 ? segmentSelected : [segmentSelected[0], segmentSelected[0]],
                       startPoint: .top, endPoint: .bottom)
    }

    static let defaultID = "cyan"

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID }!
    }

    static let all: [Theme] = [classic, cyan, jade, xuan, night]

    /// 仿 DeepL：黑色顶栏，白底平铺。
    static let classic = Theme(
        id: "classic", name: "经典黑白", isDark: false,
        header: [Color(hex: 0x141414)], headerText: Color(hex: 0xF2F2F2), headerRule: nil,
        segmentTrack: Color(hex: 0x2A2A2A), segmentSelected: [Color(hex: 0xFFFFFF)],
        segmentSelectedText: Color(hex: 0x111111), segmentText: Color(hex: 0xBDBDBD),
        canvas: Color(hex: 0xFFFFFF), sourceBackground: Color(hex: 0xFFFFFF), targetBackground: Color(hex: 0xF5F5F5),
        text: Color(hex: 0x1A1A1A), secondaryText: Color(hex: 0x8A8A8A), divider: Color(hex: 0xE2E2E2),
        accent: Color(hex: 0x1A1A1A), notice: Color(hex: 0xB26A00), error: Color(hex: 0xC0392B),
        cards: false
    )

    /// 青色 + 白色。
    static let cyan = Theme(
        id: "cyan", name: "青白", isDark: false,
        header: [Color(hex: 0x17B8C1), Color(hex: 0x0B8C9E)], headerText: .white, headerRule: nil,
        segmentTrack: Color.black.opacity(0.2), segmentSelected: [Color.white],
        segmentSelectedText: Color(hex: 0x087480), segmentText: .white,
        canvas: Color(hex: 0xEEF7F8), sourceBackground: Color(hex: 0xFFFFFF), targetBackground: Color(hex: 0xF6FCFC),
        text: Color(hex: 0x15333A), secondaryText: Color(hex: 0x7C9AA0), divider: Color(hex: 0xD6ECEE),
        accent: Color(hex: 0x087480), notice: Color(hex: 0xB86E00), error: Color(hex: 0xD14343),
        cards: true
    )

    /// 墨绿渐变 + 金色点缀。
    static let jade = Theme(
        id: "jade", name: "墨绿鎏金", isDark: false,
        header: [Color(hex: 0x0B3327), Color(hex: 0x1C5A43)], headerText: Color(hex: 0xE8D39A),
        headerRule: Color(hex: 0xC9A45C),
        segmentTrack: Color.black.opacity(0.22), segmentSelected: [Color(hex: 0xEACD84), Color(hex: 0xC49A3A)],
        segmentSelectedText: Color(hex: 0x0E3226), segmentText: Color(hex: 0xE8D39A).opacity(0.85),
        canvas: Color(hex: 0xF1EEE3), sourceBackground: Color(hex: 0xFFFDF7), targetBackground: Color(hex: 0xFAF6EA),
        text: Color(hex: 0x1E2D26), secondaryText: Color(hex: 0x8C8468), divider: Color(hex: 0xE3D8B8),
        accent: Color(hex: 0xA9822E), notice: Color(hex: 0xA9822E), error: Color(hex: 0xB03A2E),
        cards: true
    )

    /// 宣纸底色 + 朱砂红，配宋体尤其合适。
    static let xuan = Theme(
        id: "xuan", name: "宣纸朱砂", isDark: false,
        header: [Color(hex: 0xEFE7D6)], headerText: Color(hex: 0x3B3228), headerRule: Color(hex: 0xD8CCB2),
        segmentTrack: Color(hex: 0xE2D8C3), segmentSelected: [Color(hex: 0xB5332A)],
        segmentSelectedText: Color(hex: 0xFFF8EE), segmentText: Color(hex: 0x4A3F33),
        canvas: Color(hex: 0xF2ECDF), sourceBackground: Color(hex: 0xFBF7EE), targetBackground: Color(hex: 0xF6F0E2),
        text: Color(hex: 0x2A241D), secondaryText: Color(hex: 0x9A8B74), divider: Color(hex: 0xE0D3B8),
        accent: Color(hex: 0xB5332A), notice: Color(hex: 0xA0661E), error: Color(hex: 0xB5332A),
        cards: true
    )

    /// 深色，夜里用不刺眼。
    static let night = Theme(
        id: "night", name: "深夜", isDark: true,
        header: [Color(hex: 0x16181D)], headerText: Color(hex: 0xD8DCE3), headerRule: Color(hex: 0x262A31),
        segmentTrack: Color(hex: 0x252930), segmentSelected: [Color(hex: 0x3A4150)],
        segmentSelectedText: Color(hex: 0xF2F4F8), segmentText: Color(hex: 0x9AA3B2),
        canvas: Color(hex: 0x111317), sourceBackground: Color(hex: 0x1B1E24), targetBackground: Color(hex: 0x1F232A),
        text: Color(hex: 0xE3E6EB), secondaryText: Color(hex: 0x7D8594), divider: Color(hex: 0x2B3038),
        accent: Color(hex: 0x7FB0FF), notice: Color(hex: 0xE0A84A), error: Color(hex: 0xF07470),
        cards: true
    )
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - 字体

/// 正文字体：英文用一种字体，中文（英文字体里没有的字）自动换成另一种。
enum AppFont {
    static func font(latin: String, cjk: String, size: Double) -> Font {
        Font(nsFont(latin: latin, cjk: cjk, size: CGFloat(size)) as CTFont)
    }

    static func nsFont(latin: String, cjk: String, size: CGFloat) -> NSFont {
        let base = latin.isEmpty
            ? NSFont.systemFont(ofSize: size)
            : NSFontManager.shared.font(withFamily: latin, traits: [], weight: 5, size: size) ?? .systemFont(ofSize: size)
        // 英文用系统字体时，汉字本来就回退到苹方；换了英文字体（如 Georgia），系统可能回退到宋体，
        // 所以"系统默认"也要明确指定苹方。
        if latin.isEmpty && cjk.isEmpty { return base }
        let cjkFamily = cjk.isEmpty ? "PingFang SC" : cjk
        let cascade = [NSFontDescriptor(fontAttributes: [.family: cjkFamily])]
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascade])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// 设置里可选的字体：常用的放前面（只列本机已安装的），其余按字母排在后面。
/// 用 CoreText 查询，可以放在后台线程做（扫一遍 300 多个字体约 0.3 秒）。
enum FontCatalog {
    struct Entry: Hashable {
        let family: String
        let label: String
    }

    struct Lists {
        var latinFeatured: [Entry]
        var cjkFeatured: [Entry]
        var latinOthers: [String] = []
        var cjkOthers: [String] = []
    }

    /// 只含常用字体的列表，查询很快，可以先显示。
    static func featured() -> Lists {
        let families = Set(availableFamilies())
        return Lists(
            latinFeatured: [Entry(family: "", label: "系统默认（San Francisco）")] + latinCandidates.filter { families.contains($0.family) },
            cjkFeatured: [Entry(family: "", label: "系统默认（苹方）")] + cjkCandidates.filter { families.contains($0.family) }
        )
    }

    /// 完整列表。英文字体里不放自带汉字的字体（选了它，中文字体设置就不起作用了）。
    static func full() -> Lists {
        var lists = featured()
        // 苹方已经是"系统默认"，不再单列。
        let featuredFamilies = Set((lists.latinFeatured + lists.cjkFeatured).map(\.family) + ["PingFang SC"])
        for family in availableFamilies() where !featuredFamilies.contains(family) {
            if containsHan(family) {
                lists.cjkOthers.append(family)
            } else {
                lists.latinOthers.append(family)
            }
        }
        return lists
    }

    private static let latinCandidates: [Entry] = [
        ("Helvetica Neue", "Helvetica Neue"), ("Avenir Next", "Avenir Next"), ("Georgia", "Georgia"),
        ("Times New Roman", "Times New Roman"), ("Palatino", "Palatino"), ("Charter", "Charter"),
        ("Baskerville", "Baskerville"), ("Optima", "Optima"), ("Hoefler Text", "Hoefler Text"),
        ("Iowan Old Style", "Iowan Old Style"), ("Menlo", "Menlo"),
    ].map { Entry(family: $0.0, label: $0.1) }

    private static let cjkCandidates: [Entry] = [
        ("Songti SC", "宋体"), ("STKaiti", "楷体"), ("Kaiti SC", "楷体 SC"),
        ("STFangsong", "仿宋"), ("Heiti SC", "黑体"), ("Yuanti SC", "圆体"), ("Lantinghei SC", "兰亭黑"),
        ("Hiragino Sans GB", "冬青黑体"), ("LXGW WenKai", "霞鹜文楷"), ("LXGW WenKai GB", "霞鹜文楷 GB"),
        ("Source Han Serif SC", "思源宋体"), ("Source Han Sans SC", "思源黑体"),
        ("Noto Serif CJK SC", "Noto 宋体"), ("Noto Sans CJK SC", "Noto 黑体"),
    ].map { Entry(family: $0.0, label: $0.1) }

    private static func availableFamilies() -> [String] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func containsHan(_ family: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        // 找不到这个字体时 CoreText 会给一个替代字体，要排除。
        guard CTFontCopyFamilyName(font) as String == family else { return false }
        var character: UniChar = 0x4E2D // "中"
        var glyph: CGGlyph = 0
        return CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
    }
}
