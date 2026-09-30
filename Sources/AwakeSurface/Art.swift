import AppKit
import Keymap
import SwiftUI

/// The Keymap contract: one action, one spec. The global default follows the library's
/// modifier doctrine, a deliberate heavy chord on the identity initial (⌃⌥⌘A).
/// Remaps overlay via KeymapStore in UserDefaults; the spec IS the default.
public enum AwakeAction: String, ActionSet {
    case toggleSession

    public var spec: Spec {
        Spec(
            title: String(localized: "Toggle Awake Session"),
            symbol: "cup.and.heat.waves.fill",
            global: [KeyCombo("a", [.control, .option, .command])])
    }

    public static var sections: [ActionSection<AwakeAction>] {
        [ActionSection("awake", [.toggleSession])]
    }
}

extension Glyph {
    /// The menu bar image. Palette layer order verified by rendering: [cup, steam];
    /// overlays compose onto the filled cup so every held state shares one set of
    /// metrics and the bar never shifts. Dynamic colors re-resolve per menu-bar
    /// appearance at draw time, and so does the overlay closure.
    @MainActor
    public var image: NSImage {
        switch self {
        case .off: Art.off
        case .on: Art.on
        case .ask: Art.ask
        case .lid: Art.lid
        }
    }
}

@MainActor
private enum Art {
    static let burn = NSColor(name: nil) { _ in
        NSColor.systemRed.blended(withFraction: 0.35, of: .systemOrange) ?? .systemRed
    }

    static func glyph(
        _ symbol: String, _ cup: NSColor, _ steam: NSColor, weight: NSFont.Weight = .regular
    ) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [cup, steam]))
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "awake")?
            .withSymbolConfiguration(cfg)
        precondition(img != nil, "SF Symbol \(symbol) missing")
        return img!
    }

    /// `mark` drawn where the heat waves live, above the cup body.
    static func steamMark(_ base: NSImage, _ symbol: String, _ color: NSColor) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let mark = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(cfg)!
        let size = base.size
        return NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: size))
            let m = mark.size
            mark.draw(
                in: NSRect(
                    origin: NSPoint(x: (size.width - m.width) / 2 - 1, y: size.height - m.height),
                    size: m))
            return true
        }
    }

    static let off = glyph("cup.and.heat.waves", .labelColor.withAlphaComponent(0.5), .clear)
    static let on = glyph("cup.and.heat.waves.fill", .systemOrange, .clear)
    static let ask = steamMark(on, "questionmark", .labelColor)
    static let lid = glyph("cup.and.heat.waves.fill", burn, burn, weight: .heavy)
}
