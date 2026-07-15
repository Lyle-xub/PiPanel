#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: render_dmg_background.swift /path/to/background.png\n", stderr)
    exit(64)
}

let width = 660
let height = 420
let canvas = NSRect(x: 0, y: 0, width: width, height: height)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Could not allocate DMG background bitmap\n", stderr)
    exit(1)
}

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create DMG background graphics context\n", stderr)
    exit(1)
}

func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(deviceRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func drawRadialGlow(center: NSPoint, radius: CGFloat, color: NSColor, opacity: CGFloat) {
    guard let gradient = NSGradient(colorsAndLocations:
        (color.withAlphaComponent(opacity), 0),
        (color.withAlphaComponent(opacity * 0.30), 0.52),
        (color.withAlphaComponent(0), 1)
    ) else { return }
    gradient.draw(
        fromCenter: center,
        radius: 0,
        toCenter: center,
        radius: radius,
        options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
    )
}

func drawText(_ text: String, rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .center) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(in: rect, withAttributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ])
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

// Arc-inspired saturated base: a cool blue field with soft violet and aqua refraction.
let base = NSGradient(colorsAndLocations:
    (rgb(39, 62, 238), 0),
    (rgb(76, 70, 244), 0.42),
    (rgb(92, 65, 226), 0.72),
    (rgb(43, 125, 236), 1)
)!
base.draw(in: canvas, angle: -18)

drawRadialGlow(center: NSPoint(x: 82, y: 360), radius: 270, color: rgb(45, 224, 255), opacity: 0.76)
drawRadialGlow(center: NSPoint(x: 590, y: 352), radius: 255, color: rgb(255, 86, 204), opacity: 0.58)
drawRadialGlow(center: NSPoint(x: 510, y: 38), radius: 250, color: rgb(109, 207, 255), opacity: 0.50)
drawRadialGlow(center: NSPoint(x: 265, y: 185), radius: 190, color: rgb(137, 94, 255), opacity: 0.42)

// Fine deterministic grain keeps the gradient from feeling sterile without becoming noisy.
var randomState: UInt64 = 0x504950414E454C
for _ in 0..<1500 {
    randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
    let x = CGFloat((randomState >> 16) % UInt64(width))
    randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
    let y = CGFloat((randomState >> 16) % UInt64(height))
    let alpha = CGFloat(4 + (randomState % 9)) / 255
    rgb(255, 255, 255, alpha).setFill()
    NSBezierPath(rect: NSRect(x: x, y: y, width: 1, height: 1)).fill()
}

drawText(
    "PiPanel",
    rect: NSRect(x: 30, y: 344, width: 600, height: 48),
    font: .systemFont(ofSize: 34, weight: .bold),
    color: .white
)
drawText(
    "让任何窗口，都轻盈地悬浮起来",
    rect: NSRect(x: 30, y: 318, width: 600, height: 24),
    font: .systemFont(ofSize: 14, weight: .medium),
    color: .white.withAlphaComponent(0.82)
)

let glassRect = NSRect(x: 54, y: 82, width: 552, height: 208)
let glassPath = NSBezierPath(roundedRect: glassRect, xRadius: 28, yRadius: 28)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.set()
rgb(255, 255, 255, 0.13).setFill()
glassPath.fill()

NSGraphicsContext.saveGraphicsState()
NSShadow().set()
rgb(255, 255, 255, 0.30).setStroke()
glassPath.lineWidth = 1
glassPath.stroke()
NSGraphicsContext.restoreGraphicsState()

// Soft landing pads sit below Finder's live app and Applications icons.
for centerX in [172.0, 488.0] {
    let padRect = NSRect(x: centerX - 63, y: 130, width: 126, height: 126)
    let pad = NSBezierPath(roundedRect: padRect, xRadius: 30, yRadius: 30)
    rgb(255, 255, 255, 0.075).setFill()
    pad.fill()
    rgb(255, 255, 255, 0.14).setStroke()
    pad.lineWidth = 1
    pad.stroke()
}

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 267, y: 194))
arrow.curve(
    to: NSPoint(x: 389, y: 194),
    controlPoint1: NSPoint(x: 305, y: 216),
    controlPoint2: NSPoint(x: 350, y: 216)
)
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
rgb(255, 255, 255, 0.88).setStroke()
arrow.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 375, y: 207))
arrowHead.line(to: NSPoint(x: 390, y: 194))
arrowHead.line(to: NSPoint(x: 375, y: 181))
arrowHead.lineWidth = 4
arrowHead.lineCapStyle = .round
arrowHead.lineJoinStyle = .round
arrowHead.stroke()

drawText(
    "拖动 PiPanel 到 Applications",
    rect: NSRect(x: 100, y: 100, width: 460, height: 22),
    font: .systemFont(ofSize: 12, weight: .semibold),
    color: .white.withAlphaComponent(0.78)
)

let pill = NSBezierPath(roundedRect: NSRect(x: 263, y: 28, width: 134, height: 28), xRadius: 14, yRadius: 14)
rgb(255, 255, 255, 0.12).setFill()
pill.fill()
rgb(255, 255, 255, 0.18).setStroke()
pill.lineWidth = 1
pill.stroke()
drawText(
    "macOS 14 或更高版本",
    rect: NSRect(x: 270, y: 34, width: 120, height: 16),
    font: .systemFont(ofSize: 9.5, weight: .medium),
    color: .white.withAlphaComponent(0.76)
)

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode DMG background PNG\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: outputURL, options: .atomic)
} catch {
    fputs("Could not write DMG background: \(error)\n", stderr)
    exit(1)
}
