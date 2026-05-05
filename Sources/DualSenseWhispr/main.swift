import Foundation
import GameController
import CoreGraphics
import AppKit

setbuf(stdout, nil)
setbuf(stderr, nil)

let TRIGGER_HIGH: Float = 0.6
let TRIGGER_LOW: Float = 0.4

let kVK_ANSI_Grave: CGKeyCode = 0x32

func checkAccessibility(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

func tapOptionBacktick() {
    // nil source + cgSessionEventTap mirrors what osascript does (which works).
    guard
        let down = CGEvent(keyboardEventSource: nil, virtualKey: kVK_ANSI_Grave, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: kVK_ANSI_Grave, keyDown: false)
    else {
        FileHandle.standardError.write(Data("[error] failed to create CGEvent\n".utf8))
        return
    }
    down.flags = .maskAlternate
    up.flags = .maskAlternate
    down.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
}

final class TriggerWatcher {
    private var isPressed = false

    func handle(value: Float) {
        if !isPressed && value >= TRIGGER_HIGH {
            isPressed = true
            print("[R2] press -> Option+`")
            tapOptionBacktick()
        } else if isPressed && value <= TRIGGER_LOW {
            isPressed = false
            print("[R2] release")
        }
    }
}

let watcher = TriggerWatcher()

func attach(_ controller: GCController) {
    let name = controller.vendorName ?? "Unknown"
    print("[connect] \(name)")

    guard let gamepad = controller.extendedGamepad else {
        print("[warn] no extendedGamepad on \(name)")
        return
    }
    gamepad.rightTrigger.valueChangedHandler = { _, value, _ in
        watcher.handle(value: value)
    }
}

NotificationCenter.default.addObserver(
    forName: .GCControllerDidConnect, object: nil, queue: .main
) { note in
    if let c = note.object as? GCController { attach(c) }
}

NotificationCenter.default.addObserver(
    forName: .GCControllerDidDisconnect, object: nil, queue: .main
) { note in
    if let c = note.object as? GCController {
        print("[disconnect] \(c.vendorName ?? "Unknown")")
    }
}

if CommandLine.arguments.contains("--fire-once") {
    let trusted = checkAccessibility(prompt: false)
    print("[test] AX trusted = \(trusted)")
    print("[test] firing Option+` once and exiting.")
    tapOptionBacktick()
    // Give the system a beat to deliver the event before exit.
    Thread.sleep(forTimeInterval: 0.1)
    exit(0)
}

print("DualSenseWhispr started.")
print("Press R2 -> Option+` -> OpenWhispr toggles dictation (tap mode).")

if !checkAccessibility(prompt: true) {
    print("")
    print("[!] Accessibility permission NOT granted yet.")
    print("[!] Grant it in: System Settings -> Privacy & Security -> Accessibility.")
    print("[!] The host process needs to be allowed (Terminal / iTerm / your binary).")
    print("[!] Re-run after granting.")
}

for c in GCController.controllers() { attach(c) }
GCController.startWirelessControllerDiscovery {}

print("[ready] waiting for DualSense (USB or BT)...")
RunLoop.main.run()
