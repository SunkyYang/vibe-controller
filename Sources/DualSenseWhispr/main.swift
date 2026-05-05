import Foundation
import GameController
import CoreGraphics
import AppKit
import CoreHaptics

setbuf(stdout, nil)
setbuf(stderr, nil)

// MARK: - Tunables

let TRIGGER_HIGH: Float = 0.6
let TRIGGER_LOW: Float = 0.4
let kVK_ANSI_Grave: CGKeyCode = 0x32

// MARK: - Accessibility

func checkAccessibility(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

// MARK: - Synthetic key

func tapOptionBacktick() {
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

// MARK: - Haptics

final class HapticBumper {
    private let engine: CHHapticEngine?

    init(controller: GCController) {
        guard let h = controller.haptics else {
            self.engine = nil
            print("[haptics] not supported on this controller")
            return
        }
        let e = h.createEngine(withLocality: .default)
        do {
            try e?.start()
        } catch {
            print("[haptics] engine start failed: \(error)")
        }
        e?.resetHandler = { [weak e] in
            try? e?.start()
        }
        self.engine = e
    }

    func bump(intensity: Float = 1.0, sharpness: Float = 0.6, duration: TimeInterval = 0.08) {
        guard let engine = engine else { return }
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: 0,
            duration: duration
        )
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            print("[haptics] play failed: \(error)")
        }
    }
}

// MARK: - Light

func setLight(_ controller: GCController?, recording: Bool) {
    guard let light = controller?.light else { return }
    light.color = recording
        ? GCColor(red: 0.0, green: 0.4, blue: 1.0)   // recording = blue
        : GCColor(red: 0.0, green: 0.0, blue: 0.0)   // idle = off
}

// MARK: - Trigger watcher

final class TriggerWatcher {
    weak var controller: GCController?
    var bumper: HapticBumper?
    var statusUpdate: ((Bool) -> Void)?

    private var pressed = false
    private(set) var recording = false

    func handle(value: Float) {
        if !pressed && value >= TRIGGER_HIGH {
            pressed = true
            recording.toggle()
            tapOptionBacktick()
            setLight(controller, recording: recording)
            bumper?.bump()
            statusUpdate?(recording)
            print("[R2] press -> recording=\(recording)")
        } else if pressed && value <= TRIGGER_LOW {
            pressed = false
        }
    }

    func resetForDisconnect() {
        pressed = false
        if recording {
            recording = false
            statusUpdate?(false)
        }
    }
}

let watcher = TriggerWatcher()

// MARK: - Connection

func attach(_ controller: GCController) {
    let name = controller.vendorName ?? "Unknown"
    print("[connect] \(name)")

    guard let gamepad = controller.extendedGamepad else {
        print("[warn] no extendedGamepad on \(name)")
        return
    }

    watcher.controller = controller
    watcher.bumper = HapticBumper(controller: controller)
    setLight(controller, recording: false)

    gamepad.rightTrigger.valueChangedHandler = { _, value, _ in
        watcher.handle(value: value)
    }
}

func detach(_ controller: GCController) {
    print("[disconnect] \(controller.vendorName ?? "Unknown")")
    if watcher.controller === controller {
        watcher.controller = nil
        watcher.bumper = nil
        watcher.resetForDisconnect()
    }
}

// MARK: - Status bar

final class StatusBar: NSObject {
    let item: NSStatusItem
    private let statusItem = NSMenuItem(title: "Status: scanning…", action: nil, keyEquivalent: "")

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setIcon(symbol: "gamecontroller")
        let menu = NSMenu()
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(
            title: "Quit DualSenseWhispr",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func quitApp() {
        if let c = watcher.controller {
            setLight(c, recording: false)
        }
        NSApp.terminate(nil)
    }

    private func setIcon(symbol: String) {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "DualSenseWhispr")
        img?.isTemplate = true
        item.button?.image = img
    }

    func setConnected(_ name: String?) {
        statusItem.title = name.map { "Connected: \($0)" } ?? "Waiting for DualSense…"
    }

    func setRecording(_ on: Bool) {
        setIcon(symbol: on ? "mic.fill" : "gamecontroller")
    }
}

// MARK: - Bootstrap

if CommandLine.arguments.contains("--fire-once") {
    let trusted = checkAccessibility(prompt: false)
    print("[test] AX trusted = \(trusted)")
    print("[test] firing Option+` once and exiting.")
    tapOptionBacktick()
    Thread.sleep(forTimeInterval: 0.1)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Accessory apps don't get controller events by default; opt in.
if #available(macOS 11.3, *) {
    GCController.shouldMonitorBackgroundEvents = true
}

let statusBar = StatusBar()

NotificationCenter.default.addObserver(
    forName: .GCControllerDidConnect, object: nil, queue: .main
) { note in
    if let c = note.object as? GCController {
        attach(c)
        statusBar.setConnected(c.vendorName)
    }
}

NotificationCenter.default.addObserver(
    forName: .GCControllerDidDisconnect, object: nil, queue: .main
) { note in
    if let c = note.object as? GCController {
        detach(c)
        statusBar.setConnected(nil)
    }
}

watcher.statusUpdate = { recording in
    statusBar.setRecording(recording)
}

if !checkAccessibility(prompt: true) {
    print("[!] Accessibility permission NOT granted yet.")
    print("[!] Grant it in: System Settings -> Privacy & Security -> Accessibility.")
}

print("DualSenseWhispr started. Click the status bar icon for menu.")

for c in GCController.controllers() {
    attach(c)
    statusBar.setConnected(c.vendorName)
}
GCController.startWirelessControllerDiscovery {}

app.run()
