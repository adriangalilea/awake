import Foundation
import IOKit.pwr_mgt

/// Result of a subprocess run with both pipes drained to EOF BEFORE waiting — a child
/// that fills the ~64KB pipe buffer before exiting can never deadlock us.
public struct RunResult: Sendable {
    public let status: Int32
    public let out: String
    public let err: String
}

public func run(_ path: String, _ args: [String]) -> RunResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    // No TTY, ever: a GUI daemon blocking on a prompt is an unrecoverable hang.
    p.standardInput = FileHandle.nullDevice
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch {
        return RunResult(status: -1, out: "", err: "launch failed: \(error.localizedDescription)")
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return RunResult(status: p.terminationStatus,
                     out: String(data: outData, encoding: .utf8) ?? "",
                     err: String(data: errData, encoding: .utf8) ?? "")
}

/// Outcome of flipping the lid flag. Judged from sudo's REAL exit status and stderr,
/// never by re-reading SleepDisabled afterward: a safety net legitimately flipping
/// sleep back on is observationally identical to "the toggle failed", and confusing
/// the two is the bug Sleepless shipped and fixed.
public enum LidResult: Equatable, Sendable {
    case ok
    case grantMissing
    case failed(String)
}

public enum Kernel {
    /// EFFECT ground truth for the lid flag. No root needed.
    /// preconditions, not asserts: this must scream in the RELEASE binary too —
    /// a daemon misreading the kernel is worse dead than wrong.
    public static func sleepDisabled() -> Bool {
        let r = run("/usr/bin/pmset", ["-g"])
        precondition(r.status == 0, "pmset -g failed: \(r.err)")
        for line in r.out.split(separator: "\n") where line.contains("SleepDisabled") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            precondition(tokens.count >= 2, "pmset -g SleepDisabled line shape changed: \(line)")
            return tokens.last == "1"
        }
        return false // line absent = flag off (pre-toggle machines never show it)
    }

    /// Flip the kernel flag through the scoped sudoers grant. `sudo -n` never prompts;
    /// the exact argument vector must match /etc/sudoers.d/awake.
    public static func setSleepDisabled(_ on: Bool) -> LidResult {
        let r = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
        if r.status == 0 { return .ok }
        let err = r.err.lowercased()
        if err.contains("a password is required") || err.contains("not allowed")
            || err.contains("may not run") {
            return .grantMissing
        }
        return .failed(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The daemon's held assertions, keyed by mode. Only `.idle`/`.display` live here;
    /// `.lid` is the kernel flag above.
    public static func createAssertion(_ mode: Mode) -> IOPMAssertionID {
        let type: String
        switch mode {
        case .idle: type = kIOPMAssertionTypePreventUserIdleSystemSleep as String
        case .display: type = kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        case .lid: fatalError("lid is the pmset flag, not an assertion")
        }
        var id: IOPMAssertionID = 0
        let rc = IOPMAssertionCreateWithName(type as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "awake" as CFString, &id)
        precondition(rc == kIOReturnSuccess, "IOPMAssertionCreateWithName(\(type)) rc=\(rc)")
        return id
    }

    public static func releaseAssertion(_ id: IOPMAssertionID) {
        let rc = IOPMAssertionRelease(id)
        precondition(rc == kIOReturnSuccess, "IOPMAssertionRelease(\(id)) rc=\(rc)")
    }
}
