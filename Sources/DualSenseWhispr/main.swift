import Foundation
import GameController
import CoreGraphics
import AppKit
import CoreHaptics
import CoreAudio

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

// MARK: - Audio device introspection / switching

enum AudioInputSwitcher {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static var defaultInputID: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        var id = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            system, &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        ) == noErr
    }

    static func name(of id: AudioDeviceID) -> String? {
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &nameRef) == noErr,
              let cf = nameRef?.takeRetainedValue() else { return nil }
        return cf as String
    }

    static func findInputDevice(matching pattern: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        let pat = pattern.lowercased()
        for id in ids {
            guard let n = name(of: id), n.lowercased().contains(pat) else { continue }
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &bufSize) == noErr,
                  bufSize > 0 else { continue }
            let bufList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(bufSize))
            defer { bufList.deallocate() }
            guard AudioObjectGetPropertyData(id, &streamAddr, 0, nil, &bufSize, bufList) == noErr else { continue }
            let bufs = UnsafeMutableAudioBufferListPointer(bufList)
            let total = bufs.reduce(0) { $0 + Int($1.mNumberChannels) }
            if total > 0 { return id }
        }
        return nil
    }
}

func currentDefaultInputName() -> String {
    guard let id = AudioInputSwitcher.defaultInputID else { return "unknown" }
    return AudioInputSwitcher.name(of: id) ?? "id=\(id)"
}

// MARK: - Preferences

enum Preferences {
    static let useDualSenseMicKey = "useDualSenseMic"

    static var useDualSenseMic: Bool {
        get { UserDefaults.standard.bool(forKey: useDualSenseMicKey) }
        set { UserDefaults.standard.set(newValue, forKey: useDualSenseMicKey) }
    }
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

func turnOffLight(_ controller: GCController?) {
    controller?.light?.color = GCColor(red: 0, green: 0, blue: 0)
}

/// Drives a slow blue breathing animation on the DualSense light bar
/// while recording. ~3s period, gamma-corrected so the perceived rhythm
/// is even rather than spiking at the peaks.
final class BreathingLight {
    private weak var controller: GCController?
    private var timer: DispatchSourceTimer?
    private var startTime = Date()

    private let period: TimeInterval = 3.0
    private let minBrightness: Double = 0.10   // never fully off — looks more "alive"
    private let maxBrightness: Double = 1.0

    init(controller: GCController) {
        self.controller = controller
    }

    func start() {
        stop(turnOff: false)
        startTime = Date()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))   // ~30 fps
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop(turnOff: Bool = true) {
        timer?.cancel()
        timer = nil
        if turnOff {
            turnOffLight(controller)
        }
    }

    private func tick() {
        guard let light = controller?.light else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let phase = elapsed.truncatingRemainder(dividingBy: period) / period
        let raw = (1.0 - cos(2.0 * .pi * phase)) / 2.0   // 0..1..0
        let gamma = pow(raw, 2.2)                         // perceptual easing
        let brightness = Float(minBrightness + (maxBrightness - minBrightness) * gamma)
        light.color = GCColor(
            red:   0.0,
            green: 0.4 * brightness,
            blue:  1.0 * brightness
        )
    }
}

// MARK: - Trigger watcher

final class TriggerWatcher {
    weak var controller: GCController?
    var bumper: HapticBumper?
    var breathing: BreathingLight?
    var statusUpdate: ((Bool) -> Void)?

    private var pressed = false
    private(set) var recording = false
    private var savedInputDevice: AudioDeviceID?

    func handle(value: Float) {
        if !pressed && value >= TRIGGER_HIGH {
            pressed = true
            recording.toggle()
            bumper?.bump()
            statusUpdate?(recording)
            if recording {
                breathing?.start()
                startRecording()
            } else {
                breathing?.stop()
                stopRecording()
            }
        } else if pressed && value <= TRIGGER_LOW {
            pressed = false
        }
    }

    private func startRecording() {
        if Preferences.useDualSenseMic,
           let ds = AudioInputSwitcher.findInputDevice(matching: "DualSense") {
            savedInputDevice = AudioInputSwitcher.defaultInputID
            AudioInputSwitcher.setDefaultInput(ds)
            let dsName = AudioInputSwitcher.name(of: ds) ?? "DualSense"
            print("[mic] switched default input -> \(dsName)")
            // Wait for CoreAudio to settle before OpenWhispr opens its capture stream.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.fireStartHotkey()
            }
        } else {
            if Preferences.useDualSenseMic {
                print("[mic] DualSense audio device not found; using current default")
            }
            fireStartHotkey()
        }
    }

    private func fireStartHotkey() {
        print("[R2] press -> recording=true (OpenWhispr mic = \(currentDefaultInputName()))")
        tapOptionBacktick()
    }

    private func stopRecording() {
        print("[R2] press -> recording=false")
        tapOptionBacktick()
        if let saved = savedInputDevice {
            // Give OpenWhispr a beat to release its in-flight capture stream
            // before we yank the default out from under it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                AudioInputSwitcher.setDefaultInput(saved)
                let restored = AudioInputSwitcher.name(of: saved) ?? "id=\(saved)"
                print("[mic] restored default input -> \(restored)")
            }
            savedInputDevice = nil
        }
    }

    func resetForDisconnect() {
        pressed = false
        if recording {
            recording = false
            statusUpdate?(false)
        }
        if let saved = savedInputDevice {
            AudioInputSwitcher.setDefaultInput(saved)
            savedInputDevice = nil
        }
        breathing?.stop(turnOff: false)
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
    watcher.breathing = BreathingLight(controller: controller)
    turnOffLight(controller)

    gamepad.rightTrigger.valueChangedHandler = { _, value, _ in
        watcher.handle(value: value)
    }
}

func detach(_ controller: GCController) {
    print("[disconnect] \(controller.vendorName ?? "Unknown")")
    if watcher.controller === controller {
        watcher.resetForDisconnect()
        watcher.breathing = nil
        watcher.bumper = nil
        watcher.controller = nil
    }
}

// MARK: - Status bar

final class StatusBar: NSObject {
    let item: NSStatusItem
    private let statusItem = NSMenuItem(title: "Status: scanning…", action: nil, keyEquivalent: "")
    private let micToggleItem = NSMenuItem(
        title: "Use DualSense Mic",
        action: #selector(toggleDualSenseMic),
        keyEquivalent: ""
    )

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setIcon("gamecontroller")
        let menu = NSMenu()
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(NSMenuItem.separator())

        micToggleItem.target = self
        micToggleItem.state = Preferences.useDualSenseMic ? .on : .off
        menu.addItem(micToggleItem)
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

    @objc private func toggleDualSenseMic() {
        Preferences.useDualSenseMic.toggle()
        micToggleItem.state = Preferences.useDualSenseMic ? .on : .off
        print("[pref] useDualSenseMic = \(Preferences.useDualSenseMic)")
    }

    @objc private func quitApp() {
        if let c = watcher.controller {
            turnOffLight(c)
        }
        NSApp.terminate(nil)
    }

    func setConnected(_ name: String?) {
        statusItem.title = name.map { "Connected: \($0)" } ?? "Waiting for DualSense…"
    }

    func setRecording(_ on: Bool) {
        setIcon(on ? "mic.fill" : "gamecontroller")
    }

    private func setIcon(_ symbol: String) {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "DualSenseWhispr")
        img?.isTemplate = true
        item.button?.image = img
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
