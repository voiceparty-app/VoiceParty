// Renders Resources/AppIcon.icns: a teal squircle with a white waveform.
//   swift scripts/make-icon.swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.09, green: 0.2, blue: 0.2, alpha: 1), NSColor(red: 0.2, green: 0.46, blue: 0.44, alpha: 1)])!
        .draw(in: shape, angle: -60)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    shape.lineWidth = max(1, s * 0.004)
    shape.stroke()

    let heights: [CGFloat] = [0.18, 0.34, 0.52, 0.34, 0.24, 0.42, 0.2]
    let barWidth = rect.width * 0.062
    let gap = rect.width * 0.045
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = rect.midX - total / 2
    NSColor.white.setFill()
    for h in heights {
        let height = rect.height * h
        NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height),
                     xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in sizes where size <= 512 {
    try render(size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
