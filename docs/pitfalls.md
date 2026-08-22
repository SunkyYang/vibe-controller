# Pitfalls

Things that cost real debugging time. Each entry is a symptom first, because
that is how you will arrive here.

## Deploying

### Every install drops the Accessibility permission

**Symptom:** you reinstall, the app runs, the light bar and haptics work, but
no key ever lands. Log says `[!] Accessibility permission NOT granted yet.`

`launchagent/install.sh` re-signs the bundle ad-hoc, and ad-hoc trust is keyed
on `(path, cdhash)`. The path does not change, the hash does — so the entry
stays in System Settings looking enabled while being ignored. **Toggle it off
and back on**; a checked box proves nothing. Adding a fresh entry works too,
but the stale one has to go first.

There is no way around this short of a real Developer ID signature.

### There are two permissions, not one

They fail differently and are granted in different panes:

| Permission | Needed for | Log line when missing |
|---|---|---|
| Accessibility | Posting synthetic key/mouse events (`CGEvent.post`) | `[!] Accessibility permission NOT granted yet.` |
| Input Monitoring | The listen-only `CGEventTap` in `KeyboardSyncWatcher`, and the button map's keypress dismissal | `[sync] CGEventTap creation failed; keyboard Option+\` sync disabled` |

A keyboard `CGEventTap` has required Input Monitoring since Catalina, separate
from Accessibility. Chasing the `CGEventTap` failure in the Accessibility pane
gets you nowhere.

### Toggling a permission can leave two instances running

**Symptom:** every button fires twice — one press, two newlines.

Granting or revoking a TCC permission makes macOS kill the app. The
LaunchAgent's KeepAlive immediately restarts it, and that new process is no
longer the one launchd is tracking. A later `launchctl kickstart -k` then
starts a *third* process while the orphan keeps running — and both of them are
listening to the controller.

Order that avoids it entirely: **install, toggle the permission, and stop.**
The TCC-triggered restart already has the new permission; no kickstart needed.

Verify with:

```bash
pgrep -fl "Applications/VibeController.app"        # expect exactly one
launchctl list com.sunky.vibe-controller | grep PID # must be that same pid
```

If there is an extra, `kill` the one launchd does not claim. Do not `pkill -f
VibeController` — that takes out the good one too, and KeepAlive races you.

## Input handling

### A fixed-interval cursor timer stutters on 60Hz displays

**Symptom:** stick-driven cursor is glassy smooth, then abruptly choppy, with
no obvious trigger. Moving between displays "fixes" and "breaks" it.

A `DispatchSourceTimer` repeating every 16ms is ~62.5Hz free-running, aligned
to nothing. Against a 120Hz panel the mismatch is invisible. Against a 60Hz
panel, 62.5 vs 60 beats at 2.5Hz: about every 0.4s a refresh gets two position
updates or none. The trigger is just the cursor crossing onto the external
display, which is not something you notice doing.

`StickMouseMover` therefore integrates over real elapsed time (`dt`) and ticks
at ~120Hz, faster than any attached panel, so every refresh picks up a fresh
and correctly scaled position at either rate. Speed is expressed in px/second
rather than px/tick so the tick rate can change without changing the feel.

Check what you are actually running on before theorising:

```swift
CGDisplayBounds(id)                                  // negative origin = second display
CGDisplayCopyDisplayMode(id)?.refreshRate            // 0 can mean "variable"
```

### Nothing may sit permanently on the gamepad hot path

A DualSense reports a few hundred times a second and `GCController`'s handlers
run on the main queue — the same queue as the cursor timer. A profile-level
`valueChangedHandler` fires for *every* element change, so anything in it is
executed hundreds of times a second forever.

The button map's "any button dismisses" handler used to live there permanently
and check overlay visibility on each call. That check was free until the panel
was first allocated and then queried an `NSWindow` on every sample — so the
cursor degraded starting from the first L3 press and never recovered. It is
now installed on show and removed on hide (`dismissHookInstaller`).

Same reasoning applies to anything else tempting to add there.

### gamecontrollerd stalls stick samples for hundreds of milliseconds

**Symptom:** stick-driven cursor lurches every second or two. Restarting the
app, switching Bluetooth to USB, quitting other apps with event taps: nothing
changes it. Seen on macOS 26.5.2.

Measured on the same USB cable, same 10-second window, Bluetooth powered off:

| layer | samples | p50 | p99 | max | gaps > 200ms |
|---|---|---|---|---|---|
| raw HID input reports (`IOHIDManager`) | 2502 | 4.0ms | 4.1ms | 4.3ms | 0 |
| `GCController` `valueChangedHandler` | 977 | 4.0ms | 176ms | 300ms | 6 |

The device streams a clean 250Hz; `gamecontrollerd` forwards it with stalls.
Nothing in the app was on the hot path (a 40-line test program with an empty
run loop reproduces it), and `gamecontrollerd` logs nothing.

`DualSenseRawSticks` therefore reads the input report straight from IOKit and
feeds `StickMouseMover` / `StickScroller`; GameController keeps the buttons,
haptics and light bar, which are discrete and survive a stalled sample.
Report layouts: USB `0x01` has LX LY RX RY at bytes 1-4, Bluetooth `0x31` has
one extra sequence byte so they sit at 2-5. HID Y grows downward, so it is
flipped to match GameController before it reaches the movers.

Two things to keep straight while debugging this class of problem:

- **Plugging in USB does not move a paired DualSense off Bluetooth.** The
  input keeps flowing over BT; the USB interface just appears alongside it
  (`[trigger] reacquire: 2 DualSense IOHID device(s)`). Power Bluetooth off
  to actually test the cable.
- **`CGGetEventTapList` latency numbers lie for a freshly created tap.** A
  tap that has just been installed reports an avg/max latency of tens of
  seconds; it is not evidence that the owning process is blocking events.

### `ProcessType = Background` in the LaunchAgent throttles the cursor timer to 10Hz

**Symptom:** stick-driven cursor moves in ~100ms steps, on every transport,
with the trackpad perfectly smooth. The same 8ms `DispatchSourceTimer` in a
bare command-line process ticks at 8.3ms.

launchd spawns a `ProcessType = Background` job with the background darwin
role (`launchctl print gui/$UID/<label>` shows `spawn type = background (5)`,
`ps -o pri` shows priority 4). The kernel applies aggressive timer coalescing
to that role, so the cursor timer fires about every 100ms no matter what
leeway it asks for. Measured on macOS 26.5.2 with a listen-only tap counting
the app's own `mouseMoved` posts over 10s of stick movement:

| ProcessType | mouse events | p50 gap |
|---|---|---|
| Background | 94 | 101ms |
| Interactive | 1146 | 8.3ms |

The plist now uses `Interactive` (`spawn type = interactive (4)`, priority 37).
`NSAppSleepDisabled` (App Nap) made no difference and is not the knob.

How to tell this apart from the `gamecontrollerd` stall above: count the
app's posted mouse events with a listen-only `CGEventTap`. Input-side stalls
leave the event cadence intact and the positions stale; this one thins the
event stream itself.

### Thumbsticks must be excluded from any "any input" handler

Sticks report continuously and drift at rest. An `any element changed`
dismissal that does not exclude `leftThumbstick` / `rightThumbstick` closes the
overlay before it finishes fading in.

## GameController framework

### Apple's names for Create/Options are the reverse of Sony's

`buttonOptions` is the **Create** key (left of the touchpad, formerly Share).
`buttonMenu` is the **Options** key (right of the touchpad). Guessing from the
name gets it backwards. `attach()` logs both `localizedName`s at connect:

```
[buttons] buttonOptions=Create Button buttonMenu=Options Button
```

### The touchpad click is not the touchpad surface

The touchpad's capacitive X/Y is unusable as a pointer — drift makes it wander
— and is deliberately unmapped. `touchpadButton` is a plain digital button and
is unaffected; it is mapped to left click. Do not disable both because one is
broken.

`touchpadButton` lives on `GCDualSenseGamepad` (macOS 11.3+) and
`GCDualShockGamepad`, not on `GCExtendedGamepad`, so it needs an availability
check and a cast.

### Adaptive trigger is USB-only in practice

Over Bluetooth the log says:

```
[trigger] reacquire: 1 DualSense IOHID device(s) visible
[trigger]   device: outputSize=547 transport=Bluetooth
[trigger] no usable DualSense IOHID device
```

The BT output report is a different size and layout (0x31, 79 bytes, CRC32
trailer) than the USB one (0x02, 47 bytes, no CRC). LED and rumble still work
over BT because the GameController framework handles those itself — only the
direct IOHID trigger writes are affected.
