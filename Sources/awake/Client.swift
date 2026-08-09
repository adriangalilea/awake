import AwakeKit
import Foundation

/// The CLI: a thin client over the daemon's socket. It never flips state itself.
enum Client {
    static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data("awake: \(message)\n".utf8))
        exit(1)
    }

    /// One round trip, auto-starting the daemon when it isn't reachable. launchd
    /// kickstart -k also recovers a wedged daemon (alive but not accepting).
    static func send(_ cmd: Command) -> Reply {
        if let r = Wire.roundTrip(cmd) { return r }
        _ = AwakeKit.run("/bin/launchctl",
                         ["kickstart", "-k", "gui/\(getuid())/\(Paths.launchdLabel)"])
        for _ in 0 ..< 50 {
            usleep(100_000)
            if let r = Wire.roundTrip(cmd) { return r }
        }
        die("daemon unreachable. Install the launchd agent with: awake agent install")
    }

    // MARK: - Commands

    static func engage(_ args: [String]) {
        var modes = Session.defaultModes
        // The persisted display preference applies EVERYWHERE (menu, hotkey, CLI);
        // --display remains the explicit per-call opt-in on top.
        if Config.load().menuDisplay { modes.insert(.display) }
        var term = Term.indefinite
        var rest = args
        if let i = rest.firstIndex(of: "--display") {
            modes.insert(.display)
            rest.remove(at: i)
        }
        if let i = rest.firstIndex(of: "--until") {
            guard rest.count > i + 1, let date = parseUntil(rest[i + 1]) else {
                die("usage: awake --until HH:MM")
            }
            term = .until(date)
            rest.removeSubrange(i ... i + 1)
        }
        if let i = rest.firstIndex(of: "-w") {
            guard rest.count > i + 1, let pid = Int32(rest[i + 1]) else {
                die("usage: awake -w <pid>")
            }
            guard let started = procStartTime(pid) else { die("no such process: \(pid)") }
            term = .whilePid(pid: pid, started: started)
            rest.removeSubrange(i ... i + 1)
        }
        if let token = rest.first {
            guard rest.count == 1, let seconds = parseDuration(token) else {
                die("unrecognized: \(rest.joined(separator: " "))\n\n\(usage)")
            }
            guard case .indefinite = term else { die("-w/--until and a duration are exclusive") }
            term = .until(Date().addingTimeInterval(seconds))
        }
        let reply = send(.engage(Session(modes: modes, term: term, forced: true)))
        if !reply.ok { die(reply.error ?? "engage failed") }
        if let p = reply.previous { print(dim("replaced: \(describe(p))")) }
        render(reply.status)
    }

    static func end() {
        let reply = send(.end)
        // The undo breadcrumb: what was running lands in the transcript/scrollback.
        if let p = reply.previous { print(dim("ended: \(describe(p))")) }
        render(reply.status)
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
        print("battery floor: \(reply.status.floor)%\(reply.status.floor == 0 ? " (disabled)" : "")")
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
        print(status.notifyCommand.isEmpty
            ? "notify hook: none — closed-lid ends are screen-only"
            : "notify hook: \(status.notifyCommand)")
    }

    // MARK: - Parsing

    /// "HH:MM" wall-clock → the NEXT such time (today, or tomorrow if already past).
    static func parseUntil(_ s: String) -> Date? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0 ... 23).contains(h), (0 ... 59).contains(m) else { return nil }
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
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    static func describe(_ s: Session) -> String {
        let modes = s.modes.map(\.rawValue).sorted().joined(separator: "+")
        switch s.term {
        case .indefinite: return "\(modes), indefinite"
        case .until(let d): return "\(modes), \(formatInterval(d.timeIntervalSinceNow)) left"
        case .whilePid(let pid, _): return "\(modes), while pid \(pid)"
        }
    }

    static func render(_ st: Status) {
        if let s = st.session {
            print(color("1;33", "☕ awake") + " — " + describe(s))
        } else {
            print(color("34", "💤 asleep") + " — Mac sleeps normally")
        }
        var env: [String] = []
        if st.power.hasBattery {
            env.append("battery \(st.power.percent)%\(st.power.onAC ? " (AC)" : "")")
            env.append("floor \(st.floor == 0 ? "off" : "\(st.floor)%")")
            if st.power.lowPowerMode { env.append("low power mode") }
        }
        if !env.isEmpty { print(dim("   " + env.joined(separator: " · "))) }
        // Intent and effect must agree; the daemon's tick heals divergence, so seeing
        // this line means something is actively wrong. Scream.
        let wantLid = st.session?.modes.contains(.lid) ?? false
        if wantLid != st.sleepDisabled {
            print(color("1;31",
                "   ✗ DIVERGED: SleepDisabled=\(st.sleepDisabled) but session wants \(wantLid)"))
        }
    }
}
