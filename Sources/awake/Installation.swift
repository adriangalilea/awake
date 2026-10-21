import AwakeKit
import Foundation
import PermissionGrants

extension AppInstallation.Job {
    /// The daemon (`awake daemon`): menu bar, socket, state machine, a launchd agent
    /// with KeepAlive whose plist ships in the bundle. Its witness is its own
    /// socket answering; before any unregister it hands back (sleep restored, the
    /// claims kept for the copy that takes over).
    static let awake = AppInstallation.Job(
        .agent(plist: "\(Paths.launchdLabel).plist"), name: "awake",
        answers: { Wire.roundTrip(.status) != nil },
        handBack: { _ = Wire.roundTrip(.handBack) })
}

extension PermissionGrant {
    /// The agent as the person meets it: opened from the dmg or a download it
    /// offers the Installer's question (everyone or just you) and moves there; held
    /// for approval it opens Login Items; off it installs.
    static let agent = PermissionGrant.backgroundService(
        .awake, title: "awake",
        why: "Keeps the Mac awake for the claims you and your tools make.",
        installFor: [.everyone, .me])
}

/// What deleting awake takes with it, beside the standard places by bundle id.
enum Installation {
    /// Claims, config and the notification reach; the service log.
    static let keeps = [Paths.stateDir, Paths.logDir]

    /// The command lines and the agent skill, links into the bundle: re-pointed when
    /// the app opens from a new copy, removed when it is deleted. Homebrew's own
    /// links (`/opt/homebrew/bin/awake`) are Homebrew's.
    static var links: [AppInstallation.Link] {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin")
        return [
            AppInstallation.Link(bin.appending(path: "awake"), to: "Contents/MacOS/awake"),
            AppInstallation.Link(bin.appending(path: "asleep"), to: "Contents/MacOS/awake"),
        ]
            + Skill.homes.map { AppInstallation.Link($0.link, to: "Contents/Resources/skill") }
    }

    /// The agent turned on from this copy, the one approval included: a bare
    /// launch of the app (a double click, Spotlight, the first CLI call), and the
    /// copy a move opened. Once it runs, the notifier asks for its permission in
    /// context. The answer is the job's state.
    @MainActor static func turnOn() async -> AppInstallation.Job.State {
        await PermissionGrant.agent.ask()
        let state = AppInstallation.Job.awake.state
        if state == .running { Notifier.launch(["--prime"]) }
        return state
    }
}
