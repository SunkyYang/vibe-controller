# Vibe Controller

## Quick start

```bash
git clone https://github.com/SunkyYang/vibe-controller.git
cd vibe-controller
swift build -c release
./.build/release/VibeController
```

A game-controller icon appears in the menu bar. Plug in the DualSense (or pair via Bluetooth — long-press `PS + Create` to enter pairing mode), press R2, dictate, press R2 again. `Ctrl+C` to quit, or click the menu bar icon → Quit.

Requires macOS 11.3+, Swift 5.9+, and [OpenWhispr](https://github.com/openwhispr/openwhispr) configured for `Option+\`` in tap mode. For prerequisites, autostart, and Accessibility setup, see [`docs/install.md`](docs/install.md).

## Buttons

| Button | Action |
|---|---|
| **L3** (click left stick) | **Pop up the on-screen button map** — press it when you forget the rest of this table |
| R2 | Toggle dictation (OpenWhispr) |
| L2 | Modifier — held to enable the combos below; ticks and turns the light bar amber |
| L1 / R1 | `Cmd+Shift+←` / `Cmd+Shift+→` (tab nav) |
| ✕ / ○ | Enter / Esc |
| D-Pad | Arrow keys with auto-repeat |
| △ | Launch Ghostty + run `claude` (long press: `claude --resume`) |
| □ / Touchpad click | Mouse left click (+ drag) / right click |
| Left stick / Right stick | Mouse cursor / scroll wheel |
| Create / Options | `Cmd+Shift+4` screenshot / `Tab` |
| PS | Mission Control |
| L2 + R2 | Dictate directly into Ghostty |
| L2 + ✕ / ○ | `Cmd+Z` undo / Delete |
| L2 + D-Pad ↑ / → / ↓ | `Cmd+T` / `Cmd+D` / type `/new` |

Full table and tunable constants in [`docs/button-mapping.md`](docs/button-mapping.md).

## What & why

Use a PS5 DualSense controller as a push-to-talk voice input device on macOS. Pulling the **R2 trigger** toggles dictation in [OpenWhispr](https://github.com/openwhispr/openwhispr); recognized text is injected wherever the cursor sits. Lives in the menu bar, runs as a LaunchAgent at login. The PS5 controller has been in arm's reach the whole time, with a perfectly good analog trigger. OpenWhispr already handles audio capture, transcription, reasoning, and text injection — all that was missing was a way to translate a gamepad trigger event into the keyboard shortcut OpenWhispr listens for. About 200 lines of Swift do that, plus light-bar feedback and haptic confirmation for free.

## Features

- R2 trigger toggles OpenWhispr dictation; light bar breathes blue while recording and reacts to your voice level
- Face buttons, D-Pad, and shoulder buttons mapped to common keys. L2 acts as a Fn modifier for combos. Sticks act as mouse cursor + scroll wheel.
- Click the left stick (L3) for a click-through HUD that draws the controller with every mapping labelled; any other button or keypress dismisses it. Also on the status bar menu
- Haptic feedback on recording start/stop, with distinct patterns for different events
- Optional [Claude Code state mirroring](docs/claude-code-integration.md) — light bar reflects what Claude is doing
- Optional [adaptive trigger weapon mode](docs/adaptive-trigger.md) on R2 (USB only)
- Menu bar icon, no Dock entry, no window. USB and Bluetooth both work.

## Documentation

- [Button mapping & configuration](docs/button-mapping.md)
- [Pitfalls](docs/pitfalls.md) — permissions, duplicate instances, cursor stutter, GameController naming traps
- [How it works](docs/how-it-works.md)
- [Install as LaunchAgent](docs/install.md) — requirements, autostart, Accessibility, smoke test
- [Microphone strategy on macOS](docs/microphone-on-macos.md)
- [Claude Code state mirroring](docs/claude-code-integration.md)
- [Adaptive trigger (USB)](docs/adaptive-trigger.md)

## License

MIT — see [LICENSE](LICENSE).
