import Foundation

/// A wake mechanism. `.lid` is the kernel flag (needs the sudoers grant); the others
/// are IOKit power assertions held by the daemon process.
public enum Mode: String, Codable, CaseIterable, Sendable {
    case lid      // pmset -a disablesleep 1 — survives lid close
    case idle     // PreventUserIdleSystemSleep — no idle sleep while lid open
    case display  // PreventUserIdleDisplaySleep — screen stays on
}

/// When a claim ends on its own.
public enum Term: Codable, Equatable, Sendable {
    case indefinite
    case until(Date)
    /// pid + its kernel start time: `kill(pid, 0)` alone would let a recycled PID
    /// keep a dead process's claim alive forever.
    case whilePid(pid: Int32, started: Double)
}

/// When the system booted. Claims never span a reboot: the kernel flag resets at
/// boot BY DESIGN and re-arming stale intent would undo that safety.
public func bootTime() -> Date {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    let rc = sysctl(&mib, 2, &tv, &size, nil, 0)
    precondition(rc == 0, "sysctl kern.boottime failed: \(String(cString: strerror(errno)))")
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
}

private func kinfo(_ pid: Int32) -> kinfo_proc? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0,
          info.kp_proc.p_pid == pid else { return nil }
    return info
}

/// Kernel start time of a process (seconds since epoch, µs precision), nil if gone.
public func procStartTime(_ pid: Int32) -> Double? {
    guard let info = kinfo(pid) else { return nil }
    let tv = info.kp_proc.p_starttime
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
}

/// Process name as a human knows it: argv[0]'s basename (the name it was invoked
/// by), falling back to the kernel's 16-char p_comm. The distinction is real: a
/// version-managed tool execs a binary literally named "2.1.231" but was invoked
/// as "claude", and only argv[0] remembers that.
public func procName(_ pid: Int32) -> String? {
    if let argv0 = procArgv0(pid), !argv0.isEmpty {
        return URL(fileURLWithPath: argv0).lastPathComponent
    }
    guard var info = kinfo(pid) else { return nil }
    return withUnsafeBytes(of: &info.kp_proc.p_comm) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

/// KERN_PROCARGS2 layout: int32 argc, exec_path\0, NUL padding, argv[0]\0, ...
/// Readable for the caller's own processes, which is exactly the `-w` use case.
private func procArgv0(_ pid: Int32) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
    var i = 4 // skip argc
    while i < size, buf[i] != 0 { i += 1 } // skip exec_path
    while i < size, buf[i] == 0 { i += 1 } // skip its NUL padding
    let start = i
    while i < size, buf[i] != 0 { i += 1 }
    guard i > start else { return nil }
    return String(decoding: buf[start ..< i], as: UTF8.self)
}

/// One party's wish that the Mac stay awake. The machine is awake while ANY valid
/// claim exists; the effect is the UNION of all claims' modes — the same OR the
/// kernel itself applies to IOPM assertions. Owners coexist instead of clobbering
/// each other: your indefinite session and an agent's `-w` watch are two claims.
public struct Claim: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Who wants this, rendered everywhere a human reads state: "you" for menu,
    /// hotkey and bare-CLI gestures, the watched process's name for `-w`,
    /// free text via `--label`, "external" for adopted kernel flags.
    public var owner: String
    /// True when engaged deliberately. Forced claims survive Low Power Mode;
    /// nothing survives the battery floor.
    public var forced: Bool
    public var modes: Set<Mode>
    public var term: Term
    public var startedAt: Date

    public init(owner: String, forced: Bool, modes: Set<Mode>, term: Term,
                startedAt: Date = Date()) {
        self.id = UUID()
        // Owner strings reach osascript notifications; quotes would break the
        // quoting there and control characters have no business in a label.
        self.owner = String(owner.map { $0 == "\"" ? "'" : $0 }
            .filter { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
        self.forced = forced
        self.modes = modes
        self.term = term
        self.startedAt = startedAt
    }

    public static let defaultModes: Set<Mode> = [.lid, .idle]
    public static let humanOwner = "you"

    /// Replace-key: engaging again with the same key REPLACES that claim instead of
    /// stacking a duplicate. One claim per watched pid; one per owner label otherwise
    /// (re-clicking a menu duration updates YOUR claim, a hook re-arming the same
    /// process refreshes ITS claim).
    public var key: String {
        if case .whilePid(let pid, _) = term { return "pid:\(pid)" }
        return "owner:\(owner.lowercased())"
    }

    /// Whether this claim makes `other` currently redundant: at least the same modes,
    /// for at least as long. A pid watch covers nothing (the pid can outlive any
    /// deadline) and only an indefinite claim covers one.
    public func covers(_ other: Claim) -> Bool {
        guard modes.isSuperset(of: other.modes) else { return false }
        switch (term, other.term) {
        case (.indefinite, _): return true
        case (.until(let mine), .until(let theirs)): return mine >= theirs
        default: return false
        }
    }

    /// Expired/orphaned claims are invalid and must be torn down, not re-armed.
    /// A claim predating the current boot is ALWAYS invalid, whatever its term.
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
    public static let claimsFile = stateDir.appendingPathComponent("claims.json")
    /// The human's suspend switch, its own file: orthogonal to the claim set and
    /// absent whenever the switch is off, so claims.json keeps its shape.
    public static let suspendFile = stateDir.appendingPathComponent("suspended.json")
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
    /// Duration of the last HUMAN engagement, minutes (0 = indefinite). Right-click
    /// and the global hotkey re-use it; only menu/hotkey gestures teach it — a wire
    /// client arming a timed claim must never rewrite the human's muscle memory.
    public var lastMinutes: Int
    /// Menu/hotkey engagements include the display mode when true. CLI claims opt in
    /// per call with --display; a background agent's claim must never light the screen.
    public var menuDisplay: Bool
    /// Out-of-band notification for the ends that fire while the lid is CLOSED,
    /// where a screen notification informs nobody. Any executable taking one
    /// message argument: a push service, an SMS gateway, a webhook script.
    /// Empty (the default) means screen only.
    public var notifyCommand: String
    /// The daily version check against awake.untitled.garden/appcast.xml. One
    /// GET a day, no payload; the server keeps a salted hash of the caller's IP
    /// for that day to count active installs (never the IP). Off = silent.
    public var updateCheck: Bool
    /// When the next check is due (nil = due now). Success schedules a day
    /// ahead, failure an hour, so a flaky network is not hammered every tick.
    public var nextUpdateCheck: Date?
    /// The newest version the feed has reported, and the one already announced
    /// on screen (each new version is announced exactly once).
    public var latestVersion: String?
    public var updateAnnounced: String?

    public init(batteryFloorPercent: Int = 15, lastMinutes: Int = 0, menuDisplay: Bool = false,
                notifyCommand: String = "", updateCheck: Bool = true) {
        self.batteryFloorPercent = batteryFloorPercent
        self.lastMinutes = lastMinutes
        self.menuDisplay = menuDisplay
        self.notifyCommand = notifyCommand
        self.updateCheck = updateCheck
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        batteryFloorPercent = try c.decodeIfPresent(Int.self, forKey: .batteryFloorPercent) ?? 15
        lastMinutes = try c.decodeIfPresent(Int.self, forKey: .lastMinutes) ?? 0
        menuDisplay = try c.decodeIfPresent(Bool.self, forKey: .menuDisplay) ?? false
        notifyCommand = try c.decodeIfPresent(String.self, forKey: .notifyCommand) ?? ""
        updateCheck = try c.decodeIfPresent(Bool.self, forKey: .updateCheck) ?? true
        nextUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .nextUpdateCheck)
        latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion)
        updateAnnounced = try c.decodeIfPresent(String.self, forKey: .updateAnnounced)
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

public enum ClaimStore {
    public static func load() -> [Claim] {
        guard let data = try? Data(contentsOf: Paths.claimsFile) else { return [] }
        guard let claims = try? JSONDecoder().decode([Claim].self, from: data) else {
            // A file we can't decode is a schema change or corruption: scream and clear,
            // never limp along with unknown intent.
            log("claims.json undecodable, clearing: \(String(data: data, encoding: .utf8) ?? "<binary>")")
            clear()
            return []
        }
        return claims
    }

    public static func save(_ claims: [Claim]) {
        guard !claims.isEmpty else {
            clear()
            return
        }
        Paths.ensureStateDir()
        let data = try! JSONEncoder().encode(claims)
        try! data.write(to: Paths.claimsFile, options: .atomic)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: Paths.claimsFile)
    }
}

/// The suspend switch on disk: the ISO date it was thrown, or no file. Never
/// spans a reboot: like claims, intent from before the boot is stale by design.
public enum SuspendStore {
    public static func load() -> Date? {
        guard let data = try? Data(contentsOf: Paths.suspendFile),
              let since = try? JSONDecoder.iso.decode(Date.self, from: data) else { return nil }
        guard since >= bootTime() else {
            log("suspend switch predates this boot, clearing")
            save(nil)
            return nil
        }
        return since
    }

    public static func save(_ since: Date?) {
        guard let since else {
            try? FileManager.default.removeItem(at: Paths.suspendFile)
            return
        }
        Paths.ensureStateDir()
        try! JSONEncoder.iso.encode(since).write(to: Paths.suspendFile, options: .atomic)
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

/// "0.4.0" > "0.3.10" by numeric components; a missing component is 0.
public func versionIsNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0 ..< max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}

/// One log line shape everywhere: ISO timestamp, then the message. The daemon's
/// stdout/stderr land in ~/Library/Logs/awake/service.log via launchd.
public func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(ts) \(message)\n".utf8))
}
