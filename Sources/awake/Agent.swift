import AwakeKit
import Foundation
import PermissionGrants

/// `awake agent install|uninstall`, and the CLI's way to bring the daemon up: the
/// agent is `AppInstallation.Job.awake` (Installation.swift), so registering,
/// approval, a fresh registration for this copy and the hand-back before any stop
/// are AppInstallations', never this file's. A brew install comes alive on the
/// first CLI call: cask steps run sandboxed, and launchd, LaunchServices and
/// SMAppService all refuse a sandboxed caller.
enum Agent {
    static func run(_ args: [String]) {
        switch args.first {
        case "install": install()
        case "uninstall": uninstall()
        default: Client.die("usage: awake agent install|uninstall")
        }
    }

    /// Diagnostics go to stderr: the first CLI call after an install runs this
    /// before printing its own answer, and `awake status --json` must stay JSON.
    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// The agent running from this copy, or a death naming the one fix. A copy
    /// outside Applications is moved by the app itself (a double click asks where),
    /// never from a terminal.
    static func install() {
        let job = AppInstallation.Job.awake
        switch job.state(probing: false) {
        case .misplaced(let home):
            Client.die(
                "awake runs from \(home.words): open awake.app and it moves itself into Applications"
            )
        case .bare:
            Client.die("no agent in this build (a bare binary): mise run install")
        default: break
        }
        do {
            _ = try blocking { try await job.install() }
        } catch AppInstallation.Job.Failure.awaitingApproval(let needsAdmin) {
            Client.die(
                "macOS holds awake's agent for \(needsAdmin ? "an admin's" : "your") approval. \(AppInstallation.Job.approvalSteer) Then run awake again."
            )
        } catch {
            Client.die("the agent: \(error)")
        }
        say("✓ agent running (\(Paths.launchdLabel)) → \(Bundle.main.bundlePath)")
        Notifier.launch(["--prime"])
    }

    static func uninstall() {
        do {
            try AppInstallation.Job.awake.uninstall()
        } catch {
            Client.die("cannot unregister the agent: \(error)")
        }
        say("✓ agent unregistered (\(Paths.launchdLabel))")
    }

    /// The running daemon replaced by a fresh one from this image (a remapped
    /// hotkey re-registers with Carbon only at launch). Its SIGTERM parks the
    /// claims; the new process re-arms them.
    static func restart() {
        let target = "gui/\(getuid())/\(Paths.launchdLabel)"
        guard AwakeKit.run("/bin/launchctl", ["kickstart", "-k", target]).status == 0 else {
            install()
            return
        }
    }

    /// An async job verb from the CLI's synchronous world.
    private static func blocking<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>!
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result.get()
    }
}
