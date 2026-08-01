#!/usr/bin/env swift
import AppKit
import Foundation

let projectURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetURL = projectURL.appendingPathComponent("Resources/XPaste.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawIcon(pixels: Int) throws -> Data {
    let size = CGFloat(pixels)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw NSError(domain: "XPasteIcon", code: 1) }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw NSError(domain: "XPasteIcon", code: 2) }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let inset = size * 0.045
    let baseRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let base = roundedRect(baseRect, radius: size * 0.225)
    let gradient = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.16, green: 0.12, blue: 0.55, alpha: 1), 0),
        (NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.93, alpha: 1), 0.58),
        (NSColor(calibratedRed: 0.15, green: 0.70, blue: 0.95, alpha: 1), 1)
    )!
    gradient.draw(in: base, angle: -52)

    NSGraphicsContext.saveGraphicsState()
    base.addClip()
    let glow = NSGradient(starting: NSColor.white.withAlphaComponent(0.27), ending: .clear)!
    glow.draw(in: NSRect(x: -size * 0.1, y: size * 0.52, width: size * 1.15, height: size * 0.65), relativeCenterPosition: NSPoint(x: -0.25, y: 0.2))
    NSGraphicsContext.restoreGraphicsState()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = size * 0.045
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
    shadow.set()

    let backRect = NSRect(x: size * 0.26, y: size * 0.22, width: size * 0.49, height: size * 0.55)
    NSColor.white.withAlphaComponent(0.38).setFill()
    roundedRect(backRect, radius: size * 0.075).fill()

    let paperRect = NSRect(x: size * 0.20, y: size * 0.17, width: size * 0.51, height: size * 0.57)
    NSColor.white.withAlphaComponent(0.96).setFill()
    roundedRect(paperRect, radius: size * 0.075).fill()

    NSShadow().set()
    let clipRect = NSRect(x: size * 0.33, y: size * 0.65, width: size * 0.25, height: size * 0.13)
    let clipGradient = NSGradient(starting: NSColor(calibratedRed: 0.24, green: 0.28, blue: 0.58, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.43, alpha: 1))!
    clipGradient.draw(in: roundedRect(clipRect, radius: size * 0.045), angle: -90)
    NSColor.white.withAlphaComponent(0.65).setFill()
    roundedRect(NSRect(x: size * 0.395, y: size * 0.705, width: size * 0.12, height: size * 0.035), radius: size * 0.018).fill()

    NSColor(calibratedRed: 0.27, green: 0.38, blue: 0.70, alpha: 0.28).setFill()
    for index in 0..<3 {
        let width = index == 2 ? size * 0.22 : size * 0.30
        roundedRect(NSRect(x: size * 0.295, y: size * (0.52 - CGFloat(index) * 0.10), width: width, height: size * 0.027), radius: size * 0.014).fill()
    }

    let badgeRect = NSRect(x: size * 0.60, y: size * 0.13, width: size * 0.27, height: size * 0.27)
    let badgeGradient = NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.16, alpha: 1), ending: NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.09, alpha: 1))!
    badgeGradient.draw(in: roundedRect(badgeRect, radius: size * 0.135), angle: -90)

    let star = NSBezierPath()
    let center = NSPoint(x: badgeRect.midX, y: badgeRect.midY)
    for point in 0..<10 {
        let angle = CGFloat(point) * .pi / 5 - .pi / 2
        let radius = point.isMultiple(of: 2) ? size * 0.075 : size * 0.033
        let p = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        point == 0 ? star.move(to: p) : star.line(to: p)
    }
    star.close()
    NSColor.white.setFill()
    star.fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "XPasteIcon", code: 3) }
    return data
}

for variant in variants {
    try drawIcon(pixels: variant.pixels).write(to: iconsetURL.appendingPathComponent(variant.name), options: .atomic)
}

print(iconsetURL.path)
