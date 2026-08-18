// Generates Resources/awake.icns - the cup, steaming. The menu bar says the
// state by silhouette (steam = awake, saucer = normal sleep); the app icon is
// always the awake one. Drawn, never an SF Symbol: Apple's SF Symbols licence
// forbids using a symbol as an app icon or logo.
// Run: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Warm near-black, so the amber reads as heat rather than decoration.
let plateCenter = NSColor(calibratedRed: 0.11, green: 0.085, blue: 0.06, alpha: 1)
let plateEdge = NSColor(calibratedRed: 0.04, green: 0.03, blue: 0.02, alpha: 1)
let porcelain = NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.93, alpha: 1)
let amber = NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.28, alpha: 1)

// Big Sur metrics: an 824pt squircle centred in a 1024 canvas.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)

NSGraphicsContext.current?.saveGraphicsState()
let dropShadow = NSShadow()
dropShadow.shadowBlurRadius = 26
dropShadow.shadowOffset = NSSize(width: 0, height: -10)
dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
dropShadow.set()
plateEdge.setFill()
squircle.fill()
NSGraphicsContext.current?.restoreGraphicsState()

NSGradient(starting: plateCenter, ending: plateEdge)!
    .draw(in: squircle, relativeCenterPosition: NSPoint(x: 0, y: 0.15))

NSGraphicsContext.current?.saveGraphicsState()
squircle.setClip()

// Warmth pooling under the cup.
NSGradient(starting: amber.withAlphaComponent(0.20), ending: NSColor.clear)!
    .draw(in: squircle, relativeCenterPosition: NSPoint(x: 0, y: -0.25))

func glowStroke(_ path: NSBezierPath, color: NSColor, blur: CGFloat, passes: Int) {
    for _ in 0..<passes {
        NSGraphicsContext.current?.saveGraphicsState()
        let s = NSShadow()
        s.shadowBlurRadius = blur
        s.shadowOffset = .zero
        s.shadowColor = color.withAlphaComponent(0.85)
        s.set()
        color.setStroke()
        path.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

let cx: CGFloat = 512

// THE STEAM: three waves, the middle one taller. Amber, glowing, because it is
// the one element that says "on".
for (dx, height, phase) in [(-108.0, 150.0, 0.0), (0.0, 196.0, 26.0), (108.0, 150.0, 0.0)] {
    let base: CGFloat = 604
    let top = base + CGFloat(height)
    let wave = NSBezierPath()
    wave.move(to: NSPoint(x: cx + CGFloat(dx), y: base))
    wave.curve(
        to: NSPoint(x: cx + CGFloat(dx), y: base + CGFloat(height) * 0.5),
        controlPoint1: NSPoint(x: cx + CGFloat(dx) + 46, y: base + CGFloat(height) * 0.16),
        controlPoint2: NSPoint(x: cx + CGFloat(dx) + 46, y: base + CGFloat(height) * 0.34)
    )
    wave.curve(
        to: NSPoint(x: cx + CGFloat(dx), y: top + CGFloat(phase)),
        controlPoint1: NSPoint(x: cx + CGFloat(dx) - 46, y: base + CGFloat(height) * 0.66),
        controlPoint2: NSPoint(x: cx + CGFloat(dx) - 46, y: base + CGFloat(height) * 0.84)
    )
    wave.lineWidth = 34
    wave.lineCapStyle = .round
    glowStroke(wave, color: amber, blur: 56, passes: 3)
}

// THE CUP: a tapered body, porcelain, with a handle on the right.
let bodyTop: CGFloat = 560
let bodyBottom: CGFloat = 300
let body = NSBezierPath()
body.move(to: NSPoint(x: cx - 210, y: bodyTop))
body.line(to: NSPoint(x: cx + 210, y: bodyTop))
body.curve(
    to: NSPoint(x: cx + 120, y: bodyBottom),
    controlPoint1: NSPoint(x: cx + 206, y: bodyTop - 150),
    controlPoint2: NSPoint(x: cx + 176, y: bodyBottom)
)
body.line(to: NSPoint(x: cx - 120, y: bodyBottom))
body.curve(
    to: NSPoint(x: cx - 210, y: bodyTop),
    controlPoint1: NSPoint(x: cx - 176, y: bodyBottom),
    controlPoint2: NSPoint(x: cx - 206, y: bodyTop - 150)
)
body.close()
porcelain.setFill()
body.fill()

// The handle reads as one stroke, its inner cut kept clear of the body.
let handle = NSBezierPath()
handle.appendArc(
    withCenter: NSPoint(x: cx + 236, y: bodyTop - 118),
    radius: 96, startAngle: 108, endAngle: -108, clockwise: true
)
handle.lineWidth = 46
handle.lineCapStyle = .round
porcelain.setStroke()
handle.stroke()

// The surface of the coffee: one amber ellipse, the only warm note inside.
let brew = NSBezierPath(ovalIn: NSRect(x: cx - 186, y: bodyTop - 40, width: 372, height: 74))
amber.setFill()
brew.fill()

NSGraphicsContext.current?.restoreGraphicsState()
image.unlockFocus()

// Emit the iconset and compile to icns.
let iconset = URL(fileURLWithPath: "Resources/awake.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 1 ? "" : "@2x"
        try! rep.representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

// The studio surface wants a flat PNG too (the project row's `icon`).
let webRep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
webRep.size = NSSize(width: 512, height: 512)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: webRep)
image.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512))
NSGraphicsContext.restoreGraphicsState()
try! webRep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Resources/icon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/awake.icns"]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Resources/awake.icns + Resources/icon.png written")
