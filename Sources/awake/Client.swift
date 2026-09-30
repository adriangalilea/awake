import AwakeKit
import AwakeSurface
import Foundation

/// The CLI's IO: argv through `CLI.parse`, one round trip, `CLI.output` to the
/// terminal. It never flips state itself, and never decides a word it prints.
enum Client {
    static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data("awake: \(message)\n".utf8))
        exit(1)
    }

    /// One round trip, bringing the daemon up when it isn't reachable: a fresh
    /// `brew install` registers the agent here, a wedged daemon (alive but not
    /// accepting) is restarted, a job launchd gave up on is registered again.
    static func send(_ cmd: Command) -> Reply {
        if let r = Wire.roundTrip(cmd) { return r }
        if Agent.registered { Agent.restart() } else { Agent.install() }
        for _ in 0..<50 {
            usleep(100_000)
            if let r = Wire.roundTrip(cmd) { return r }
        }
        die("daemon unreachable after starting its agent. Why: \(Paths.serviceLog.path)")
    }

    static func run(_ args: [String], asleep: Bool) -> Never {
        let host = CLI.Host(
            now: Date(),
            process: { pid in procStartTime(pid).map { ($0, procName(pid)) } },
            executable: { FileManager.default.isExecutableFile(atPath: $0) })
        let verb: CLI.Verb
        switch CLI.parse(args, asleep: asleep, host: host) {
        case .success(let v): verb = v
        case .failure(let e): die(e.message)
        }
        let reply = send(verb.command)
        let out = CLI.output(
            verb, reply, now: Date(),
            running: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        if let failure = out.failure { die(failure) }
        for line in out.lines { print(line.map(paint).joined()) }
        exit(out.exit)
    }

    private static let tty = isatty(1) == 1

    private static func paint(_ span: CLI.Span) -> String {
        let code: String? =
            switch span.tone {
            case .plain: nil
            case .muted: "90"
            case .awake: "1;33"
            case .asleep: "34"
            case .warn: "33"
            case .alarm: "1;31"
            }
        guard tty, let code else { return span.text }
        return "\u{1B}[\(code)m\(span.text)\u{1B}[0m"
    }
}
