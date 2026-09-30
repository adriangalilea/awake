import Foundation

/// The file the web plays: @ag/macos-session's `Timeline`, field for field. Steps are
/// relative (`delay` = the author's pause before a step, absent = the player's
/// default), and say who caused them (`author`), because pacing (typing speed, how
/// long a line takes to read) belongs to the player and is never decided twice.
struct Timeline: Encodable {
    let app: String
    /// The toggle chord, as the menu draws it.
    let chord: String
    let steps: [Step]
}

struct Step: Encodable {
    var kind: Kind
    /// The script did this; absent = awake's reaction to it.
    var author: Bool?
    var delay: Int?
    /// command · output · muted · banner · caption
    var text: String?
    /// menu
    var rows: [Row]?
    /// hover · press: indices into the open menu, then its submenu
    var path: [Int]?
    /// glyph
    var glyph: String?
    var tooltip: String?
    /// key
    var keys: String?
    /// world
    var world: WorldState?
    /// agent (its working directory) · tool (its argument)
    var arg: String?
    /// tool: what came back, one line each
    var lines: [String]?

    enum Kind: String, Encodable {
        case world, glyph, command, output, muted, menu, close, hover, press, key
        case rightClick = "right-click"
        case banner, caption
        case agent, history, prompt, say, tool, work, done
    }

    init(_ kind: Kind, delay: Int? = nil) {
        self.kind = kind
        self.delay = delay
    }
}

/// A separator is `{"separator": true}` and nothing else; an item says only what
/// is true of it.
struct Row: Encodable {
    let title: String
    let separator: Bool
    let enabled: Bool
    let checked: Bool
    let chord: String?
    let submenu: [Row]?

    enum Key: String, CodingKey { case title, separator, disabled, checked, chord, submenu }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        if separator { return try c.encode(true, forKey: .separator) }
        try c.encode(title, forKey: .title)
        if !enabled { try c.encode(true, forKey: .disabled) }
        if checked { try c.encode(true, forKey: .checked) }
        try c.encodeIfPresent(chord, forKey: .chord)
        try c.encodeIfPresent(submenu, forKey: .submenu)
    }
}

/// The Mac as the stage shows it.
struct WorldState: Encodable, Equatable {
    let clock: String
    let battery: Int
    let charging: Bool
    let lid: String
    let asleep: Bool
    let heat: Bool
}

/// The glyph art, rendered by the app's own drawing code: one PNG per state per
/// menu bar appearance. Its own file: pixels depend on the macOS that drew them,
/// the timeline must not.
struct Art: Encodable {
    let icon: String
    let glyphs: [String: [String: String]]
}
