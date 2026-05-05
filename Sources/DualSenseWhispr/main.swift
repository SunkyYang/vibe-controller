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
let kVK_ANSI_Grave:  CGKeyCode = 0x32
let kVK_Return:      CGKeyCode = 0x24
let kVK_Escape:      CGKeyCode = 0x35
let kVK_UpArrow:     CGKeyCode = 0x7E
let kVK_DownArrow:   CGKeyCode = 0x7D
let kVK_LeftArrow:   CGKeyCode = 0x7B
let kVK_RightArrow:  CGKeyCode = 0x7C

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

func tapOptionBacktick() {
    tapKey(kVK_ANSI_Grave, flags: .maskAlternate)
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
/// output report. USB-only MVP — Bluetooth needs a CRC32 on report id 0x31
/// which we don't implement yet.
///
/// kIOHIDMaxOutputReportSize for DualSense is 48 over USB (1 byte report ID
/// + 47-byte payload) and 79 over Bluetooth. We pass the 47-byte payload
/// to IOHIDDeviceSetReport with reportID=0x02 separately.
///
/// Mode 0x02 = "weapon": resistance ramps up between start..end, then
/// snaps loose past end (the gun-trigger feel).
final class DualSenseTriggerEffect {
    private let manager: IOHIDManager
    private var device: IOHIDDevice?

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

    /// Locate a USB-attached DualSense (47-byte output report). Returns true on success.
    @discardableResult
    func reacquire() -> Bool {
        let raw = IOHIDManagerCopyDevices(manager)
        guard let set = raw as? Set<IOHIDDevice> else {
            print("[trigger] reacquire: copy returned nil")
            device = nil
            return false
        }
        print("[trigger] reacquire: \(set.count) DualSense IOHID device(s) visible")
        for d in set {
            let size = (IOHIDDeviceGetProperty(d, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) ?? -1
            let transport = IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String ?? "?"
            print("[trigger]   device: outputSize=\(size) transport=\(transport)")
        }
        let usb = set.first { d in
            (IOHIDDeviceGetProperty(d, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) == 48
        }
        device = usb
        if device != nil {
            print("[trigger] using USB IOHID for adaptive trigger")
            return true
        }
        if !set.isEmpty {
            print("[trigger] only Bluetooth IOHID seen — adaptive trigger skipped (CRC32 not implemented)")
        }
        return false
    }

    /// R2 two-stage feel. start/end are 0..9 positions across the trigger pull;
    /// strength 0..255 controls the resistance peak.
    func setWeaponMode(start: UInt8 = 2, end: UInt8 = 6, strength: UInt8 = 255) {
        guard let device = device else { return }
        var payload = [UInt8](repeating: 0, count: 47)
        // valid_flag0 = 0xFF enables every field in the rumble+haptics+trigger
        // group. We zero the rumble bytes so that group doesn't fight haptics.
        // valid_flag1 = 0x00 leaves lightbar / LEDs / mute / power-save alone
        // so GameController's lightbar control still wins.
        payload[0] = 0xFF
        payload[1] = 0x00
        payload[2] = 0           // rumble right (off)
        payload[3] = 0           // rumble left (off)
        payload[10] = 0x02       // right trigger mode = weapon
        payload[11] = start
        payload[12] = end
        payload[13] = strength
        sendReport(device: device, payload: payload, label: "weapon")
    }

    /// Release any resistance.
    func reset() {
        guard let device = device else { return }
        var payload = [UInt8](repeating: 0, count: 47)
        payload[0] = 0xFF
        payload[1] = 0x00
        payload[10] = 0x00       // off
        sendReport(device: device, payload: payload, label: "reset")
    }

    private func sendReport(device: IOHIDDevice, payload: [UInt8], label: String) {
        let result = payload.withUnsafeBufferPointer { buf -> IOReturn in
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
            print("[trigger] SetReport(\(label)) failed: \(String(format: "0x%x", result))")
        }
    }
}

// MARK: - Claude Code state mirroring

/// Watches `~/.dualsense-whispr/state` (written by Claude Code hooks) and
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

// MARK: - Touchpad swipe

/// One-finger horizontal swipe on the DualSense touchpad → Enter / Esc.
/// Right swipe = Enter (accept). Left swipe = Esc (reject).
///
/// GCControllerDirectionPad does not surface a touch-begin/touch-end event;
/// when the finger lifts the axes snap back to (0, 0). So we treat the
/// arrival of the (0, 0) sample as the release boundary and use the most
/// recently observed non-zero position as the gesture endpoint.
final class TouchpadSwipe {
    private var firstX: Float?
    private var firstY: Float?
    private var lastX: Float = 0
    private var lastY: Float = 0
    private let threshold: Float = 0.5
    private let zeroEpsilon: Float = 0.02

    func attach(_ pad: GCControllerDirectionPad) {
        pad.valueChangedHandler = { [weak self] _, x, y in
            guard let self = self else { return }
            let isReleased = abs(x) < self.zeroEpsilon && abs(y) < self.zeroEpsilon
            if isReleased {
                if let fx = self.firstX, let fy = self.firstY {
                    let dx = self.lastX - fx
                    let dy = self.lastY - fy
                    self.firstX = nil
                    self.firstY = nil
                    self.lastX = 0
                    self.lastY = 0
                    if abs(dx) > self.threshold && abs(dx) > abs(dy) {
                        if dx > 0 {
                            print("[touchpad] swipe right -> Enter")
                            tapKey(kVK_Return)
                        } else {
                            print("[touchpad] swipe left -> Esc")
                            tapKey(kVK_Escape)
                        }
                    }
                }
            } else {
                if self.firstX == nil {
                    self.firstX = x
                    self.firstY = y
                }
                self.lastX = x
                self.lastY = y
            }
        }
    }
}

// MARK: - Trigger watcher

final class TriggerWatcher {
    weak var controller: GCController?
    var bumper: HapticBumper?
    var breathing: BreathingLight?
    var touchpad: TouchpadSwipe?
    var micMonitor: MicLevelMonitor?
    var claudeState: ClaudeStateWatcher?
    var trigger: DualSenseTriggerEffect?
    var statusUpdate: ((Bool) -> Void)?

    private var pressed = false
    private(set) var recording = false
    private var savedInputDevice: AudioDeviceID?

    func handle(value: Float) {
        if !pressed && value >= TRIGGER_HIGH {
            pressed = true
            recording.toggle()
            statusUpdate?(recording)
            if recording {
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
        // Start mic-level monitor so the light bar reacts to voice volume.
        // Slight delay so the CoreAudio switch (if any) settles first.
        if Preferences.useDualSenseMic,
           let ds = AudioInputSwitcher.findInputDevice(matching: "DualSense") {
            savedInputDevice = AudioInputSwitcher.defaultInputID
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
            startMicMonitor()
            fireStartHotkey()
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
        print("[R2] press -> recording=false")
        tapOptionBacktick()
        micMonitor?.stop()
        breathing?.currentMicLevel = 0
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
    if #available(macOS 11.3, *), let dualSense = gamepad as? GCDualSenseGamepad {
        let tp = TouchpadSwipe()
        tp.attach(dualSense.touchpadPrimary)
        watcher.touchpad = tp
    }

    // Adaptive trigger over IOHID (USB only). No-op on Bluetooth.
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

    // Button -> keyboard mappings (PS5 face buttons + D-Pad).
    // GCExtendedGamepad uses Xbox naming, so:
    //   buttonA = Cross (✕ / "X key" in PS5 lingo)
    //   buttonB = Circle (○)
    gamepad.buttonA.pressedChangedHandler = { _, _, pressed in
        if pressed { tapKey(kVK_Return) }
    }
    gamepad.buttonB.pressedChangedHandler = { _, _, pressed in
        if pressed { tapKey(kVK_Escape) }
    }
    gamepad.dpad.up.pressedChangedHandler = { _, _, pressed in
        if pressed { tapKey(kVK_UpArrow) }
    }
    gamepad.dpad.down.pressedChangedHandler = { _, _, pressed in
        if pressed { tapKey(kVK_DownArrow) }
    }
    gamepad.dpad.left.pressedChangedHandler = { _, _, pressed in
        if pressed { tapKey(kVK_LeftArrow) }
    }
    gamepad.dpad.right.pressedChangedHandler = { _, _, pressed in
        if pressed { tapKey(kVK_RightArrow) }
    }
}

func detach(_ controller: GCController) {
    print("[disconnect] \(controller.vendorName ?? "Unknown")")
    if watcher.controller === controller {
        watcher.trigger?.reset()
        watcher.resetForDisconnect()
        watcher.breathing = nil
        watcher.bumper = nil
        watcher.touchpad = nil
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

let claudeStateWatcher = ClaudeStateWatcher(
    path: NSHomeDirectory() + "/.dualsense-whispr/state"
)
watcher.claudeState = claudeStateWatcher
claudeStateWatcher.stateChangedHandler = { state in
    applyClaudeStateLight(state)
}
claudeStateWatcher.start()

// Adaptive-trigger effect over IOHID (USB only). Created once at boot;
// each attach() reacquires + re-applies the weapon-mode profile.
watcher.trigger = DualSenseTriggerEffect()

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
