import AwakeKit
import Foundation

import enum Grant.Notifications  // scoped: Grant's own Claim would shadow AwakeKit's

/// The CLI: a thin client over the daemon's socket. It never flips state itself.
enum Client {
    static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data("awake: \(message)\n".utf8))
        exit(1)
    }

    /// One round trip, bringing the daemon up when it isn't reachable: no agent
    /// registered (a fresh `brew install`, or unregistered) → register it; registered
    /// → kickstart -k, which also recovers a wedged daemon (alive but not accepting).
    static func send(_ cmd: Command) -> Reply {
        if let r = Wire.roundTrip(cmd) { return r }
        if Agent.registered {
            _ = AwakeKit.run(
                "/bin/launchctl",
                ["kickstart", "-k", "gui/\(getuid())/\(Paths.launchdLabel)"])
        } else {
            Agent.install()
        }
        for _ in 0..<50 {
            usleep(100_000)
            if let r = Wire.roundTrip(cmd) { return r }
        }
        die("daemon unreachable after starting its agent. Why: \(Paths.serviceLog.path)")
    }

    // MARK: - Commands

    static func engage(_ args: [String]) {
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
                die("usage: awake --on-end CMD ...")
            }
            onEnd = rest[i + 1]
            rest.removeSubrange(i...i + 1)
        }
        if let i = rest.firstIndex(of: "--label") {
            guard rest.count > i + 1, !rest[i + 1].isEmpty else {
                die("usage: awake --label NAME ...")
            }
            owner = rest[i + 1]
            rest.removeSubrange(i...i + 1)
        }
        if let i = rest.firstIndex(of: "--until") {
            guard rest.count > i + 1, let date = parseUntil(rest[i + 1]) else {
                die("usage: awake --until HH:MM")
            }
            term = .until(date)
            rest.removeSubrange(i...i + 1)
        }
        if let i = rest.firstIndex(of: "-w") {
            guard rest.count > i + 1, let pid = Int32(rest[i + 1]) else {
                die("usage: awake -w <pid>")
            }
            guard let started = procStartTime(pid) else { die("no such process: \(pid)") }
            term = .whilePid(pid: pid, started: started)
            // The watched process names the claim: "claude · while it runs", never
            // a bare pid in the human's menu bar.
            if owner == Claim.humanOwner { owner = procName(pid) ?? "pid \(pid)" }
            rest.removeSubrange(i...i + 1)
        }
        if let token = rest.first {
            guard rest.count == 1, let seconds = parseDuration(token) else {
                die("unrecognized: \(rest.joined(separator: " "))\n\n\(usage)")
            }
            guard case .indefinite = term else { die("-w/--until and a duration are exclusive") }
            term = .until(Date().addingTimeInterval(seconds))
        }
        // Your own gesture carries lid; anyone else's claim is idle-only and lid is
        // an ASK (--lid), granted from the menu or `awake allow`. The daemon
        // enforces the same rule; this split just keeps the CLI honest about it.
        var modes: Set<Mode> = owner == Claim.humanOwner ? Claim.defaultModes : [.idle]
        if display { modes.insert(.display) }
        let reply = send(
            .engage(
                Claim(
                    owner: owner, forced: true, modes: modes, term: term,
                    wantsLid: wantsLid, onEnd: onEnd)))
        if !reply.ok { die(reply.error ?? "engage failed") }
        if let r = reply.replaced { print(dim("replaced own claim: \(describe(r))")) }
        if let c = reply.coveredBy {
            print(dim("already covered by \(describe(c)) · claim added, takes over if that ends"))
        }
        render(reply.status)
    }

    /// `awake check [WHO]`: the caller's half of the contract — a claim is a wish,
    /// not a lock, and this is how a script asks whether its wish is being honored
    /// RIGHT NOW. Exit 0 = in effect · 2 = kept but inert (suspended) · 3 = gone.
    static func check(_ token: String?) {
        let st = send(.status).status
        let matches = token.map { Claim.matching($0, in: st.claims) } ?? st.claims
        if matches.isEmpty {
            print(token.map { "gone · no claim matches '\($0)'" } ?? "gone · no claims")
            exit(3)
        }
        if st.suspendedSince != nil {
            print("inert · suspended by you · \(matches.count) claim(s) kept")
            exit(2)
        }
        print(
            "in effect · " + matches.map { describe($0) }.joined(separator: " · ")
                + (st.lidArmed ? " · lid armed" : " · sleeps on lid close"))
    }

    /// `awake allow|deny [WHO]`: the human's answer to a lid ask, from the shell.
    static func resolveLid(_ granted: Bool, _ token: String?) {
        let reply = send(granted ? .allowLid(token) : .denyLid(token))
        if !reply.ok { die(reply.error ?? (granted ? "allow failed" : "deny failed")) }
        render(reply.status)
    }

    /// nil ends everything; a token ends the claims it names (owner prefix or pid).
    static func end(_ token: String? = nil) {
        let reply = send(.end(token))
        if !reply.ok { die(reply.error ?? "end failed") }
        // The undo breadcrumb: what was running lands in the transcript/scrollback.
        for c in reply.ended ?? [] { print(dim("ended: \(describe(c))")) }
        render(reply.status)
    }

    /// The human's "let it sleep" switch from the shell (same thing as the
    /// right-click / hotkey). Claims stay; only the effect goes.
    static func suspend() { render(send(.suspend).status) }
    static func resume() { render(send(.resume).status) }

    /// `awake updates [on|off]`: the daily version check (= the active-install
    /// ping). Bare form prints the current setting and the newest known version.
    static func updates(_ args: [String]) {
        switch args.first {
        case "on": render(send(.setUpdateCheck(true)).status)
        case "off": render(send(.setUpdateCheck(false)).status)
        case nil: render(send(.status).status)
        default: die("usage: awake updates [on|off]")
        }
    }

    static func status(json: Bool = false) {
        let st = send(.status).status
        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            print(String(data: try! enc.encode(st), encoding: .utf8)!)
            return
        }
        render(st)
    }

    static func setFloor(_ v: Int) {
        let reply = send(.setFloor(v))
        print(
            "battery floor: \(reply.status.floor)%\(reply.status.floor == 0 ? " (disabled)" : "")")
    }

    /// No argument shows, `on`/`off` sets. The standing preference: while anything
    /// holds the machine awake, hold the display too. `--display` remains the
    /// per-claim opt-in when the preference is off.
    static func keepDisplay(_ args: [String]) {
        let status: Status
        switch args.first {
        case nil: status = send(.status).status
        case "on": status = send(.setKeepDisplay(true)).status
        case "off": status = send(.setKeepDisplay(false)).status
        default: die("usage: awake display [on|off]")
        }
        print(
            status.keepDisplay
                ? "display: kept on while anything holds the Mac awake"
                : "display: allowed to sleep (--display opts one claim in)")
    }

    /// No argument shows, a path sets, `--clear` removes. Always through the daemon:
    /// it holds config in memory, so editing config.json by hand loses the edit.
    static func notifyHook(_ args: [String]) {
        let status: Status
        switch args.first {
        case nil:
            status = send(.status).status
        case "--clear":
            status = send(.setNotifyCommand("")).status
        case let path?:
            let full = (path as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: full) else {
                die("not an executable file: \(full)")
            }
            status = send(.setNotifyCommand(full)).status
        }
        print(
            status.notifyCommand.isEmpty
                ? "notify hook: none — closed-lid ends are screen-only"
                : "notify hook: \(status.notifyCommand)")
    }

    // MARK: - Parsing

    /// "HH:MM" wall-clock → the NEXT such time (today, or tomorrow if already past).
    static func parseUntil(_ s: String) -> Date? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
            (0...23).contains(h), (0...59).contains(m)
        else { return nil }
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day], from: Date())
        c.hour = h
        c.minute = m
        let today = cal.date(from: c)!
        return today > Date() ? today : cal.date(byAdding: .day, value: 1, to: today)!
    }

    /// "2h", "90m", "1h30m", bare "45" = minutes.
    static func parseDuration(_ s: String) -> TimeInterval? {
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

    // MARK: - Rendering

    private static var tty: Bool { isatty(1) == 1 }
    private static func color(_ code: String, _ s: String) -> String {
        tty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }
    private static func dim(_ s: String) -> String { color("90", s) }

    static func formatInterval(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded(.up)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// Menu/notification-grade summaries: one line per OWNER, "you" first, pids
    /// demoted to a count — that surface answers who holds the Mac awake and until
    /// when, and a process-table number answers neither. CLI rows keep pids (the
    /// scripting surface; `awake off <pid>` needs them), and each summary carries
    /// the full per-claim detail for tooltips.
    static func summarize(_ claims: [Claim]) -> [(owner: String, label: String, detail: String)] {
        var order: [String] = []
        var groups: [String: [Claim]] = [:]
        for c in claims {
            if groups[c.owner] == nil {
                if c.owner == Claim.humanOwner {
                    order.insert(c.owner, at: 0)
                } else {
                    order.append(c.owner)
                }
            }
            groups[c.owner, default: []].append(c)
        }
        return order.map { owner in
            let g = groups[owner]!
            let label: String
            if g.count == 1 {
                let c = g[0]
                let how: String
                switch c.term {
                case .indefinite: how = "indefinite"
                case .until(let d): how = "\(formatInterval(d.timeIntervalSinceNow)) left"
                case .whilePid: how = "while it runs"
                }
                label = "\(owner) · \(how)\(marks(g[0]))"
            } else if g.allSatisfy({
                if case .whilePid = $0.term { return true } else { return false }
            }) {
                label = "\(owner) · while \(g.count) processes run"
            } else {
                label = "\(owner) · \(g.count) claims"
            }
            return (owner, label, g.map { describe($0) }.joined(separator: "\n"))
        }
    }

    /// The full per-claim line for the CLI, logs and tooltips: owner first, then
    /// how it ends (pid included — `awake off <pid>` needs it), then the display
    /// flare.
    static func describe(_ c: Claim) -> String {
        let how: String
        switch c.term {
        case .indefinite: how = "indefinite"
        case .until(let d): how = "\(formatInterval(d.timeIntervalSinceNow)) left"
        case .whilePid(let pid, _): how = "while it runs (pid \(pid))"
        }
        return "\(c.owner) · \(how)\(marks(c))"
    }

    /// The flares a claim line carries beyond owner + term, one vocabulary for
    /// menu, CLI, logs and tooltips.
    static func marks(_ c: Claim) -> String {
        var out = ""
        if c.modes.contains(.display) { out += " · display on" }
        if c.wantsLid { out += c.lidGranted ? " · lid granted" : " · asks lid" }
        return out
    }

    static func render(_ st: Status) {
        if let since = st.suspendedSince {
            print(
                color("34", "💤 sleeping")
                    + " — suspended by you \(formatInterval(Date().timeIntervalSince(since))) ago"
                    + (st.claims.isEmpty
                        ? ""
                        : " · \(st.claims.count) claim\(st.claims.count == 1 ? "" : "s") waiting for `awake resume` / right-click")
            )
            for c in st.claims { print(dim("   waiting: " + describe(c))) }
        } else {
            switch st.claims.count {
            case 0:
                print(color("34", "💤 asleep") + " — Mac sleeps normally")
            case 1:
                print(color("1;33", "☕ awake") + " — " + describe(st.claims[0]))
            default:
                print(color("1;33", "☕ awake") + " — \(st.claims.count) claims")
                for c in st.claims { print("   " + describe(c)) }
            }
        }
        var env: [String] = []
        if st.power.hasBattery {
            env.append("battery \(st.power.percent)%\(st.power.onAC ? " (AC)" : "")")
            env.append("floor \(st.floor == 0 ? "off" : "\(st.floor)%")")
            if st.power.lowPowerMode { env.append("low power mode") }
        }
        if st.thermalCritical { env.append("critical heat, lid refused") }
        if !env.isEmpty { print(dim("   " + env.joined(separator: " · "))) }
        let notifications = Notifications.standing(st.notifications)
        if notifications.grade == .broken, let note = notifications.note {
            print(
                color("33", "   notifications off: ")
                    + dim("\(note) System Settings › Notifications › awake, or the menu's row"))
        }
        // The upgrade nudge, from the daemon's last feed read; the check itself
        // is one GET a day (awake updates off silences it).
        let running = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        if !st.updateCheck {
            print(dim("   update check off"))
        } else if let latest = st.latestVersion, let running, versionIsNewer(latest, than: running)
        {
            print(
                color(
                    "1;33",
                    "   ⬆ awake \(latest) is out (you run \(running)) · brew upgrade --cask awake"))
        }
        // Intent and effect must agree; the daemon's tick heals divergence, so seeing
        // this line means something is actively wrong. Scream.
        if st.askPending {
            print(
                color("1;33", "   ? lid asked")
                    + dim(
                        " — grant lid-closed survival with `awake allow`, dismiss with `awake deny`"
                    ))
        }
        let wantLid =
            st.suspendedSince == nil && st.claims.contains { $0.effectiveModes.contains(.lid) }
        if wantLid != st.sleepDisabled {
            print(
                color(
                    "1;31",
                    "   ✗ DIVERGED: SleepDisabled=\(st.sleepDisabled) but claims want \(wantLid)"))
        }
    }
}
