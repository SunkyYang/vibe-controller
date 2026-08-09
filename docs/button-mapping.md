# Button Mapping

Current DualSense button assignments. The implementation in `Sources/VibeController/main.swift` is the source of truth.

## Mapped buttons

| Button | GC API | Action | Notes |
|---|---|---|---|
| R2 (right trigger, analog) | `rightTrigger` | Toggle OpenWhispr recording (`Option+\``) | Engages at 0.6, releases at 0.4 (hysteresis); adaptive trigger weapon mode over USB; **if L2 is held when R2 fires, the resulting paste is routed to Ghostty** |
| L2 (left trigger) | `leftTrigger` | Modifier / "Fn" | Held to change the meaning of other buttons. Engaging the layer fires a short haptic tick and turns the light bar amber; released, the bar reverts to the current Claude state. Suppressed while recording, where the voice-reactive bar owns the light |
| R1 | `rightShoulder` | `Cmd+Shift+→` | Ghostty next tab (matches the author's Ghostty config) |
| L1 | `leftShoulder` | `Cmd+Shift+←` | Ghostty previous tab |
| ✕ (Cross) | `buttonA` | `Return` (default) / `Cmd+Z` undo while L2 is held | |
| ○ (Circle) | `buttonB` | `Esc` (default) / `Delete` while L2 is held | |
| □ (Square) | `buttonX` | Mouse **right** click | Left click moved to the touchpad click |
| △ (Triangle) | `buttonY` | Short press: focus Ghostty + type `claude\n`. Long press (>0.55s): focus Ghostty + type `claude --resume\n` | Waits for `NSWorkspace.didActivateApplicationNotification` before typing, with a 2s fallback |
| D-Pad ↑ | `dpad.up` | Arrow ↑ (default) / `Cmd+T` new Ghostty tab while L2 held | Long-press auto-repeat mimics macOS |
| D-Pad ↓ | `dpad.down` | Arrow ↓ (default) / type `/new\n` while L2 held | |
| D-Pad ← | `dpad.left` | Arrow ← | |
| D-Pad → | `dpad.right` | Arrow → (default) / `Cmd+D` split right while L2 held | |
| Left stick (analog) | `leftThumbstick` | Mouse cursor movement | |
| L3 (left stick click) | `leftThumbstickButton` | Toggle the on-screen button map | A click-through HUD drawn in `CheatSheet.swift`. Dismissed by any other controller button (via `gamepad.valueChangedHandler`, with the thumbsticks excluded so drift cannot close it) or by any keypress. Also reachable from the status bar menu ("Show Button Map") |
| Right stick (analog) | `rightThumbstick` | Vertical scroll wheel | |
| Create (left of touchpad) | `buttonOptions` | `Cmd+Shift+4` screenshot selection | Apple's naming is inverted from Sony's: `buttonOptions` is the **Create** key, `buttonMenu` is **Options**. `attach()` logs both `localizedName`s at connect so this can be verified per controller |
| Options (right of touchpad) | `buttonMenu` | `Tab` | Shell and Claude Code completion |
| Touchpad click | `touchpadButton` | Mouse left click (with drag via `mouseHeld`) | The capacitive X/Y drift that got the touchpad surface disabled does not affect this — the click is a plain digital button |
| PS (Home) | `buttonHome` | Mission Control (`Ctrl+↑`) | Was `Cmd+Tab`, but a tap-and-release `Cmd+Tab` can only bounce between the two most recent apps. macOS may intercept; some controllers do not expose this button |

## Unmapped (available)

| Button | GC API | Status |
|---|---|---|
| R3 (right stick click) | `rightThumbstickButton` | Unused |
| Touchpad (analog X/Y) | touchpad | **Intentionally disabled** — capacitive drift was unworkable; the left stick covers the same role |
| Mute key (below the mic) | — | Hardware-level, not exposed by GameController |

## Reverse reference: common actions → buttons

- **Forgot the mapping → L3 (click the left stick)** — pops up the button map
- Start/stop dictation → R2
- Enter / Escape → ✕ / ○
- Arrow nav (with auto-repeat) → D-Pad
- Delete char (with auto-repeat) → L2 + ○
- Undo → L2 + ✕ (Cmd+Z)
- Switch tab → L1 / R1
- Mouse → left stick to move + touchpad click for left, □ for right
- Scroll → right stick
- Mission Control → PS
- Screenshot selection → Create
- Tab / completion → Options
- Launch/focus Ghostty and run `claude` → △ short press
- Launch Ghostty and run `claude --resume` → △ long press
- Dictate directly into Claude (force paste to Ghostty) → L2 + R2
- New Ghostty tab → L2 + ↑ (Cmd+T)
- Split Ghostty right → L2 + → (Cmd+D)
- Claude `/new` → L2 + ↓

## Configuration

The knobs you most likely want to tweak. All live in `Sources/VibeController/main.swift`.

```swift
let TRIGGER_HIGH: Float = 0.6     // R2 press threshold
let TRIGGER_LOW:  Float = 0.4     // R2 release threshold (hysteresis)
let kVK_ANSI_Grave: CGKeyCode = 0x32   // ` key — combine with .flags to remap
```

Other tunables, by location:

- Light bar color and breathing curve → `BreathingLight`
- Haptic patterns and intensity → `HapticBumper.bump(...)` and `HapticBumper.playRecording*`
- Triangle long-press threshold → `TrianglePress` (0.55s)
- Adaptive trigger feel → `DualSenseTriggerEffect.setWeaponMode(...)` (start/end positions, strength)
- Button-map HUD (labels, layout) → `Sources/VibeController/CheatSheet.swift`. The callout text lives in `leftCallouts` / `rightCallouts` / `combos`; keep it in sync with the table above. `./.build/release/VibeController --render-map out.png` renders the HUD to a PNG without a controller attached.
- L2 layer feedback (tick strength, amber colour) → `setModifierLayerFeedback(...)`
- Stick-to-cursor sensitivity → `StickMouseMover`
- Stick-to-scroll sensitivity → `StickScroller`
- D-Pad auto-repeat timing → `DPadAutoRepeat`
