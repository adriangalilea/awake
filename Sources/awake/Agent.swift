import AwakeKit
import Foundation
import ServiceManagement

/// The launchd agent, registered by the app itself through SMAppService. Its plist
/// ships inside the bundle (Contents/Library/LaunchAgents, `BundleProgram`), so
/// launchd always runs the image at the bundle's path: an upgrade that replaces
/// the bundle keeps the registration, and the next start runs the new binary.
///
/// Every install path lands here: `mise run install`, a double click (an
/// argument-less LaunchServices launch), and the first CLI call that finds no
/// daemon, which is how a Homebrew install comes alive. The cask cannot do it:
/// cask steps run sandboxed, and launchd bootstrap, LaunchServices and
/// SMAppService all refuse a sandboxed caller. Removal is the daemon's own job
/// (Daemon.watchImage): deleting the app leaves the registration in place, and
/// launchd would retry the missing binary forever.
///
/// SMAppService refuses an ad-hoc signature (kSMErrorInvalidSignature): the
/// bundle must carry a Developer ID.
enum Agent {
    static var service: SMAppService { .agent(plistName: "\(Paths.launchdLabel).plist") }
    private static var target: String { "gui/\(getuid())/\(Paths.launchdLabel)" }

    static func run(_ args: [String]) {
        switch args.first {
        case "install": install()
        case "uninstall": uninstall()
        default: Client.die("usage: awake agent install|uninstall")
        }
    }

    static var registered: Bool { service.status == .enabled }

    /// Diagnostics go to stderr: the first CLI call after an install runs this
    /// before printing its own answer, and `awake status --json` must stay JSON.
    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func install() {
        removeUserAgentPlist()
        if registered, running {
            // A reinstall: restart into the image the bundle holds now. The SIGTERM
            // parks the claims; startup re-arms them. Only a running job: kickstart
            // on a job launchd has given up on (its bundle deleted, a refused image)
            // blocks forever; those fall through to the re-registration below.
            _ = AwakeKit.run("/bin/launchctl", ["kickstart", "-k", target])
        } else if !registered {
            register()
        }
        // `enabled` is BTM's record, not launchd's. A job can be registered and
        // missing from launchd, or loaded and stuck: after a few refused launches
        // (a launch constraint violation, an image caught mid-install) launchd keeps
        // it in `spawn scheduled` and kickstart no longer revives it. Only a fresh
        // registration does, so anything short of running gets one, once.
        if !waitRunning() {
            say("agent registered but not running, registering it again")
            do { try service.unregister() } catch {}
            register()
            guard waitRunning() else {
                Client.die(
                    "agent registered but launchd does not run it. Why: /usr/bin/log show --last 5m --predicate 'eventMessage CONTAINS \"\(Paths.launchdLabel)\"'"
                )
            }
        }
        say("✓ agent running (\(Paths.launchdLabel)) → \(Bundle.main.bundlePath)")
        Notifier.launch(["--prime"])
    }

    static var running: Bool {
        AwakeKit.run("/bin/launchctl", ["print", target]).out.contains("\tstate = running")
    }

    private static func waitRunning() -> Bool {
        for _ in 0..<20 {
            if running { return true }
            usleep(250_000)
        }
        return false
    }

    /// Retried for a few seconds: `register` right after an `unregister` fails with
    /// EPERM until BTM settles (a second was not always enough).
    private static func register() {
        var lastError: Error?
        for attempt in 0..<6 {
            if attempt > 0 { sleep(1) }
            do {
                try service.register()
                lastError = nil
                break
            } catch {
                lastError = error
            }
        }
        if let lastError {
            Client.die(
                "cannot register the agent: \(lastError.localizedDescription). SMAppService needs the bundle signed with a Developer ID."
            )
        }
        switch service.status {
        case .enabled: return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            Client.die(
                "macOS holds awake's agent for approval: allow it in System Settings › General › Login Items & Extensions, then run awake again."
            )
        default:
            Client.die("agent registered but its status is \(service.status.rawValue), not enabled")
        }
    }

    static func uninstall() {
        do {
            try service.unregister()
        } catch {
            Client.die("cannot unregister the agent: \(error.localizedDescription)")
        }
        say("✓ agent unregistered (\(Paths.launchdLabel))")
    }

    /// The daemon, its bundle deleted, taking itself out of launchd so KeepAlive stops
    /// retrying a missing binary. launchd kills this process inside the call, so
    /// everything that must happen (sleep restored, claims ended) happens before it.
    /// BTM keeps its record (unregister needs the bundle); a reinstall reuses it.
    static func bootoutSelf() {
        _ = AwakeKit.run("/bin/launchctl", ["bootout", target])
    }

    /// A plist under our label in ~/Library/LaunchAgents is a second definition of
    /// the same job, loaded at every login, and it would hold the label the bundled
    /// agent needs. Booted out and deleted before registering.
    private static func removeUserAgentPlist() {
        guard FileManager.default.fileExists(atPath: Paths.userAgentPlist.path) else { return }
        stop()
        do {
            try FileManager.default.removeItem(at: Paths.userAgentPlist)
        } catch {
            Client.die("cannot remove \(Paths.userAgentPlist.path): \(error.localizedDescription)")
        }
        say("removed \(Paths.userAgentPlist.path)")
    }

    /// bootout is ASYNCHRONOUS: wait for the label to actually disappear before
    /// anything else claims it.
    private static func stop() {
        _ = AwakeKit.run("/bin/launchctl", ["bootout", target])
        for _ in 0..<20 {
            if AwakeKit.run("/bin/launchctl", ["print", target]).status != 0 { return }
            usleep(500_000)
        }
        Client.die("launchd still reports \(Paths.launchdLabel) after bootout")
    }
}
