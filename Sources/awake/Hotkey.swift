import AwakeKit
import Foundation
import Keymap
import SwiftUI

/// `awake hotkey` — the remap surface without a settings window. The CLI symlink
/// resolves into the .app bundle, so this writes the SAME UserDefaults domain the
/// daemon's KeymapStore reads; a daemon bounce picks the change up.
@MainActor
enum Hotkey {
    static func run(_ args: [String]) {
        let store = KeymapStore<AwakeAction>()
        guard let spec = args.first else {
            let current = store.combos(for: .toggleSession, .global)
            print("global hotkey: \(current.map(\.display).joined(separator: ", "))")
            print("remap: awake hotkey ctrl+alt+cmd+a · reset: awake hotkey --reset")
            return
        }
        if spec == "--reset" {
            store.reset(.toggleSession)
            bounceDaemon()
            print("hotkey reset to default: "
                + store.combos(for: .toggleSession, .global).map(\.display).joined(separator: ", "))
            return
        }
        guard let combo = parse(spec) else {
            Client.die("can't parse '\(spec)' — grammar: [ctrl+][alt+][cmd+][shift+]<key>, e.g. ctrl+alt+cmd+a")
        }
        for old in store.combos(for: .toggleSession, .global) {
            store.remove(old, plane: .global, from: .toggleSession)
        }
        if let rejection = store.add(combo, plane: .global, to: .toggleSession) {
            store.reset(.toggleSession) // never leave the action unbound on failure
            Client.die(rejection.message(for: combo))
        }
        bounceDaemon()
        print("global hotkey: \(combo.display)")
    }

    /// "ctrl+alt+cmd+a" → KeyCombo. Modifier aliases match common muscle memory.
    private static func parse(_ s: String) -> KeyCombo? {
        var modifiers: EventModifiers = []
        var key: String?
        for token in s.lowercased().split(separator: "+") {
            switch token {
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            default:
                guard key == nil else { return nil }
                key = String(token)
            }
        }
        guard let key else { return nil }
        return KeyCombo(key, modifiers)
    }

    /// The daemon's Carbon registrations only rebuild in-process; a kickstart makes
    /// the new binding live now instead of at next login.
    private static func bounceDaemon() {
        _ = AwakeKit.run("/bin/launchctl",
                         ["kickstart", "-k", "gui/\(getuid())/\(Paths.launchdLabel)"])
    }
}
