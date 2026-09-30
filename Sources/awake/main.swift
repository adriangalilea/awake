import AwakeKit
import AwakeSurface
import Foundation

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
let args = Array(rawArgs.dropFirst())

// LaunchServices (a double click, Spotlight, `open`) starts the bundle with no
// arguments and launchd as parent. That launch means "make awake run": register
// the agent, or restart it into this image. Output goes to the service log, since
// nobody reads an LS-launched process's stderr.
if args.isEmpty, getppid() == 1, Bundle.main.bundleIdentifier != nil {
    Paths.redirectOutputToServiceLog()
    log("launched by LaunchServices, installing the agent")
    Agent.install()
    exit(0)
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
case "help", "-h", "--help":
    print(CLI.usage)
default:
    Client.run(args, asleep: invocation == "asleep")
}
