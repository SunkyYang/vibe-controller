# Vibe Controller

Use a PS5 DualSense controller as a push-to-talk voice input device on macOS. The **R2 trigger** toggles dictation in [OpenWhispr](https://github.com/openwhispr/openwhispr), the light bar breathes while you speak, haptics confirm, and the sticks double as a mouse. A ~200-line Swift menu bar app.

## Quick start

```bash
git clone https://github.com/SunkyYang/vibe-controller.git
cd vibe-controller
swift build -c release
./.build/release/VibeController
```

A game-controller icon appears in the menu bar. Plug in the DualSense (or pair via Bluetooth — long-press `PS + Create`), press R2, dictate, press R2 again.

Requires macOS 11.3+, Swift 5.9+, and OpenWhispr configured for `Option+\`` in tap mode. Prerequisites, autostart, and Accessibility setup: [`docs/install.md`](docs/install.md).

## Buttons

| Button | Action |
|---|---|
| **L3** (click left stick) | **Pop up the on-screen button map** — press it when you forget the rest of this table |
| R2 | Toggle dictation (OpenWhispr) |
| L2 | Modifier — held to enable the combos below; ticks and turns the light bar amber |
| L1 / R1 | `Cmd+Shift+←` / `Cmd+Shift+→` (tab nav) |
| ✕ / ○ | Enter / Esc |
| D-Pad | Arrow keys with auto-repeat |
| △ | Cycle Claude Code mode — `Shift+Tab` (long press: `Ctrl+C` interrupt) |
| □ / Touchpad click | Mouse left click (+ drag) / right click |
| Left stick / Right stick | Mouse cursor / scroll wheel |
| Create / Options | `Cmd+Shift+4` screenshot / `Tab` |
| PS | Mission Control |
| L2 + R2 | Dictate directly into Ghostty |
| L2 + △ | Launch Ghostty + run `claude` (long press: `claude --resume`) |
| L2 + ✕ / ○ | `Cmd+Z` undo / Delete |
| L2 + D-Pad ↑ / → / ↓ | `Cmd+T` / `Cmd+D` / type `/new` |

Full table and tunable constants in [`docs/button-mapping.md`](docs/button-mapping.md).

## Documentation

- [Button mapping & configuration](docs/button-mapping.md)
- [Pitfalls](docs/pitfalls.md) — permissions, duplicate instances, cursor stutter, GameController naming traps
- [How it works](docs/how-it-works.md)
- [Install as LaunchAgent](docs/install.md) — requirements, autostart, Accessibility, smoke test
- [Microphone strategy on macOS](docs/microphone-on-macos.md)
- [Claude Code state mirroring](docs/claude-code-integration.md) — light bar reflects what Claude is doing
- [Adaptive trigger weapon mode](docs/adaptive-trigger.md) (USB only)

## License

MIT — see [LICENSE](LICENSE).
