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

    /// `force` skips the works-already short-circuit: the rule CONTENT is not
    /// readable without root (440), so tightening an installed rule requires an
    /// unconditional reinstall.
    static func run(remove: Bool, force: Bool = false) {
        if remove {
            adminShell("rm -f \(Paths.sudoers)")
            print("✓ removed \(Paths.sudoers)")
            return
        }

        // Verify by flipping the flag to its CURRENT value: proves the grant works
        // without changing any state.
        let current = Kernel.sleepDisabled()
        if !force, Kernel.setSleepDisabled(current) == .ok {
            print("✓ grant already installed and working (\(Paths.sudoers))")
            return
        }

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
        try! script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        print("Installing \(Paths.sudoers) — macOS will ask you to authenticate once.")
        print("Content:\n  \(content)")
        adminShell("/bin/bash '\(scriptURL.path)'")

        guard Kernel.setSleepDisabled(current) == .ok else {
            Client.die("grant installed but sudo -n still fails; inspect \(Paths.sudoers)")
        }
        print("✓ grant installed; awake/asleep now work passwordless")
    }

    /// One `do shell script ... with administrator privileges` — the native Touch ID
    /// or password sheet, no Terminal sudo.
    private static func adminShell(_ command: String) {
        let escaped =
            command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let r = AwakeKit.run(
            "/usr/bin/osascript",
            ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        if r.status != 0 {
            if r.err.contains("-128") { Client.die("cancelled") }
            Client.die(
                "privileged install failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }
}
