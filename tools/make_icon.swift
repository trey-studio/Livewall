// Draws the Livewall app icon and writes AppIcon.icns into the folder given as the first argument.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let px = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()

// Sky
NSGradient(colors: [
    NSColor(red: 0.16, green: 0.08, blue: 0.36, alpha: 1),
    NSColor(red: 0.78, green: 0.28, blue: 0.50, alpha: 1),
    NSColor(red: 1.00, green: 0.66, blue: 0.38, alpha: 1),
])!.draw(in: body, angle: -90)

// Sun glow and disc
let sun = NSPoint(x: 512, y: 470)
NSGradient(colors: [NSColor(red: 1, green: 0.85, blue: 0.5, alpha: 0.7), NSColor(red: 1, green: 0.6, blue: 0.4, alpha: 0)])!
    .draw(fromCenter: sun, radius: 0, toCenter: sun, radius: 360, options: [])
NSGradient(colors: [NSColor(red: 1, green: 0.97, blue: 0.7, alpha: 1), NSColor(red: 1, green: 0.55, blue: 0.3, alpha: 1)])!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: sun.x - 150, y: sun.y - 150, width: 300, height: 300)), angle: -90)

// Waves, back to front
let waveColors: [NSColor] = [
    NSColor(red: 0.50, green: 0.20, blue: 0.48, alpha: 1),
    NSColor(red: 0.30, green: 0.12, blue: 0.38, alpha: 1),
    NSColor(red: 0.12, green: 0.06, blue: 0.24, alpha: 1),
]
for (i, color) in waveColors.enumerated() {
    let base = 470.0 - Double(i) * 115
    let amp = 26.0 + Double(i) * 10
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 0, y: 0))
    var x = 0.0
    while x <= 1024 {
        path.line(to: NSPoint(x: x, y: base + sin(x / 1024 * .pi * 2 * 1.5 + Double(i) * 1.3) * amp))
        x += 8
    }
    path.line(to: NSPoint(x: 1024, y: 0))
    path.close()
    color.setFill()
    path.fill()
}

// Play badge
let badge = NSRect(x: 640, y: 640, width: 190, height: 190)
NSColor.white.withAlphaComponent(0.92).setFill()
NSBezierPath(ovalIn: badge).fill()
let tri = NSBezierPath()
tri.move(to: NSPoint(x: badge.midX - 28, y: badge.midY + 46))
tri.line(to: NSPoint(x: badge.midX - 28, y: badge.midY - 46))
tri.line(to: NSPoint(x: badge.midX + 50, y: badge.midY))
tri.close()
NSColor(red: 0.62, green: 0.22, blue: 0.48, alpha: 1).setFill()
tri.fill()

NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = iconset.appendingPathComponent("master.png")
try! rep.representation(using: .png, properties: [:])!.write(to: master)

func run(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
}
for size in [16, 32, 128, 256, 512] {
    run(["sips", "-z", "\(size)", "\(size)", master.path, "--out", iconset.appendingPathComponent("icon_\(size)x\(size).png").path])
    run(["sips", "-z", "\(size * 2)", "\(size * 2)", master.path, "--out", iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png").path])
}
try! FileManager.default.removeItem(at: master)
run(["iconutil", "-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path])
print("Wrote \(outDir.appendingPathComponent("AppIcon.icns").path)")
