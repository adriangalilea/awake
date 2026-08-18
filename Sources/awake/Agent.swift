import AwakeKit
import Foundation

/// The launchd agent, owned by the BINARY rather than by an installer, because
/// there is more than one installer: `mise run install`, a Homebrew cask's postflight,
/// and a human doing it by hand all have to land the same plist pointed at the
/// same image. A copy of this logic in an install script is a copy that drifts.
enum Agent {
    static func run(_ args: [String]) {
        switch args.first {
        case "install": install()
        case "uninstall": uninstall()
        default: Client.die("usage: awake agent install|uninstall")
        }
    }

    private static var domain: String { "gui/\(getuid())" }
    private static var service: String { "\(domain)/\(Paths.launchdLabel)" }

    /// The running binary with symlinks resolved. The CLI is normally invoked
    /// through a symlink into the bundle, and launchd must be handed the real
    /// image or it runs whatever the symlink pointed at when it was written.
    private static var binaryPath: String {
        URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
    }

    static func install() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.logDir, withIntermediateDirectories: true)
        try? fm.createDirectory(
            at: Paths.launchdPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let log = Paths.logDir.appendingPathComponent("service.log").path
        do {
            try plist(bin: binaryPath, log: log)
                .write(to: Paths.launchdPlist, atomically: true, encoding: .utf8)
        } catch {
            Client.die("cannot write \(Paths.launchdPlist.path): \(error.localizedDescription)")
        }
        stop()
        let r = AwakeKit.run("/bin/launchctl", ["bootstrap", domain, Paths.launchdPlist.path])
        guard r.status == 0 else {
            Client.die(
                "launchctl bootstrap failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        print("✓ daemon bootstrapped (\(Paths.launchdLabel)) → \(binaryPath)")
        prime()
    }

    /// Ask for notification permission NOW, in context, with the human at the
    /// keyboard and an intro banner that says what will arrive here, instead of
    /// letting the first real event (a battery-floor end at 3am behind a closed
    /// lid, prompt unseen, message lost) be the first ask. The notifier itself
    /// makes this a no-op once the person has answered, so re-installs never nag.
    private static func prime() {
        let bundle = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()
            .deletingLastPathComponent()
        let notifier = bundle.appendingPathComponent("Helpers/awake-notifier.app")
        guard
            FileManager.default.isExecutableFile(
                atPath: notifier.appendingPathComponent("Contents/MacOS/awake-notifier").path)
        else { return }
        let r = AwakeKit.run(
            "/usr/bin/open", ["-g", "-n", "-a", notifier.path, "--args", "--prime"])
        if r.status != 0 {
            print(
                "⚠ notification prompt could not be launched: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    static func uninstall() {
        stop()
        try? FileManager.default.removeItem(at: Paths.launchdPlist)
        print("✓ daemon removed (\(Paths.launchdLabel))")
    }

    /// bootout is ASYNCHRONOUS: bootstrapping while the previous instance is still
    /// tearing down fails with EIO, so wait for the label to actually disappear.
    /// A running service also keeps executing its OLD image, so every install must
    /// come through here or it leaves yesterday's binary running.
    private static func stop() {
        _ = AwakeKit.run("/bin/launchctl", ["bootout", service])
        for _ in 0..<20 {
            if AwakeKit.run("/bin/launchctl", ["print", service]).status != 0 { return }
            usleep(500_000)
        }
        Client.die("launchd still reports \(Paths.launchdLabel) after bootout")
    }

    private static func plist(bin: String, log: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>Label</key>
        \t<string>\(Paths.launchdLabel)</string>
        \t<key>ProcessType</key>
        \t<string>Interactive</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(bin)</string>
        \t\t<string>daemon</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>StandardErrorPath</key>
        \t<string>\(log)</string>
        \t<key>StandardOutPath</key>
        \t<string>\(log)</string>
        </dict>
        </plist>

        """
    }
}
