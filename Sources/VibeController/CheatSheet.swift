import AppKit

// MARK: - Cheat sheet overlay
//
// A HUD that draws the DualSense and labels every mapped button, so the
// mapping never has to be remembered. Toggled from the controller itself
// (L3 — click the left stick) or from the status bar menu.
//
// The panel is non-activating and click-through: it never steals focus from
// whatever is in front, which matters because this app runs as .accessory
// and the left stick is doubling as the mouse.

private let kCheatSheetSize = NSSize(width: 1000, height: 760)

final class CheatSheetOverlay {
    static let shared = CheatSheetOverlay()

    private var panel: NSPanel?
    private var keyMonitor: Any?

    /// Installs (true) or removes (false) the controller-side "any button
    /// dismisses" handler. Set by `attach()`, cleared by `detach()`.
    ///
    /// This is a hook rather than a flag the handler checks because the
    /// handler sits on the input hot path: a gamepad reports a few hundred
    /// times a second, all on the main queue, and the cursor timer shares
    /// that queue. Nothing at all should be installed while the map is
    /// hidden, which is all of the time.
    var dismissHookInstaller: ((Bool) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Center on whichever screen the pointer is on.
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - kCheatSheetSize.width / 2,
                y: frame.midY - kCheatSheetSize.height / 2
            ))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }

        installKeyMonitor()
        dismissHookInstaller?(true)
    }

    func hide() {
        removeKeyMonitor()
        dismissHookInstaller?(false)
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: Keyboard dismissal
    //
    // Two independent paths, because neither is guaranteed:
    //   - KeyboardSyncWatcher's CGEventTap (needs Input Monitoring)
    //   - the global NSEvent monitor below (needs Accessibility)
    // Whichever is permitted wins; hide() is idempotent, so both firing is
    // harmless. The panel is non-activating and can never be key, so there is
    // no third option of just handling keyDown ourselves.

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    /// Draw the same HUD into a @2x PNG (see `--render-map`).
    static func renderPNG(to path: String) -> Bool {
        let view = CheatSheetView(frame: NSRect(origin: .zero, size: kCheatSheetSize))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return false
        }
        rep.size = kCheatSheetSize
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: kCheatSheetSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        panel.contentView = CheatSheetView(
            frame: NSRect(origin: .zero, size: kCheatSheetSize)
        )
        return panel
    }
}

// MARK: - Drawing

/// One labelled callout: a key cap, a description, and where on the
/// controller drawing the leader line points to.
private struct Callout {
    let cap: String
    let action: String
    /// Anchor in controller-local coordinates (see `CheatSheetView.point`).
    let anchor: NSPoint
    var highlight: Bool = false
}

final class CheatSheetView: NSView {

    // Palette (this HUD is deliberately dark in both system themes).
    private let panelBG = NSColor(calibratedWhite: 0.07, alpha: 0.94)
    private let panelEdge = NSColor(calibratedWhite: 1.0, alpha: 0.12)
    private let bodyFill = NSColor(calibratedWhite: 0.20, alpha: 1.0)
    private let bodyEdge = NSColor(calibratedWhite: 1.0, alpha: 0.28)
    private let partFill = NSColor(calibratedWhite: 0.34, alpha: 1.0)
    private let textPrimary = NSColor(calibratedWhite: 0.96, alpha: 1.0)
    private let textDim = NSColor(calibratedWhite: 0.60, alpha: 1.0)
    private let accent = NSColor(calibratedRed: 0.36, green: 0.72, blue: 1.0, alpha: 1.0)
    private let highlight = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.30, alpha: 1.0)

    // Controller placement inside the panel.
    private let origin = NSPoint(x: 500, y: 430)
    private let scale: CGFloat = 1.7

    // Column geometry.
    private let leftEdge: CGFloat = 280      // right edge of the left column
    private let rightEdge: CGFloat = 720     // left edge of the right column
    private let colWidth: CGFloat = 250
    private let leftElbow: CGFloat = 302
    private let rightElbow: CGFloat = 698

    // Both columns are ordered by anchor height so the leader lines fan out
    // without crossing each other.
    private let leftCallouts: [Callout] = [
        Callout(cap: "L2", action: "Fn layer — hold. Ticks, bar turns amber",
                anchor: NSPoint(x: -64, y: 86)),
        Callout(cap: "L1", action: "Previous tab · Cmd+Shift+←",
                anchor: NSPoint(x: -72, y: 62)),
        Callout(cap: "Create", action: "Screenshot selection · Cmd+Shift+4",
                anchor: NSPoint(x: -38, y: 50)),
        Callout(cap: "D-Pad", action: "Arrow keys, with auto-repeat",
                anchor: NSPoint(x: -56, y: 18)),
        Callout(cap: "Left stick", action: "Move the mouse cursor",
                anchor: NSPoint(x: -30, y: -30)),
        Callout(cap: "L3", action: "Click the left stick — opens this map",
                anchor: NSPoint(x: -30, y: -34), highlight: true),
    ]

    private let rightCallouts: [Callout] = [
        Callout(cap: "R2", action: "Toggle dictation (OpenWhispr)",
                anchor: NSPoint(x: 64, y: 86)),
        Callout(cap: "R1", action: "Next tab · Cmd+Shift+→",
                anchor: NSPoint(x: 72, y: 62)),
        Callout(cap: "Options", action: "Tab — shell and Claude Code completion",
                anchor: NSPoint(x: 38, y: 50)),
        Callout(cap: "△", action: "Claude mode · Shift+Tab · hold: Ctrl+C",
                anchor: NSPoint(x: 58, y: 35)),
        Callout(cap: "○", action: "Esc",
                anchor: NSPoint(x: 75, y: 18)),
        // □ sits on the far side of the cluster; keeping it above ✕ in the
        // column routes its leader over the buttons instead of through them.
        Callout(cap: "□", action: "Mouse right click",
                anchor: NSPoint(x: 41, y: 18)),
        Callout(cap: "✕", action: "Return",
                anchor: NSPoint(x: 58, y: 1)),
        Callout(cap: "Right stick", action: "Scroll wheel",
                anchor: NSPoint(x: 30, y: -30)),
        Callout(cap: "R3", action: "Click the right stick — paste · Cmd+V",
                anchor: NSPoint(x: 30, y: -34)),
        Callout(cap: "PS", action: "Mission Control · Ctrl+↑",
                anchor: NSPoint(x: 0, y: -22)),
    ]

    private let combos: [(String, String)] = [
        ("L2 + △", "Run claude · hold: --resume"),
        ("L2 + R2", "Dictate straight into Ghostty"),
        ("L2 + ○", "Delete (auto-repeat)"),
        ("L2 + ✕", "Undo · Cmd+Z"),
        ("L2 + ↑", "New Ghostty tab · Cmd+T"),
        ("L2 + →", "Split right · Cmd+D"),
        ("L2 + ↓", "Type /new"),
    ]

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.imageInterpolation = .high

        drawBackground()
        drawHeader()
        drawController()

        for (i, c) in leftCallouts.enumerated() {
            drawCallout(c, rowY: 620 - CGFloat(i) * 54, onLeft: true)
        }
        for (i, c) in rightCallouts.enumerated() {
            drawCallout(c, rowY: 632 - CGFloat(i) * 44, onLeft: false)
        }

        drawCombos()
        drawFooter()
    }

    // MARK: Chrome

    private func drawBackground() {
        let r = bounds.insetBy(dx: 6, dy: 6)
        let p = NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20)
        panelBG.setFill()
        p.fill()
        panelEdge.setStroke()
        p.lineWidth = 1
        p.stroke()
    }

    private func drawHeader() {
        text("Vibe Controller — Button Map", at: NSPoint(x: 34, y: 706),
             size: 19, color: textPrimary, weight: .semibold)
        let hint = attributed("L3 opens · any other button or key dismisses", size: 12,
                              color: textDim, weight: .regular)
        hint.draw(at: NSPoint(x: bounds.width - 34 - hint.size().width, y: 710))

        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: 34, y: 692))
        rule.line(to: NSPoint(x: bounds.width - 34, y: 692))
        panelEdge.setStroke()
        rule.lineWidth = 1
        rule.stroke()
    }

    private func drawFooter() {
        let s = attributed(
            "Status bar → Show Button Map  ·  full table in docs/button-mapping.md",
            size: 11, color: textDim, weight: .regular
        )
        s.draw(at: NSPoint(x: (bounds.width - s.size().width) / 2, y: 16))
    }

    // MARK: Callouts

    private func drawCallout(_ c: Callout, rowY: CGFloat, onLeft: Bool) {
        let capColor = c.highlight ? highlight : accent
        let capText = attributed(c.cap, size: 12.5, color: capColor, weight: .semibold)
        let capW = capText.size().width + 16
        let capX = onLeft ? leftEdge - capW : rightEdge
        let capRect = NSRect(x: capX, y: rowY - 11, width: capW, height: 22)

        let capBG = NSBezierPath(roundedRect: capRect, xRadius: 6, yRadius: 6)
        capColor.withAlphaComponent(c.highlight ? 0.22 : 0.14).setFill()
        capBG.fill()
        capColor.withAlphaComponent(0.55).setStroke()
        capBG.lineWidth = 1
        capBG.stroke()
        capText.draw(at: NSPoint(
            x: capRect.midX - capText.size().width / 2,
            y: capRect.midY - capText.size().height / 2
        ))

        // Description sits under the cap, hugging the outer edge.
        let para = NSMutableParagraphStyle()
        para.alignment = onLeft ? .right : .left
        para.lineBreakMode = .byWordWrapping
        let body = attributed(c.action, size: 12,
                              color: c.highlight ? highlight.withAlphaComponent(0.9) : textDim,
                              weight: .regular, paragraph: para)
        let bodyX = onLeft ? leftEdge - colWidth : rightEdge
        body.draw(with: NSRect(x: bodyX, y: rowY - 15 - 32, width: colWidth, height: 32),
                  options: [.usesLineFragmentOrigin])

        // Leader line: cap edge → elbow → anchor on the controller.
        let start = NSPoint(x: onLeft ? capRect.maxX + 6 : capRect.minX - 6, y: rowY)
        let elbow = NSPoint(x: onLeft ? leftElbow : rightElbow, y: rowY)
        let target = point(c.anchor.x, c.anchor.y)

        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: elbow)
        line.line(to: target)
        line.lineWidth = 1
        line.lineJoinStyle = .round
        capColor.withAlphaComponent(c.highlight ? 0.75 : 0.38).setStroke()
        line.stroke()

        let dot = NSBezierPath(ovalIn: NSRect(x: target.x - 2.5, y: target.y - 2.5,
                                              width: 5, height: 5))
        capColor.withAlphaComponent(c.highlight ? 0.95 : 0.7).setFill()
        dot.fill()
    }

    // MARK: L2 combo strip

    private func drawCombos() {
        let box = NSRect(x: 34, y: 44, width: bounds.width - 68, height: 148)
        let p = NSBezierPath(roundedRect: box, xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 1.0, alpha: 0.05).setFill()
        p.fill()
        panelEdge.setStroke()
        p.lineWidth = 1
        p.stroke()

        text("Hold L2", at: NSPoint(x: box.minX + 20, y: box.maxY - 30),
             size: 13, color: accent, weight: .semibold)
        text("the gamepad's Fn key", at: NSPoint(x: box.minX + 92, y: box.maxY - 29),
             size: 12, color: textDim, weight: .regular)

        // Three columns, two rows.
        let colW = (box.width - 40) / 3
        for (i, combo) in combos.enumerated() {
            let col = i % 3
            let row = i / 3
            let x = box.minX + 20 + CGFloat(col) * colW
            let y = box.maxY - 66 - CGFloat(row) * 42

            let capText = attributed(combo.0, size: 12, color: textPrimary, weight: .semibold)
            let capRect = NSRect(x: x, y: y - 10, width: capText.size().width + 16, height: 21)
            let capBG = NSBezierPath(roundedRect: capRect, xRadius: 6, yRadius: 6)
            NSColor(calibratedWhite: 1.0, alpha: 0.10).setFill()
            capBG.fill()
            capText.draw(at: NSPoint(
                x: capRect.midX - capText.size().width / 2,
                y: capRect.midY - capText.size().height / 2
            ))

            text(combo.1, at: NSPoint(x: capRect.maxX + 10, y: y - 7),
                 size: 12, color: textDim, weight: .regular)
        }
    }

    // MARK: Controller drawing

    /// Controller-local (x right, y up, ~86 units to the outer edge) → view coords.
    private func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: origin.x + (x - w / 2) * scale,
               y: origin.y + (y - h / 2) * scale,
               width: w * scale, height: h * scale)
    }

    private func drawController() {
        // Shoulders and triggers first, so the body overlaps their bottoms.
        for sign in [CGFloat(-1), 1] {
            let trigger = NSBezierPath(roundedRect: rect(sign * 62, 84, 30, 20),
                                       xRadius: 7, yRadius: 7)
            partFill.setFill(); trigger.fill()
            bodyEdge.setStroke(); trigger.lineWidth = 1; trigger.stroke()

            let bumper = NSBezierPath(roundedRect: rect(sign * 66, 63, 34, 16),
                                      xRadius: 6, yRadius: 6)
            partFill.setFill(); bumper.fill()
            bodyEdge.setStroke(); bumper.lineWidth = 1; bumper.stroke()
        }

        // Body: top bulge, flared shoulders, two grips.
        let body = NSBezierPath()
        body.move(to: point(-58, 62))
        body.curve(to: point(58, 62), controlPoint1: point(-20, 78), controlPoint2: point(20, 78))
        body.curve(to: point(86, -30), controlPoint1: point(84, 44), controlPoint2: point(90, -8))
        body.curve(to: point(52, -96), controlPoint1: point(82, -66), controlPoint2: point(74, -96))
        body.curve(to: point(26, -50), controlPoint1: point(30, -96), controlPoint2: point(28, -70))
        body.curve(to: point(-26, -50), controlPoint1: point(10, -38), controlPoint2: point(-10, -38))
        body.curve(to: point(-52, -96), controlPoint1: point(-28, -70), controlPoint2: point(-30, -96))
        body.curve(to: point(-86, -30), controlPoint1: point(-74, -96), controlPoint2: point(-82, -66))
        body.curve(to: point(-58, 62), controlPoint1: point(-90, -8), controlPoint2: point(-84, 44))
        body.close()
        bodyFill.setFill(); body.fill()
        bodyEdge.setStroke(); body.lineWidth = 1.5; body.stroke()

        // Touchpad (intentionally unmapped, drawn plain).
        // Touchpad. Its click is mapped, so the label goes inside the pad —
        // a leader line to dead centre would have to cross the D-Pad or the
        // face buttons whichever side it came from.
        let padRect = rect(0, 24, 52, 40)
        let pad = NSBezierPath(roundedRect: padRect, xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 0.26, alpha: 1).setFill(); pad.fill()
        bodyEdge.setStroke(); pad.lineWidth = 1; pad.stroke()
        centered("CLICK", in: padRect, dy: 6, size: 9.5, color: accent, weight: .bold)
        centered("left mouse", in: padRect, dy: -7, size: 9, color: textDim, weight: .regular)

        // Create / Options.
        for sign in [CGFloat(-1), 1] {
            let b = NSBezierPath(roundedRect: rect(sign * 38, 50, 9, 12), xRadius: 3, yRadius: 3)
            partFill.setFill(); b.fill()
        }

        drawDPad()
        drawFaceButtons()

        // Sticks.
        for sign in [CGFloat(-1), 1] {
            let well = NSBezierPath(ovalIn: rect(sign * 30, -30, 34, 34))
            NSColor(calibratedWhite: 0.14, alpha: 1).setFill(); well.fill()
            bodyEdge.setStroke(); well.lineWidth = 1; well.stroke()
            let cap = NSBezierPath(ovalIn: rect(sign * 30, -30, 24, 24))
            partFill.setFill(); cap.fill()
        }

        // PS button and the mic slit.
        let ps = NSBezierPath(ovalIn: rect(0, -22, 12, 12))
        partFill.setFill(); ps.fill()
        let mic = NSBezierPath(roundedRect: rect(0, -44, 16, 5), xRadius: 2.5, yRadius: 2.5)
        NSColor(calibratedWhite: 0.14, alpha: 1).setFill(); mic.fill()

        // Light bar hint down both sides of the touchpad.
        for sign in [CGFloat(-1), 1] {
            let bar = NSBezierPath(roundedRect: rect(sign * 30.5, 24, 3, 34),
                                   xRadius: 1.5, yRadius: 1.5)
            accent.withAlphaComponent(0.55).setFill(); bar.fill()
        }
    }

    private func drawDPad() {
        let cx: CGFloat = -56, cy: CGFloat = 18
        let arm: CGFloat = 11, thick: CGFloat = 11
        let h = NSBezierPath(roundedRect: rect(cx, cy, arm * 2 + thick, thick),
                             xRadius: 3, yRadius: 3)
        let v = NSBezierPath(roundedRect: rect(cx, cy, thick, arm * 2 + thick),
                             xRadius: 3, yRadius: 3)
        partFill.setFill(); h.fill(); v.fill()
    }

    private func drawFaceButtons() {
        let cx: CGFloat = 58, cy: CGFloat = 18, r: CGFloat = 8.5, d: CGFloat = 17
        let spots: [(CGFloat, CGFloat, (NSPoint, CGFloat) -> Void)] = [
            (cx, cy + d, glyphTriangle),
            (cx + d, cy, glyphCircle),
            (cx, cy - d, glyphCross),
            (cx - d, cy, glyphSquare),
        ]
        for (bx, by, glyph) in spots {
            let well = NSBezierPath(ovalIn: rect(bx, by, r * 2, r * 2))
            NSColor(calibratedWhite: 0.28, alpha: 1).setFill(); well.fill()
            bodyEdge.setStroke(); well.lineWidth = 1; well.stroke()
            glyph(point(bx, by), 4.4 * scale)
        }
    }

    // Face-button glyphs, drawn rather than typeset so they always line up.

    private func glyphTriangle(_ c: NSPoint, _ r: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x, y: c.y + r))
        p.line(to: NSPoint(x: c.x + r * 0.87, y: c.y - r * 0.5))
        p.line(to: NSPoint(x: c.x - r * 0.87, y: c.y - r * 0.5))
        p.close()
        strokeGlyph(p)
    }

    private func glyphCircle(_ c: NSPoint, _ r: CGFloat) {
        strokeGlyph(NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r,
                                                width: r * 2, height: r * 2)))
    }

    private func glyphCross(_ c: NSPoint, _ r: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x - r * 0.75, y: c.y - r * 0.75))
        p.line(to: NSPoint(x: c.x + r * 0.75, y: c.y + r * 0.75))
        p.move(to: NSPoint(x: c.x - r * 0.75, y: c.y + r * 0.75))
        p.line(to: NSPoint(x: c.x + r * 0.75, y: c.y - r * 0.75))
        strokeGlyph(p)
    }

    private func glyphSquare(_ c: NSPoint, _ r: CGFloat) {
        strokeGlyph(NSBezierPath(rect: NSRect(x: c.x - r * 0.72, y: c.y - r * 0.72,
                                              width: r * 1.44, height: r * 1.44)))
    }

    private func strokeGlyph(_ p: NSBezierPath) {
        NSColor(calibratedWhite: 0.92, alpha: 0.85).setStroke()
        p.lineWidth = 1.4
        p.lineJoinStyle = .round
        p.stroke()
    }

    // MARK: Text helpers

    private func attributed(_ s: String, size: CGFloat, color: NSColor,
                            weight: NSFont.Weight,
                            paragraph: NSParagraphStyle? = nil) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        if let paragraph = paragraph { attrs[.paragraphStyle] = paragraph }
        return NSAttributedString(string: s, attributes: attrs)
    }

    private func text(_ s: String, at p: NSPoint, size: CGFloat,
                      color: NSColor, weight: NSFont.Weight) {
        attributed(s, size: size, color: color, weight: weight).draw(at: p)
    }

    /// Draw `s` horizontally centred in `r`, offset `dy` above its midline.
    private func centered(_ s: String, in r: NSRect, dy: CGFloat, size: CGFloat,
                          color: NSColor, weight: NSFont.Weight) {
        let a = attributed(s, size: size, color: color, weight: weight)
        a.draw(at: NSPoint(x: r.midX - a.size().width / 2,
                           y: r.midY + dy - a.size().height / 2))
    }
}
