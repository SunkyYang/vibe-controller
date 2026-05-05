# Vibe Controller

Use a PS5 DualSense controller as a push-to-talk voice input device on macOS. Pulling the **R2 trigger** toggles dictation in [OpenWhispr](https://github.com/openwhispr/openwhispr); recognized text is injected wherever the cursor sits. Lives in the menu bar, runs as a LaunchAgent at login.

## Why

The PS5 controller has been in arm's reach the whole time, with a perfectly good analog trigger. OpenWhispr already handles audio capture, transcription, reasoning, and text injection — all that was missing was a way to translate a gamepad trigger event into the keyboard shortcut OpenWhispr listens for. About 200 lines of Swift do that, plus light-bar feedback and haptic confirmation for free.

## Feature checklist

- ✅ R2 leading-edge → toggles OpenWhispr dictation (`Option+\``, tap mode)
- ✅ Face buttons & D-Pad mapped to common keyboard keys (✕→Enter, ○→Esc, D-Pad→arrows)
- ✅ **Touchpad swipes** → Enter (right) / Esc (left) for accept/reject gestures
- ✅ Light bar **breathes blue** while recording, **brightness reacts to your voice level**, sweeps in/out on start/stop
- ✅ Haptic choreography — different patterns for start (`da-DUM`) vs stop (`DUM-da`), error etc.
- ✅ **Claude Code lifecycle mirrored on the light bar** (thinking / tool use / notification / idle) via Claude Code hooks
- ✅ **Adaptive trigger weapon mode on R2** (USB only, IOHID output report) — two-stage resistance like a gun trigger
- ✅ Menu bar icon (no Dock entry, no window) with connection status + Quit
- ✅ Optional **"Use DualSense Mic"** toggle: switches the system default input to the controller while recording, restores it after (USB-only — see the *Microphone strategy* section)
- ✅ USB and Bluetooth both work — GameController.framework handles output reports either way
- ✅ Proper `.app` bundle with custom icon, installed to `~/Applications/`
- ✅ LaunchAgent for autostart at login, restart on crash

## How it works

```
DualSense (USB or Bluetooth)
    │  GameController.framework rightTrigger handler
    ▼
VibeController (Swift menu bar app)
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
- **Accessibility permission** granted to the installed app (`~/Applications/VibeController.app` after running `launchagent/install.sh`)

## Quick start

```bash
git clone git@github.com:SunkyYang/vibe-controller.git
cd vibe-controller
swift build -c release
./.build/release/VibeController
```

A game-controller icon appears in the menu bar. Plug in the DualSense (or pair via Bluetooth — long-press `PS + Create` to enter pairing mode), press R2, dictate, press R2 again. `Ctrl+C` to quit, or click the menu bar icon → Quit.

## Run as a LaunchAgent (autostart)

```bash
bash launchagent/install.sh
```

This builds release, packages a `.app` bundle (`Info.plist` + custom icon), copies it to `~/Applications/VibeController.app`, and bootstraps the agent under `gui/$UID`. The stable install path matters — System Settings → Privacy & Security → Accessibility looks for installed apps in standard locations; pointing trust at the transient `.build/release/` artifact is brittle. Logs go to `~/Library/Logs/vibe-controller.{log,err}`.

After installing, **System Settings → Privacy & Security → Accessibility** must allow `VibeController`. Click `+`, navigate to `~/Applications`, and pick `VibeController.app`. Once granted:

```bash
launchctl kickstart -k gui/$UID/com.sunky.vibe-controller
```

Manual control:

```bash
launchctl kickstart -k gui/$UID/com.sunky.vibe-controller   # restart
launchctl bootout    gui/$UID/com.sunky.vibe-controller     # stop + unload
bash launchagent/uninstall.sh                                # remove
```

## Smoke test (no controller needed)

```bash
./.build/release/VibeController --fire-once
# or, after installing as a LaunchAgent:
~/Applications/VibeController.app/Contents/MacOS/VibeController --fire-once
```

Fires `Option+\`` once and exits — verifies the key-event path independently of the controller.

## Configuration

Two sets of knobs in `Sources/VibeController/main.swift`:

```swift
let TRIGGER_HIGH: Float = 0.6     // press threshold
let TRIGGER_LOW:  Float = 0.4     // release threshold (hysteresis)
let kVK_ANSI_Grave: CGKeyCode = 0x32   // ` key — change with `.flags` to remap
```

Light-bar color and haptic intensity are inline in `BreathingLight` and `HapticBumper.bump(...)`.

## Microphone strategy

The whole point of this tool, for me, was **remote dictation**: sit on the couch holding the controller, press R2, talk. That immediately runs into a hard limitation worth documenting:

### DualSense built-in microphone is **not** usable over Bluetooth on macOS

Sony's PS5 controller does not expose its audio devices via standard Bluetooth audio profiles (A2DP / HFP). Audio over Bluetooth uses a Sony-proprietary protocol that only the PS5 console implements. Consequences across operating systems:

| OS | DualSense BT mic | Notes |
|---|---|---|
| **PS5** | ✅ | Native, custom protocol |
| **Windows** | ✅ in supported games | Game-level, not OS-level |
| **macOS** | ❌ | Not exposed as audio device. No third-party kext exists. |
| **Linux** | ❌ over BT | `hid-playstation` supports USB only; BT audio is not on the roadmap |

USB is different — when the controller is plugged into a USB-C cable, macOS sees it as a **USB Audio Class** composite device with 2 input channels and 4 output channels, and the built-in mic and 3.5 mm jack work normally. But USB defeats the "couch dictation" use case.

### What this app actually does

There's a menu bar toggle **"Use DualSense Mic"** that, when enabled, switches the system default audio input to the DualSense Wireless Controller right before sending the dictation hotkey, and restores the previous input when recording stops. This works **only when the controller is connected over USB** (because that's the only mode in which the DualSense exposes itself as an audio device). On Bluetooth the toggle silently no-ops and OpenWhispr captures from whatever the system default is.

### Recommended setup for remote dictation

The pragmatic answer is to split the two roles:

- **DualSense over Bluetooth** → input device for *triggering* (R2 press, light bar, haptics). No audio.
- **AirPods (or any other Bluetooth headset)** → input device for *audio capture*. Becomes the system default automatically when worn.

With that combo, "Use DualSense Mic" stays **off**. The controller triggers the recording, the headset captures the voice, and OpenWhispr sees them as one continuous experience.

The on-device DualSense microphone (USB only) is left as an option for niche cases — couch with a long USB-C cable, no headset around, etc.

### Sources for the macOS limitation

- [PlayStation official: DualSense with PC, Mac and mobile](https://www.playstation.com/en-us/support/hardware/pair-dualsense-controller-bluetooth/) — "built-in microphone and speaker … aren't compatible with Mac and mobile devices"
- [Phoronix: Sony DualSense Audio Jack Handling Ready For Linux 6.18](https://www.phoronix.com/news/Sony-DualSense-Audio-Handling) — kernel work is USB only
- [Linux kernel patch: DualSense mic mute support](https://patchwork.kernel.org/project/linux-input/patch/20210215004549.135251-3-roderick@gaikai.com/) — explicitly notes "supported using USB, not yet using Bluetooth (which uses a custom protocol)"

## Optional: Claude Code state mirroring

Make the light bar react to what Claude Code is doing — blue while thinking, purple during tool calls, amber on notifications, dark when idle.

```bash
bash scripts/install-claude-hooks.sh    # one-time wiring
# undo with:
bash scripts/uninstall-claude-hooks.sh
```

The installer is idempotent and **non-destructive** — it backs up `~/.claude/settings.json` and uses `jq` to merge five hook entries (UserPromptSubmit, PreToolUse, PostToolUse, Stop, Notification) without touching anything else. Each hook calls `scripts/claude-state-hook.sh <state>`, which writes a single line into `~/.vibe-controller/state`. The running app watches that file and updates the light bar.

Pre-existing hooks in your settings are preserved; we just append. Open a new Claude Code session for the hooks to take effect.

The state file is just one word — easy to introspect:

```bash
cat ~/.vibe-controller/state
```

## Adaptive trigger (USB only)

When the controller is plugged in via USB-C, the app sends a `0x02` HID output report to put R2 into "weapon mode": resistance ramps up between positions 2 and 6 of the trigger pull, then snaps loose past position 6. Pull R2 slowly to feel it.

Bluetooth uses a different report ID (`0x31`) that requires a CRC32 trailer; the app currently no-ops the trigger effect over Bluetooth and the trigger feels stock.

Constants are in `DualSenseTriggerEffect.setWeaponMode(...)` — change start/end positions or strength as you like.

## Roadmap

- [ ] True push-to-talk (hold R2 to record, release to stop) — needs OpenWhispr `activationMode=push`
- [ ] DualSense lightbar mirroring system status (Spark / Homelab healthcheck color)
- [ ] L1 / R1 → Ghostty / Claude Code tab switching
- [ ] Touchpad → mouse cursor (absolute positioning)
- [ ] Per-app mapping profiles (NSWorkspace frontmost app awareness)
- [ ] Adaptive trigger over Bluetooth (needs CRC32 on report 0x31)
- [ ] Battery level in menu bar
- [ ] State sync with OpenWhispr to avoid recording-state drift if the user also presses the keyboard shortcut

## License

MIT — see [LICENSE](LICENSE).
