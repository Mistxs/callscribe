#!/usr/bin/env swift
import AppKit
import Foundation

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/icon-1024.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

let background = NSBezierPath(
    roundedRect: NSRect(x: 40, y: 40, width: size - 80, height: size - 80),
    xRadius: 210,
    yRadius: 210
)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.26, alpha: 1),
    NSColor(calibratedRed: 0.35, green: 0.17, blue: 0.60, alpha: 1),
])!
gradient.draw(in: background, angle: -55)

let glow = NSBezierPath(ovalIn: NSRect(x: 120, y: 430, width: 784, height: 500))
NSColor(calibratedRed: 0.55, green: 0.35, blue: 1.0, alpha: 0.12).setFill()
glow.fill()

let barWidth: CGFloat = 62
let gap: CGFloat = 38
let heights: [CGFloat] = [230, 390, 560, 390, 230]
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (size - totalWidth) / 2
let centerY = size / 2 - 40

NSColor.white.setFill()
for height in heights {
    let rect = NSRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
    NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}

let dot = NSBezierPath(ovalIn: NSRect(x: 735, y: 735, width: 125, height: 125))
NSColor(calibratedRed: 1.0, green: 0.28, blue: 0.36, alpha: 1).setFill()
dot.fill()
NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
dot.lineWidth = 8
dot.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Не удалось создать иконку\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
print("Иконка: \(output)")
