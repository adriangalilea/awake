import Foundation

/// A wake mechanism. `.lid` is the kernel flag (needs the sudoers grant); the others
/// are IOKit power assertions held by the daemon process.
public enum Mode: String, Codable, CaseIterable, Sendable {
    case lid      // pmset -a disablesleep 1 — survives lid close
    case idle     // PreventUserIdleSystemSleep — no idle sleep while lid open
    case display  // PreventUserIdleDisplaySleep — screen stays on
}

/// When a session ends on its own.
public enum Term: Codable, Equatable, Sendable {
    case indefinite
    case until(Date)
    /// pid + its kernel start time: `kill(pid, 0)` alone would let a recycled PID
    /// keep a dead process's session alive forever.
    case whilePid(pid: Int32, started: Double)
}

/// When the system booted. Sessions never span a reboot: the kernel flag resets at
/// boot BY DESIGN and re-arming stale intent would undo that safety.
public func bootTime() -> Date {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    let rc = sysctl(&mib, 2, &tv, &size, nil, 0)
    precondition(rc == 0, "sysctl kern.boottime failed: \(String(cString: strerror(errno)))")
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
}

/// Kernel start time of a process (seconds since epoch, µs precision), nil if gone.
public func procStartTime(_ pid: Int32) -> Double? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0,
          info.kp_proc.p_pid == pid else { return nil }
    let tv = info.kp_proc.p_starttime
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
}

/// Intent: what Adrian asked for. Persisted so a crashed daemon re-arms on restart.
/// The kernel is the source of truth for EFFECT; this is the source of truth for WANT.
public struct Session: Codable, Equatable, Sendable {
    public var modes: Set<Mode>
    public var term: Term
    /// True when a human engaged it deliberately (CLI, menu). Forced sessions survive
    /// Low Power Mode; nothing survives the battery floor.
    public var forced: Bool
    public var startedAt: Date

    public init(modes: Set<Mode>, term: Term, forced: Bool, startedAt: Date = Date()) {
        self.modes = modes
        self.term = term
        self.forced = forced
        self.startedAt = startedAt
    }

    public static let defaultModes: Set<Mode> = [.lid, .idle]

    /// Expired/orphaned sessions are invalid and must be torn down, not re-armed.
    /// A session predating the current boot is ALWAYS invalid, whatever its term.
    public func isValid(now: Date = Date()) -> Bool {
        guard startedAt >= bootTime() else { return false }
        switch term {
        case .indefinite: return true
        case .until(let d): return d > now
        case .whilePid(let pid, let started): return procStartTime(pid) == started
        }
    }

    public func remaining(now: Date = Date()) -> TimeInterval? {
        if case .until(let d) = term { return max(0, d.timeIntervalSince(now)) }
        return nil
    }
}

/// Everything on disk lives here. Single place, no scattered paths.
public enum Paths {
    public static let stateDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/awake")
    public static let sessionFile = stateDir.appendingPathComponent("session.json")
    public static let configFile = stateDir.appendingPathComponent("config.json")
    public static let socket = stateDir.appendingPathComponent("awake.sock")
    public static let sudoers = "/etc/sudoers.d/awake"
    public static let launchdLabel = "garden.untitled.awake"
    public static let launchdPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(launchdLabel).plist")
    public static let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/awake")

    public static func ensureStateDir() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }
}

/// Daemon config, persisted. Floor 0 disables the cutoff. Decoding tolerates missing
/// keys (each falls back to its default) so adding a field never resets the rest.
public struct Config: Codable, Equatable, Sendable {
    public var batteryFloorPercent: Int
    /// Duration of the last deliberate engagement, minutes (0 = indefinite).
    /// Right-click and the global hotkey re-use it.
    public var lastMinutes: Int
    /// Menu/hotkey engagements include the display mode when true.
    public var menuDisplay: Bool

    public init(batteryFloorPercent: Int = 15, lastMinutes: Int = 0, menuDisplay: Bool = false) {
        self.batteryFloorPercent = batteryFloorPercent
        self.lastMinutes = lastMinutes
        self.menuDisplay = menuDisplay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        batteryFloorPercent = try c.decodeIfPresent(Int.self, forKey: .batteryFloorPercent) ?? 15
        lastMinutes = try c.decodeIfPresent(Int.self, forKey: .lastMinutes) ?? 0
        menuDisplay = try c.decodeIfPresent(Bool.self, forKey: .menuDisplay) ?? false
    }

    public static let floorRange = 0 ... 50

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.configFile),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }

    public func save() {
        Paths.ensureStateDir()
        let data = try! JSONEncoder().encode(self)
        try! data.write(to: Paths.configFile, options: .atomic)
    }
}

public enum SessionStore {
    public static func load() -> Session? {
        guard let data = try? Data(contentsOf: Paths.sessionFile) else { return nil }
        guard let s = try? JSONDecoder().decode(Session.self, from: data) else {
            // A file we can't decode is a schema change or corruption: scream and clear,
            // never limp along with unknown intent.
            log("session.json undecodable, clearing: \(String(data: data, encoding: .utf8) ?? "<binary>")")
            clear()
            return nil
        }
        return s
    }

    public static func save(_ s: Session) {
        Paths.ensureStateDir()
        let data = try! JSONEncoder().encode(s)
        try! data.write(to: Paths.sessionFile, options: .atomic)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: Paths.sessionFile)
    }
}

/// One log line shape everywhere: ISO timestamp, then the message. The daemon's
/// stdout/stderr land in ~/Library/Logs/awake/service.log via launchd.
public func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(ts) \(message)\n".utf8))
}
