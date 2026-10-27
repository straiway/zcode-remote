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
        // Keychain 异常（权限/迁移等）时退回应用私有偏好
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let conns = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            return conns
        }
        return []
    }

    static func persist(_ conns: [SavedConnection]) {
        guard let data = try? JSONEncoder().encode(conns) else { return }
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
        config.userContentController.add(self, name: "shellBridge")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "ZCode Remote"
        window.contentView = web
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.setFrameAutosaveName("ZCodeShellMainWindow")

        self.window = window
        webView = web
    }

    private func buildMenus() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 ZCode Remote", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 ZCode Remote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        window?.title = "ZCode Remote"
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
        window?.title = conns.first { $0.url == url }?.name ?? "ZCode Remote"
        requestNotificationPermissionIfNeeded()
        if let u = URL(string: url) {
            webView?.load(URLRequest(url: u))
        }
    }

    private func requestNotificationPermissionIfNeeded() {
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
            NSLog("ZCode Remote: downloaded \(url.absoluteString)")
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
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
