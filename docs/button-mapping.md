# Button Mapping

Current DualSense button assignments. The implementation in `Sources/VibeController/main.swift` is the source of truth.

## Mapped buttons

| Button | GC API | Action | Notes |
|---|---|---|---|
| R2 (right trigger, analog) | `rightTrigger` | Toggle OpenWhispr recording (`Option+\``) | Engages at 0.6, releases at 0.4 (hysteresis); adaptive trigger weapon mode over USB; **if L2 is held when R2 fires, the resulting paste is routed to Ghostty** |
| L2 (left trigger) | `leftTrigger` | Modifier / "Fn" | Held to change the meaning of other buttons |
| R1 | `rightShoulder` | `Cmd+Shift+→` | Ghostty next tab (matches the author's Ghostty config) |
| L1 | `leftShoulder` | `Cmd+Shift+←` | Ghostty previous tab |
| ✕ (Cross) | `buttonA` | `Return` | |
| ○ (Circle) | `buttonB` | `Esc` (default) / `Delete` while L2 is held | |
| □ (Square) | `buttonX` | Mouse left click | Pairs with the right stick used as scroll wheel and the left stick used as cursor |
| △ (Triangle) | `buttonY` | Short press: focus Ghostty + type `claude\n`. Long press (>0.55s): focus Ghostty + type `claude --resume\n` | Waits for `NSWorkspace.didActivateApplicationNotification` before typing, with a 2s fallback |
| D-Pad ↑ | `dpad.up` | Arrow ↑ (default) / `Cmd+T` new Ghostty tab while L2 held | Long-press auto-repeat mimics macOS |
| D-Pad ↓ | `dpad.down` | Arrow ↓ (default) / type `/new\n` while L2 held | |
| D-Pad ← | `dpad.left` | Arrow ← | |
| D-Pad → | `dpad.right` | Arrow → (default) / `Cmd+D` split right while L2 held | |
| Left stick (analog) | `leftThumbstick` | Mouse cursor movement | |
| Right stick (analog) | `rightThumbstick` | Vertical scroll wheel | |
| PS (Home) | `buttonHome` | `Cmd+Tab` | macOS may intercept; some controllers do not expose this button |

## Unmapped (available)

| Button | GC API | Status |
|---|---|---|
| L3 (left stick click) | `leftThumbstickButton` | Unused |
| R3 (right stick click) | `rightThumbstickButton` | Unused |
| Options | `buttonOptions` | Unused |
| Create (top-left, formerly Share) | `buttonMenu` | Unused |
| Touchpad (analog X/Y) | touchpad | **Intentionally disabled** — capacitive drift was unworkable; the right stick + Square covers the same role |
| Touchpad click | touchpadButton | Intentionally disabled (same reason) |
| Mute key (below the mic) | — | Hardware-level, not exposed by GameController |

## Reverse reference: common actions → buttons

- Start/stop dictation → R2
- Enter / Escape → ✕ / ○
- Arrow nav (with auto-repeat) → D-Pad
- Delete char (with auto-repeat) → L2 + ○
- Switch tab → L1 / R1
- Mouse → left stick to move + □ to click
- Scroll → right stick
- Cmd+Tab between apps → PS
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
- Stick-to-cursor sensitivity → `StickMouseMover`
- Stick-to-scroll sensitivity → `StickScroller`
- D-Pad auto-repeat timing → `DPadAutoRepeat`
