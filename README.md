# ZCode Remote

**非官方的 ZCode 远程控制客户端（Android / macOS）**——在手机上，或者用另一台电脑，随时查看和操控你电脑上正在运行的 [ZCode](https://zcode.z.ai) 任务。

[English](README.en.md) · [下载安装包](https://github.com/straiway/zcode-remote/releases/latest) · [Android 子项目](android/) · [macOS 子项目](macos/)

> 本项目与智谱 AI / Z.ai 无关，是基于 ZCode 官方「Web 远程控制」功能的第三方客户端。客户端只连接 ZCode 官方中继服务，不经过任何第三方服务器，也不收集任何数据。

## 这是什么

ZCode 桌面端自带「手机远程控制」功能：点击左下角的手机图标，会生成一个二维码 / 链接，用手机浏览器打开就能远程查看任务、发送指令。它能用，但浏览器标签页有几个明显短板：没有通知、每次都要重新扫码、多台电脑切换麻烦。

ZCode Remote 把这个页面包成原生客户端，补上这些体验：

| 能力 | 说明 |
|---|---|
| **系统通知** | 应用在后台时，任务结束弹「任务已完成」，Agent 停下来等你审批时弹「等待你的确认」（高优先级） |
| **多台电脑** | 保存多台电脑的连接，一键切换；连接名默认取电脑主机名，可重命名 |
| **安全存储** | 远程链接内含授权令牌，Android 用 EncryptedSharedPreferences，macOS 用 Keychain 加密保存 |
| **链接处理** | 消息里的站外链接交给系统浏览器，不会把会话页顶掉；下载链接正常保存（macOS） |
| **原生体验** | 全屏、深浅模式跟随系统、返回键 / 快捷键符合平台习惯 |

典型场景：出门在外用手机盯着电脑上跑的长任务，跑完手机会响；或者在公司用一台 Mac 遥控家里那台装了 ZCode 的电脑。

## 下载安装

前往 [Releases](https://github.com/straiway/zcode-remote/releases/latest) 下载最新版本。

### Android

1. 下载 `zcode-remote-android-x.y.z.apk`
2. 用手机浏览器打开或传到手机后安装，安装时允许「未知来源应用」
3. 要求 Android 8.0 及以上

APK 为开发者自签名构建（不经应用商店分发）。覆盖安装升级时请使用同一来源的 APK。

### macOS

1. 下载 `ZCode-Remote-macOS-x.y.z.zip`，解压
2. 把 `ZCode Remote.app` 拖到「应用程序」文件夹（与官方 ZCode.app 名字不冲突，可共存）
3. 首次打开会被 Gatekeeper 拦截（应用未经 Apple 公证），任选其一：
   - 终端执行 `xattr -cr "/Applications/ZCode Remote.app"`，然后正常双击
   - 或双击被拦后，到「系统设置 → 隐私与安全性」底部点「仍要打开」
4. 要求 macOS 13 及以上，Apple 芯片 / Intel 通用

## 使用方法

1. **受控电脑**：运行 ZCode 桌面端，点击左下角的手机图标，弹出二维码和链接
2. **连接**
   - Android：打开 ZCode Remote，点「扫码连接」扫那个二维码（也可以复制链接后用「粘贴链接连接」）
   - macOS：打开 ZCode Remote，菜单「连接 → 添加连接…」（⌘N），粘贴复制的链接
3. **登录**：首次会进入登录页，选择**与受控电脑相同的登录平台和账号**（Z.ai 或 BigModel）。这是官方远程控制的要求，登录态会保留
4. 之后就能像在电脑上一样查看任务、发送指令。应用退到后台后，有结果或需要你确认时会收到通知

多台电脑：在每台电脑上生成链接并添加即可，连接名默认是对应电脑的主机名。

- Android：会话页右上有个半透明悬浮按钮——轻点打开连接列表切换，按住可拖到任意位置，长按重新加载页面
- macOS：菜单栏「连接」里切换，⌘R 重新加载页面

## 通知是怎么判断的

远程控制页面在 Agent 工作时显示「正在思考 / 工作中 xx 秒」，结束后变成「已工作 xx 分 xx 秒」。ZCode Remote 向页面注入一段通用的变化观察脚本：

- 「工作中」消失、出现「已工作」→ 一轮结束，立即通知
- 新增内容包含「等待确认」「仅本次允许」「始终允许」等审批文案 → 高优先级通知
- 其他变化只积累不打扰，页面安静 12 秒后兜底发一条，计时器跳动的文字不计入正文

脚本只依赖页面文案，不依赖具体 DOM 结构，官方页面改版一般无需适配。

## 已知限制

- **官方限制**：同一台受控电脑同时只允许一个远程端连接；受控电脑的 ZCode 桌面端必须保持运行且在线
- **链接即密钥**：远程链接等同临时密钥，桌面端刷新二维码后旧链接立即失效（需重新扫码 / 添加）；不要把链接转发给他人
- **Android**：通知依赖应用进程存活，被系统彻底杀掉后不再通知（没有常驻前台服务，以省电为先）
- **macOS**：应用使用本地 ad-hoc 签名、未经 Apple 公证，所以首次打开需要上面的放行步骤

## 从源码构建

两个子项目相互独立：

- **Android**（Kotlin，WebView）：见 [android/README.md](android/README.md)。Android Studio 直接打开，或 `./gradlew :app:assembleDebug`
- **macOS**（Swift，WKWebView）：见 [macos/README.md](macos/README.md)。需要 Xcode，运行 `./build-app.sh` 一键出 `.app` 和 zip（通用二进制）

## 项目结构

```
zcode-remote/
├── android/   Android 客户端（Kotlin + WebView）
├── macos/     macOS 客户端（Swift + AppKit + WKWebView）
├── README.md  本文
└── README.en.md
```

## 隐私与安全

- 不包含任何统计、上报、第三方 SDK；网络连接只有 ZCode 官方中继（`zcode.z.ai`）和你登录时选择的认证平台
- 远程链接在本地加密保存，不同步到任何地方
- 开源可审计，欢迎阅读源码：Android 的全部逻辑在 `android/app/src/main/java/`，macOS 在 `macos/Sources/ZCodeShell/main.swift`

## 许可证

[MIT](LICENSE)

ZCode、Z.ai 是智谱 AI 的商标，本项目仅为方便使用者而提供的第三方客户端，与官方无隶属关系。
