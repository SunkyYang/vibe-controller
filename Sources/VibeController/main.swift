import Foundation
import GameController
import CoreGraphics
import AppKit
import CoreHaptics
import CoreAudio
import AVFoundation
import IOKit.hid

setbuf(stdout, nil)
setbuf(stderr, nil)

// MARK: - Tunables

let TRIGGER_HIGH: Float = 0.6
let TRIGGER_LOW: Float = 0.4

// macOS virtual keycodes (from Carbon/HIToolbox/Events.h)
let kVK_ANSI_Grave:        CGKeyCode = 0x32
let kVK_Return:            CGKeyCode = 0x24
let kVK_Escape:            CGKeyCode = 0x35
let kVK_Tab:               CGKeyCode = 0x30
let kVK_UpArrow:           CGKeyCode = 0x7E
let kVK_DownArrow:         CGKeyCode = 0x7D
let kVK_LeftArrow:         CGKeyCode = 0x7B
let kVK_RightArrow:        CGKeyCode = 0x7C
let kVK_ANSI_LeftBracket:  CGKeyCode = 0x21
let kVK_ANSI_RightBracket: CGKeyCode = 0x1E
let kVK_ANSI_T:            CGKeyCode = 0x11
let kVK_ANSI_D:            CGKeyCode = 0x02
let kVK_ANSI_Z:            CGKeyCode = 0x06
let kVK_ANSI_4:            CGKeyCode = 0x15
let kVK_Delete:            CGKeyCode = 0x33   // Backspace ("Delete" on Mac keyboards)

/// L2 acts as a controller-side "Fn" modifier. When held, other buttons can
/// produce different keystrokes. Currently: L2+○ → Delete.
var l2ModifierHeld: Bool = false

/// Auto-repeat for Delete while L2+○ is held.
var deleteRepeatTimer: DispatchSourceTimer?

func startDeleteRepeat() {
    stopDeleteRepeat()
    tapKey(kVK_Delete)
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 0.4, repeating: 0.045, leeway: .milliseconds(5))
    t.setEventHandler { tapKey(kVK_Delete) }
    t.resume()
    deleteRepeatTimer = t
}

func stopDeleteRepeat() {
    deleteRepeatTimer?.cancel()
    deleteRepeatTimer = nil
}

// MARK: - Accessibility

func checkAccessibility(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

// MARK: - Keyboard sync (catch user-typed Option+`)

/// CGEventTap that listens to global keyDown events and reports when the user
/// pressed Option+\` on the actual keyboard (vs us synthesizing it). Lets the
/// app keep its recording state in sync so the lightbar / haptic feedback
/// don't drift out of phase with OpenWhispr.
final class KeyboardSyncWatcher {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onExternalToggle: (() -> Void)?
    /// Fires on every keyDown, whatever the key. Used to dismiss the button map.
    var onAnyKeyDown: (() -> Void)?

    func start() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info = info else { return Unmanaged.passUnretained(event) }
            if type == .keyDown {
                let kc = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let watcher = Unmanaged<KeyboardSyncWatcher>.fromOpaque(info).takeUnretainedValue()
                DispatchQueue.main.async { watcher.onAnyKeyDown?() }
                if kc == 0x32 && flags.contains(.maskAlternate) {
                    DispatchQueue.main.async {
                        if !selfPostedBacktickInFlight {
                            watcher.onExternalToggle?()
                        }
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: info
        ) else {
            print("[sync] CGEventTap creation failed; keyboard Option+` sync disabled")
            return
        }
        let rl = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rl, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = rl
        print("[sync] keyboard Option+` listener active")
    }

    func stop() {
        if let s = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes)
        }
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
        }
        tap = nil
        runLoopSource = nil
    }
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
        return findDevice(matching: pattern, scope: kAudioDevicePropertyScopeInput)
    }

    static func findOutputDevice(matching pattern: String) -> AudioDeviceID? {
        return findDevice(matching: pattern, scope: kAudioDevicePropertyScopeOutput)
    }

    private static func findDevice(matching pattern: String,
                                   scope: AudioObjectPropertyScope) -> AudioDeviceID? {
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
                mScope: scope,
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

    // MARK: Output

    static var defaultOutputID: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var id = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            system, &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        ) == noErr
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

func tapKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    guard
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    else {
        FileHandle.standardError.write(Data("[error] failed to create CGEvent for key \(keyCode)\n".utf8))
        return
    }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
}

/// Set briefly while we're synthesizing Option+\`, so the global keyboard
/// listener can ignore the event and avoid double-toggling.
var selfPostedBacktickInFlight = false

func tapOptionBacktick() {
    selfPostedBacktickInFlight = true
    tapKey(kVK_ANSI_Grave, flags: .maskAlternate)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
        selfPostedBacktickInFlight = false
    }
}

let ghosttyBundleID = "com.mitchellh.ghostty"

/// Bring Ghostty to the front and call `then` once it is actually frontmost.
/// Subscribes to `didActivateApplicationNotification` so we don't fire keystrokes
/// before the app is ready to receive them. Falls back to a 2s timeout in case
/// the notification never arrives (e.g. activation failed silently).
func activateGhostty(then: @escaping () -> Void) {
    let workspace = NSWorkspace.shared
    if workspace.frontmostApplication?.bundleIdentifier == ghosttyBundleID {
        then()
        return
    }

    var fired = false
    var observer: NSObjectProtocol?
    let fire: () -> Void = {
        if fired { return }
        fired = true
        if let o = observer {
            workspace.notificationCenter.removeObserver(o)
        }
        // Tiny extra beat for the shell prompt to render after focus arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: then)
    }

    observer = workspace.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
    ) { notification in
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        if app?.bundleIdentifier == ghosttyBundleID { fire() }
    }

    // Cold-start timeout. Warm activation usually returns within ~150ms.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { fire() }

    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = ["-a", "Ghostty"]
    do {
        try task.run()
    } catch {
        print("[ghostty] failed to activate: \(error)")
        fire()
    }
}

/// △ action: focus Ghostty, then start `claude` (optionally `--resume`).
func launchClaudeInGhostty(resume: Bool = false) {
    print("[△] launchClaudeInGhostty(resume: \(resume))")
    activateGhostty {
        let cmd = resume ? "claude --resume" : "claude"
        print("[△] typing: \(cmd)")
        typeString(cmd)
        tapKey(kVK_Return)
    }
}

/// Long-press detector for △: short press → `claude`, long press → `claude --resume`.
final class TrianglePress {
    private let threshold: TimeInterval = 0.55
    private var timer: DispatchSourceTimer?
    private var fired = false
    private var armed = false

    func handle(pressed: Bool) {
        if pressed {
            armed = true
            fired = false
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + threshold)
            t.setEventHandler { [weak self] in
                guard let self = self, self.armed else { return }
                self.fired = true
                launchClaudeInGhostty(resume: true)
            }
            t.resume()
            timer = t
        } else {
            timer?.cancel()
            timer = nil
            if armed && !fired {
                launchClaudeInGhostty(resume: false)
            }
            armed = false
        }
    }
}

let trianglePress = TrianglePress()

/// Synthesize a string of characters via per-character Unicode keyboard events.
/// Works for ASCII / ANSI / extended characters without needing per-character
/// virtual-keycode lookup. Note: the receiving app must accept text input (TUI
/// or text field). Bracketed paste-aware shells will see this as raw typing.
func typeString(_ string: String) {
    for scalar in string.unicodeScalars {
        var u = UniChar(scalar.value)
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { continue }
        // Explicitly clear modifier flags. Without this, a recently-posted
        // event with `.maskCommand` (e.g. our own Cmd+T from L2+↑) leaks its
        // flag state into subsequent synthetic events, causing characters like
        // 'd' in "claude" to be interpreted as Cmd+D (split right in Ghostty).
        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
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

    /// One short pulse (the original "bump").
    func bump(intensity: Float = 1.0, sharpness: Float = 0.6, duration: TimeInterval = 0.08) {
        play(events: [
            HapticEvent(duration: duration, intensity: intensity, sharpness: sharpness)
        ])
    }

    /// Recording starts: a soft "da-DUM" — a quick build-up, then a confirming thump.
    func playRecordingStart() {
        play(events: [
            HapticEvent(start: 0.00, duration: 0.04, intensity: 0.45, sharpness: 0.30),
            HapticEvent(start: 0.07, duration: 0.10, intensity: 1.00, sharpness: 0.70),
        ])
    }

    /// Recording stops: "DUM-da" — a strong heavy hit, then a small tail.
    /// Mirror of the start cue (which is "da-DUM"), so beginning and end echo each other.
    func playRecordingStop() {
        play(events: [
            HapticEvent(start: 0.00, duration: 0.10, intensity: 1.00, sharpness: 0.70),
            HapticEvent(start: 0.14, duration: 0.05, intensity: 0.55, sharpness: 0.30),
        ])
    }

    /// "ka-cha" — a short bright peak followed by a low thump. Reserved for later tool/agent
    /// completion signals once Claude state mirroring is wired in.
    func playToolDone() {
        play(events: [
            HapticEvent(start: 0.00, duration: 0.03, intensity: 0.85, sharpness: 0.90),
            HapticEvent(start: 0.06, duration: 0.10, intensity: 0.70, sharpness: 0.20),
        ])
    }

    /// Three rapid sharp pulses for errors.
    func playError() {
        play(events: [
            HapticEvent(start: 0.00, duration: 0.04, intensity: 1.00, sharpness: 1.00),
            HapticEvent(start: 0.07, duration: 0.04, intensity: 1.00, sharpness: 1.00),
            HapticEvent(start: 0.14, duration: 0.04, intensity: 1.00, sharpness: 1.00),
        ])
    }

    private struct HapticEvent {
        var start: TimeInterval = 0
        var duration: TimeInterval
        var intensity: Float
        var sharpness: Float

        init(start: TimeInterval = 0, duration: TimeInterval, intensity: Float, sharpness: Float) {
            self.start = start
            self.duration = duration
            self.intensity = intensity
            self.sharpness = sharpness
        }
    }

    private func play(events: [HapticEvent]) {
        guard let engine = engine else { return }
        let chEvents = events.map { e in
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: e.intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: e.sharpness),
                ],
                relativeTime: e.start,
                duration: e.duration
            )
        }
        do {
            let pattern = try CHHapticPattern(events: chEvents, parameters: [])
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

/// Choreographs the DualSense light bar across three phases:
///   - sweepIn:   white→blue ramp-up over ~0.4s, gamma-eased
///   - breathing: blue 3s gamma-eased sine, indefinitely
///   - sweepOut:  blue→amber→off ramp-down over ~0.4s
/// Calls to `start()` / `stop()` are non-blocking; phases run on a 30fps timer.
final class BreathingLight {
    private weak var controller: GCController?
    private var timer: DispatchSourceTimer?

    private let breathPeriod: TimeInterval = 3.0
    private let breathMin: Double = 0.05
    private let breathMax: Double = 1.0

    /// 0..1, modulates breathing brightness while recording. Set by an
    /// outside MicLevelMonitor so the bar reacts to voice volume.
    var currentMicLevel: Float = 0

    private let sweepInDuration: TimeInterval = 0.4
    private let sweepOutDuration: TimeInterval = 0.4

    private enum Phase {
        case idle
        case sweepIn(start: Date)
        case breathing(start: Date)
        case sweepOut(start: Date)
    }

    private var phase: Phase = .idle

    init(controller: GCController) {
        self.controller = controller
    }

    func start() {
        cancelTimer()
        phase = .sweepIn(start: Date())
        runTimer()
    }

    func stop(turnOff: Bool = true) {
        cancelTimer()
        if turnOff {
            // Animated fade-out instead of an abrupt blackout.
            phase = .sweepOut(start: Date())
            runTimer()
        } else {
            phase = .idle
            turnOffLight(controller)
        }
    }

    private func runTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))  // ~30 fps
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let light = controller?.light else { return }
        switch phase {
        case .idle:
            cancelTimer()
            return

        case .sweepIn(let start):
            let progress = min(1.0, Date().timeIntervalSince(start) / sweepInDuration)
            // White→blue: red/green fade out, blue stays on; brightness ramps in.
            let eased = pow(progress, 1.6)
            let brightness = Float(eased)
            light.color = GCColor(
                red:   Float(1.0 - eased) * brightness,
                green: Float(0.7 - 0.3 * eased) * brightness,
                blue:  brightness
            )
            if progress >= 1.0 {
                phase = .breathing(start: Date())
            }

        case .breathing(let start):
            let elapsed = Date().timeIntervalSince(start)
            let p = elapsed.truncatingRemainder(dividingBy: breathPeriod) / breathPeriod
            let raw = (1.0 - cos(2.0 * .pi * p)) / 2.0
            let gamma = pow(raw, 2.2)
            let baseBrightness = breathMin + (breathMax - breathMin) * gamma
            // Mix: 10% breathing rhythm baseline + 90% mic level. The bar
            // basically *is* the voice — breathing only kicks in to give a
            // small living-pulse when silent.
            let mic = Double(min(1, max(0, currentMicLevel)))
            let mixed = baseBrightness * 0.1 + mic * 0.9
            let brightness = Float(min(breathMax, max(breathMin, mixed)))
            // Color ramps from deep blue (low) to electric white-blue (high) so
            // loud sound visibly punches the eye, not just dims/brightens.
            let t = brightness
            light.color = GCColor(
                red:   0.25 * t * t,                        // only enters at high brightness
                green: (0.4 + 0.4 * t) * t,                 // 0.4 floor, climbs to 0.8
                blue:  t                                    // full blue scale
            )

        case .sweepOut(let start):
            let progress = min(1.0, Date().timeIntervalSince(start) / sweepOutDuration)
            let eased = pow(progress, 1.6)
            // Blue→amber→off: cross-fade hue while brightness drops to zero.
            let blueComponent = Float(1.0 - eased)
            let amberR = Float(eased)
            let amberG = Float(0.4 * eased)
            let brightness = Float(1.0 - eased)
            light.color = GCColor(
                red:   amberR * brightness,
                green: (0.4 * blueComponent + amberG) * brightness,
                blue:  blueComponent * brightness
            )
            if progress >= 1.0 {
                turnOffLight(controller)
                phase = .idle
                cancelTimer()
            }
        }
    }
}

// MARK: - Adaptive trigger (USB only, IOHID output report)

/// Drives the DualSense's R2 adaptive-trigger motors directly via an IOHID
/// output report. Supports both transports:
///   - USB:       report 0x02 with 47-byte payload (kIOHIDMaxOutputReportSize=48)
///   - Bluetooth: report 0x31 with 78-byte payload (size 79), trailer is
///                CRC32 over [0xa2, 0x31, payload[0..73]]
///
/// Mode 0x02 = "weapon": resistance ramps up between start..end, then
/// snaps loose past end (the gun-trigger feel).
final class DualSenseTriggerEffect {
    private enum Transport { case usb, bluetooth }

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var transport: Transport = .usb
    private var btSeqTag: UInt8 = 0

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x054C,    // Sony Interactive Entertainment
            kIOHIDProductIDKey as String: 0x0CE6    // DualSense
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            print("[trigger] IOHIDManagerOpen failed: \(String(format: "0x%x", r))")
        }
    }

    /// Locate any DualSense (USB or Bluetooth). Returns true on success.
    @discardableResult
    func reacquire() -> Bool {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            print("[trigger] reacquire: copy returned nil")
            device = nil
            return false
        }
        print("[trigger] reacquire: \(set.count) DualSense IOHID device(s) visible")
        for d in set {
            let size = (IOHIDDeviceGetProperty(d, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) ?? -1
            let tx = IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String ?? "?"
            print("[trigger]   device: outputSize=\(size) transport=\(tx)")
        }
        // Prefer USB (smaller report, no CRC math).
        if let usb = set.first(where: { d in
            (IOHIDDeviceGetProperty(d, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) == 48
        }) {
            device = usb
            transport = .usb
            print("[trigger] using USB IOHID for adaptive trigger")
            return true
        }
        if let bt = set.first(where: { d in
            let s = IOHIDDeviceGetProperty(d, kIOHIDMaxOutputReportSizeKey as CFString) as? Int
            return s == 79 || s == 78
        }) {
            device = bt
            transport = .bluetooth
            print("[trigger] using Bluetooth IOHID for adaptive trigger (CRC32 enabled)")
            return true
        }
        print("[trigger] no usable DualSense IOHID device")
        return false
    }

    /// R2 two-stage feel. start/end are 0..9 positions across the trigger pull;
    /// strength 0..255 controls the resistance peak.
    func setWeaponMode(start: UInt8 = 2, end: UInt8 = 6, strength: UInt8 = 255) {
        sendWeapon(mode: 0x02, start: start, end: end, strength: strength, label: "weapon")
    }

    /// Release any resistance.
    func reset() {
        sendWeapon(mode: 0x00, start: 0, end: 0, strength: 0, label: "reset")
    }

    /// Build the 47-byte common payload. Same layout for USB and BT.
    private func commonPayload(mode: UInt8, start: UInt8, end: UInt8, strength: UInt8) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 47)
        payload[0] = 0xFF       // valid_flag0
        payload[1] = 0x00       // valid_flag1 (leave lightbar / LEDs alone)
        payload[2] = 0          // rumble right
        payload[3] = 0          // rumble left
        payload[10] = mode      // right trigger mode
        payload[11] = start
        payload[12] = end
        payload[13] = strength
        return payload
    }

    private func sendWeapon(mode: UInt8, start: UInt8, end: UInt8, strength: UInt8, label: String) {
        guard let device = device else { return }
        let common = commonPayload(mode: mode, start: start, end: end, strength: strength)
        switch transport {
        case .usb:
            sendUSB(device: device, common: common, label: label)
        case .bluetooth:
            sendBT(device: device, common: common, label: label)
        }
    }

    private func sendUSB(device: IOHIDDevice, common: [UInt8], label: String) {
        let result = common.withUnsafeBufferPointer { buf -> IOReturn in
            guard let base = buf.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(0x02),
                base,
                CFIndex(buf.count)
            )
        }
        if result != kIOReturnSuccess {
            print("[trigger] usb SetReport(\(label)) failed: \(String(format: "0x%x", result))")
        }
    }

    private func sendBT(device: IOHIDDevice, common: [UInt8], label: String) {
        // BT layout: seq_tag, tag (0x10), 47-byte common, 24 bytes reserved, CRC32 (4 bytes).
        // Total payload = 78 bytes.
        var payload = [UInt8](repeating: 0, count: 78)
        btSeqTag = (btSeqTag &+ 1) & 0x0F
        payload[0] = (btSeqTag << 4) | 0x00     // sequence in upper nibble
        payload[1] = 0x10                       // fixed tag
        for (i, b) in common.enumerated() {
            payload[2 + i] = b
        }
        // payload[49..72] reserved (zeroed)
        // CRC32 over [0xa2, 0x31, payload[0..73]]
        var crcInput: [UInt8] = [0xa2, 0x31]
        crcInput.append(contentsOf: payload[0..<74])
        let crc = Self.crc32(crcInput)
        payload[74] = UInt8(crc & 0xFF)
        payload[75] = UInt8((crc >> 8) & 0xFF)
        payload[76] = UInt8((crc >> 16) & 0xFF)
        payload[77] = UInt8((crc >> 24) & 0xFF)
        let result = payload.withUnsafeBufferPointer { buf -> IOReturn in
            guard let base = buf.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(0x31),
                base,
                CFIndex(buf.count)
            )
        }
        if result != kIOReturnSuccess {
            print("[trigger] bt SetReport(\(label)) failed: \(String(format: "0x%x", result))")
        }
    }

    /// Standard CRC-32 (IEEE 802.3, reversed poly 0xEDB88320), seed 0xFFFFFFFF, output xor 0xFFFFFFFF.
    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? ((crc >> 1) ^ 0xEDB88320) : (crc >> 1)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Claude Code state mirroring

/// Watches `~/.vibe-controller/state` (written by Claude Code hooks) and
/// reports state changes on the main queue. State strings are the literal
/// argument passed to scripts/claude-state-hook.sh — recommend the set
/// {thinking, tool_use, idle, notification}.
final class ClaudeStateWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private(set) var currentState: String = "idle"
    private var enabled = true
    var stateChangedHandler: ((String) -> Void)?

    let statePath: String

    init(path: String) {
        self.statePath = path
    }

    func start() {
        let dir = (statePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: statePath) {
            FileManager.default.createFile(atPath: statePath, contents: Data("idle\n".utf8))
        }
        attachSource()
        readState(announce: true)
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Used while recording: don't let Claude state writes fight the breathing light.
    func suspend() { enabled = false }

    /// Resume + force-reapply the current state to the light.
    func resume() {
        enabled = true
        if let h = stateChangedHandler { h(currentState) }
    }

    private func attachSource() {
        fd = open(statePath, O_EVTONLY)
        guard fd >= 0 else {
            print("[claude-state] open failed for \(statePath)")
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        s.setEventHandler { [weak self] in
            guard let self = self, let src = self.source else { return }
            let mask = src.data
            if mask.contains(.delete) || mask.contains(.rename) {
                src.cancel()
                self.source = nil
                // hook uses atomic mv → reopen on the new inode
                self.attachSource()
            }
            self.readState(announce: false)
        }
        s.setCancelHandler { [weak self] in
            if let f = self?.fd, f >= 0 {
                close(f)
                self?.fd = -1
            }
        }
        s.resume()
        source = s
    }

    private func readState(announce: Bool) {
        guard let content = try? String(contentsOfFile: statePath, encoding: .utf8) else { return }
        let state = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isEmpty else { return }
        if state != currentState || announce {
            currentState = state
            print("[claude-state] -> \(state)")
            if enabled, let h = stateChangedHandler {
                h(state)
            }
        }
    }
}

// MARK: - Microphone level monitor

/// Taps the system default audio input and reports a 0..1 normalized RMS
/// level on the main queue. Used to modulate the light bar brightness so
/// it visibly reacts to your voice while recording.
final class MicLevelMonitor {
    private let engine = AVAudioEngine()
    private var running = false
    var levelHandler: ((Float) -> Void)?

    func start() {
        guard !running else { return }
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            print("[mic-level] input format has no channels; skipping")
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            var sum: Float = 0
            for i in 0..<frameCount {
                let s = channelData[i]
                sum += s * s
            }
            let rms = sqrt(sum / Float(frameCount))
            // Noise gate at RMS 0.005 (~ -46 dB), then aggressively boost so
            // normal speaking volume drives the bar near 1.0 quickly.
            let normalized: Float
            if rms < 0.005 {
                normalized = 0
            } else {
                let boosted = min(1.0, (rms - 0.005) * 18.0)
                normalized = pow(boosted, 0.4)
            }
            DispatchQueue.main.async {
                self?.levelHandler?(normalized)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            print("[mic-level] engine start failed: \(error)")
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}

// MARK: - Touchpad input (mouse + click)

/// DualSense touchpad behavior:
///  - Single-finger movement → relative cursor motion (always in mouse mode)
///  - Touchpad physically clicked → left mouse button (down on click,
///    up on release). Click + finger still = single click; click + drag =
///    proper drag.
final class TouchpadInput {
    private var prevFingerX: Float = 0
    private var prevFingerY: Float = 0
    private var hasFinger = false
    private var mouseButtonHeld = false

    // Wider zero-band: GameController reports non-zero noise (~0.01-0.04)
    // when the finger is just resting on the pad. Anything inside this is "no touch".
    private let zeroEps: Float = 0.05
    // Per-sample movement threshold: tiny axis jitter doesn't move the cursor.
    // Touchpad axis range is -1..1 over ~52mm, so 0.004 ≈ 0.2mm of finger motion.
    private let minDelta: Float = 0.004
    private let mouseSensitivity: CGFloat = 350

    func attach(touchpadPrimary pad: GCControllerDirectionPad,
                touchpadButton button: GCControllerButtonInput?)
    {
        pad.valueChangedHandler = { [weak self] _, x, y in
            self?.handleAxis(x: x, y: y)
        }
        button?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleClick(pressed: pressed)
        }
    }

    private func handleAxis(x: Float, y: Float) {
        let released = abs(x) < zeroEps && abs(y) < zeroEps
        if released {
            hasFinger = false
            return
        }
        if !hasFinger {
            hasFinger = true
            prevFingerX = x
            prevFingerY = y
            return
        }
        let dx = x - prevFingerX
        let dy = y - prevFingerY
        // Skip motion below the per-sample noise floor; both axes must be quiet.
        if abs(dx) < minDelta && abs(dy) < minDelta {
            return
        }
        prevFingerX = x
        prevFingerY = y
        moveCursor(dx: dx, dy: dy)
    }

    private func handleClick(pressed: Bool) {
        mouseButtonHeld = pressed
        postMouseButton(down: pressed)
    }

    private func currentCursor() -> CGPoint {
        return CGEvent(source: nil)?.location ?? .zero
    }

    private func moveCursor(dx: Float, dy: Float) {
        let cur = currentCursor()
        // Touchpad y axis: positive = up; screen y axis: positive = down. Invert.
        let nx = cur.x + CGFloat(dx) * mouseSensitivity
        let ny = cur.y - CGFloat(dy) * mouseSensitivity
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseButtonHeld ? .leftMouseDragged : .mouseMoved,
            mouseCursorPosition: CGPoint(x: nx, y: ny),
            mouseButton: .left
        )
        event?.post(tap: .cgSessionEventTap)
    }

    private func postMouseButton(down: Bool) {
        let cur = currentCursor()
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: down ? .leftMouseDown : .leftMouseUp,
            mouseCursorPosition: cur,
            mouseButton: .left
        )
        event?.post(tap: .cgSessionEventTap)
    }
}

// MARK: - D-Pad auto-repeat

/// Holds-down behavior for the D-Pad: pressing fires a key immediately, then
/// after a short delay starts repeating it at a steady rate. Mirrors macOS's
/// own keyboard repeat (initial pause + fast cadence). Only one key repeats
/// at a time (last pressed wins).
final class DPadAutoRepeat {
    private var timer: DispatchSourceTimer?
    private var currentKey: CGKeyCode?
    private let initialDelay: TimeInterval = 0.4
    private let repeatInterval: TimeInterval = 0.045

    func attach(_ dpad: GCControllerDirectionPad) {
        // L2 held → one-shot Ghostty actions instead of arrow auto-repeat.
        bind(dpad.up,    key: kVK_UpArrow,
             l2Override: { print("[L2+↑] Cmd+T new tab"); tapKey(kVK_ANSI_T, flags: .maskCommand) })
        bind(dpad.down,  key: kVK_DownArrow,
             l2Override: { print("[L2+↓] /new"); typeString("/new"); tapKey(kVK_Return) })
        bind(dpad.left,  key: kVK_LeftArrow)
        bind(dpad.right, key: kVK_RightArrow,
             l2Override: { print("[L2+→] Cmd+D split right"); tapKey(kVK_ANSI_D, flags: .maskCommand) })
    }

    private func bind(_ button: GCControllerButtonInput,
                      key: CGKeyCode,
                      l2Override: (() -> Void)? = nil) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard let self = self else { return }
            if pressed {
                if l2ModifierHeld, let override = l2Override {
                    override()
                    return
                }
                self.startRepeat(for: key)
            } else if self.currentKey == key {
                self.stopRepeat()
            }
        }
    }

    private func startRepeat(for key: CGKeyCode) {
        stopRepeat()
        currentKey = key
        // Fire once immediately for instant feedback.
        tapKey(key)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + initialDelay, repeating: repeatInterval, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in
            guard let self = self, let k = self.currentKey else { return }
            tapKey(k)
        }
        t.resume()
        timer = t
    }

    private func stopRepeat() {
        timer?.cancel()
        timer = nil
        currentKey = nil
    }

    func stop() {
        stopRepeat()
    }
}

// MARK: - Right stick → mouse cursor

/// Drives the cursor with the left thumbstick. Gain follows a square curve
/// past the dead zone so weak pushes give precise micro-motion and full
/// deflection ramps to a fast traversal speed. While `mouseHeld` is true
/// (set by the touchpad click handler), motion is emitted as
/// leftMouseDragged so OS drag tracking works.
///
/// Motion is integrated over real elapsed time rather than counted per
/// tick, and the tick rate is ~120Hz. A fixed 16ms tick is ~62.5Hz, which
/// on a 60Hz display beats against the refresh rate: some refreshes get
/// two position updates and some get none, roughly 2.5 times a second.
/// That reads as stutter on an external 60Hz panel while looking fine on
/// the 120Hz built-in display. Ticking faster than any attached display
/// and scaling by dt means every refresh picks up a fresh, correctly
/// scaled position whatever the refresh rate.
final class StickMouseMover {
    private var timer: DispatchSourceTimer?
    private var currentX: Float = 0
    private var currentY: Float = 0
    private var lastTick: DispatchTime?
    private let deadZone: Float = 0.15
    /// Pixels per second at full deflection. Matches the old feel: the
    /// previous code moved 60px per tick on a 60fps timer.
    private let maxSpeed: CGFloat = 3600
    /// Ignore absurd gaps (app suspended, display sleep) so the cursor never
    /// teleports on the first tick after a stall.
    private let maxDelta: CFTimeInterval = 0.05
    var mouseHeld: Bool = false

    func attach(_ stick: GCControllerDirectionPad) {
        stick.valueChangedHandler = { [weak self] _, x, y in
            self?.update(x: x, y: y)
        }
    }

    /// Axis feed in GameController convention (-1...1, y up). Used by both
    /// the GameController handler and the raw IOHID path.
    func update(x: Float, y: Float) {
        currentX = x
        currentY = y
    }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        currentX = 0
        currentY = 0
        lastTick = nil
    }

    private func tick() {
        let now = DispatchTime.now()
        let previous = lastTick
        lastTick = now

        let x = currentX
        let y = currentY
        let mag = sqrt(x * x + y * y)
        // Resting: keep the clock fresh so the first tick of the next push
        // integrates one frame, not however long the stick sat centred.
        guard mag > deadZone else { return }
        guard let previous = previous else { return }

        let dt = min(
            maxDelta,
            CFTimeInterval(now.uptimeNanoseconds &- previous.uptimeNanoseconds) / 1_000_000_000
        )
        guard dt > 0 else { return }

        let normalized = (mag - deadZone) / (1 - deadZone)
        let curved = normalized * normalized
        let distance = CGFloat(curved) * maxSpeed * CGFloat(dt)
        let dx = CGFloat(x / mag) * distance
        let dy = CGFloat(-y / mag) * distance              // y up = screen y up
        moveMouse(dx: dx, dy: dy)
    }

    private func moveMouse(dx: CGFloat, dy: CGFloat) {
        let cur = CGEvent(source: nil)?.location ?? .zero
        let nx = cur.x + dx
        let ny = cur.y + dy
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseHeld ? .leftMouseDragged : .mouseMoved,
            mouseCursorPosition: CGPoint(x: nx, y: ny),
            mouseButton: .left
        )
        event?.post(tap: .cgSessionEventTap)
    }
}

// MARK: - Left stick → scroll wheel

/// Reads the left thumbstick's Y axis on a 30 fps timer; while held outside
/// a small dead zone, posts a synthesized scroll-wheel event so you can
/// scroll Claude Code / terminal output without leaving the controller.
final class StickScroller {
    private var timer: DispatchSourceTimer?
    private var currentY: Float = 0
    private let deadZone: Float = 0.18
    private let maxStep: Int32 = 70  // pixels per tick at full deflection

    func attach(_ stick: GCControllerDirectionPad) {
        stick.valueChangedHandler = { [weak self] _, _, y in
            self?.update(y: y)
        }
    }

    func update(y: Float) {
        currentY = y
    }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))   // ~30 fps
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        currentY = 0
    }

    private func tick() {
        let y = currentY
        let absY = abs(y)
        guard absY > deadZone else { return }
        let normalized = (absY - deadZone) / (1.0 - deadZone)
        let curved = normalized * normalized                      // ease-in
        let step = Int32(curved * Float(maxStep)) * (y > 0 ? 1 : -1)
        guard step != 0 else { return }
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: step,
            wheel2: 0,
            wheel3: 0
        )
        event?.post(tap: .cgSessionEventTap)
    }
}

// MARK: - Battery monitor

/// Polls the controller battery once a minute; pushes "Battery: NN%" to the
/// menu bar status line and fires a haptic + log when the device drops below
/// 20% on its own power.
final class BatteryMonitor {
    weak var controller: GCController?
    var bumper: HapticBumper?
    var statusUpdate: ((String?) -> Void)?

    private var timer: DispatchSourceTimer?
    private var lowAlertFired = false

    init(controller: GCController) {
        self.controller = controller
    }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(2), repeating: .seconds(60), leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        tick()   // immediate first read
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let battery = controller?.battery else {
            statusUpdate?(nil)
            return
        }
        let pct = Int((battery.batteryLevel * 100).rounded())
        let suffix: String
        switch battery.batteryState {
        case .charging:    suffix = " ⚡"
        case .full:        suffix = " ⚡✓"
        case .discharging: suffix = ""
        default:           suffix = " ?"
        }
        statusUpdate?("Battery: \(pct)%\(suffix)")

        let isLow = battery.batteryLevel > 0 && battery.batteryLevel < 0.20
        let charging = (battery.batteryState == .charging || battery.batteryState == .full)
        if isLow && !charging && !lowAlertFired {
            lowAlertFired = true
            print("[battery] low (\(pct)%) — please charge")
            bumper?.bump(intensity: 1.0, sharpness: 0.9, duration: 0.15)
        } else if !isLow || charging {
            lowAlertFired = false
        }
    }
}

// MARK: - Trigger watcher

final class TriggerWatcher {
    weak var controller: GCController?
    var bumper: HapticBumper?
    var breathing: BreathingLight?
    var touchpad: TouchpadInput?
    var micMonitor: MicLevelMonitor?
    var claudeState: ClaudeStateWatcher?
    var trigger: DualSenseTriggerEffect?
    var rawSticks: DualSenseRawSticks?
    var stickScroller: StickScroller?
    var stickMouse: StickMouseMover?
    var dpadRepeat: DPadAutoRepeat?
    var battery: BatteryMonitor?
    var statusUpdate: ((Bool) -> Void)?

    private var pressed = false
    private(set) var recording = false
    private var savedInputDevice: AudioDeviceID?
    /// Captured at recording start: was L2 held? If yes, paste should land in
    /// Ghostty regardless of where focus was at trigger time.
    private var targetGhostty = false

    func handle(value: Float) {
        if !pressed && value >= TRIGGER_HIGH {
            pressed = true
            recording.toggle()
            statusUpdate?(recording)
            if recording {
                targetGhostty = l2ModifierHeld
                claudeState?.suspend()
                bumper?.playRecordingStart()
                breathing?.start()
                startRecording()
            } else {
                bumper?.playRecordingStop()
                breathing?.stop()
                stopRecording()
                // After ~0.5s the sweep-out finishes; let claude state retake the bar.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.claudeState?.resume()
                }
            }
        } else if pressed && value <= TRIGGER_LOW {
            pressed = false
        }
    }

    private func startRecording() {
        let begin: () -> Void = { [weak self] in
            guard let self = self else { return }
            if Preferences.useDualSenseMic,
               let ds = AudioInputSwitcher.findInputDevice(matching: "DualSense") {
                self.savedInputDevice = AudioInputSwitcher.defaultInputID
                AudioInputSwitcher.setDefaultInput(ds)
                let dsName = AudioInputSwitcher.name(of: ds) ?? "DualSense"
                print("[mic] switched default input -> \(dsName)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.startMicMonitor()
                    self?.fireStartHotkey()
                }
            } else {
                if Preferences.useDualSenseMic {
                    print("[mic] DualSense audio device not found; using current default")
                }
                self.startMicMonitor()
                self.fireStartHotkey()
            }
        }
        if targetGhostty {
            print("[R2] L2-held → routing recording paste to Ghostty")
            activateGhostty(then: begin)
        } else {
            begin()
        }
    }

    private func startMicMonitor() {
        if micMonitor == nil {
            micMonitor = MicLevelMonitor()
        }
        micMonitor?.levelHandler = { [weak self] level in
            self?.breathing?.currentMicLevel = level
        }
        micMonitor?.start()
    }

    private func fireStartHotkey() {
        print("[R2] press -> recording=true (OpenWhispr mic = \(currentDefaultInputName()))")
        tapOptionBacktick()
    }

    private func stopRecording() {
        let finish: () -> Void = { [weak self] in
            guard let self = self else { return }
            print("[R2] press -> recording=false")
            tapOptionBacktick()
            self.micMonitor?.stop()
            self.breathing?.currentMicLevel = 0
            if let saved = self.savedInputDevice {
                // Give OpenWhispr a beat to release its in-flight capture stream
                // before we yank the default out from under it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    AudioInputSwitcher.setDefaultInput(saved)
                    let restored = AudioInputSwitcher.name(of: saved) ?? "id=\(saved)"
                    print("[mic] restored default input -> \(restored)")
                }
                self.savedInputDevice = nil
            }
            self.targetGhostty = false
        }
        if targetGhostty {
            // Re-assert focus before OpenWhispr's paste fires.
            activateGhostty(then: finish)
        } else {
            finish()
        }
    }

    /// Called by KeyboardSyncWatcher when the user pressed Option+` on the
    /// actual keyboard. Mirrors the hotkey-driven side of `handle(value:)`
    /// without re-posting the keystroke or fighting OpenWhispr.
    func handleExternalToggle() {
        recording.toggle()
        statusUpdate?(recording)
        if recording {
            claudeState?.suspend()
            bumper?.playRecordingStart()
            breathing?.start()
            if micMonitor == nil { micMonitor = MicLevelMonitor() }
            micMonitor?.levelHandler = { [weak self] level in
                self?.breathing?.currentMicLevel = level
            }
            micMonitor?.start()
        } else {
            bumper?.playRecordingStop()
            breathing?.stop()
            micMonitor?.stop()
            breathing?.currentMicLevel = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.claudeState?.resume()
            }
        }
        print("[sync] external Option+` -> recording=\(recording)")
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

// MARK: - Claude state → light bar mapping

/// Render the current Claude lifecycle state on the controller's light bar.
/// Suppressed while recording so the breathing/voice-reactive bar wins.
func applyClaudeStateLight(_ state: String) {
    guard let light = watcher.controller?.light else { return }
    if watcher.recording { return }
    switch state {
    case "thinking", "user_prompt":
        light.color = GCColor(red: 0.0, green: 0.15, blue: 0.55)   // soft blue
    case "tool_use":
        light.color = GCColor(red: 0.45, green: 0.0, blue: 0.75)   // purple
    case "notification", "warning":
        light.color = GCColor(red: 0.9, green: 0.4, blue: 0.0)     // amber
    case "error":
        light.color = GCColor(red: 0.9, green: 0.0, blue: 0.0)     // red
        watcher.bumper?.playError()
    case "idle", "stop":
        turnOffLight(watcher.controller)
    default:
        turnOffLight(watcher.controller)
    }
}

/// Physical confirmation that the L2 "Fn" layer is engaged: a crisp tick plus
/// an amber light bar. Without it there is no way to tell a half-pulled L2
/// from a held one, and the combo silently comes out as the base binding.
///
/// Skipped while recording — the voice-reactive bar repaints at 30fps and
/// would fight us for the light anyway.
func setModifierLayerFeedback(_ engaged: Bool) {
    guard !watcher.recording else { return }
    if engaged {
        watcher.bumper?.bump(intensity: 0.35, sharpness: 0.9, duration: 0.03)
        watcher.controller?.light?.color = GCColor(red: 0.85, green: 0.35, blue: 0.0)
    } else {
        applyClaudeStateLight(watcher.claudeState?.currentState ?? "idle")
    }
}

func postMouseButton(_ button: CGMouseButton, down: Bool) {
    let type: CGEventType
    switch button {
    case .right: type = down ? .rightMouseDown : .rightMouseUp
    default:     type = down ? .leftMouseDown : .leftMouseUp
    }
    let cur = CGEvent(source: nil)?.location ?? .zero
    let event = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: cur,
        mouseButton: button
    )
    event?.post(tap: .cgSessionEventTap)
}

// MARK: - Raw stick input (IOHID, bypasses gamecontrollerd)

/// Feeds the thumbsticks straight from the DualSense's HID input reports.
///
/// `gamecontrollerd` (macOS 26.5) forwards stick samples with periodic
/// 200-700ms stalls even though the device itself streams a clean 4ms report
/// cadence over the very same cable (see docs/pitfalls.md). Reading the raw
/// report here gives the cursor timer the device's own cadence. Buttons,
/// haptics and the light bar stay on GameController; those are discrete and
/// do not care about a stalled sample.
///
/// Report layouts (first byte is the report ID as delivered by IOKit):
///   - USB       0x01: LX LY RX RY at bytes 1..4
///   - Bluetooth 0x31: one extra sequence byte, so LX LY RX RY at bytes 2..5
///   - Bluetooth 0x01: the "simple" report before full mode; same as USB
/// Axes are 0..255 with 0x80 centred; HID Y grows downward, GameController
/// Y grows upward, so Y is flipped to keep `StickMouseMover` unchanged.
final class DualSenseRawSticks {
    private let manager: IOHIDManager
    private var buffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
    private var activeDevices = 0
    private let bufferSize = 128

    /// Called on the main queue with GameController-convention axes (-1...1).
    var onLeft: ((Float, Float) -> Void)?
    var onRight: ((Float, Float) -> Void)?
    /// Fired on the main queue whenever a DualSense HID device appears or
    /// goes away, so the stick wiring can be re-decided after the fact.
    var onDevicesChanged: (() -> Void)?

    var isActive: Bool { activeDevices > 0 }

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x054C,
            kIOHIDProductIDKey as String: 0x0CE6
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<DualSenseRawSticks>.fromOpaque(ctx).takeUnretainedValue().add(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<DualSenseRawSticks>.fromOpaque(ctx).takeUnretainedValue().remove(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            print("[rawstick] IOHIDManagerOpen failed: \(String(format: "0x%x", r))")
        }
    }

    private func add(_ device: IOHIDDevice) {
        guard buffers[device] == nil else { return }
        let tx = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        buffers[device] = buf
        activeDevices = buffers.count
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, bufferSize, { ctx, _, _, _, id, report, length in
            guard let ctx = ctx else { return }
            Unmanaged<DualSenseRawSticks>.fromOpaque(ctx).takeUnretainedValue()
                .handle(id: id, report: report, length: length)
        }, ctx)
        print("[rawstick] reading \(tx) input reports directly")
        onDevicesChanged?()
    }

    private func remove(_ device: IOHIDDevice) {
        guard let buf = buffers.removeValue(forKey: device) else { return }
        activeDevices = buffers.count
        // IOKit has already torn the callback down with the device; the
        // buffer is ours to free.
        buf.deallocate()
        print("[rawstick] device gone (\(activeDevices) left)")
        onDevicesChanged?()
    }

    /// Hot path: a few hundred calls a second. Parse four bytes, nothing else.
    private func handle(id: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let base: Int
        switch id {
        case 0x01: base = 1
        case 0x31: base = 2
        default: return
        }
        guard length >= base + 4 else { return }
        @inline(__always) func axis(_ v: UInt8) -> Float {
            max(-1, min(1, (Float(v) - 128) / 127))
        }
        onLeft?(axis(report[base]), -axis(report[base + 1]))
        onRight?(axis(report[base + 2]), -axis(report[base + 3]))
    }
}

// MARK: - Connection

/// Decide where the thumbsticks get their samples from. Idempotent; called
/// from attach() and again whenever the raw HID device set changes, because
/// at launch IOKit's matching callback can land after the controller has
/// already been attached through GameController.
func wireSticks() {
    guard let gamepad = watcher.controller?.extendedGamepad,
          let mouseMover = watcher.stickMouse,
          let scroller = watcher.stickScroller else { return }
    if let raw = watcher.rawSticks, raw.isActive {
        gamepad.leftThumbstick.valueChangedHandler = nil
        gamepad.rightThumbstick.valueChangedHandler = nil
        raw.onLeft = { [weak mouseMover] x, y in mouseMover?.update(x: x, y: y) }
        raw.onRight = { [weak scroller] _, y in scroller?.update(y: y) }
        print("[rawstick] sticks fed from IOHID, GameController stick handlers skipped")
    } else {
        watcher.rawSticks?.onLeft = nil
        watcher.rawSticks?.onRight = nil
        mouseMover.attach(gamepad.leftThumbstick)
        scroller.attach(gamepad.rightThumbstick)
        print("[rawstick] no DualSense HID device; sticks fed from GameController")
    }
}

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
    // The DualSense touchpad as a mouse drifts noticeably under capacitive noise.
    // We disable it on purpose; right stick + buttonX (□) replace it cleanly.

    // Adaptive trigger over IOHID. USB sends report 0x02; Bluetooth sends
    // report 0x31 with CRC32 trailer.
    if let trig = watcher.trigger, trig.reacquire() {
        trig.setWeaponMode()
    }

    // Show whatever Claude state is current (no-op if state is "idle").
    if let state = watcher.claudeState?.currentState {
        applyClaudeStateLight(state)
    } else {
        turnOffLight(controller)
    }

    gamepad.rightTrigger.valueChangedHandler = { _, value, _ in
        watcher.handle(value: value)
    }

    // L2 as a controller-side modifier ("Fn" on the gamepad). Holding it
    // changes the meaning of other buttons. Confirmed by tick + amber bar so
    // the layer is never silently un-engaged.
    gamepad.leftTrigger.pressedChangedHandler = { _, _, pressed in
        l2ModifierHeld = pressed
        setModifierLayerFeedback(pressed)
    }

    // Button -> keyboard mappings (PS5 face buttons + D-Pad).
    // GCExtendedGamepad uses Xbox naming, so:
    //   buttonA = Cross (✕ / "X key" in PS5 lingo)
    //   buttonB = Circle (○)
    //   buttonX = Square (□)
    //   buttonY = Triangle (△)
    gamepad.buttonA.pressedChangedHandler = { _, _, pressed in
        if pressed {
            tapKey(l2ModifierHeld ? kVK_ANSI_Z : kVK_Return,
                   flags: l2ModifierHeld ? .maskCommand : [])
        }
    }
    gamepad.buttonB.pressedChangedHandler = { _, _, pressed in
        if pressed {
            if l2ModifierHeld {
                startDeleteRepeat()
            } else {
                tapKey(kVK_Escape)
            }
        } else {
            // Always stop the delete repeat on release; harmless when in Esc mode.
            stopDeleteRepeat()
        }
    }
    // □ is the right mouse button. Left click moved to the touchpad click
    // below, which is the biggest, most obvious "click here" surface on the
    // controller — and unlike the touchpad's X/Y, it is a plain digital
    // button, so the capacitive drift that got the touchpad disabled does
    // not apply to it.
    gamepad.buttonX.pressedChangedHandler = { _, _, pressed in
        postMouseButton(.right, down: pressed)
    }
    // △ → short press = `claude`; long press (>0.55s) = `claude --resume`.
    gamepad.buttonY.pressedChangedHandler = { _, _, pressed in
        trianglePress.handle(pressed: pressed)
    }
    let dpadRepeat = DPadAutoRepeat()
    dpadRepeat.attach(gamepad.dpad)
    watcher.dpadRepeat = dpadRepeat
    // Shoulders → Cmd+Shift+← / Cmd+Shift+→ (Ghostty tab switching, matches
    // user's ~/.config/ghostty/config which remaps tabs off of Cmd+[/]).
    gamepad.leftShoulder.pressedChangedHandler = { _, _, pressed in
        if pressed {
            tapKey(kVK_LeftArrow, flags: [.maskCommand, .maskShift])
        }
    }
    gamepad.rightShoulder.pressedChangedHandler = { _, _, pressed in
        if pressed {
            tapKey(kVK_RightArrow, flags: [.maskCommand, .maskShift])
        }
    }
    // L3 (click the left stick) → the button map HUD. Chosen because it is the
    // one control you can find without knowing the mapping, and because a stray
    // click only flashes an overlay that ignores mouse events anyway.
    gamepad.leftThumbstickButton?.pressedChangedHandler = { _, _, pressed in
        guard pressed else { return }
        DispatchQueue.main.async {
            CheatSheetOverlay.shared.toggle()
        }
        watcher.bumper?.bump(intensity: 0.5, sharpness: 0.4, duration: 0.05)
    }

    // Touchpad click → left mouse button (with drag support via mouseHeld).
    if #available(macOS 11.3, *), let ds = gamepad as? GCDualSenseGamepad {
        ds.touchpadButton.pressedChangedHandler = { _, _, pressed in
            watcher.stickMouse?.mouseHeld = pressed
            postMouseButton(.left, down: pressed)
        }
    } else if let dualShock = gamepad as? GCDualShockGamepad {
        dualShock.touchpadButton.pressedChangedHandler = { _, _, pressed in
            watcher.stickMouse?.mouseHeld = pressed
            postMouseButton(.left, down: pressed)
        }
    } else {
        print("[warn] no touchpad button on this controller; left click unmapped")
    }

    // Create (the ⊞-ish key left of the touchpad) → screenshot selection.
    // Sony calls it "Create"; Cmd+Shift+4 is the closest macOS equivalent, so
    // the label on the key matches what it does.
    //
    // Apple's naming is the reverse of what you'd guess: buttonOptions is the
    // left-hand Create/Share key, buttonMenu is the right-hand Options key.
    // The localizedName log below confirms it per-controller.
    print("[buttons] buttonOptions=\(gamepad.buttonOptions?.localizedName ?? "nil")"
          + " buttonMenu=\(gamepad.buttonMenu.localizedName ?? "nil")")
    gamepad.buttonOptions?.pressedChangedHandler = { _, _, pressed in
        if pressed { tapKey(kVK_ANSI_4, flags: [.maskCommand, .maskShift]) }
    }
    // Options (right of the touchpad) → Tab. Completion in the shell and in
    // Claude Code was the one everyday key with nowhere to live.
    gamepad.buttonMenu.pressedChangedHandler = { _, _, pressed in
        if pressed { tapKey(kVK_Tab) }
    }

    // PS / home button → Mission Control (Ctrl+↑). Cmd+Tab used to live here
    // but a tap-and-release Cmd+Tab can only bounce between the two most
    // recent apps — it can never reach the third. Mission Control is complete
    // in a single press. macOS may still intercept Home entirely.
    gamepad.buttonHome?.pressedChangedHandler = { _, _, pressed in
        if pressed { tapKey(kVK_UpArrow, flags: .maskControl) }
    }

    // Any button press dismisses the button map. Sticks are excluded (they
    // drift, and drift would close it instantly); L3 is excluded because its
    // own handler owns the toggle.
    //
    // Installed only while the map is on screen — see `dismissHookInstaller`.
    CheatSheetOverlay.shared.dismissHookInstaller = { [weak gamepad] install in
        guard let gamepad = gamepad else { return }
        guard install else {
            gamepad.valueChangedHandler = nil
            return
        }
        gamepad.valueChangedHandler = { pad, element in
            if element === pad.leftThumbstick || element === pad.rightThumbstick { return }
            if element === pad.leftThumbstickButton { return }
            if let button = element as? GCControllerButtonInput, !button.isPressed { return }
            // Async so the handler is not torn down inside its own call.
            DispatchQueue.main.async { CheatSheetOverlay.shared.hide() }
        }
    }
    // Covers connecting a controller while the map is already up (opened from
    // the status bar menu).
    CheatSheetOverlay.shared.dismissHookInstaller?(CheatSheetOverlay.shared.isVisible)

    // Left stick → mouse cursor (paired with □ as left button).
    // Right stick → vertical scroll wheel (continuous).
    //
    // Both sticks prefer the raw IOHID feed; GameController is the fallback
    // only when no DualSense HID device is visible (e.g. a different pad).
    let mouseMover = StickMouseMover()
    let scroller = StickScroller()
    mouseMover.start()
    watcher.stickMouse = mouseMover
    scroller.start()
    watcher.stickScroller = scroller
    wireSticks()

    // Battery monitor.
    let battery = BatteryMonitor(controller: controller)
    battery.bumper = watcher.bumper
    battery.statusUpdate = { line in
        DispatchQueue.main.async {
            statusBar.setBattery(line)
        }
    }
    battery.start()
    watcher.battery = battery
}

func detach(_ controller: GCController) {
    print("[disconnect] \(controller.vendorName ?? "Unknown")")
    if watcher.controller === controller {
        watcher.trigger?.reset()
        watcher.rawSticks?.onLeft = nil
        watcher.rawSticks?.onRight = nil
        watcher.stickScroller?.stop()
        watcher.stickMouse?.stop()
        watcher.dpadRepeat?.stop()
        watcher.battery?.stop()
        watcher.resetForDisconnect()
        watcher.breathing = nil
        watcher.bumper = nil
        watcher.touchpad = nil
        watcher.stickScroller = nil
        watcher.stickMouse = nil
        watcher.dpadRepeat = nil
        watcher.battery = nil
        watcher.controller = nil
        CheatSheetOverlay.shared.dismissHookInstaller = nil
        statusBar.setBattery(nil)
    }
}

// MARK: - Status bar

final class StatusBar: NSObject {
    let item: NSStatusItem
    private let statusItem = NSMenuItem(title: "Status: scanning…", action: nil, keyEquivalent: "")
    private let batteryItem = NSMenuItem(title: "Battery: —", action: nil, keyEquivalent: "")
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
        batteryItem.isEnabled = false
        batteryItem.isHidden = true
        menu.addItem(statusItem)
        menu.addItem(batteryItem)
        menu.addItem(NSMenuItem.separator())

        micToggleItem.target = self
        micToggleItem.state = Preferences.useDualSenseMic ? .on : .off
        menu.addItem(micToggleItem)

        let mapItem = NSMenuItem(
            title: "Show Button Map",
            action: #selector(showButtonMap),
            keyEquivalent: ""
        )
        mapItem.target = self
        menu.addItem(mapItem)
        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit VibeController",
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

    @objc private func showButtonMap() {
        CheatSheetOverlay.shared.show()
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

    func setBattery(_ line: String?) {
        if let line = line {
            batteryItem.title = line
            batteryItem.isHidden = false
        } else {
            batteryItem.title = "Battery: —"
            batteryItem.isHidden = true
        }
    }

    func setRecording(_ on: Bool) {
        setIcon(on ? "mic.fill" : "gamecontroller")
    }

    private func setIcon(_ symbol: String) {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "VibeController")
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

// Render the button map to a PNG and exit — useful for the README and for
// eyeballing layout changes without a controller attached.
if let i = CommandLine.arguments.firstIndex(of: "--render-map") {
    let out = CommandLine.arguments.count > i + 1
        ? CommandLine.arguments[i + 1]
        : "button-map.png"
    if CheatSheetOverlay.renderPNG(to: out) {
        print("[render] wrote \(out)")
        exit(0)
    }
    print("[render] failed")
    exit(1)
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

let claudeStateWatcher = ClaudeStateWatcher(
    path: NSHomeDirectory() + "/.vibe-controller/state"
)
watcher.claudeState = claudeStateWatcher
claudeStateWatcher.stateChangedHandler = { state in
    applyClaudeStateLight(state)
}
claudeStateWatcher.start()

// Adaptive-trigger effect over IOHID (USB only). Created once at boot;
// each attach() reacquires + re-applies the weapon-mode profile.
watcher.trigger = DualSenseTriggerEffect()

// Raw stick reader. IOKit reports already-present devices only once the
// main run loop spins, i.e. after the initial attach() below has run, so the
// device-change hook re-wires the sticks when that happens.
let rawSticks = DualSenseRawSticks()
rawSticks.onDevicesChanged = { wireSticks() }
watcher.rawSticks = rawSticks

// Keyboard sync: if the user types Option+` themselves (e.g. when the
// controller is asleep), keep our state in phase with OpenWhispr.
let kbSync = KeyboardSyncWatcher()
kbSync.onExternalToggle = {
    watcher.handleExternalToggle()
}
kbSync.onAnyKeyDown = {
    CheatSheetOverlay.shared.hide()
}
kbSync.start()

if !checkAccessibility(prompt: true) {
    print("[!] Accessibility permission NOT granted yet.")
    print("[!] Grant it in: System Settings -> Privacy & Security -> Accessibility.")
}

print("VibeController started. Click the status bar icon for menu.")

for c in GCController.controllers() {
    attach(c)
    statusBar.setConnected(c.vendorName)
}
GCController.startWirelessControllerDiscovery {}

app.run()
