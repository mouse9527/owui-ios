# Installing on your iPhone (free Apple ID)

No paid developer account is needed. A free ("Personal Team") signature lasts **7 days**; after that the app
will not open until you run it from Xcode again (see [Re-signing](#re-signing-every-7-days)).

Requirements: a Mac with Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), an iPhone on iOS 26 or later, and a USB cable (or the phone paired with Xcode over Wi-Fi).

## 1. Sign in to Xcode

Xcode → Settings → Accounts → **+** → Apple ID. Your Apple ID now has a "Personal Team".

## 2. Choose a bundle ID prefix and your team

Bundle IDs must be unique across all Apple accounts, so pick a prefix nobody else uses:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Edit `Config/Local.xcconfig`:

- `OWUI_BUNDLE_ID_PREFIX`: e.g. `io.github.<your-name>`. The app becomes `<prefix>.owui` and the Live Activity
  extension `<prefix>.owui.LiveActivity`. That is **two App IDs**; a free account may register 10 per 7 days, so avoid
  changing the prefix repeatedly.
- `OWUI_DEVELOPMENT_TEAM`: your Personal Team ID. In Xcode → Settings → Accounts, select the team; the ID is the
  10-character code. (Alternatively leave it empty and pick the team in step 3.)

`Config/Local.xcconfig` is ignored by git.

## 3. Generate the project and run

```sh
xcodegen generate
open OWUI.xcodeproj
```

1. Select the **OWUI** scheme and your iPhone as the run destination.
2. If you left the team empty: select the project → each of the two targets → Signing & Capabilities → Team →
   your Personal Team.
3. Press **Run** (⌘R). The first time, Xcode creates the signing certificate and profiles.

## 4. On the iPhone, the first time

1. **Developer Mode**: Settings → Privacy & Security → Developer Mode → on. The phone restarts; confirm "Turn On".
   (The option appears after Xcode has tried to install once.)
2. **Trust the developer**: if the app does not open, Settings → General → VPN & Device Management → your Apple ID →
   Trust.
3. Open **OWUI**. In Settings enter your Open WebUI address, then sign in on the web page that loads.
4. Back in Settings, choose the **default model** for voice calls.
5. Tap the **phone** button at the top once and allow the **microphone**. This has to happen inside the app:
   when a call is started from the Action button the app is in the background and iOS cannot ask for permission.
6. Allow Live Activities if asked (Settings → OWUI → Live Activities should be on).

## 5. Bind the Action button

Settings → Action Button → **Shortcut** → choose **OWUI → 语音通话**.

Pressing the Action button starts a call without leaving the current app; the Dynamic Island shows the call state
(连接中 / 在听 / 在想 / 在说). Press it again to hang up, or use the buttons in the expanded Dynamic Island or on the
Lock Screen (mute, open app, end).

The same action is available in the Shortcuts app if you prefer to start it from a shortcut.

## Re-signing every 7 days

When the free profile expires the app shows "no longer available" or quits immediately. Your settings and the
sign-in are kept.

1. Connect the phone, open `OWUI.xcodeproj` (run `xcodegen generate` first if you pulled new code).
2. Press **Run**. That is all; the bundle IDs are unchanged, so no new App IDs are used.

## Troubleshooting

- **"Failed to register bundle identifier"**: the prefix is taken; choose another one in `Config/Local.xcconfig`.
- **Action button does nothing**: open the app once and start a call from the phone button to grant the microphone;
  check that a default model is selected.
- **Call ends right away with a sign-in error**: sign in again on the web page inside the app; the voice call uses
  the same account.
- **Web search or memory is missing in calls**: Settings → 高级 → 委派 should be 完整. 降级 only uses the
  model's configured tools.
