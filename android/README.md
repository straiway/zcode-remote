# ZCode Remote for Android

ZCode「手机远程控制」页面的安卓原生壳。ZCode 官方没有原生手机 App，远程控制是通过手机
浏览器打开桌面端生成的链接（走官方中继，外网可用）。本工程把那个页面包成原生 App，
补上浏览器给不了的体验。安装与使用说明见仓库根目录 [README](../README.md)。

## 功能

- **扫码连接**：直接扫 ZCode 桌面端左下角手机图标弹出的二维码；也支持粘贴链接
- **多连接管理**：保存多台电脑的连接，名称默认取链接里的主机名；会话页的悬浮切换按钮
  可拖动并记住位置，轻点切换、长按重新加载页面；连接列表长按可重命名 / 删除
- **系统通知**：App 在后台时，任务结束弹「任务已完成」，等审批弹「等待你的确认」
  （高优先级渠道）；回到前台自动清掉已发通知
- **加密存储**：链接内含授权令牌，用 EncryptedSharedPreferences（Android KeyStore）保存；
  `allowBackup=false` 防止随系统备份导出
- **链接策略**：消息里的站外链接交给系统浏览器，不会把会话页顶掉
- **体验细节**：透明状态栏 + 深浅模式跟随系统；加载超时 / 断网 / 桌面端离线有明确提示和重试入口

## 构建

### Android Studio（推荐）

直接 Open 本目录，Gradle Sync 完成后 Run。

### 命令行

需要 JDK 17+ 与 Android SDK（platform 34）。`local.properties` 中 `sdk.dir` 指向 SDK 路径。

```bash
./gradlew :app:assembleDebug
```

产物：`app/build/outputs/apk/debug/app-debug.apk`。安装：

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## 目录结构

```
app/src/main/
├── AndroidManifest.xml
├── java/dev/straiway/zcodeshell/
│   ├── MainActivity.kt      # WebView 壳、扫码 / 连接管理 / 通知聚合 / 页面事件桥
│   └── ConnectionStore.kt   # 多连接加密存储（KeyStore 异常时降级私有目录）
└── res/
    ├── layout/activity_main.xml
    ├── drawable/            # 图标、切换按钮
    ├── mipmap-anydpi-v26/   # 自适应启动图标（含 monochrome 层）
    └── values/{strings,themes,colors}.xml
```

## 通知的实现方式

向远程控制页注入一段通用的 DOM 变化观察脚本（`MainActivity.WATCHER_JS`）：

- 页面状态从「正在思考 / 工作中」变为「已工作 xx 分 xx 秒」→ 判定一轮结束，立即通知
- 新增内容含「等待确认 / 仅本次允许 / 始终允许 …」等审批文案 → 高优先级通知
- 其余变化只积累内容，页面静默 12 秒后兜底发一条；计时器跳动的文字不计入正文

脚本只依赖页面文案与「会追加内容」这一通用行为，不依赖具体 DOM 结构。
App 进程被系统杀死后通知停止（没有常驻前台服务）。
