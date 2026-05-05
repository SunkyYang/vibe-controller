#!/usr/bin/env swift
// Renders all macOS iconset PNGs (10 entries) into a target directory.
// Design: solid black rounded square + Apple's gamecontroller.fill SF Symbol
// in white, centered. No hand-drawn vectors — Apple's symbol is the artwork.
//
// Usage: swift build-icns.swift <output-iconset-dir>

import Cocoa
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: build-icns.swift <iconset-dir>\n".utf8))
    exit(1)
}
let outDir = CommandLine.arguments[1]

let entries: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

func whiteSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: .white))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)
}

func render(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        // Background: solid black rounded square (~22% radius matches Big Sur app icon shape).
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()

        // Centered SF Symbol controller, ~62% of the canvas.
        if let sym = whiteSymbol("gamecontroller.fill", pointSize: size * 0.62) {
            let s = sym.size
            let r = NSRect(
                x: rect.midX - s.width / 2,
                y: rect.midY - s.height / 2,
                width: s.width,
                height: s.height
            )
            sym.draw(in: r)
        }
        return true
    }
}

try? FileManager.default.createDirectory(
    at: URL(fileURLWithPath: outDir),
    withIntermediateDirectories: true
)

for entry in entries {
    let img = render(size: entry.pixels)
    guard
        let tiff = img.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("failed to encode \(entry.name)\n".utf8))
        continue
    }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(entry.name)"))
    print("wrote \(entry.name)")
}
