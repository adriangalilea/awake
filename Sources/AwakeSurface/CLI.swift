import AwakeKit
import Foundation

import enum Grant.Notifications  // scoped: Grant's own Claim would shadow AwakeKit's

/// The CLI as two pure functions: argv → `Verb`, and (verb, reply) → `Output`. The
/// binary does the IO between them (the socket, the terminal); a scene runs the same
/// two against a scripted machine, so its terminal shows what `awake` really prints.
public enum CLI {
    public static let usage = """
        awake: close the lid, your Mac stays awake. One state machine, menu bar + CLI.

        The machine stays awake while ANY claim exists; claims coexist instead of
        replacing each other. Yours, an agent's process watch, a build's timer: each is
        its own claim, and sleep restores when the last one ends.

          awake                 indefinite claim (lid + idle)
          awake 2h | 90m | 45   timed claim (bare number = minutes)
          awake --until HH:MM   until a wall-clock time (tomorrow if already past)
          awake -w PID          while a process lives (builds, agents, jobs); named after it
          awake --label NAME .. name the claim (who wants this; default "you", -w names itself)
          awake --lid ...       ask for lid-closed survival (named claims; you grant it)
          awake --display ...   also keep the display on for this claim
          awake --on-end CMD .. run CMD when this claim ends, any reason (sh -c, $1 = why)
          awake check [WHO]     is the wish honored right now? exit 0 in effect · 2 inert · 3 gone
          awake allow [WHO]     grant a pending lid ask (all, or owner prefix / pid)
          awake deny [WHO]      dismiss it; after a grant, this revokes
          awake suspend         let it sleep: every claim kept, effect off (= right-click / ⌃⌥⌘A)
          awake resume          lift the switch, claims take effect again
          asleep | awake off    END every claim, restore normal sleep
          awake off WHO         end matching claims only (owner prefix or pid)
          awake status [--json] all claims + effect + battery, honestly
          awake floor N         battery floor percent (0 disables)
          awake display [on|off] keep the screen on while anything holds the Mac awake
          awake notify [CMD]    out-of-band hook for closed-lid ends (--clear removes)
          awake updates [on|off] the daily version check (one GET, counts as an active install)
          awake hotkey [COMBO]  show/remap the global toggle (--reset for default)
          awake skill [install|remove]  the agent skill, for Claude Code and Codex
          awake grant           install the scoped sudoers grant (once)
          awake grant --remove  remove it · --force reinstalls over an existing rule
          awake agent install   register the agent for THIS bundle (or restart it into it)
          awake agent uninstall stop it and unregister it

        Lid-closed survival is YOURS to grant. Your own claims (menu, hotkey, bare
        `awake`) carry it; a named claim (any programmatic caller: a cron job, a
        build, a script, a coding agent) runs lid-open only and may ASK with --lid.
        The ask shows as ? in the menu bar and leads the menu; grant it there or with
        `awake allow`. A grant dies with the claim it answered.

        Global hotkey (default ⌃⌥⌘A) and right-click on the menu bar cup toggle YOUR
        claim only: yours running → end it (lid disarms, named claims keep working);
        none → start yours at the last menu-chosen duration; suspended → resume and
        start yours. "Let it sleep" (everything inert) is the menu item / `awake
        suspend`, an explicit act, never this gesture.
        Battery floor: at the floor every claim ends; if the Mac is still awake below it
        with the display dark (someone else's assertion), it is put to sleep.
        """

    /// A verb that talks to the daemon.
    public enum Verb: Sendable {
        case engage(Claim)
        case end(String?)
        case check(String?)
        case lid(granted: Bool, String?)
        case suspend
        case resume
        case status(json: Bool)
        case floor(Int)
        case display(Bool?)
        case notify(Notify)
        case updates(Bool?)

        public enum Notify: Sendable {
            case show, clear
            case set(String)
        }

        public var command: Command {
            switch self {
            case .engage(let c): return .engage(c)
            case .end(let t): return .end(t)
            case .check, .status, .display(nil), .notify(.show), .updates(nil): return .status
            case .lid(let granted, let t): return granted ? .allowLid(t) : .denyLid(t)
            case .suspend: return .suspend
            case .resume: return .resume
            case .floor(let v): return .setFloor(v)
            case .display(let on?): return .setKeepDisplay(on)
            case .notify(.clear): return .setNotifyCommand("")
            case .notify(.set(let path)): return .setNotifyCommand(path)
            case .updates(let on?): return .setUpdateCheck(on)
            }
        }
    }

    /// What parsing needs from outside: the clock, the process table (`-w`), and
    /// the filesystem (`notify PATH`).
    public struct Host {
        public var now: Date
        public var process: (Int32) -> (started: Double, name: String?)?
        public var executable: (String) -> Bool

        public init(
            now: Date, process: @escaping (Int32) -> (started: Double, name: String?)?,
            executable: @escaping (String) -> Bool
        ) {
            self.now = now
            self.process = process
            self.executable = executable
        }
    }

    public struct ParseError: Error, Sendable {
        public let message: String
    }

    /// `args` without argv[0]. `asleep` is its own spelling of `awake off`.
    public static func parse(_ args: [String], asleep: Bool = false, host: Host) -> Result<
        Verb, ParseError
    > {
        func fail(_ m: String) -> Result<Verb, ParseError> { .failure(ParseError(message: m)) }
        let second = args.count > 1 ? args[1] : nil
        if asleep { return .success(.end(args.first)) }
        switch args.first {
        case "status": return .success(.status(json: args.contains("--json")))
        case "off": return .success(.end(second))
        case "suspend": return .success(.suspend)
        case "resume": return .success(.resume)
        case "check": return .success(.check(second))
        case "allow": return .success(.lid(granted: true, second))
        case "deny": return .success(.lid(granted: false, second))
        case "floor":
            guard args.count == 2, let v = Int(args[1]) else {
                return fail("usage: awake floor <percent>")
            }
            return .success(.floor(v))
        case "display":
            switch second {
            case nil: return .success(.display(nil))
            case "on": return .success(.display(true))
            case "off": return .success(.display(false))
            default: return fail("usage: awake display [on|off]")
            }
        case "notify":
            switch second {
            case nil: return .success(.notify(.show))
            case "--clear": return .success(.notify(.clear))
            case let path?:
                let full = (path as NSString).expandingTildeInPath
                guard host.executable(full) else { return fail("not an executable file: \(full)") }
                return .success(.notify(.set(full)))
            }
        case "updates":
            switch second {
            case nil: return .success(.updates(nil))
            case "on": return .success(.updates(true))
            case "off": return .success(.updates(false))
            default: return fail("usage: awake updates [on|off]")
            }
        default:
            return engage(args, host: host)
        }
    }

    private static func engage(_ args: [String], host: Host) -> Result<Verb, ParseError> {
        func fail(_ m: String) -> Result<Verb, ParseError> { .failure(ParseError(message: m)) }
        var term = Term.indefinite
        var owner = Claim.humanOwner
        var rest = args
        var display = false
        if let i = rest.firstIndex(of: "--display") {
            display = true
            rest.remove(at: i)
        }
        var wantsLid = false
        if let i = rest.firstIndex(of: "--lid") {
            wantsLid = true
            rest.remove(at: i)
        }
        var onEnd = ""
        if let i = rest.firstIndex(of: "--on-end") {
            guard rest.count > i + 1, !rest[i + 1].isEmpty else {
                return fail("usage: awake --on-end CMD ...")
            }
            onEnd = rest[i + 1]
            rest.removeSubrange(i...i + 1)
        }
        if let i = rest.firstIndex(of: "--label") {
            guard rest.count > i + 1, !rest[i + 1].isEmpty else {
                return fail("usage: awake --label NAME ...")
            }
            owner = rest[i + 1]
            rest.removeSubrange(i...i + 1)
        }
        if let i = rest.firstIndex(of: "--until") {
            guard rest.count > i + 1, let date = parseUntil(rest[i + 1], now: host.now) else {
                return fail("usage: awake --until HH:MM")
            }
            term = .until(date)
            rest.removeSubrange(i...i + 1)
        }
        if let i = rest.firstIndex(of: "-w") {
            guard rest.count > i + 1, let pid = Int32(rest[i + 1]) else {
                return fail("usage: awake -w <pid>")
            }
            guard let proc = host.process(pid) else { return fail("no such process: \(pid)") }
            term = .whilePid(pid: pid, started: proc.started)
            // The watched process names the claim: "claude · while it runs", never
            // a bare pid in the human's menu bar.
            if owner == Claim.humanOwner { owner = proc.name ?? "pid \(pid)" }
            rest.removeSubrange(i...i + 1)
        }
        if let token = rest.first {
            guard rest.count == 1, let seconds = parseDuration(token) else {
                return fail("unrecognized: \(rest.joined(separator: " "))\n\n\(usage)")
            }
            guard case .indefinite = term else {
                return fail("-w/--until and a duration are exclusive")
            }
            term = .until(host.now.addingTimeInterval(seconds))
        }
        // Your own gesture carries lid; anyone else's claim is idle-only and lid is
        // an ASK (--lid), granted from the menu or `awake allow`. The daemon
        // enforces the same rule; this split keeps the CLI honest about it.
        var modes: Set<Mode> = owner == Claim.humanOwner ? Claim.defaultModes : [.idle]
        if display { modes.insert(.display) }
        return .success(
            .engage(
                Claim(
                    owner: owner, forced: true, modes: modes, term: term, startedAt: host.now,
                    wantsLid: wantsLid, onEnd: onEnd)))
    }

    /// "HH:MM" wall-clock → the NEXT such time (today, or tomorrow if already past).
    static func parseUntil(_ s: String, now: Date) -> Date? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
            (0...23).contains(h), (0...59).contains(m)
        else { return nil }
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day], from: now)
        c.hour = h
        c.minute = m
        let today = cal.date(from: c)!
        return today > now ? today : cal.date(byAdding: .day, value: 1, to: today)!
    }

    /// "2h", "90m", "1h30m", bare "45" = minutes.
    public static func parseDuration(_ s: String) -> TimeInterval? {
        if let minutes = Int(s) { return minutes > 0 ? TimeInterval(minutes * 60) : nil }
        var total: TimeInterval = 0
        var digits = ""
        for ch in s {
            if ch.isNumber {
                digits.append(ch)
            } else if ch == "h" || ch == "m" {
                guard let n = Int(digits), n > 0 else { return nil }
                total += TimeInterval(n * (ch == "h" ? 3600 : 60))
                digits = ""
            } else {
                return nil
            }
        }
        guard digits.isEmpty else { return nil }
        return total > 0 ? total : nil
    }

    // MARK: - Output

    /// How a span reads on a terminal. The binary maps tones to ANSI; a scene maps
    /// them to its terminal's tiers.
    public enum Tone: Sendable {
        case plain, muted, awake, asleep, warn, alarm
    }

    public struct Span: Sendable {
        public let text: String
        public let tone: Tone
        init(_ text: String, _ tone: Tone = .plain) {
            self.text = text
            self.tone = tone
        }
    }

    public typealias Line = [Span]

    public struct Output: Sendable {
        public var lines: [Line]
        /// Lines go to stderr as `awake: <message>` and the process exits 1.
        public var failure: String?
        public var exit: Int32

        static func lines(_ lines: [Line], exit: Int32 = 0) -> Output {
            Output(lines: lines, failure: nil, exit: exit)
        }
        static func failed(_ message: String) -> Output {
            Output(lines: [], failure: message, exit: 1)
        }
    }

    public static func output(_ verb: Verb, _ reply: Reply, now: Date, running: String?) -> Output {
        let st = reply.status
        let render = { status(st, now: now, running: running) }
        switch verb {
        case .engage:
            guard reply.ok else { return .failed(reply.error ?? "engage failed") }
            var lines: [Line] = []
            if let r = reply.replaced {
                lines.append([Span("replaced own claim: \(Words.describe(r, now: now))", .muted)])
            }
            if let c = reply.coveredBy {
                lines.append([
                    Span(
                        "already covered by \(Words.describe(c, now: now)) · claim added, takes over if that ends",
                        .muted)
                ])
            }
            return .lines(lines + render())
        case .end:
            guard reply.ok else { return .failed(reply.error ?? "end failed") }
            // The undo breadcrumb: what was running lands in the scrollback.
            let ended = (reply.ended ?? []).map {
                [Span("ended: \(Words.describe($0, now: now))", .muted)]
            }
            return .lines(ended + render())
        case .check(let token):
            // A claim is a wish, not a lock: this is how a script asks whether its
            // wish is honored RIGHT NOW. 0 = in effect · 2 = kept but inert · 3 = gone.
            let matches = token.map { Claim.matching($0, in: st.claims) } ?? st.claims
            if matches.isEmpty {
                return .lines(
                    [[Span(token.map { "gone · no claim matches '\($0)'" } ?? "gone · no claims")]],
                    exit: 3)
            }
            if st.suspendedSince != nil {
                return .lines(
                    [[Span("inert · suspended by you · \(matches.count) claim(s) kept")]], exit: 2)
            }
            return .lines([
                [
                    Span(
                        "in effect · "
                            + matches.map { Words.describe($0, now: now) }.joined(separator: " · ")
                            + (st.lidArmed ? " · lid armed" : " · sleeps on lid close"))
                ]
            ])
        case .lid(let granted, _):
            guard reply.ok else {
                return .failed(reply.error ?? (granted ? "allow failed" : "deny failed"))
            }
            return .lines(render())
        case .suspend, .resume, .updates, .status(json: false):
            return .lines(render())
        case .status(json: true):
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            return .lines([[Span(String(data: try! enc.encode(st), encoding: .utf8)!)]])
        case .floor:
            return .lines([
                [Span("battery floor: \(st.floor)%\(st.floor == 0 ? " (disabled)" : "")")]
            ])
        case .display:
            return .lines([
                [
                    Span(
                        st.keepDisplay
                            ? "display: kept on while anything holds the Mac awake"
                            : "display: allowed to sleep (--display opts one claim in)")
                ]
            ])
        case .notify:
            return .lines([
                [
                    Span(
                        st.notifyCommand.isEmpty
                            ? "notify hook: none, closed-lid ends are screen-only"
                            : "notify hook: \(st.notifyCommand)")
                ]
            ])
        }
    }

    /// The status block every verb ends with.
    public static func status(_ st: Status, now: Date, running: String?) -> [Line] {
        var lines: [Line] = []
        if let since = st.suspendedSince {
            lines.append([
                Span("💤 sleeping", .asleep),
                Span(
                    " · suspended by you \(Words.interval(now.timeIntervalSince(since))) ago"
                        + (st.claims.isEmpty
                            ? ""
                            : " · \(st.claims.count) claim\(st.claims.count == 1 ? "" : "s") waiting for `awake resume` / right-click")
                ),
            ])
            for c in st.claims {
                lines.append([Span("   waiting: " + Words.describe(c, now: now), .muted)])
            }
        } else {
            switch st.claims.count {
            case 0:
                lines.append([Span("💤 asleep", .asleep), Span(" · Mac sleeps normally")])
            case 1:
                lines.append([
                    Span("☕ awake", .awake), Span(" · " + Words.describe(st.claims[0], now: now)),
                ])
            default:
                lines.append([Span("☕ awake", .awake), Span(" · \(st.claims.count) claims")])
                for c in st.claims { lines.append([Span("   " + Words.describe(c, now: now))]) }
            }
        }
        var env: [String] = []
        if st.power.hasBattery {
            env.append("battery \(st.power.percent)%\(st.power.onAC ? " (AC)" : "")")
            env.append("floor \(st.floor == 0 ? "off" : "\(st.floor)%")")
            if st.power.lowPowerMode { env.append("low power mode") }
        }
        if st.thermalCritical { env.append("critical heat, lid refused") }
        if !env.isEmpty { lines.append([Span("   " + env.joined(separator: " · "), .muted)]) }
        let notifications = Notifications.standing(st.notifications)
        if notifications.grade == .broken, let note = notifications.note {
            lines.append([
                Span("   notifications off: ", .warn),
                Span("\(note) System Settings › Notifications › awake, or the menu's row", .muted),
            ])
        }
        // The upgrade nudge, from the daemon's last feed read.
        if !st.updateCheck {
            lines.append([Span("   update check off", .muted)])
        } else if let latest = st.latestVersion, let running, versionIsNewer(latest, than: running)
        {
            lines.append([
                Span(
                    "   ⬆ awake \(latest) is out (you run \(running)) · brew upgrade --cask awake",
                    .awake)
            ])
        }
        if st.askPending {
            lines.append([
                Span("   ? lid asked", .awake),
                Span(
                    " · grant lid-closed survival with `awake allow`, dismiss with `awake deny`",
                    .muted),
            ])
        }
        // Intent and effect must agree; the daemon's tick heals divergence, so this
        // line means something is actively wrong. Scream.
        let wantLid =
            st.suspendedSince == nil && st.claims.contains { $0.effectiveModes.contains(.lid) }
        if wantLid != st.sleepDisabled {
            lines.append([
                Span(
                    "   ✗ DIVERGED: SleepDisabled=\(st.sleepDisabled) but claims want \(wantLid)",
                    .alarm)
            ])
        }
        return lines
    }
}
