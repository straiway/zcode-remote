# ZCode Remote

**Unofficial ZCode remote-control client for Android and macOS** — follow and steer the [ZCode](https://zcode.z.ai) tasks running on your computer from your phone, or from another computer.

[中文](README.md) · [Download](https://github.com/straiway/zcode-remote/releases/latest) · [Android project](android/) · [macOS project](macos/)

> This project is not affiliated with Zhipu AI / Z.ai. It is a third-party client built on top of ZCode's official "Web Remote Control" feature. The client talks only to the official ZCode relay; there is no third-party server and no data collection of any kind.

## What it is

The ZCode desktop app ships a "remote control" feature: click the phone icon in the bottom-left corner, scan the QR code (or open the link) in your phone's browser, and you can watch tasks and send instructions remotely. It works, but a browser tab has obvious gaps: no notifications, re-scanning every time, and clumsy switching between several computers.

ZCode Remote wraps that page in a native client and fills those gaps:

| Capability | Details |
|---|---|
| **System notifications** | While the app is in the background: "Task finished" when a turn completes, and a high-priority "Waiting for your approval" when the agent pauses for confirmation |
| **Multiple computers** | Save connections to several machines and switch with one tap; connections are named after the computer's hostname by default and can be renamed |
| **Secure storage** | The remote link contains an auth token; it is stored encrypted — EncryptedSharedPreferences on Android, Keychain on macOS |
| **Link handling** | External links in messages open in the system browser so the session page is never navigated away; file downloads work (macOS) |
| **Native feel** | Full screen, follows system dark/light mode, back button and keyboard shortcuts behave as expected on each platform |

Typical uses: keep an eye on a long-running task from your phone while you're out and get buzzed when it finishes; or drive the ZCode instance on your home machine from a Mac at the office.

## Download & install

Grab the latest build from [Releases](https://github.com/straiway/zcode-remote/releases/latest).

### Android

1. Download `zcode-remote-android-x.y.z.apk`
2. Open it on the phone (or transfer it over) and install; allow "unknown sources" when prompted
3. Requires Android 8.0 or newer

The APK is self-signed by the developer (not distributed through an app store). Upgrade in place with APKs from the same source.

### macOS

1. Download `ZCode-Remote-macOS-x.y.z.zip` and unzip it
2. Drag `ZCode Remote.app` into **Applications** (the name does not clash with the official ZCode.app, so both can coexist)
3. Gatekeeper will block the first launch because the app is not notarized by Apple. Either:
   - run `xattr -cr "/Applications/ZCode Remote.app"` in Terminal, then open it normally, or
   - after the first blocked attempt, go to **System Settings → Privacy & Security** and click **Open Anyway**
4. Requires macOS 13 or newer; universal binary (Apple silicon and Intel)

## How to use

1. **On the controlled computer**: run the ZCode desktop app and click the phone icon in the bottom-left corner. A QR code and a link appear.
2. **Connect**
   - Android: open ZCode Remote and tap **Scan to connect** (or copy the link and use **Paste link**)
   - macOS: open ZCode Remote, choose **Connection → Add connection…** (⌘N) and paste the link
3. **Sign in**: the first time you will see a sign-in page. Pick **the same provider and account as the controlled computer** (Z.ai or BigModel). This is required by the official remote-control page; the session is remembered afterwards.
4. From then on you can browse tasks and send instructions as if you were at the desk. Once the app goes to the background you'll be notified when there is a result or a decision waiting for you.

Several computers: generate a link on each machine and add them all. Connections are named after each machine's hostname.

- Android: a translucent floating button sits near the top-right of the session page — tap to open the connection list, drag to move it anywhere, long-press to reload the page
- macOS: switch from the **Connection** menu; ⌘R reloads the page

## How notifications are decided

While the agent is working, the remote page shows "thinking…" / "working for N s"; when it stops, that turns into "worked for N min N s". ZCode Remote injects a small, generic observer script into the page:

- "working" disappears and "worked for" appears → the turn is over → notify immediately
- newly added content contains approval wording ("waiting for your confirmation", "allow once", "always allow", …) → high-priority notification
- everything else is only accumulated; if the page stays quiet for 12 seconds a single fallback notification is sent, and the ticking timer text is filtered out of the body

The script relies on visible wording only, not on the page's DOM structure, so official UI updates rarely break it.

## Known limitations

- **Official constraints**: only one remote client may be connected to a given computer at a time; the ZCode desktop app on the controlled machine must stay running and online
- **The link is the key**: the remote link acts as a temporary credential. Refreshing the QR code on the desktop invalidates the old link immediately (scan / add again). Never forward it to others
- **Android**: notifications depend on the app process being alive; once the system fully kills it, notifications stop (no persistent foreground service, by design, to save battery)
- **macOS**: the app is ad-hoc signed and not notarized, hence the one-time Gatekeeper step above

## Building from source

The two sub-projects are independent:

- **Android** (Kotlin, WebView): see [android/README.md](android/README.md). Open in Android Studio, or run `./gradlew :app:assembleDebug`
- **macOS** (Swift, WKWebView): see [macos/README.md](macos/README.md). Requires Xcode; `./build-app.sh` produces the `.app` and a zip (universal binary)

## Project layout

```
zcode-remote/
├── android/   Android client (Kotlin + WebView)
├── macos/     macOS client (Swift + AppKit + WKWebView)
├── README.md  Chinese README
└── README.en.md
```

## Privacy & security

- No analytics, no telemetry, no third-party SDKs. The only network endpoints are the official ZCode relay (`zcode.z.ai`) and the identity provider you choose when signing in
- Remote links are stored encrypted on the device and never synced anywhere
- Fully open source and auditable: all Android logic lives under `android/app/src/main/java/`, all macOS logic in `macos/Sources/ZCodeShell/main.swift`

## License

[MIT](LICENSE)

ZCode and Z.ai are trademarks of Zhipu AI. This is an independent third-party client provided for convenience and is not affiliated with or endorsed by the trademark holder.
