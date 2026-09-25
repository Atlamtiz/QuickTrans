import AppKit
import SwiftUI

private extension NSToolbarItem.Identifier {
    static let headerControls = NSToolbarItem.Identifier("headerControls")
    static let settings = NSToolbarItem.Identifier("settings")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private let model = TranslatorModel.shared
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var appliedDarkAppearance: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        showMainWindow()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyThemeAppearance() }
        }
        HotkeyManager.shared.onTrigger = { [weak self] result in
            self?.handleCapture(result)
        }
        HotkeyManager.shared.start()
    }

    // 关掉窗口不退出，留在 Dock；点 Dock 图标重新打开主窗口。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindow?.isVisible != true {
            showMainWindow()
        }
        return true
    }

    /// 取词后：填入原文、开始翻译，并把主窗口带到最前面（位置保持你上次放的地方）。
    private func handleCapture(_ result: CaptureResult) {
        switch result {
        case .text(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                model.showNotice("没有取到文字，请先选中要翻译的文字。")
            } else {
                model.load(text)
            }
        case .nothingSelected:
            model.showNotice("没有取到文字，请先选中要翻译的文字。")
        case .sensitive:
            model.showNotice("剪贴板内容被标记为密码等敏感信息，没有翻译。")
        case .needsPermission:
            model.showNotice("需要先在「系统设置 → 隐私与安全性 → 辅助功能」中打开 QuickTrans。")
        }
        showMainWindow()
    }

    // MARK: - 窗口

    @objc func showMainWindowAction(_ sender: Any?) {
        showMainWindow()
    }

    func showMainWindow() {
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        applyThemeAppearance()
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        guard !NSApp.isActive else { return }
        // 新版 macOS 可能拒绝后台 app 自己切到前台：先保证窗口显示在最上层，稍后再确认一次。
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Self.forceFrontmostIfNeeded()
        }
    }

    /// 借辅助功能权限把本 app 设为最前（窗口管理类工具也是这样切换 app 的）。
    /// 必须在后台线程调用：主线程对自己发辅助功能请求会互相等待卡住。
    private static func forceFrontmostIfNeeded() {
        guard !NSApp.isActive, AXIsProcessTrusted() else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .userInteractive).async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }

    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "QuickTrans"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        // 快捷键唤出时，窗口来到你当前所在的桌面（屏幕位置不变），而不是把屏幕切回窗口原来的桌面；
        // 也允许出现在全屏 app 的上面。
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // 顶栏用工具栏承载：红绿灯自动垂直居中，按钮点击和拖动窗口都走系统原生逻辑。
        let toolbar = NSToolbar(identifier: "QuickTransMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.headerControls]
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.contentView = NSHostingView(rootView: MainView(model: model, hotkeys: HotkeyManager.shared))
        window.center()
        // 记住你把窗口放在哪、拉多大，下次（包括快捷键唤出时）还在原处。
        window.setFrameAutosaveName("QuickTransMainWindow")
        return window
    }

    /// 深色主题时让输入框、光标、滚动条等系统部件也用深色。
    private func applyThemeAppearance() {
        let theme = Theme.named(UserDefaults.standard.string(forKey: Keys.theme) ?? Theme.defaultID)
        guard appliedDarkAppearance != theme.isDark, let mainWindow else { return }
        appliedDarkAppearance = theme.isDark
        mainWindow.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "QuickTrans 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 工具栏

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.headerControls, .flexibleSpace, .settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.headerControls, .flexibleSpace, .settings]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .headerControls:
            item.view = NSHostingView(rootView: HeaderControls(model: model))
            item.label = "翻译方向与风格"
        case .settings:
            item.view = NSHostingView(rootView: HeaderSettingsButton { [weak self] in self?.showSettings() })
            item.label = "设置"
        default:
            return nil
        }
        return item
    }

    // MARK: - 字号

    @objc func increaseFontSize(_ sender: Any?) { adjustFontSize(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { adjustFontSize(by: -1) }
    @objc func resetFontSize(_ sender: Any?) {
        UserDefaults.standard.set(Defaults.fontSize, forKey: Keys.fontSize)
    }

    private func adjustFontSize(by delta: Double) {
        let current = UserDefaults.standard.double(forKey: Keys.fontSize)
        let range = Defaults.fontSizeRange
        UserDefaults.standard.set(min(max(current + delta, range.lowerBound), range.upperBound), forKey: Keys.fontSize)
    }

    // MARK: - 菜单（没有"编辑"菜单的话，⌘V/⌘C 在输入框里不起作用）

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 QuickTrans",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 QuickTrans", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 QuickTrans", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: mainMenu)

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(editMenu, to: mainMenu)

        let viewMenu = NSMenu(title: "显示")
        let bigger = viewMenu.addItem(withTitle: "放大字号", action: #selector(increaseFontSize(_:)), keyEquivalent: "+")
        bigger.target = self
        // ⌘= 也能放大（不用按 Shift）。
        let biggerAlt = viewMenu.addItem(withTitle: "放大字号", action: #selector(increaseFontSize(_:)), keyEquivalent: "=")
        biggerAlt.target = self
        biggerAlt.isHidden = true
        biggerAlt.allowsKeyEquivalentWhenHidden = true
        let smaller = viewMenu.addItem(withTitle: "缩小字号", action: #selector(decreaseFontSize(_:)), keyEquivalent: "-")
        smaller.target = self
        let reset = viewMenu.addItem(withTitle: "默认字号", action: #selector(resetFontSize(_:)), keyEquivalent: "0")
        reset.target = self
        addSubmenu(viewMenu, to: mainMenu)

        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        let showMain = windowMenu.addItem(withTitle: "翻译窗口",
                                          action: #selector(showMainWindowAction(_:)), keyEquivalent: "1")
        showMain.target = self
        addSubmenu(windowMenu, to: mainMenu)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        menu.addItem(item)
    }
}
