# How it works

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
