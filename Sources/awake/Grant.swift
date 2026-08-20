import AwakeKit
import Foundation

/// The privilege boundary, solofan's shape: one native auth sheet installs a sudoers
/// drop-in scoped to exactly the two pmset invocations, validated by visudo BEFORE it
/// lands (a broken sudoers file locks sudo for the whole machine).
enum Grant {
    /// Pinned to the installing user, not %admin: exactly one principal gets the
    /// passwordless flip, the narrowest rule that works.
    static var content: String {
        "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    }

    /// Verified-live truth: can the flip actually run? Probes by flipping the
    /// flag to its CURRENT value - proves the grant without changing state.
    static func works() -> Bool {
        Kernel.setSleepDisabled(Kernel.sleepDisabled()) == .ok
    }

    enum Outcome: Equatable {
        case installed
        case cancelled
        case failed(String)
    }

    /// The effectful core, UI-agnostic: native admin sheet → visudo-validated
    /// install → live verification. The CLI wraps it with prints; the DAEMON
    /// calls it from the menu and from any gesture that hits grantMissing -
    /// a menu bar app that needs a terminal first has its onboarding inverted.
    static func installInteractively(force: Bool = false) -> Outcome {
        // The rule CONTENT is not readable without root (440), so tightening an
        // installed rule requires an unconditional reinstall - hence `force`.
        if !force, works() { return .installed }

        let script = """
            set -e
            tmp="$(mktemp)"
            cat > "$tmp" <<'SUDOERS'
            \(content)
            SUDOERS
            /usr/sbin/visudo -c -q -f "$tmp"
            /usr/bin/install -m 440 -o root -g wheel "$tmp" \(Paths.sudoers)
            rm -f "$tmp"
            """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("awake-grant-\(getpid()).sh")
        do { try script.write(to: scriptURL, atomically: true, encoding: .utf8) } catch {
            return .failed("could not stage the install script: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        switch adminShell("/bin/bash '\(scriptURL.path)'") {
        case .cancelled: return .cancelled
        case .failed(let e): return .failed(e)
        case .ok:
            guard works() else {
                return .failed("grant installed but sudo -n still fails; inspect \(Paths.sudoers)")
            }
            return .installed
        }
    }

    /// The CLI face: prints, and exits nonzero through Client.die on failure.
    static func run(remove: Bool, force: Bool = false) {
        if remove {
            switch adminShell("rm -f \(Paths.sudoers)") {
            case .ok: print("✓ removed \(Paths.sudoers)")
            case .cancelled: Client.die("cancelled")
            case .failed(let e): Client.die("privileged remove failed: \(e)")
            }
            return
        }
        if !force, works() {
            print("✓ grant already installed and working (\(Paths.sudoers))")
            return
        }
        print("Installing \(Paths.sudoers) — macOS will ask you to authenticate once.")
        print("Content:\n  \(content)")
        switch installInteractively(force: force) {
        case .installed: print("✓ grant installed; awake/asleep now work passwordless")
        case .cancelled: Client.die("cancelled")
        case .failed(let e): Client.die(e)
        }
    }

    private enum ShellOutcome {
        case ok
        case cancelled
        case failed(String)
    }

    /// One `do shell script ... with administrator privileges` — the native Touch ID
    /// or password sheet, no Terminal sudo.
    private static func adminShell(_ command: String) -> ShellOutcome {
        let escaped =
            command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let r = AwakeKit.run(
            "/usr/bin/osascript",
            ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        if r.status != 0 {
            if r.err.contains("-128") { return .cancelled }
            return .failed(
                "privileged install failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return .ok
    }
}
