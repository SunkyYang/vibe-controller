# Microphone strategy on macOS

The whole point of this tool, for me, was **remote dictation**: sit on the couch holding the controller, press R2, talk. That immediately runs into a hard limitation worth documenting.

## DualSense built-in microphone is **not** usable over Bluetooth on macOS

Sony's PS5 controller does not expose its audio devices via standard Bluetooth audio profiles (A2DP / HFP). Audio over Bluetooth uses a Sony-proprietary protocol that only the PS5 console implements. Consequences across operating systems:

| OS | DualSense BT mic | Notes |
|---|---|---|
| **PS5** | ✅ | Native, custom protocol |
| **Windows** | ✅ in supported games | Game-level, not OS-level |
| **macOS** | ❌ | Not exposed as audio device. No third-party kext exists. |
| **Linux** | ❌ over BT | `hid-playstation` supports USB only; BT audio is not on the roadmap |

USB is different — when the controller is plugged into a USB-C cable, macOS sees it as a **USB Audio Class** composite device with 2 input channels and 4 output channels, and the built-in mic and 3.5 mm jack work normally. But USB defeats the "couch dictation" use case.

## What this app actually does

There's a menu bar toggle **"Use DualSense Mic"** that, when enabled, switches the system default audio input to the DualSense Wireless Controller right before sending the dictation hotkey, and restores the previous input when recording stops. This works **only when the controller is connected over USB** (because that's the only mode in which the DualSense exposes itself as an audio device). On Bluetooth the toggle silently no-ops and OpenWhispr captures from whatever the system default is.

## Recommended setup for remote dictation

The pragmatic answer is to split the two roles:

- **DualSense over Bluetooth** → input device for *triggering* (R2 press, light bar, haptics). No audio.
- **AirPods (or any other Bluetooth headset)** → input device for *audio capture*. Becomes the system default automatically when worn.

With that combo, "Use DualSense Mic" stays **off**. The controller triggers the recording, the headset captures the voice, and OpenWhispr sees them as one continuous experience.

The on-device DualSense microphone (USB only) is left as an option for niche cases — couch with a long USB-C cable, no headset around, etc.

## Sources

- [PlayStation official: DualSense with PC, Mac and mobile](https://www.playstation.com/en-us/support/hardware/pair-dualsense-controller-bluetooth/) — "built-in microphone and speaker … aren't compatible with Mac and mobile devices"
- [Phoronix: Sony DualSense Audio Jack Handling Ready For Linux 6.18](https://www.phoronix.com/news/Sony-DualSense-Audio-Handling) — kernel work is USB only
- [Linux kernel patch: DualSense mic mute support](https://patchwork.kernel.org/project/linux-input/patch/20210215004549.135251-3-roderick@gaikai.com/) — explicitly notes "supported using USB, not yet using Bluetooth (which uses a custom protocol)"
