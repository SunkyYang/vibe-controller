# Install as a LaunchAgent (autostart at login)

## Requirements

- macOS 11.3+
- Swift 5.9+ (Xcode toolchain)
- DualSense controller, USB-C or Bluetooth
- [OpenWhispr](https://github.com/openwhispr/openwhispr) installed and configured with:
  - Dictation hotkey set to `Option+\`` (the backtick key under Esc)
  - Activation mode: `tap` (press once to start, again to stop)
- **Accessibility permission** (and, for keyboard sync, **Input Monitoring**) granted to the installed app (`~/Applications/VibeController.app` after running `launchagent/install.sh`) — re-granted after every reinstall, see below

## Install

```bash
bash launchagent/install.sh
```

This builds release, packages a `.app` bundle (`Info.plist` + custom icon), copies it to `~/Applications/VibeController.app`, and bootstraps the agent under `gui/$UID`. The stable install path matters — System Settings → Privacy & Security → Accessibility looks for installed apps in standard locations; pointing trust at the transient `.build/release/` artifact is brittle.

Logs go to `~/Library/Logs/vibe-controller.{log,err}`.

## Granting permissions

Two separate permissions are needed, in **System Settings → Privacy & Security**:

| Pane | Needed for | Missing it looks like |
|---|---|---|
| **Accessibility** | Posting key and mouse events — i.e. every binding | `[!] Accessibility permission NOT granted yet.` in the log |
| **Input Monitoring** | Syncing state when *you* type `Option+\``, and dismissing the button map with a keypress | `[sync] CGEventTap creation failed` in the log |

Click `+`, press `Cmd+Shift+G`, enter `~/Applications`, and pick `VibeController.app`. The Finder sidebar's "Applications" is `/Applications`, which is not where this installs.

**Every reinstall revokes Accessibility.** `install.sh` re-signs the bundle ad-hoc and that trust is keyed on `(path, cdhash)`; the path is stable but the hash is not, so the existing entry silently stops counting. Toggle it off and back on — a checked box is not evidence it works. See [pitfalls](pitfalls.md).

**Do not run `kickstart` afterwards.** Changing a permission makes macOS kill the app, and KeepAlive restarts it already holding the new permission. A kickstart on top of that leaves an orphaned second instance, and two instances mean every button press fires twice. Confirm there is exactly one:

```bash
pgrep -fl "Applications/VibeController.app"
launchctl list com.sunky.vibe-controller | grep PID
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
