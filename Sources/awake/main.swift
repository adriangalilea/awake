import AppKit
import AwakeKit
import AwakeSurface
import Foundation
import PermissionGrants

// Run as the bundle's own executable, always. Invoked through a symlink
// (~/.local/bin/awake, /opt/homebrew/bin/asleep), Bundle.main is the symlink's
// directory, not the app: SMAppService would look for the agent's plist there, the
// notifier would not be found, and the defaults domain would not be the daemon's.
// Re-exec through the resolved path; argv is kept, so `asleep` still dispatches.
if let exe = Bundle.main.executablePath {
    let real = URL(fileURLWithPath: exe).resolvingSymlinksInPath().path
    if real != exe {
        let argv = CommandLine.arguments.map { strdup($0) } + [nil]
        execv(real, argv)
        fatalError("execv \(real): \(String(cString: strerror(errno)))")
    }
}

let rawArgs = CommandLine.arguments
let invocation = URL(fileURLWithPath: rawArgs[0]).lastPathComponent
// AppInstallations' own launch arguments (a copy a move opened to turn the agent
// on, or one an old agent runs as its child to take the agent over) are the
// app's launch, never a verb.
let given = Array(rawArgs.dropFirst())
let args = AppInstallation.appArguments(given)
let byInstallation = AppInstallation.isInstallationLaunch(given)

// The app's launch means "make awake run": the agent turned on from this copy
// (moved into Applications first when it runs from elsewhere), the one approval
// included. It is either AppInstallations' (its arguments say so, whoever the
// parent) or LaunchServices' (a double click, Spotlight, `open`: no verb, launchd
// as parent). Without either, no verb is the CLI's bare `awake`. Output goes to
// the service log, since nobody reads such a process's stderr.
if args.isEmpty, byInstallation || getppid() == 1, Bundle.main.bundleIdentifier != nil {
    Paths.redirectOutputToServiceLog()
    log("launched by LaunchServices: turning the agent on")
    // A hand-over's launch registers the agent for this copy and exits inside.
    let installation = AppInstallation.ImageWatch.start(
        jobs: [.awake], links: Installation.links)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        _ = await Installation.turnOn()
        log("agent: \(AppInstallation.Job.awake.words)")
        withExtendedLifetime(installation) {}
        exit(0)
    }
    app.run()
}

// The verbs that act on this Mac directly; everything else talks to the daemon.
switch invocation == "asleep" ? nil : args.first {
case "daemon":
    // Under launchd the bundled plist cannot name a per-user log path; a foreground
    // dev daemon (`mise dev`) keeps its terminal.
    if getppid() == 1 { Paths.redirectOutputToServiceLog() }
    Daemon.main()  // never returns
case "grant":
    Sudoers.run(remove: args.contains("--remove"), force: args.contains("--force"))
case "agent":
    Agent.run(Array(args.dropFirst()))
case "hotkey":
    Hotkey.run(Array(args.dropFirst()))
case "skill":
    Skill.run(Array(args.dropFirst()))
case "help", "-h", "--help":
    print(CLI.usage)
default:
    Client.run(args, asleep: invocation == "asleep")
}
