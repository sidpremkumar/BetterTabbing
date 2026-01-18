#!/usr/bin/env swift

import AppKit
import Foundation

// Icon sizes needed for macOS .icns
let sizes: [(size: Int, scale: Int, name: String)] = [
    (16, 1, "icon_16x16"),
    (16, 2, "icon_16x16@2x"),
    (32, 1, "icon_32x32"),
    (32, 2, "icon_32x32@2x"),
    (128, 1, "icon_128x128"),
    (128, 2, "icon_128x128@2x"),
    (256, 1, "icon_256x256"),
    (256, 2, "icon_256x256@2x"),
    (512, 1, "icon_512x512"),
    (512, 2, "icon_512x512@2x")
]

func createIcon(size: Int, scale: Int) -> NSImage {
    let pixelSize = size * scale
    let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))

    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)

    // Background gradient - modern blue/purple gradient
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.2, green: 0.5, blue: 1.0, alpha: 1.0),  // Blue
        NSColor(calibratedRed: 0.4, green: 0.3, blue: 0.9, alpha: 1.0)   // Purple
    ])!

    // Rounded rectangle background
    let cornerRadius = CGFloat(pixelSize) * 0.22  // macOS Big Sur style
    let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius)
    gradient.draw(in: bgPath, angle: -45)

    // Add subtle inner shadow/glow
    let innerShadow = NSShadow()
    innerShadow.shadowColor = NSColor.white.withAlphaComponent(0.3)
    innerShadow.shadowOffset = NSSize(width: 0, height: -CGFloat(pixelSize) * 0.02)
    innerShadow.shadowBlurRadius = CGFloat(pixelSize) * 0.05

    // Draw the SF Symbol "rectangle.stack" manually
    let symbolSize = CGFloat(pixelSize) * 0.55
    let symbolRect = NSRect(
        x: (CGFloat(pixelSize) - symbolSize) / 2,
        y: (CGFloat(pixelSize) - symbolSize) / 2,
        width: symbolSize,
        height: symbolSize
    )

    // Draw three stacked rectangles (like rectangle.stack)
    let rectWidth = symbolSize * 0.7
    let rectHeight = symbolSize * 0.35
    let spacing = symbolSize * 0.12
    let rectCorner = symbolSize * 0.08
    let strokeWidth = symbolSize * 0.06

    NSColor.white.setStroke()

    // Bottom rectangle (largest, most offset)
    let bottomRect = NSRect(
        x: symbolRect.midX - rectWidth/2 + spacing,
        y: symbolRect.midY - rectHeight/2 - spacing * 0.8,
        width: rectWidth,
        height: rectHeight
    )
    let bottomPath = NSBezierPath(roundedRect: bottomRect, xRadius: rectCorner, yRadius: rectCorner)
    bottomPath.lineWidth = strokeWidth
    NSColor.white.withAlphaComponent(0.5).setStroke()
    bottomPath.stroke()

    // Middle rectangle
    let middleRect = NSRect(
        x: symbolRect.midX - rectWidth/2 + spacing/2,
        y: symbolRect.midY - rectHeight/2,
        width: rectWidth,
        height: rectHeight
    )
    let middlePath = NSBezierPath(roundedRect: middleRect, xRadius: rectCorner, yRadius: rectCorner)
    middlePath.lineWidth = strokeWidth
    NSColor.white.withAlphaComponent(0.7).setStroke()
    middlePath.stroke()

    // Top rectangle (front, full opacity)
    let topRect = NSRect(
        x: symbolRect.midX - rectWidth/2,
        y: symbolRect.midY - rectHeight/2 + spacing * 0.8,
        width: rectWidth,
        height: rectHeight
    )
    let topPath = NSBezierPath(roundedRect: topRect, xRadius: rectCorner, yRadius: rectCorner)
    topPath.lineWidth = strokeWidth
    NSColor.white.setStroke()
    topPath.stroke()

    // Add a subtle shine/reflection on top
    let shineGradient = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.25),
        NSColor.white.withAlphaComponent(0.0)
    ])!

    let shineRect = NSRect(x: 0, y: CGFloat(pixelSize) * 0.5, width: CGFloat(pixelSize), height: CGFloat(pixelSize) * 0.5)
    let shinePath = NSBezierPath(roundedRect: shineRect.insetBy(dx: 1, dy: 0), xRadius: cornerRadius, yRadius: cornerRadius)
    shineGradient.draw(in: shinePath, angle: -90)

    image.unlockFocus()

    return image
}

// Create iconset directory
let iconsetPath = "AppIcon.iconset"
let fileManager = FileManager.default

try? fileManager.removeItem(atPath: iconsetPath)
try! fileManager.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

print("Generating icon images...")

for (size, scale, name) in sizes {
    let image = createIcon(size: size, scale: scale)
    let pixelSize = size * scale

    // Convert to PNG data
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG for \(name)")
        continue
    }

    let filename = "\(iconsetPath)/\(name).png"
    try! pngData.write(to: URL(fileURLWithPath: filename))
    print("  Created \(name).png (\(pixelSize)x\(pixelSize))")
}

print("\nConverting to .icns...")

// Convert iconset to icns using iconutil
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetPath]

try! process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Successfully created AppIcon.icns")

    // Clean up iconset
    try? fileManager.removeItem(atPath: iconsetPath)

    // Copy to app bundle Resources
    let resourcesPath = "BetterTabbing.app/Contents/Resources"
    if fileManager.fileExists(atPath: resourcesPath) {
        try? fileManager.copyItem(atPath: "AppIcon.icns", toPath: "\(resourcesPath)/AppIcon.icns")
        print("Copied to \(resourcesPath)/AppIcon.icns")
    }
} else {
    print("Failed to create .icns file")
}

print("\nDone!")
