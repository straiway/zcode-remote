# ZCode Remote for macOS

ZCode「手机远程控制」页面的 macOS 原生壳，用于**在一台电脑上遥控另一台电脑的 ZCode**。
应用名刻意与官方 `ZCode.app` 区分（`ZCode Remote.app`），可与官方桌面端装在同一台机器上。
与安卓版（[`../android`](../android)）功能对齐，逻辑同源。安装与使用说明见仓库根目录 [README](../README.md)。

## 功能

- **多连接管理**：菜单栏「连接」里保存多台电脑的链接，一键切换；名称默认取链接里的
  主机名（`name=` 参数），链接在受控电脑的 ZCode 桌面端左下角手机图标处复制
- **Keychain 加密存储**：链接内含授权令牌，存 Keychain；异常时退回应用私有偏好
- **系统通知**：应用不在前台时，任务结束弹「任务已完成」，等审批弹「等待你的确认」
  （时间敏感级别）；页面计时器文字不计入通知正文；回到前台自动清掉已发通知
- **链接策略**：消息里的站外链接（含右键「在浏览器中打开」）交给默认浏览器；
  登录重定向等页面内跳转留在应用内；指向文件的链接走保存面板下载
- 标准「编辑」菜单（⌘C/⌘V/⌘X/⌘A/⌘Z）、`⌘N` 添加连接、`⌘R` 重新加载页面

## 构建

```bash
./build-app.sh
```

产物：`build/bin/ZCode Remote.app` 与 `build/bin/ZCode-Remote-macOS-<version>.zip`（通用二进制，
Apple 芯片 / Intel 均可）。需要 Xcode（Swift 5.9+）与 Python 3 + Pillow（生成图标）。

## 安装到另一台 Mac

解压后拖到「应用程序」。因为是本地 ad-hoc 签名、未经 Apple 公证，首次打开会被 Gatekeeper
拦截，任选其一：

- 终端执行 `xattr -cr "/Applications/ZCode Remote.app"` 去掉隔离标记后正常双击
- 或双击被拦后到「系统设置 → 隐私与安全性」底部点「仍要打开」

## 目录

```
Package.swift                 SwiftPM 可执行目标
Sources/ZCodeShell/main.swift 全部逻辑（AppKit + WKWebView + UserNotifications + Keychain）
tools/make_icon.py            生成 AppIcon.icns（与安卓版同款 Z 字图标）
build-app.sh                  编译 → 组装 .app → 签名 → 打 zip
```
