import AppKit
import AwakeSurface
import Foundation

// awake-scene: compiles scene scripts into the timelines @ag/macos-session plays.
//   awake-scene scenes/agent.scene...        writes scenes/agent.json beside each script
//     --out DIR     (repeatable) write them there instead
//     --art         also write art.json: the glyphs and icon, drawn by the app's own code
//     --watch       recompile whenever a script changes (the studio loop)
// A step the app cannot do (a menu row that does not exist, a command that fails)
// stops the compile with the script's line number: a scene never shows what awake
// would not.

// One clock for every machine: a scene renders the same timeline in any timezone.
NSTimeZone.default = TimeZone(identifier: "UTC")!
// The engine logs every transition to stderr; the compiler speaks on stdout.
freopen("/dev/null", "w", stderr)

var scripts: [String] = []
var outs: [String] = []
var withArt = false
var watch = false
var argv = CommandLine.arguments.dropFirst()
while let a = argv.popFirst() {
    switch a {
    case "--out":
        guard let d = argv.popFirst() else { fatalError("--out DIR") }
        outs.append(d)
    case "--art": withArt = true
    case "--watch": watch = true
    default: scripts.append(a)
    }
}
guard !scripts.isEmpty else {
    print("usage: awake-scene <scene>... [--out DIR]... [--art] [--watch]")
    exit(2)
}

@MainActor
func destinations(beside script: String) -> [URL] {
    (outs.isEmpty ? [URL(fileURLWithPath: script).deletingLastPathComponent().path] : outs)
        .map { URL(fileURLWithPath: $0) }
}

@MainActor
func write(_ data: Data, _ name: String, beside script: String) {
    for dir in destinations(beside: script) {
        let dest = dir.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! data.write(to: dest, options: .atomic)
        print("✓ \(dest.path)")
    }
}

func encode<T: Encodable>(_ value: T) -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try! enc.encode(value) + Data("\n".utf8)
}

/// One script → its timeline in every output dir. False when the script is wrong.
@MainActor
func compile(_ script: String) -> Bool {
    let url = URL(fileURLWithPath: script)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        print("✗ \(script): unreadable")
        return false
    }
    let player = Player()
    do {
        try player.play(source)
    } catch let e as ScriptError {
        print("✗ \(script):\(e.line): \(e.message)")
        return false
    } catch {
        print("✗ \(script): \(error)")
        return false
    }
    write(
        encode(player.timeline()), url.deletingPathExtension().lastPathComponent + ".json",
        beside: script)
    return true
}

@MainActor
func png(_ draw: (NSRect) -> Void, points: NSSize, scale: CGFloat) -> String {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(points.width * scale),
        pixelsHigh: Int(points.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0)!
    rep.size = points
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(origin: .zero, size: points))
    NSGraphicsContext.restoreGraphicsState()
    return "data:image/png;base64,"
        + rep.representation(using: .png, properties: [:])!.base64EncodedString()
}

@MainActor
func art() -> Art {
    var glyphs: [String: [String: String]] = [:]
    for g in Glyph.allCases {
        let image = g.image
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                glyphs[g.rawValue, default: [:]][name] = png(
                    { image.draw(in: $0) }, points: image.size, scale: 3)
            }
        }
    }
    let icon = NSImage(contentsOfFile: "Resources/icon.png")
    precondition(icon != nil, "Resources/icon.png missing: run from the awake checkout")
    return Art(
        icon: png({ icon!.draw(in: $0) }, points: NSSize(width: 64, height: 64), scale: 2),
        glyphs: glyphs)
}

var ok = true
for s in scripts { ok = compile(s) && ok }
if withArt { write(encode(art()), "art.json", beside: scripts[0]) }

// The output dirs are the compiler's: a timeline whose script is gone (renamed,
// deleted) goes too, so no consumer plays a scene the app no longer has. Only
// after a clean full compile, when the produced set is the whole truth.
if ok {
    let produced = Set(
        scripts.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent + ".json" }
            + (withArt ? ["art.json"] : []))
    for dir in Set(scripts.flatMap { destinations(beside: $0) }) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasSuffix(".json") && !produced.contains(f) {
            if f == "art.json" && !withArt { continue }
            try! FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            print("- \(dir.appendingPathComponent(f).path)")
        }
    }
}
guard watch else { exit(ok ? 0 : 1) }

func mtime(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}
var seen = Dictionary(uniqueKeysWithValues: scripts.map { ($0, mtime($0)) })
print("watching \(scripts.joined(separator: ", "))")
while true {
    usleep(250_000)
    for s in scripts where mtime(s) != seen[s] {
        seen[s] = mtime(s)
        _ = compile(s)
    }
}
