package dev.straiway.zcodeshell

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.os.SystemClock
import android.text.format.DateUtils
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlin.math.abs

/**
 * ZCode 远程控制的 WebView 壳。
 *
 * 远程控制链接内含授权令牌、等同临时密钥，因此：
 * - 仅接受显式带 http/https 协议的链接，不猜测协议；
 * - 链接保存在加密存储中（ConnectionStore），支持保存多台电脑的连接；
 * - 桌面端刷新二维码后旧链接立即失效，此时用户需重新扫码。
 *
 * 通知：向远程控制页注入一个通用的 DOM 变化观察脚本，App 在后台时
 * 有新内容/等待确认就发系统通知。脚本只依赖页面会追加内容这一通用
 * 行为，不依赖官方页面的具体 DOM 结构。
 */
class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private lateinit var emptyState: View
    private lateinit var errorState: View
    private lateinit var errorDetail: TextView
    private lateinit var switcher: View
    private lateinit var rootLayout: View

    private var pendingUrl: String? = null
    private var pageLoaded = false
    private var loadTimedOut = false
    private var notifAsked = false
    private var connDialog: AlertDialog? = null

    // 通知聚合：页面变化只积累内容，静默一段时间后才发一条通知
    private val pendingBuffer = StringBuilder()
    private var pendingWait = false
    private var pendingDone = false
    private var lastFlushAt = 0L

    // 切换按钮拖动状态
    private var dragDownX = 0f
    private var dragDownY = 0f
    private var dragStartTx = 0f
    private var dragStartTy = 0f
    private var dragged = false
    private var longPressed = false

    private val timeoutHandler = Handler(Looper.getMainLooper())

    private val loadTimeoutRunnable = Runnable {
        if (webView.isVisible && !pageLoaded) {
            loadTimedOut = true
            showError(getString(R.string.error_timeout))
        }
    }

    private val quietRunnable = Runnable { flushPendingNotification() }

    private val longPressRunnable = Runnable {
        longPressed = true
        webView.reload()
        Toast.makeText(this, R.string.reloading, Toast.LENGTH_SHORT).show()
    }

    private val scanLauncher = registerForActivityResult(ScanContract()) { result ->
        val contents = result.contents?.trim() ?: return@registerForActivityResult
        openConnection(contents)
    }

    private val notifPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        // 个别 ROM 上 DayNight 跟随系统可能失效，显式声明一次
        AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM)
        // 边到边：配合透明状态栏，让窗口背景填充刘海区域
        WindowCompat.setDecorFitsSystemWindows(window, false)

        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        // 内容整体从系统栏下方开始，刘海区域露出的是窗口背景（深浅模式自适应）
        rootLayout = findViewById(R.id.root)
        ViewCompat.setOnApplyWindowInsetsListener(rootLayout) { v, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }

        webView = findViewById(R.id.webView)
        emptyState = findViewById(R.id.emptyState)
        errorState = findViewById(R.id.errorState)
        errorDetail = findViewById(R.id.tvErrorDetail)
        switcher = findViewById(R.id.btnSwitcher)

        setupWebView()
        setupActions()

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (webView.isVisible && webView.canGoBack()) {
                    webView.goBack()
                } else {
                    finish()
                }
            }
        })

        // 有历史连接则自动恢复最近的；链接已被桌面端刷新作废时页面会报错，
        // 由错误页引导用户重新扫码。
        ConnectionStore.list(this).firstOrNull()?.let { openConnection(it.url) }
    }

    private fun setupActions() {
        findViewById<Button>(R.id.btnScan).setOnClickListener { startScan() }
        findViewById<Button>(R.id.btnPaste).setOnClickListener { pasteFromClipboard() }
        findViewById<Button>(R.id.btnRetry).setOnClickListener {
            val url = pendingUrl
            if (url != null) openConnection(url) else startScan()
        }
        findViewById<Button>(R.id.btnRescan).setOnClickListener { startScan() }
        findViewById<Button>(R.id.btnSaved).setOnClickListener { showConnectionDialog() }
        switcher.setOnClickListener { showConnectionDialog() }
        setupSwitcherDragging()

        ConnectionStore.list(this).firstOrNull()?.let { refreshConnectionUi(it.url) }
    }

    /**
     * 切换按钮可拖动：按住拖到任意位置，松手后记住位置；按住不动是长按重载。
     * 默认停在右缘、约四分之一屏高处，避开远程页面右上角的控件。
     */
    @SuppressLint("ClickableViewAccessibility")
    private fun setupSwitcherDragging() {
        val touchSlop = ViewConfiguration.get(this).scaledTouchSlop
        switcher.setOnTouchListener { v, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    dragDownX = ev.rawX
                    dragDownY = ev.rawY
                    dragStartTx = v.translationX
                    dragStartTy = v.translationY
                    dragged = false
                    longPressed = false
                    // 自定义触摸处理会吞掉系统长按检测，这里自己实现
                    v.postDelayed(longPressRunnable, ViewConfiguration.getLongPressTimeout().toLong())
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = ev.rawX - dragDownX
                    val dy = ev.rawY - dragDownY
                    if (dragged || abs(dx) > touchSlop || abs(dy) > touchSlop) {
                        dragged = true
                        v.removeCallbacks(longPressRunnable)
                        v.translationX = dragStartTx + dx
                        v.translationY = dragStartTy + dy
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    v.removeCallbacks(longPressRunnable)
                    when {
                        longPressed -> Unit // 长按重载已在 longPressRunnable 里执行
                        dragged -> {
                            clampSwitcher()
                            saveSwitcherPos()
                            dragged = false
                        }
                        else -> v.performClick()
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    v.removeCallbacks(longPressRunnable)
                    dragged = false
                    true
                }
                else -> false
            }
        }
        // 屏幕旋转 / 布局变化时把按钮拉回屏内
        rootLayout.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            clampSwitcher()
        }
        switcher.post { restoreSwitcherPos() }
    }

    private fun clampSwitcher() {
        if (rootLayout.width == 0 || switcher.width == 0) return
        val minX = rootLayout.paddingLeft.toFloat()
        val maxX = (rootLayout.width - rootLayout.paddingRight - switcher.width).toFloat()
        val minY = rootLayout.paddingTop.toFloat()
        val maxY = (rootLayout.height - rootLayout.paddingBottom - switcher.height).toFloat()
        switcher.x = switcher.x.coerceIn(minX, maxX.coerceAtLeast(minX))
        switcher.y = switcher.y.coerceIn(minY, maxY.coerceAtLeast(minY))
    }

    private fun saveSwitcherPos() {
        getSharedPreferences(PREF_UI, MODE_PRIVATE).edit()
            .putFloat(KEY_SWITCHER_X, switcher.x)
            .putFloat(KEY_SWITCHER_Y, switcher.y)
            .apply()
    }

    private fun restoreSwitcherPos() {
        val p = getSharedPreferences(PREF_UI, MODE_PRIVATE)
        if (p.contains(KEY_SWITCHER_X)) {
            switcher.x = p.getFloat(KEY_SWITCHER_X, switcher.x)
            switcher.y = p.getFloat(KEY_SWITCHER_Y, switcher.y)
            clampSwitcher()
        } else if (rootLayout.height > 0) {
            // 首次使用：右缘不动（布局锚点在右上），下移到约四分之一屏高
            switcher.translationY = rootLayout.height * 0.25f
            clampSwitcher()
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            // 消息里的链接多为 target="_blank" / window.open，
            // 必须开启多窗口并配 WebChromeClient 才能接到请求
            setSupportMultipleWindows(true)
            javaScriptCanOpenWindowsAutomatically = true
        }
        webView.addJavascriptInterface(PageBridge(), "AndroidBridge")
        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                pageLoaded = false
                armLoadTimeout()
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                if (!loadTimedOut) {
                    pageLoaded = true
                    disarmLoadTimeout()
                }
                if (url != null && view != null && isSameHost(url)) {
                    view.evaluateJavascript(WATCHER_JS, null)
                }
            }

            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest,
            ): Boolean {
                // 远程控制页自己的跳转留在 WebView 内；
                // 跳往其他站点的链接交给系统浏览器，避免把会话页顶掉
                if (isSameHost(request.url.toString())) return false
                openExternally(request.url.toString())
                return true
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (!request.isForMainFrame) return
                val detail = error.description?.toString().orEmpty()
                    .ifBlank { getString(R.string.error_generic) }
                showError(detail)
            }

            override fun onReceivedHttpError(
                view: WebView,
                request: WebResourceRequest,
                errorResponse: WebResourceResponse,
            ) {
                if (!request.isForMainFrame) return
                showError(getString(R.string.error_http, errorResponse.statusCode))
            }
        }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onReceivedTitle(view: WebView, title: String?) {
                // 页面标题即电脑/工作区名称：自动命名尚未被用户锁定的连接
                val cleaned = sanitizeName(title.orEmpty())
                if (cleaned.isEmpty() || cleaned == "about:blank") return
                val url = pendingUrl ?: return
                if (ConnectionStore.autoRename(this@MainActivity, url, cleaned)) {
                    refreshConnectionUi(url)
                }
            }

            override fun onCreateWindow(
                view: WebView,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: Message,
            ): Boolean {
                // 新窗口请求（target="_blank" / window.open）：借一个临时 WebView
                // 接住目标 URL，转交系统浏览器后立即销毁
                val transport = resultMsg.obj as WebView.WebViewTransport
                val popup = WebView(view.context)
                popup.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(
                        popupView: WebView,
                        request: WebResourceRequest,
                    ): Boolean {
                        openExternally(request.url.toString())
                        popupView.post { popupView.destroy() }
                        return true
                    }
                }
                transport.webView = popup
                resultMsg.sendToTarget()
                return true
            }
        }
    }

    private fun startScan() {
        scanLauncher.launch(ScanOptions().apply {
            setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            setPrompt(getString(R.string.scan_prompt))
            setBeepEnabled(false)
            setOrientationLocked(true)
        })
    }

    private fun pasteFromClipboard() {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        val text = cm?.primaryClip?.getItemAt(0)?.coerceToText(this)?.toString()?.trim()
        if (text.isNullOrBlank()) {
            Toast.makeText(this, R.string.paste_empty, Toast.LENGTH_SHORT).show()
        } else {
            openConnection(text)
        }
    }

    private fun openConnection(rawUrl: String) {
        val url = normalizeUrl(rawUrl)
        if (url == null) {
            Toast.makeText(this, R.string.invalid_link, Toast.LENGTH_LONG).show()
            return
        }
        pendingUrl = url
        ConnectionStore.upsert(this, url)
        refreshConnectionUi(url)
        maybeAskNotificationPermission()

        pageLoaded = false
        loadTimedOut = false
        errorState.isVisible = false
        emptyState.isVisible = false
        switcher.isVisible = true
        webView.isVisible = true
        webView.loadUrl(url)
        armLoadTimeout()
    }

    private fun showError(detail: String) {
        disarmLoadTimeout()
        switcher.isVisible = false
        webView.isVisible = false
        errorState.isVisible = true
        errorDetail.text = buildString {
            append(detail)
            append("\n\n")
            append(
                if (isNetworkAvailable()) getString(R.string.error_hint_desktop)
                else getString(R.string.error_hint_offline)
            )
        }
    }

    private fun refreshConnectionUi(url: String) {
        val btnLast = findViewById<Button>(R.id.btnLast)
        btnLast.isVisible = true
        btnLast.text = getString(R.string.action_last_with_url, hostOf(url))
        btnLast.setOnClickListener { openConnection(url) }
        findViewById<Button>(R.id.btnSaved).isVisible = ConnectionStore.list(this).size > 1
    }

    // ---- 多连接管理 ----

    private fun showConnectionDialog() {
        val conns = ConnectionStore.list(this)
        if (conns.isEmpty()) {
            startScan()
            return
        }
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(8), dp(8), dp(8), 0)
        }
        conns.forEach { c ->
            val row = TextView(this).apply {
                text = buildString {
                    append(c.name)
                    if (c.url == pendingUrl) append(getString(R.string.connection_current))
                    append('\n')
                    append(hostOf(c.url))
                    append(" · ")
                    append(DateUtils.getRelativeTimeSpanString(c.savedAt))
                }
                textSize = 15f
                setPadding(dp(12), dp(14), dp(12), dp(14))
                setOnClickListener {
                    connDialog?.dismiss()
                    openConnection(c.url)
                }
                setOnLongClickListener {
                    showConnectionActions(c)
                    true
                }
            }
            container.addView(row)
        }
        val scroll = ScrollView(this).apply { addView(container) }
        connDialog = AlertDialog.Builder(this)
            .setTitle(R.string.connections_title)
            .setView(scroll)
            .setPositiveButton(R.string.action_scan) { _, _ -> startScan() }
            .setNeutralButton(R.string.action_reload) { _, _ -> webView.reload() }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun showConnectionActions(c: SavedConnection) {
        val items = arrayOf(getString(R.string.action_rename), getString(R.string.action_delete))
        AlertDialog.Builder(this)
            .setTitle(c.name)
            .setItems(items) { _, which ->
                when (which) {
                    0 -> showRenameDialog(c)
                    else -> {
                        ConnectionStore.remove(this, c.url)
                        connDialog?.dismiss()
                        showConnectionDialog()
                    }
                }
            }
            .show()
    }

    private fun showRenameDialog(c: SavedConnection) {
        val input = EditText(this).apply {
            setText(c.name)
            setSelection(text.length)
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.action_rename)
            .setView(input)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val name = input.text.toString().trim()
                if (name.isNotEmpty()) ConnectionStore.rename(this, c.url, name)
                connDialog?.dismiss()
                showConnectionDialog()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    // ---- 消息通知 ----

    /** 注入给页面的 JS 桥：后台收到页面内容变化时发系统通知。 */
    private inner class PageBridge {
        @JavascriptInterface
        fun onEvent(type: String, snippet: String) {
            runOnUiThread { handlePageEvent(type, snippet) }
        }
    }

    private fun handlePageEvent(type: String, snippet: String) {
        if (isFinishing || isDestroyed) return
        if (!canNotify()) return
        val now = SystemClock.elapsedRealtime()
        // 结束通知已发，忽略其后一小段 UI 收尾产生的杂音
        if (type == "new_message" && now - lastFlushAt < POST_DONE_GRACE_MS) return
        if (snippet.isNotBlank()) {
            if (pendingBuffer.isNotEmpty()) pendingBuffer.append(' ')
            pendingBuffer.append(snippet.trim())
            if (pendingBuffer.length > 600) {
                pendingBuffer.delete(0, pendingBuffer.length - 600)
            }
        }
        when (type) {
            "task_wait" -> pendingWait = true
            "task_done" -> pendingDone = true
        }
        if (type == "task_done") {
            // 页面出现「已工作xx分xx秒」且不再「工作中」：一轮结束，立即通知
            timeoutHandler.removeCallbacks(quietRunnable)
            flushPendingNotification()
        } else {
            // 静默兜底：页面安静 QUIET_MS（回复结束/等确认但文案不识别）才发一条
            timeoutHandler.removeCallbacks(quietRunnable)
            timeoutHandler.postDelayed(quietRunnable, QUIET_MS)
        }
    }

    private fun flushPendingNotification() {
        val text = pendingBuffer.toString().trim()
        val waiting = pendingWait
        val done = pendingDone
        pendingBuffer.setLength(0)
        pendingWait = false
        pendingDone = false
        lastFlushAt = SystemClock.elapsedRealtime()
        if (text.isEmpty() && !waiting && !done) return
        ensureChannels()

        val (channelId, title) = when {
            waiting -> CHANNEL_WAIT to getString(R.string.notif_wait_title)
            done -> CHANNEL_MSG to getString(R.string.notif_done_title)
            else -> CHANNEL_MSG to getString(R.string.notif_msg_title)
        }
        val body = when {
            text.isBlank() -> getString(R.string.notif_fallback)
            else -> {
                // 展示前再清一遍漏网的计时文字
                val cleaned = text
                    .replace(Regex("(正在思考|思考中|工作中|执行中|运行中|已工作|已停止)\\s*\\d[\\d分秒时:\\s.…]*"), " ")
                    .replace(Regex("\\s+"), " ")
                    .trim()
                if (cleaned.isBlank()) getString(R.string.notif_fallback)
                else if (cleaned.length > NOTIF_BODY_MAX) "…" + cleaned.takeLast(NOTIF_BODY_MAX)
                else cleaned
            }
        }
        val notification = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(mainPendingIntent())
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(this).notify(SystemClock.elapsedRealtime().toInt(), notification)
        } catch (e: SecurityException) {
            // 用户在系统设置里关了通知权限，静默降级
        }
    }

    private fun canNotify(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun maybeAskNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33 || notifAsked) return
        notifAsked = true
        if (!canNotify()) {
            notifPermissionLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_MSG, getString(R.string.channel_msg),
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        )
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_WAIT, getString(R.string.channel_wait),
                NotificationManager.IMPORTANCE_HIGH,
            )
        )
    }

    private fun mainPendingIntent() = PendingIntent.getActivity(
        this, 0,
        Intent(this, MainActivity::class.java),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    // ---- 工具 ----

    /** 链接等同密钥，只接受显式带协议的 http(s) 链接。 */
    private fun normalizeUrl(raw: String): String? {
        val candidate = raw.trim()
        if (!candidate.startsWith("http://") && !candidate.startsWith("https://")) return null
        val host = Uri.parse(candidate).host ?: return null
        return if (host.isBlank()) null else candidate
    }

    private fun isSameHost(url: String): Boolean {
        val currentHost = pendingUrl?.let { Uri.parse(it).host } ?: return true
        return Uri.parse(url).host == currentHost
    }

    private fun hostOf(url: String): String = Uri.parse(url).host ?: url

    private fun sanitizeName(raw: String): String =
        raw.replace(Regex("\\s+"), " ").trim().take(30)

    private fun openExternally(url: String) {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        } catch (e: ActivityNotFoundException) {
            Toast.makeText(this, R.string.no_browser, Toast.LENGTH_SHORT).show()
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun armLoadTimeout() {
        disarmLoadTimeout()
        timeoutHandler.postDelayed(loadTimeoutRunnable, LOAD_TIMEOUT_MS)
    }

    private fun disarmLoadTimeout() {
        timeoutHandler.removeCallbacks(loadTimeoutRunnable)
    }

    private fun isNetworkAvailable(): Boolean {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return true
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    override fun onResume() {
        webView.onResume()
        // 回到前台说明用户已看到内容，清掉积压的通知和未聚合的内容
        timeoutHandler.removeCallbacks(quietRunnable)
        pendingBuffer.setLength(0)
        pendingWait = false
        pendingDone = false
        NotificationManagerCompat.from(this).cancelAll()
        super.onResume()
    }

    override fun onPause() {
        webView.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        disarmLoadTimeout()
        webView.destroy()
        super.onDestroy()
    }

    companion object {
        private const val LOAD_TIMEOUT_MS = 20_000L
        private const val QUIET_MS = 12_000L
        private const val POST_DONE_GRACE_MS = 20_000L
        private const val NOTIF_BODY_MAX = 160
        private const val CHANNEL_MSG = "zcode_messages"
        private const val CHANNEL_WAIT = "zcode_waiting"
        private const val PREF_UI = "ui_state"
        private const val KEY_SWITCHER_X = "switcher_x"
        private const val KEY_SWITCHER_Y = "switcher_y"

        /**
         * 通用页面变化观察器：只在页面不可见（App 在后台）时上报。
         * 每次节流窗口（1.5s）发一个事件：
         * - task_done：页面状态从「正在思考/工作中」变为「已工作 xx分xx秒」→ 一轮结束
         *   （workStatus.state: running→stopped/completed/interrupted；已工作后带空格再接时长）
         * - task_wait：新增内容含「等待确认/批准」类关键词 → 需要用户操作
         * - new_message：其余新增内容
         * 「工作中」消失且出现「已工作」才判定结束（防止计时文字边走边跳导致误判），
         * 结束只报一次，下次出现「工作中」后重新武装。
         */
        private val WATCHER_JS = """
            (function(){
              if (window.__zcodeWatch) return;
              if (!window.AndroidBridge) return;
              window.__zcodeWatch = true;
              var last = 0;
              var armed = true;
              var WAIT = /等待你|待你确认|待你批准|待你审批|等待确认|等待批准|等待审批|需要你确认|需要你批准|待确认|待批准|是否允许|是否同意|仅本次允许|始终允许|始终拒绝|不允许|awaiting your|waiting for your|approval required|do you want/i;
              var ACTIVE = /正在思考|思考中|工作中|执行中|运行中/;
              var DONE = /已工作/;
              var KEYWORD = /正在思考|思考中|工作中|执行中|运行中|已工作|已停止/g;
              // 纯状态/计时节点（每秒跳动的「工作中 xx 秒」）不算消息内容
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
                if (document.visibilityState !== 'hidden') return;
                var now = Date.now();
                if (now - last < 1500) return;
                last = now;
                var text = '';
                for (var i = 0; i < muts.length; i++) text += textOf(muts[i]);
                // 混在大段内容里的计时片段也剔除（关键词后紧跟数字才认，避免误伤正文）
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
                AndroidBridge.onEvent(type, text.substring(0, 140));
              }).observe(document.body, {childList: true, subtree: true, characterData: true});
            })();
        """.trimIndent()
    }
}
