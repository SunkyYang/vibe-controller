# Install as a LaunchAgent (autostart at login)

## Requirements

- macOS 11.3+
- Swift 5.9+ (Xcode toolchain)
- DualSense controller, USB-C or Bluetooth
- [OpenWhispr](https://github.com/openwhispr/openwhispr) installed and configured with:
  - Dictation hotkey set to `Option+\`` (the backtick key under Esc)
  - Activation mode: `tap` (press once to start, again to stop)
- **Accessibility permission** granted to the installed app (`~/Applications/VibeController.app` after running `launchagent/install.sh`)

## Install

```bash
bash launchagent/install.sh
```

This builds release, packages a `.app` bundle (`Info.plist` + custom icon), copies it to `~/Applications/VibeController.app`, and bootstraps the agent under `gui/$UID`. The stable install path matters — System Settings → Privacy & Security → Accessibility looks for installed apps in standard locations; pointing trust at the transient `.build/release/` artifact is brittle.

Logs go to `~/Library/Logs/vibe-controller.{log,err}`.

## Granting Accessibility permission

After installing, **System Settings → Privacy & Security → Accessibility** must allow `VibeController`. Click `+`, navigate to `~/Applications`, and pick `VibeController.app`. Once granted:

```bash
launchctl kickstart -k gui/$UID/com.sunky.vibe-controller
```

## Manual control

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
