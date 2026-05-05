# DualSense Whispr

Use a PS5 DualSense controller as a push-to-talk voice input device on macOS. Pulling the **R2 trigger** toggles dictation in [OpenWhispr](https://github.com/openwhispr/openwhispr); recognized text gets injected wherever the cursor sits.

## Why

The PS5 controller has been in arm's reach the whole time, with a perfectly good analog trigger. OpenWhispr already handles audio capture, transcription, reasoning, and text injection — all that was missing was a way to translate a gamepad trigger event into the keyboard shortcut OpenWhispr listens for. About 90 lines of Swift do that.

## How it works

```
DualSense (USB)
    │  GameController.framework rightTrigger handler
    ▼
DualSenseWhispr (Swift CLI)
    │  R2 leading edge ─► CGEvent post Option+`
    ▼
OpenWhispr (Electron globalShortcut "Alt+`")
    │  start/stop dictation, run ASR, paste text
    ▼
focused application
```

- Analog trigger debounced with hysteresis (engage at `value >= 0.6`, release at `<= 0.4`).
- Synthetic key event uses `nil` event source + `.cgSessionEventTap` — same level as `osascript`. Lower-level taps (`.cghidEventTap`) bypass Electron's Carbon-based hotkey listener and won't trigger.

## Requirements

- macOS 11+
- Swift 5.9+ (Xcode toolchain)
- DualSense controller, USB-C cable (Bluetooth mode not yet validated)
- [OpenWhispr](https://github.com/openwhispr/openwhispr) installed and configured with:
  - Dictation hotkey set to `Option+\`` (the backtick key under Esc)
  - Activation mode: `tap` (press once to start, again to stop)
- **Accessibility permission** granted to whichever process runs the binary (System Settings → Privacy & Security → Accessibility)

## Build & run

```bash
git clone git@github.com:SunkyYang/dualsense-whispr.git
cd dualsense-whispr
swift build -c release
./.build/release/DualSenseWhispr
```

Plug in the DualSense, press R2. Press R2 again to stop dictation. `Ctrl+C` to quit.

## Smoke test (no controller needed)

```bash
./.build/release/DualSenseWhispr --fire-once
```

Fires `Option+\`` once and exits — verifies the key-event path independently of the controller.

## Configuration

Two knobs, both in `Sources/DualSenseWhispr/main.swift`:

```swift
let TRIGGER_HIGH: Float = 0.6   // press threshold
let TRIGGER_LOW:  Float = 0.4   // release threshold (hysteresis)

let kVK_ANSI_Grave: CGKeyCode = 0x32   // ` key; change with .flags below to remap
```

To use a different OpenWhispr hotkey, change the virtual key code and modifier flags in `tapOptionBacktick()`.

## Roadmap

- [ ] LaunchAgent for autostart on login / USB attach
- [ ] Bluetooth mode (lightbar/rumble may need IOHID fallback)
- [ ] True push-to-talk (hold R2 to record, release to stop) — depends on OpenWhispr `activationMode=push`
- [ ] DualSense lightbar mirroring system status
- [ ] D-Pad / face-button mappings for editor and shell shortcuts

## License

MIT — see [LICENSE](LICENSE).
