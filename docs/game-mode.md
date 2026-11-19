# Game Mode

Status bar menu: **Vibe Mode (work)** / **Game Mode (pad untouched)**.

Game Mode releases every keyboard and mouse mapping so a game that reads the
controller directly (browser Gamepad API, native games) is not fighting
synthetic input. Without it, the left stick drags the system cursor out of the
game window and R2 toggles OpenWhispr dictation.

## What switching does

`setGameMode(true)`:

1. `releaseInputs()`:
   - stops an in-flight recording through the normal R2 path first
     (`watcher.handle(value: 1)` then `0`), while that handler still exists
   - releases a held left mouse button, stops Delete auto-repeat, clears L2
   - nils every `pressedChangedHandler` / `valueChangedHandler` installed by
     `attach()`, including the profile-level one and the touchpad click
   - detaches the raw IOHID stick feed, stops the cursor / scroll / D-pad timers
   - resets the adaptive trigger (no weapon resistance on R2)
   - hides the button map
2. suspends `ClaudeStateWatcher` so it cannot repaint the light bar
3. light bar steady magenta, two haptic ticks, menu icon becomes `gamecontroller.fill`

`setGameMode(false)`: calls `attach(controller)` again, which reinstalls every
mapping, the stick feed and the trigger profile; resumes the Claude state
light; one haptic tick.

Connecting a controller while in Game Mode: `attach()` returns early after the
light, trigger reset and battery monitor, so nothing gets mapped.

The mode is not persisted. The app always starts in Vibe Mode, so a reboot
cannot leave the pad silently "dead" for work.

## Status (2026-11-20)

- Committed and pushed to `main`. Smini's clone (`~/Sdevproject/vibe-controller`)
  needs a `git pull` to pick it up.
- Installed on the MacBook with `launchagent/install.sh`.
- Verified: picking the menu item logs `[mode] -> game`, and the user played a
  browser game with the DualSense in Game Mode without the cursor drifting or R2
  triggering OpenWhispr.
- After every install the Accessibility permission has to be toggled off and on
  again (see pitfalls.md). Check the log for
  `[!] Accessibility permission NOT granted yet.` before debugging anything else.

## Ideas not done

- Toggle from the controller itself (e.g. long-press PS). Note macOS may
  intercept the Home button; in Game Mode that handler would be the only one left.
- Persist the mode, if the user wants it.
