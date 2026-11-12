import Cocoa
import WebKit
import UserNotifications
import Security

// MARK: - 数据模型

struct SavedConnection: Codable, Equatable {
    var name: String
    var url: String
    var savedAt: Double
    var autoNamed: Bool
}

private extension URL {
    var queryItemsMap: [String: String] {
        guard let comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return [:] }
        var result: [String: String] = [:]
        for item in comps.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }
}

// MARK: - 连接存储（Keychain，KeyStore 异常时退回 UserDefaults）

enum ConnectionStore {
    static let service = "dev.straiway.zcodeshell.connections"
    static let account = "list"
    static let defaultsKey = "connections.fallback"

    static func list() -> [SavedConnection] {
        // ZCR_DEV_STORE=1（dev 调试）时完全绕开 Keychain：dev 二进制没有
        // release 应用的钥匙串授权，读写都会触发系统授权弹窗并阻塞主线程
        let useKeychain = ProcessInfo.processInfo.environment["ZCR_DEV_STORE"] != "1"
        if useKeychain {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data,
               let conns = try? JSONDecoder().decode([SavedConnection].self, from: data) {
                return conns.sorted { $0.savedAt > $1.savedAt }
            }
        }
        // Keychain 异常（权限/迁移等）时退回应用私有偏好
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let conns = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            return conns
        }
        return []
    }

    static func persist(_ conns: [SavedConnection]) {
        guard let data = try? JSONEncoder().encode(conns) else { return }
        if ProcessInfo.processInfo.environment["ZCR_DEV_STORE"] != "1" {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let update: [String: Any] = [kSecValueData as String: data]
            if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                SecItemAdd(add as CFDictionary, nil)
            }
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// 新增或刷新一条连接。链接的 name 参数即电脑主机名，作为默认名称并锁定。
    @discardableResult
    static func upsert(url: String) -> [SavedConnection] {
        var current = list()
        let machineName = URL(string: url)?.queryItemsMap["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let existing = current.first { $0.url == url }
        current.removeAll { $0.url == url }
        let now = Date().timeIntervalSince1970
        let entry: SavedConnection
        if let existing {
            if existing.autoNamed && !machineName.isEmpty && isPlaceholder(existing.name) {
                entry = SavedConnection(name: machineName, url: url, savedAt: now, autoNamed: false)
            } else {
                entry = SavedConnection(name: existing.name, url: url, savedAt: now, autoNamed: existing.autoNamed)
            }
        } else {
            entry = SavedConnection(
                name: machineName.isEmpty ? "工作区 \(current.count + 1)" : machineName,
                url: url,
                savedAt: now,
                autoNamed: machineName.isEmpty)
        }
        current.append(entry)
        let sorted = current.sorted { $0.savedAt > $1.savedAt }
        persist(sorted)
        return sorted
    }

    static func autoRename(url: String, title: String) {
        var conns = list()
        guard let idx = conns.firstIndex(where: { $0.url == url && $0.autoNamed && $0.name != title }) else { return }
        conns[idx].name = title
        persist(conns)
    }

    static func remove(url: String) {
        persist(list().filter { $0.url != url })
    }

    private static func isPlaceholder(_ name: String) -> Bool {
        name == "我的电脑" || name.range(of: "^工作区 \\d+$", options: .regularExpression) != nil
    }
}

// MARK: - 应用主逻辑

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler,
    WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSMenuDelegate {

    private var window: NSWindow?
    private var webView: WKWebView?
    private var popupWindows: [NSWindow] = []
    private var connectionsMenu: NSMenu?
    private var pendingUrl: String?
    private var permissionAsked = false

    // 通知聚合状态（与安卓壳一致：变化只积累，静默/结束信号到达才发一条）
    private var pendingBuffer = ""
    private var pendingWait = false
    private var pendingDone = false
    private var lastFlushAt: TimeInterval = 0
    private var quietTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        buildWindow()

        // 有历史连接自动恢复最近的，否则引导添加
        if let last = ConnectionStore.list().first {
            connect(last.url)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.addConnection(self != nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 回到前台说明用户已看到内容，清掉积压的通知和未聚合内容
        guard Self.notificationsAvailable else { return }
        quietTimer?.invalidate()
        pendingBuffer = ""
        pendingWait = false
        pendingDone = false
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: 窗口与菜单

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(
            WKUserScript(source: Self.watcherJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.addUserScript(
            WKUserScript(source: Self.chromeJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // 排查远程页 DOM 用：ZCR_DEBUG_DOM=1 时周期性采样顶带元素并经 shellBridge 回传 NSLog
        if ProcessInfo.processInfo.environment["ZCR_DEBUG_DOM"] != nil {
            config.userContentController.addUserScript(
                WKUserScript(source: Self.debugDOMJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        config.userContentController.add(self, name: "shellBridge")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        // 排查远程页 DOM 用：ZCR_WEBINSPECTOR=1 时可在 Safari「开发」菜单检查页面
        if ProcessInfo.processInfo.environment["ZCR_WEBINSPECTOR"] != nil,
           #available(macOS 13.3, *) {
            web.isInspectable = true
        }
        // 一体化标题栏（对齐官方桌面端观感）：网页顶栏直接充当窗口顶带，
        // 系统标题栏透明化并隐藏居中标题，交通灯悬浮在页面左上角的预留条内。
        // chromeJS 负责顶带拖拽手势与预留条消失时的兜底。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "ZCRemote"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // 窄窗口（<md 断点 768px）页面切移动布局，顶栏融合链路失效，
        // 最小宽度保证融合布局始终成立
        window.minSize = NSSize(width: 860, height: 480)
        window.contentView = web
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.setFrameAutosaveName("ZCodeShellMainWindow")
        // dev 调试用：ZCR_WINDOW_FRAME="x,y,w,h"（Cocoa 坐标）强制窗口框架，
        // 用于自动化验证时把窗口固定在主屏指定位置
        if let spec = ProcessInfo.processInfo.environment["ZCR_WINDOW_FRAME"], !spec.isEmpty {
            let parts = spec.split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 4 {
                window.setFrame(
                    NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]),
                    display: true)
            }
        }

        self.window = window
        webView = web
    }

    private func buildMenus() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 ZCRemote", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 ZCRemote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let connItem = NSMenuItem()
        mainMenu.addItem(connItem)
        let connMenu = NSMenu(title: "连接")
        connMenu.delegate = self
        connItem.submenu = connMenu
        connectionsMenu = connMenu

        // 标准编辑菜单：macOS 的 ⌘C/⌘V/⌘X/⌘A 等快捷键经主菜单的按键等价机制
        // 派发到响应链，缺这个菜单 WKWebView 里的文本快捷键全部失效
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector("undo:"), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector("redo:"), keyEquivalent: "Z")
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == connectionsMenu else { return }
        menu.removeAllItems()
        for conn in ConnectionStore.list() {
            let title = conn.url == pendingUrl ? "✓ \(conn.name)" : conn.name
            let item = NSMenuItem(title: title, action: #selector(switchConnection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = conn.url
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "添加连接…", action: #selector(addConnectionFromMenu(_:)), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)
        let reload = NSMenuItem(title: "重新加载页面", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)
        if pendingUrl != nil {
            menu.addItem(.separator())
            let rm = NSMenuItem(title: "移除当前连接", action: #selector(removeCurrentConnection(_:)), keyEquivalent: "")
            rm.target = self
            menu.addItem(rm)
        }
    }

    // MARK: 连接管理

    @objc func addConnectionFromMenu(_ sender: Any?) { addConnection(true) }

    @objc func switchConnection(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        connect(url)
    }

    @objc func reloadPage(_ sender: Any?) {
        webView?.reload()
    }

    @objc func removeCurrentConnection(_ sender: Any?) {
        guard let url = pendingUrl else { return }
        ConnectionStore.remove(url: url)
        pendingUrl = nil
        window?.title = "ZCRemote"
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
        if ConnectionStore.list().isEmpty {
            addConnection(true)
        }
    }

    /// 粘贴链接添加连接（桌面端复制远程控制链接后粘贴即可）
    private func addConnection(_ interactive: Bool) {
        let alert = NSAlert()
        alert.messageText = "添加连接"
        alert.informativeText = "在受控电脑的 ZCode 桌面端点击左下角手机图标，复制远程控制链接后粘贴到这里。"
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
        input.placeholderString = "https://zcode.z.ai/remote/v4?..."
        alert.accessoryView = input
        window?.makeKeyAndOrderFront(nil)
        guard interactive, alert.runModal() == .alertFirstButtonReturn else { return }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        connect(text)
    }

    private func connect(_ raw: String) {
        guard let url = normalizeUrl(raw) else {
            let alert = NSAlert()
            alert.messageText = "链接无效"
            alert.informativeText = "内容不是有效的 http(s) 链接，请在桌面端复制远程控制链接后重试。"
            alert.runModal()
            return
        }
        pendingUrl = url
        let conns = ConnectionStore.upsert(url: url)
        window?.title = conns.first { $0.url == url }?.name ?? "ZCRemote"
        requestNotificationPermissionIfNeeded()
        if let u = URL(string: url) {
            webView?.load(URLRequest(url: u))
        }
    }

    private func requestNotificationPermissionIfNeeded() {
        guard Self.notificationsAvailable else { return }
        guard !permissionAsked else { return }
        permissionAsked = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 只处理主视图；登录弹窗等子窗口不参与连接命名
        guard webView === self.webView else { return }
        // 页面标题即电脑/工作区名：自动命名尚未占用的连接
        webView.evaluateJavaScript("document.title") { [weak self] result, _ in
            guard let self,
                  let title = result as? String else { return }
            let cleaned = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, cleaned != "about:blank", cleaned.count > 1 else { return }
            let trimmed = String(cleaned.prefix(30))
            guard let url = self.pendingUrl else { return }
            ConnectionStore.autoRename(url: url, title: trimmed)
            let name = ConnectionStore.list().first { $0.url == url }?.name ?? trimmed
            if url == self.pendingUrl { self.window?.title = name }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 用户点击的站外链接（消息里的链接，含 target="_blank"）交给系统浏览器；
        // 其余（登录重定向、表单提交、同源跳转）留在应用内，
        // 否则登录态会落在浏览器里而不是应用里
        if let url = navigationAction.request.url,
           isWebUrl(url), !isSameHost(url),
           navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 一切「新窗口」请求（window.open、target="_blank"、右键菜单）：
        // 站外 → 系统浏览器；同源 → 应用内子窗口（共享登录态）
        guard let url = navigationAction.request.url, isWebUrl(url) else { return nil }
        if !isSameHost(url) {
            NSWorkspace.shared.open(url)
            return nil
        }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.title = "新窗口"
        win.contentView = popup
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        popupWindows.append(win)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        // 登录完成后页面自行 window.close()，同步关掉子窗口
        if let idx = popupWindows.firstIndex(where: { $0.contentView === webView }) {
            popupWindows[idx].close()
            popupWindows.remove(at: idx)
        }
    }

    // MARK: 网页文件选择（<input type="file">、拖拽附件等）
    // 不实现这个 delegate 方法 WebKit 会静默取消，点上传毫无反应；
    // 与安卓壳的 onShowFileChooser 对应

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        if panel.runModal() == .alertFirstButtonReturn {
            completionHandler(panel.urls)
        } else {
            completionHandler(nil)
        }
    }

    // MARK: 下载支持（下载链接多为脚本 window.open 打开，走上面的弹窗路径；
    // 不实现 WKDownloadDelegate 的话 WebKit 会直接吞掉下载，只剩白窗口）

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // 页面无法渲染的内容（zip/apk/二进制等）转为下载
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        closePopupIfDownloadHost(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        closePopupIfDownloadHost(webView)
    }

    private func closePopupIfDownloadHost(_ webView: WKWebView) {
        // 下载开始后弹窗没有可显示的内容，直接关掉
        if let idx = popupWindows.firstIndex(where: { $0.contentView === webView }) {
            popupWindows[idx].close()
            popupWindows.remove(at: idx)
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename.isEmpty ? "download" : suggestedFilename
            panel.canCreateDirectories = true
            if panel.runModal() == .alertFirstButtonReturn, let url = panel.url {
                completionHandler(url)
            } else {
                completionHandler(nil)
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = download.originalRequest?.url {
            NSLog("ZCRemote: downloaded \(url.absoluteString)")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "下载失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: 页面事件 → 系统通知（逻辑与安卓壳一致）

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "shellBridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        // 窗口手势（chromeJS 注入的顶带）：拖动窗口 / 双击缩放
        if type == "window_drag" { beginWindowDrag(); return }
        if type == "window_zoom" { window?.performZoom(nil); return }
        // DOM 排查采样（ZCR_DEBUG_DOM=1 时注入）
        if type == "page_debug" {
            NSLog("ZCRDOM: %@", body["text"] as? String ?? "")
            return
        }
        handlePageEvent(type: type, snippet: body["text"] as? String ?? "")
    }

    private func handlePageEvent(type: String, snippet: String) {
        guard !NSApp.isActive else { return } // 用户正看着，不打扰
        let now = Date().timeIntervalSince1970
        if type == "new_message" && now - lastFlushAt < Self.postDoneGrace {
            return // 结束通知已发，忽略 UI 收尾杂音
        }
        if !snippet.isEmpty {
            pendingBuffer += (pendingBuffer.isEmpty ? "" : " ") + snippet.trimmingCharacters(in: .whitespaces)
            if pendingBuffer.count > 600 {
                pendingBuffer = String(pendingBuffer.suffix(600))
            }
        }
        if type == "task_wait" { pendingWait = true }
        if type == "task_done" { pendingDone = true }

        quietTimer?.invalidate()
        if type == "task_done" {
            flushPendingNotification()
        } else {
            quietTimer = Timer.scheduledTimer(withTimeInterval: Self.quietInterval, repeats: false) { [weak self] _ in
                self?.flushPendingNotification()
            }
        }
    }

    private func flushPendingNotification() {
        guard Self.notificationsAvailable else { return }
        let text = pendingBuffer
        let waiting = pendingWait
        let done = pendingDone
        pendingBuffer = ""
        pendingWait = false
        pendingDone = false
        lastFlushAt = Date().timeIntervalSince1970
        quietTimer?.invalidate()
        if text.isEmpty && !waiting && !done { return }

        let title: String
        switch true {
        case waiting: title = "ZCode 等待你的确认"
        case done: title = "ZCode 任务已完成"
        default: title = "ZCode 有新消息"
        }
        var body = text.replacingOccurrences(
            of: "(正在思考|思考中|工作中|执行中|运行中|已工作|已停止)\\s*\\d[\\d分秒时:\\s.…]*",
            with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if body.isEmpty { body = "点击返回会话" }
        if body.count > 160 { body = "…" + String(body.suffix(160)) }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if waiting { content.interruptionLevel = .timeSensitive }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: 工具

    /// chromeJS 顶带拖拽：在当前鼠标位置发起系统级窗口拖动。
    /// performDrag 需要一个鼠标事件作为锚点，合成一个左键按下事件即可。
    private func beginWindowDrag() {
        guard let window else { return }
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSEvent.mouseLocation,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1.0)
        if let event { window.performDrag(with: event) }
    }

    private func isSameHost(_ url: URL) -> Bool {
        guard let current = pendingUrl, let currentHost = URL(string: current)?.host else { return true }
        return url.host == currentHost
    }

    private func isWebUrl(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    private func normalizeUrl(_ raw: String) -> String? {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.hasPrefix("http://") || candidate.hasPrefix("https://"),
              let url = URL(string: candidate),
              let host = url.host, !host.isEmpty else { return nil }
        return candidate
    }

    private static let quietInterval: TimeInterval = 12
    private static let postDoneGrace: TimeInterval = 20

    /// UNUserNotificationCenter 只能从带 bundle id 的 .app 进程调用，
    /// 裸 swift run 二进制会直接 NSAssertion 崩溃，这里统一守卫
    private static var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// 通用页面变化观察器（与安卓壳同源）：
    /// - task_done：「工作中/正在思考」消失且出现「已工作 …」→ 一轮结束
    /// - task_wait：新增内容含等待/审批关键词
    /// - new_message：其余新增内容（静默期兜底）
    /// 计时器跳动文字不算消息内容。
    /// 注意：桌面端窗口在后台时页面通常仍是 visible，是否打扰由原生侧
    /// 的 NSApp.isActive 判断，这里不做 visibilityState 过滤。
    static let watcherJS = #"""
    (function(){
      if (window.__zcodeWatch) return;
      if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.shellBridge) return;
      window.__zcodeWatch = true;
      var last = 0;
      var armed = true;
      var WAIT = /等待你|待你确认|待你批准|待你审批|等待确认|等待批准|等待审批|需要你确认|需要你批准|待确认|待批准|是否允许|是否同意|仅本次允许|始终允许|始终拒绝|不允许|awaiting your|waiting for your|approval required|do you want/i;
      var ACTIVE = /正在思考|思考中|工作中|执行中|运行中/;
      var DONE = /已工作/;
      var STATUS_ONLY = /^[.…\s]*(正在思考|思考中|工作中|执行中|运行中|已工作|已停止)[\d分秒时:.\s……]*$/;
      function textOf(m) {
        var t;
        if (m.type === 'characterData') {
          t = m.target.textContent || '';
        } else {
          t = '';
          for (var i = 0; i < m.addedNodes.length; i++) {
            var n = m.addedNodes[i];
            if (n.nodeType === 1 || n.nodeType === 3) t += ' ' + (n.textContent || '');
          }
        }
        if (STATUS_ONLY.test(t)) return '';
        return t;
      }
      new MutationObserver(function(muts){
        var now = Date.now();
        if (now - last < 1500) return;
        last = now;
        var text = '';
        for (var i = 0; i < muts.length; i++) text += textOf(muts[i]);
        text = text.replace(/(正在思考|思考中|工作中|执行中|运行中|已工作|已停止)\s*\d[\d分秒时:\s.……]*/g, ' ');
        text = text.replace(/\s+/g, ' ').trim();
        var pageText = document.body ? ((document.body.innerText || document.body.textContent) || '') : '';
        var isDone = false;
        if (pageText) {
          if (ACTIVE.test(pageText)) {
            armed = true;
          } else if (armed && DONE.test(pageText)) {
            armed = false;
            isDone = true;
          }
        }
        var type = isDone ? 'task_done' : (WAIT.test(text) ? 'task_wait' : 'new_message');
        if (!isDone && !text) return;
        window.webkit.messageHandlers.shellBridge.postMessage({type: type, text: text.substring(0, 140)});
      }).observe(document.body, {childList: true, subtree: true, characterData: true});
    })();
    """#

    /// 一体化标题栏的页面侧配合（仅主窗口注入）：
    /// - 顶带手势：顶带（BAND=48px）范围内、非交互元素的左键按下 → window_drag，
    ///   400ms 内二次按下 → window_zoom（自行计时，原生拖拽会吞掉第二次点击）。
    /// - 布局：预留条（h-12 [app-region:drag]，48px 空带）独占顶带承接交通灯
    ///   （系统默认位置）；侧栏头部块（flex-col）加 .zcr-rows 改为单行横向
    ///   布局，并把独立定位的箭头容器（[app-region:no-drag]）按几何特征
    ///   匹配后 fixed 定位到该行行首——最终一行排开：箭头 | 选择器 | 新建任务。
    /// - 兜底：页面改版导致预留条消失时加 zcr-fallback 类给 body 顶部留白，
    ///   保证交通灯永不遮挡可点内容；头部链路定位失败则保持页面自然布局。
    /// 注意：手势只依赖几何位置与常见交互语义（closest 表），不依赖页面 DOM 结构；
    /// 头部定位链路（预留条 → 滚动容器 → 头部块）经 ZCR_DEBUG_DOM 采样确认。
    static let chromeJS = #"""
    (function(){
      if (window.__zcrChrome) return;
      if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.shellBridge) return;
      window.__zcrChrome = true;
      var BAND = 48;
      var INTERACTIVE = 'a,button,input,textarea,select,label,summary,[role="button"],[role="tab"],[role="menuitem"],[contenteditable]';
      var style = document.createElement('style');
      style.id = 'zcr-mac-chrome';
      style.textContent =
        'html.zcr-fallback body { padding-top: 24px; }' +
        '.zcr-rows { display: flex !important; flex-direction: row !important; flex-wrap: wrap !important;' +
        '  align-items: center !important; gap: 6px !important; padding: 6px 8px 8px !important; }' +
        '.zcr-rows > * { width: auto !important; flex: 0 0 auto !important; }' +
        '.zcr-rows > :first-child { flex: 1 1 0 !important; min-width: 0 !important; }' +
        '.zcr-rows.zcr-has-arrows > :first-child { margin-left: 68px !important; }';
      (document.head || document.documentElement).appendChild(style);
      function isInteractive(el) {
        return !!(el && el.closest && el.closest(INTERACTIVE));
      }
      function send(type) {
        window.webkit.messageHandlers.shellBridge.postMessage({type: type});
      }
      var lastDownAt = 0, lastDownX = 0, lastDownY = 0;
      document.addEventListener('mousedown', function(e){
        if (e.button !== 0 || e.clientY > BAND || isInteractive(e.target)) return;
        var now = Date.now();
        var isDouble = now - lastDownAt < 400 &&
          Math.abs(e.clientX - lastDownX) < 6 && Math.abs(e.clientY - lastDownY) < 6;
        lastDownAt = now; lastDownX = e.clientX; lastDownY = e.clientY;
        send(isDouble ? 'window_zoom' : 'window_drag');
      }, true);
      // 头部块定位：预留条 → 下一兄弟（滚动容器）→ 首子节点 → 首子节点（头部块）。
      // 箭头容器（[app-region:no-drag]，约 64x28，独立绝对定位在顶带内，与
      // 预留条无 DOM 父子关系）按几何特征从全文档匹配后 position:fixed 挪到
      // 头部行行首，与选择器/新建任务同一行（周期性重施对抗软导航重置；
      // 只改样式不移动节点，对页面框架安全）。
      function mergeHeader() {
        var strip = document.querySelector('[class*="app-region:drag"]');
        if (!strip) return;
        var scroller = strip.nextElementSibling;
        var holder = scroller ? scroller.firstElementChild : null;
        var header = holder ? holder.firstElementChild : null;
        if (!scroller || !holder || !header) return;
        if (String(header.className).indexOf('flex-col') < 0) return;
        header.classList.add('zcr-rows');
        var arrows = null;
        var cands = document.querySelectorAll('[class*="app-region:no-drag"]');
        for (var i = 0; i < cands.length; i++) {
          var r = cands[i].getBoundingClientRect();
          if (r.width > 30 && r.width < 120 && r.height > 20 && r.height < 40 &&
              r.left < 120 && r.top < 60) { arrows = cands[i]; break; }
        }
        if (arrows) {
          arrows.style.position = 'fixed';
          arrows.style.left = '8px';
          arrows.style.top = '56px';
          arrows.style.zIndex = '30';
        }
        header.classList.toggle('zcr-has-arrows', !!arrows);
      }
      function adapt() {
        var strip = document.querySelector('[class*="app-region:drag"]');
        document.documentElement.classList.toggle('zcr-fallback', !strip);
        mergeHeader();
      }
      setInterval(adapt, 1500);
    })();
    """#

    /// DOM 排查采样（ZCR_DEBUG_DOM=1 时注入）：dump 侧栏头部子树的结构
    /// （tag.class + rect），用于确定一体化顶栏融合 CSS 的选择器。
    /// 经 shellBridge → NSLog(ZCRDOM:) 输出，仅实现期使用。
    static let debugDOMJS = #"""
    (function(){
      if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.shellBridge) return;
      function send(s) {
        window.webkit.messageHandlers.shellBridge.postMessage({type: 'page_debug', text: s});
      }
      function dump(n) {
        try {
          var lines = ['round=' + n];
          // 页面可能有多个 aside，取第一个可见的
          var asides = document.querySelectorAll('aside');
          var aside = null;
          for (var a = 0; a < asides.length; a++) {
            var ar = asides[a].getBoundingClientRect();
            lines.push('ASIDE[' + a + '] ' + String(asides[a].className || '').slice(0, 80) +
              ' [' + Math.round(ar.left) + ',' + Math.round(ar.top) + ',' +
              Math.round(ar.width) + ',' + Math.round(ar.height) + ']');
            if (!aside && ar.width > 50 && ar.height > 100) aside = asides[a];
          }
          function walk(el, depth) {
            if (depth > 6 || lines.length > 90) return;
            var r = el.getBoundingClientRect();
            if (r.width === 0 && r.height === 0) return;
            var pad = '';
            for (var k = 0; k < depth; k++) pad += '· ';
            lines.push(pad + el.tagName + '.' + String(el.className || '').slice(0, 110) +
              ' [' + Math.round(r.left) + ',' + Math.round(r.top) + ',' +
              Math.round(r.width) + ',' + Math.round(r.height) + ']' +
              (el.tagName === 'BUTTON' ? ' txt=' + (el.textContent || '').trim().slice(0, 14) : ''));
            var kids = el.children;
            for (var i = 0; i < kids.length && i < 12; i++) walk(kids[i], depth + 1);
          }
          if (aside) walk(aside, 0);
          // 预留条及其父节点的直接子元素（确定头部行的位置和选择器）
          var strip = document.querySelector('[class*="app-region:drag"]');
          if (strip && strip.parentElement) {
            lines.push('STRIP-PARENT ' + String(strip.parentElement.className || '').slice(0, 100));
            var sib = strip.parentElement.children;
            for (var s = 0; s < sib.length && s < 8; s++) {
              var sr = sib[s].getBoundingClientRect();
              lines.push('SIB[' + s + '] ' + sib[s].tagName + '.' + String(sib[s].className || '').slice(0, 100) +
                ' [' + Math.round(sr.left) + ',' + Math.round(sr.top) + ',' +
                Math.round(sr.width) + ',' + Math.round(sr.height) + ']');
            }
          } else if (!aside) {
            // 没侧栏也没预留条：报告页面状态（登录页/接管页等）
            lines.push('STATE title=' + document.title +
              ' body1=' + String((document.body.children[0] || {}).className || '').slice(0, 90));
          }
          // 箭头区命中测试：顶带下方左侧（页面坐标）的元素链 + 箭头容器计算样式
          lines.push('ARROW-MARK enter');
          var noDrags = document.querySelectorAll('[class*="app-region:no-drag"]');
          for (var si = 0; si < noDrags.length && si < 5; si++) {
            var st = noDrags[si];
            var sr2 = st.getBoundingClientRect();
            var pa = st.parentElement;
            lines.push('NODRAG[' + si + '] [' + Math.round(sr2.left) + ',' + Math.round(sr2.top) + ',' +
              Math.round(sr2.width) + ',' + Math.round(sr2.height) + '] ' +
              String(st.className || '').slice(0, 70) +
              ' parent=' + (pa ? pa.tagName + '.' + String(pa.className || '').slice(0, 80) : 'null'));
          }
          var pts = [[30, 27], [55, 27], [30, 60], [200, 77]];
          for (var p = 0; p < pts.length; p++) {
            var chain = document.elementsFromPoint(pts[p][0], pts[p][1]);
            var desc = [];
            for (var q = 0; q < Math.min(chain.length, 5); q++) {
              var el = chain[q];
              var r = el.getBoundingClientRect();
              desc.push(el.tagName + '.' + String(el.className || '').slice(0, 80) +
                '[' + Math.round(r.left) + ',' + Math.round(r.top) + ',' +
                Math.round(r.width) + ',' + Math.round(r.height) + ']');
            }
            lines.push('PT' + pts[p].join(',') + ' ← ' + desc.join(' < '));
          }
          for (var i = 0; i < lines.length; i += 14) send(lines.slice(i, i + 14).join('\n'));
        } catch (err) { send('round-err ' + err); }
      }
      var c = 0;
      var timer = setInterval(function(){ c++; dump(c); if (c >= 8) clearInterval(timer); }, 1000);
    })();
    """#
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
