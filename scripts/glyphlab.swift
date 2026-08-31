// glyphlab — live menu-bar preview of candidate icon states, in the real bar at
// real size. ONE status item: left click switches variant, right click cycles the
// state (off → idle → ask → lid); the label reads "a·lid". Edit the `variants`
// table, rerun, look. Quit with ⌃C in the terminal that ran it.
// Palette layer order [cup, steam] matches Daemon.swift's glyphs. Overlay states
// compose onto the FILLED cup with steam cleared, so every state shares one
// symbol's metrics and the bar never shifts.
import AppKit

let label = NSColor.labelColor
let amber = NSColor(name: nil) { _ in
    NSColor.systemOrange.blended(withFraction: 0.45, of: .labelColor) ?? .systemOrange
}
let orange = NSColor.systemOrange
let burn = NSColor(name: nil) { _ in
    NSColor.systemRed.blended(withFraction: 0.35, of: .systemOrange) ?? .systemRed
}

func g(
    _ symbol: String, _ cup: NSColor, _ steam: NSColor, weight: NSFont.Weight = .regular
) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [cup, steam]))
    return NSImage(systemSymbolName: symbol, accessibilityDescription: "glyphlab")!
        .withSymbolConfiguration(cfg)!
}

let filled = "cup.and.heat.waves.fill"
let outline = "cup.and.heat.waves"

enum Spot { case topRight, steam }

/// Draw `mark` over `base` at draw time (dynamic colors keep re-resolving).
/// `.steam` puts the mark where the heat waves live — above the cup body.
func overlay(
    _ base: NSImage, _ symbol: String, _ color: NSColor, at spot: Spot,
    pointSize: CGFloat = 8, weight: NSFont.Weight = .bold
) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    let mark = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    let size = base.size
    return NSImage(size: size, flipped: false) { _ in
        base.draw(in: NSRect(origin: .zero, size: size))
        let m = mark.size
        let origin: NSPoint =
            switch spot {
            case .topRight: NSPoint(x: size.width - m.width, y: size.height - m.height)
            case .steam: NSPoint(x: (size.width - m.width) / 2 - 1, y: size.height - m.height)
            }
        mark.draw(in: NSRect(origin: origin, size: m))
        return true
    }
}

/// The filled cup with steam cleared — the composition base every overlay rides.
func cupOnly(_ color: NSColor) -> NSImage { g(filled, color, .clear) }

struct Variant {
    let name: String
    let states: [(String, NSImage)]
}

let variants: [Variant] = [
    // a — idle in amber: outline off · amber cup on · "?" as the steam for ask
    //     · burn-red heavy for lid. The "?" only ever shows while lid is NOT armed.
    Variant(
        name: "a",
        states: [
            ("off", g(outline, label.withAlphaComponent(0.5), .clear)),
            ("idle", cupOnly(amber)),
            ("ask", overlay(cupOnly(amber), "questionmark", orange, at: .steam)),
            ("lid", g(filled, burn, burn, weight: .heavy)),
        ]),
    // b — same set, idle in full orange, "?" in ink for contrast on the orange cup
    Variant(
        name: "b",
        states: [
            ("off", g(outline, label.withAlphaComponent(0.5), .clear)),
            ("idle", cupOnly(orange)),
            ("ask", overlay(cupOnly(orange), "questionmark", label, at: .steam)),
            ("lid", g(filled, burn, burn, weight: .heavy)),
        ]),
]

final class Lab: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var variant = 0
    var state = 0

    func setUp() {
        guard let button = item.button else { return }
        button.imagePosition = .imageLeft
        button.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        render()
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            state = (state + 1) % variants[variant].states.count
        } else {
            variant = (variant + 1) % variants.count
        }
        render()
    }

    func render() {
        guard let button = item.button else { return }
        let v = variants[variant]
        let (name, image) = v.states[state]
        button.image = image
        button.title = "\(v.name)·\(name)"
        button.toolTip = "left click: variant · right click: state"
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let lab = Lab()
lab.setUp()
app.run()
