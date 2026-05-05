# DualSense Whispr

Use a PS5 DualSense controller as a push-to-talk voice input device on macOS. Pulling the **R2 trigger** toggles dictation in [OpenWhispr](https://github.com/openwhispr/openwhispr); recognized text is injected wherever the cursor sits. Lives in the menu bar, runs as a LaunchAgent at login.

## Why

The PS5 controller has been in arm's reach the whole time, with a perfectly good analog trigger. OpenWhispr already handles audio capture, transcription, reasoning, and text injection — all that was missing was a way to translate a gamepad trigger event into the keyboard shortcut OpenWhispr listens for. About 200 lines of Swift do that, plus light-bar feedback and haptic confirmation for free.

## Feature checklist

- ✅ R2 leading-edge → toggles OpenWhispr dictation (`Option+\``, tap mode)
- ✅ Light bar mirrors recording state — blue while recording, off when idle
- ✅ Haptic bump on every state change
- ✅ Menu bar icon (no Dock entry, no window) with connection status + Quit
- ✅ USB and Bluetooth both work — GameController.framework handles output reports either way
- ✅ LaunchAgent for autostart at login, restart on crash

## How it works

```
DualSense (USB or Bluetooth)
    │  GameController.framework rightTrigger handler
    ▼
DualSenseWhispr (Swift menu bar app)
    │  R2 leading edge ─► CGEvent post Option+`
    │                ─► controller.light.color = blue/off
    │                ─► CHHapticEngine bump
    ▼
OpenWhispr (Electron globalShortcut "Alt+`")
    │  start/stop dictation, run ASR, paste text
    ▼
focused application
```

- Analog trigger debounced with hysteresis (engage at `value >= 0.6`, release at `<= 0.4`).
- Synthetic key event uses `nil` event source + `.cgSessionEventTap` — same level as `osascript`. Lower-level taps (`.cghidEventTap`) bypass Electron's Carbon-based hotkey listener and won't trigger.
- Menu bar app sets `setActivationPolicy(.accessory)` and opts in via `GCController.shouldMonitorBackgroundEvents = true`, otherwise the OS won't deliver controller events to a background app.

## Requirements

- macOS 11.3+
- Swift 5.9+ (Xcode toolchain)
- DualSense controller, USB-C or Bluetooth
- [OpenWhispr](https://github.com/openwhispr/openwhispr) installed and configured with:
  - Dictation hotkey set to `Option+\`` (the backtick key under Esc)
  - Activation mode: `tap` (press once to start, again to stop)
- **Accessibility permission** granted to the binary (`.build/release/DualSenseWhispr`)

## Quick start

```bash
git clone git@github.com:SunkyYang/dualsense-whispr.git
cd dualsense-whispr
swift build -c release
./.build/release/DualSenseWhispr
```

A game-controller icon appears in the menu bar. Plug in the DualSense (or pair via Bluetooth — long-press `PS + Create` to enter pairing mode), press R2, dictate, press R2 again. `Ctrl+C` to quit, or click the menu bar icon → Quit.

## Run as a LaunchAgent (autostart)

```bash
bash launchagent/install.sh
```

This builds release, renders the plist with concrete paths, and bootstraps the agent under `gui/$UID`. Logs go to `~/Library/Logs/dualsense-whispr.{log,err}`.

After installing, **System Settings → Privacy & Security → Accessibility** must allow `DualSenseWhispr`. The release binary is a different code path than the debug build, so it needs its own grant. Once granted:

```bash
launchctl kickstart -k gui/$UID/com.sunky.dualsense-whispr
```

Manual control:

```bash
launchctl kickstart -k gui/$UID/com.sunky.dualsense-whispr   # restart
launchctl bootout    gui/$UID/com.sunky.dualsense-whispr     # stop + unload
bash launchagent/uninstall.sh                                # remove
```

## Smoke test (no controller needed)

```bash
./.build/release/DualSenseWhispr --fire-once
```

Fires `Option+\`` once and exits — verifies the key-event path independently of the controller.

## Configuration

Two sets of knobs in `Sources/DualSenseWhispr/main.swift`:

```swift
let TRIGGER_HIGH: Float = 0.6     // press threshold
let TRIGGER_LOW:  Float = 0.4     // release threshold (hysteresis)
let kVK_ANSI_Grave: CGKeyCode = 0x32   // ` key — change with `.flags` to remap
```

Light-bar color and haptic intensity are inline in `setLight(...)` and `HapticBumper.bump(...)`.

## Roadmap

- [ ] True push-to-talk (hold R2 to record, release to stop) — needs OpenWhispr `activationMode=push`
- [ ] DualSense lightbar mirroring system status (Spark / Homelab healthcheck color)
- [ ] D-Pad / face-button mappings for editor and shell shortcuts
- [ ] State sync with OpenWhispr to avoid recording-state drift if the user also presses the keyboard shortcut

## License

MIT — see [LICENSE](LICENSE).
