import AwakeKit
import AwakeSurface
import Foundation
import Keymap

import enum Grant.NotificationReach
import enum Grant.Notifications  // scoped: Grant's own Claim would shadow AwakeKit's

struct ScriptError: Error {
    let line: Int
    let message: String
}

/// Plays a scene script through the real engine. The script says what happens in
/// the world and what the human does; every word, glyph and banner that results is
/// the app's own, recorded as it happens.
///
/// One step per line, `#` comments, `@<ms>` in front of a step for a pause:
///   world    clock 21:04 · battery 64 · power ac|battery · low-power on|off
///            thermal critical|nominal · grant ready|missing · floor 15
///            notifications allowed|denied|silenced|not-asked
///            process 4127 claude · exit 4127 · time +2h40m · lid close|open
///            (several on one line, joined by ` · `, happen at once)
///   terminal $ awake -w 4127 --lid     ($! when the command is meant to fail)
///   menu     open menu · hover "Title" · click "Title" · close menu
///   gestures key (the toggle chord) · right-click
///   stage    caption "text" · wait 1200
/// Show, then tell: a caption goes AFTER the step it explains, so the viewer sees
/// the thing happen and then reads what it was. Pauses are rarely needed: the player
/// waits for everything a step put on screen to be read before the next one.
@MainActor
final class Player {
    private let world: ScriptedWorld
    private let machine: StateMachine
    private let chord = AwakeAction.toggleSession.spec.global.first!.display
    private(set) var steps: [Step] = []
    private var banners: [String] = []
    private var shownGlyph: Glyph?
    private var shownWorld: WorldState?
    /// The open menu's visible rows, and the row the pointer rests on.
    private var menu: [MenuRow]?
    private var hovered: Int?
    private var pendingDelay: Int?
    private var line = 0

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    init() {
        // The evening starts at 21:00 on a fixed day: a scene renders the same
        // timeline on every machine, in every timezone.
        world = ScriptedWorld(now: Date(timeIntervalSince1970: 1_790_000_000))
        machine = StateMachine(world: world)
        machine.notify = { [unowned self] reason, ended, remaining in
            if let m = Notice.compose(reason, ended: ended, remaining: remaining, now: world.now) {
                banners.append(m)
            }
        }
        machine.onForcedSleep = { [unowned self] in banners.append(Notice.forcedSleep(percent: $0))
        }
        precondition(setClock("21:00"))
    }

    func timeline() -> Timeline { Timeline(app: "awake", chord: chord, steps: steps) }

    func play(_ source: String) throws {
        for (i, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        {
            line = i + 1
            var text = raw.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { continue }
            var delay: Int?
            if text.hasPrefix("@") {
                let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
                guard let ms = Int(parts[0]), parts.count == 2 else { throw fail("'@<ms> <step>'") }
                delay = ms
                text = String(parts[1])
            }
            if let d = delay { pendingDelay = (pendingDelay ?? 0) + d }
            try step(text)
            settle()
        }
        guard menu == nil else { throw fail("the scene ends with the menu open; close it") }
    }

    // MARK: - Steps

    private func step(_ text: String) throws {
        if text.hasPrefix("$! ") {
            return try command(String(text.dropFirst(3)), expectFailure: true)
        }
        if text.hasPrefix("$ ") {
            return try command(String(text.dropFirst(2)), expectFailure: false)
        }
        let words = text.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = words.count > 1 ? words[1] : ""
        switch words[0] {
        case "open" where rest == "menu": openMenu()
        case "close" where rest == "menu":
            guard menu != nil else { throw fail("no menu is open") }
            closeMenu(emit: true)
        case "hover":
            let path = try resolve(quoted(rest))
            hovered = path[0]
            emit(Step(.hover), path: path, author: true)
        case "click":
            let path = try resolve(quoted(rest))
            let row = row(at: path)
            guard let action = row.action else {
                throw fail("'\(row.title)' does nothing when clicked; hover it for its submenu")
            }
            emit(Step(.press), path: path, author: true)
            closeMenu(emit: false)
            try effect(machine.perform(action))
        case "key":
            guard rest.isEmpty else {
                throw fail("'key' plays the toggle chord, \(chord), and takes nothing")
            }
            var s = Step(.key)
            s.keys = chord
            emit(s, author: true)
            try effect(machine.toggle())
        case "right-click":
            emit(Step(.rightClick), author: true)
            try effect(machine.toggle())
        case "caption":
            var s = Step(.caption)
            s.text = try quoted(rest)
            emit(s, author: true)
        case "wait":
            guard let ms = Int(rest) else { throw fail("'wait <ms>'") }
            pendingDelay = (pendingDelay ?? 0) + ms
        default:
            try worldStep(text)
        }
    }

    private func command(_ text: String, expectFailure: Bool) throws {
        let argv = try shellWords(text)
        guard let exe = argv.first, exe == "awake" || exe == "asleep" else {
            throw fail("only awake and asleep run in a scene")
        }
        var s = Step(.command)
        s.text = text
        emit(s, author: true)
        let host = CLI.Host(
            now: world.now,
            process: { [world] pid in world.processes[pid].map { ($0.started, $0.name) } },
            executable: { _ in true })
        let failure: String?
        switch CLI.parse(Array(argv.dropFirst()), asleep: exe == "asleep", host: host) {
        case .failure(let e):
            failure = e.message
        case .success(let verb):
            let out = CLI.output(verb, machine.serve(verb.command), now: world.now, running: nil)
            failure = out.failure
            for l in out.lines {
                var o = Step(l.allSatisfy { $0.tone == .muted } ? .muted : .output)
                o.text = l.map(\.text).joined()
                emit(o, author: false)
            }
        }
        if let failure {
            guard expectFailure else {
                throw fail("`\(text)` failed: \(failure) (write $! if that is the point)")
            }
            var o = Step(.output)
            o.text = "awake: \(failure)"
            emit(o, author: false)
        } else if expectFailure {
            throw fail("`\(text)` succeeded, but $! says it should fail")
        }
    }

    private func worldStep(_ text: String) throws {
        for fact in text.components(separatedBy: " · ") {
            let w = fact.split(separator: " ").map(String.init)
            guard w.count >= 2 else { throw fail("unknown step '\(fact)'") }
            switch (w[0], w[1]) {
            case ("clock", let t): try guarded(setClock(t), "'clock HH:MM'")
            case ("battery", let n):
                guard let p = Int(n), (0...100).contains(p) else { throw fail("'battery 0-100'") }
                world.battery = p
            case ("power", "ac"): world.onAC = true
            case ("power", "battery"): world.onAC = false
            case ("low-power", "on"): world.lowPower = true
            case ("low-power", "off"): world.lowPower = false
            case ("thermal", "critical"): world.thermalCritical = true
            case ("thermal", "nominal"): world.thermalCritical = false
            case ("grant", "ready"): world.grant = true
            case ("grant", "missing"): world.grant = false
            case ("floor", let n):
                guard let p = Int(n) else { throw fail("'floor <percent>'") }
                machine.setFloor(p)
            case ("notifications", let r):
                let reach: [String: NotificationReach] = [
                    "allowed": .allowed, "denied": .denied, "silenced": .silenced,
                    "not-asked": .notAsked,
                ]
                guard let v = reach[r] else {
                    throw fail("notifications \(reach.keys.sorted().joined(separator: "|"))")
                }
                world.reach = v
            case ("process", let pid):
                guard let p = Int32(pid), w.count == 3 else { throw fail("'process <pid> <name>'") }
                world.processes[p] = (world.now.timeIntervalSince1970, w[2])
            case ("exit", let pid):
                guard let p = Int32(pid), world.processes.removeValue(forKey: p) != nil else {
                    throw fail("no process \(pid) to exit")
                }
            case ("time", let d):
                guard d.hasPrefix("+"), let t = CLI.parseDuration(String(d.dropFirst())) else {
                    throw fail("'time +2h40m'")
                }
                world.now = world.now.addingTimeInterval(t)
            case ("lid", "close"): world.lidClosed = true
            case ("lid", "open"):
                world.lidClosed = false
                world.asleep = false
            default: throw fail("unknown step '\(fact)'")
            }
        }
        // The change itself shows first, then what awake does about it.
        showWorld(author: true)
        // What the daemon hears: IOPS, thermal and poll ticks. An asleep Mac hears nothing.
        if !world.asleep { machine.tick() }
    }

    // MARK: - Menu

    private func openMenu() {
        let st = machine.status()  // the heartbeat first, as menuNeedsUpdate does
        let rows = Menu.rows(
            MenuInput(
                status: st, now: world.now, sudoers: Menu.sudoersStanding(ready: world.grant),
                notifications: Notifications.standing(world.reach),
                lastMinutes: machine.config.lastMinutes))
        menu = visible(rows)
        hovered = nil
        var s = Step(.menu)
        s.rows = menu!.map(export)
        emit(s, author: true)
    }

    private func closeMenu(emit close: Bool) {
        menu = nil
        hovered = nil
        if close { emit(Step(.close), author: true) }
    }

    private func visible(_ rows: [MenuRow]) -> [MenuRow] {
        rows.filter { !$0.hidden }.map {
            var r = $0
            r.submenu = r.submenu.map(visible)
            return r
        }
    }

    private func export(_ row: MenuRow) -> Row {
        Row(
            title: row.title.trimmingCharacters(in: .whitespaces), separator: row.separator,
            enabled: row.enabled, checked: row.checked, chord: row.toggle ? chord : nil,
            submenu: row.submenu?.map(export))
    }

    /// A title in the open menu, else in the hovered row's submenu.
    private func resolve(_ title: String) throws -> [Int] {
        guard let rows = menu else { throw fail("no menu is open") }
        let match = { (r: MenuRow) in
            !r.separator && r.title.trimmingCharacters(in: .whitespaces) == title
        }
        if let i = rows.firstIndex(where: match) { return [i] }
        if let h = hovered, let sub = rows[h].submenu, let j = sub.firstIndex(where: match) {
            return [h, j]
        }
        let here = rows.filter { !$0.separator }.map {
            "\"\($0.title.trimmingCharacters(in: .whitespaces))\""
        }
        let under =
            hovered.flatMap { rows[$0].submenu }?.filter { !$0.separator }.map { "\"\($0.title)\"" }
            ?? []
        throw fail(
            "no row \"\(title)\" in the menu. It has: \(here.joined(separator: ", "))"
                + (under.isEmpty ? "" : "; the open submenu has: \(under.joined(separator: ", "))"))
    }

    private func row(at path: [Int]) -> MenuRow {
        let top = menu![path[0]]
        return path.count == 1 ? top : top.submenu![path[1]]
    }

    // MARK: - Consequences

    private func effect(_ effect: Effect?) throws {
        switch effect {
        case nil: break
        case .notify(let message): banners.append(message)
        case .offerGrant:
            throw fail(
                "that gesture raises the admin sheet (the grant is missing); a scene cannot play it"
            )
        case .notificationsGrant:
            throw fail("that click opens System Settings; a scene cannot play it")
        case .quit: throw fail("Quit ends the scene's machine")
        }
    }

    /// The world's physics and everything the step caused, recorded in the order a
    /// person would see it: banners, then the glyph, then the Mac itself.
    private func settle() {
        // A closed lid with nothing holding the flag is clamshell sleep.
        if world.lidClosed, !world.sleepDisabled() { world.asleep = true }
        for b in banners {
            var s = Step(.banner)
            s.text = b
            emit(s, author: false)
        }
        banners = []
        let glyph = Glyph(
            claimsEmpty: machine.claims.isEmpty, suspended: machine.suspended,
            lidArmed: machine.lidArmed, askPending: machine.askPending)
        if glyph != shownGlyph {
            shownGlyph = glyph
            var s = Step(.glyph)
            s.glyph = glyph.rawValue
            s.tooltip = Glyph.tooltip(machine.claims, suspended: machine.suspended, now: world.now)
            emit(s, author: false)
        }
        showWorld(author: false)
    }

    private func showWorld(author: Bool) {
        let power = world.power()
        let state = WorldState(
            clock: Self.clock.string(from: world.now), battery: power.percent, charging: power.onAC,
            lid: world.lidClosed ? "closed" : "open", asleep: world.asleep,
            heat: world.thermalCritical)
        // An authored change always lands, even one the stage cannot show (a process
        // exiting): it is the cause the reactions after it wait behind.
        if author || state != shownWorld {
            shownWorld = state
            var s = Step(.world)
            s.world = state
            emit(s, author: author)
        }
    }

    /// `author`: the script did this (a command, a click, the lid, a caption), as
    /// opposed to awake answering it (output, a banner, the glyph, the Mac going to
    /// sleep). The player gives the viewer time to read what the last author step
    /// caused before it plays the next one; a reaction follows its cause at once.
    /// Only author steps carry the script's `@` pauses.
    private func emit(_ step: Step, path: [Int]? = nil, author: Bool) {
        var s = step
        if let path { s.path = path }
        if author {
            s.author = true
            s.delay = pendingDelay
            pendingDelay = nil
        }
        steps.append(s)
    }

    // MARK: - Parsing helpers

    private func setClock(_ t: String) -> Bool {
        let parts = t.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
            return false
        }
        let day = Calendar.current.startOfDay(for: world.now)
        world.now = day.addingTimeInterval(TimeInterval(parts[0] * 3600 + parts[1] * 60))
        return true
    }

    private func guarded(_ ok: Bool, _ usage: String) throws {
        if !ok { throw fail(usage) }
    }

    private func quoted(_ s: String) throws -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else {
            throw fail("expected a \"quoted\" title")
        }
        return String(s.dropFirst().dropLast())
    }

    /// Spaces split, double quotes group.
    private func shellWords(_ s: String) throws -> [String] {
        var words: [String] = []
        var cur = ""
        var quoted = false
        for ch in s {
            if ch == "\"" {
                quoted.toggle()
            } else if ch == " ", !quoted {
                if !cur.isEmpty { words.append(cur) }
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        guard !quoted else { throw fail("unclosed quote") }
        if !cur.isEmpty { words.append(cur) }
        return words
    }

    private func fail(_ message: String) -> ScriptError {
        ScriptError(line: line, message: message)
    }
}
