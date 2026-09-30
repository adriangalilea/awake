import AwakeKit
import Foundation

let usage = """
    awake — keep the Mac awake, lid closed included. One state machine, menu bar + CLI.

    The machine stays awake while ANY claim exists; claims coexist instead of
    replacing each other. Yours, an agent's process watch, a build's timer — each is
    its own claim, and sleep restores when the last one ends.

      awake                 indefinite claim (lid + idle)
      awake 2h | 90m | 45   timed claim (bare number = minutes)
      awake --until HH:MM   until a wall-clock time (tomorrow if already past)
      awake -w PID          while a process lives (builds, agents, jobs); named after it
      awake --label NAME .. name the claim (who wants this; default "you", -w names itself)
      awake --lid ...       ask for lid-closed survival (named claims; you grant it)
      awake --display ...   also keep the display on for this claim
      awake --on-end CMD .. run CMD when this claim ends, any reason (sh -c, $1 = why)
      awake check [WHO]     is the wish honored right now? exit 0 in effect · 2 inert · 3 gone
      awake allow [WHO]     grant a pending lid ask (all, or owner prefix / pid)
      awake deny [WHO]      dismiss it — after a grant, this revokes
      awake suspend         let it sleep: every claim kept, effect off (= right-click / ⌃⌥⌘A)
      awake resume          lift the switch, claims take effect again
      asleep | awake off    END every claim, restore normal sleep
      awake off WHO         end matching claims only (owner prefix or pid)
      awake status [--json] all claims + effect + battery, honestly
      awake floor N         battery floor percent (0 disables)
      awake display [on|off] keep the screen on while anything holds the Mac awake
      awake notify [CMD]    out-of-band hook for closed-lid ends (--clear removes)
      awake updates [on|off] the daily version check (one GET, counts as an active install)
      awake hotkey [COMBO]  show/remap the global toggle (--reset for default)
      awake grant           install the scoped sudoers grant (once)
      awake grant --remove  remove it · --force reinstalls over an existing rule
      awake agent install   register the agent for THIS bundle (or restart it into it)
      awake agent uninstall stop it and unregister it

    Lid-closed survival is YOURS to grant. Your own claims (menu, hotkey, bare
    `awake`) carry it; a named claim — any programmatic caller: a cron job, a
    build, a script, a coding agent — runs lid-open only and may ASK with --lid.
    The ask shows as ? in the menu bar and leads the menu; grant it there or with
    `awake allow`. A grant dies with the claim it answered.

    Global hotkey (default ⌃⌥⌘A) and right-click on the menu bar cup toggle YOUR
    claim only: yours running → end it (lid disarms, named claims keep working);
    none → start yours at the last menu-chosen duration; suspended → resume and
    start yours. "Let it sleep" (everything inert) is the menu item / `awake
    suspend`, an explicit act, never this gesture.
    Battery floor: at the floor every claim ends; if the Mac is still awake below it
    with the display dark (someone else's assertion), it is put to sleep.
    """

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

if invocation == "asleep" {
    Client.end(args.first)
    exit(0)
}

switch args.first {
case "daemon":
    // Under launchd the bundled plist cannot name a per-user log path; a foreground
    // dev daemon (`mise dev`) keeps its terminal.
    if getppid() == 1 { Paths.redirectOutputToServiceLog() }
    Daemon.main()  // never returns
case "grant":
    Sudoers.run(remove: args.contains("--remove"), force: args.contains("--force"))
case "agent":
    Agent.run(Array(args.dropFirst()))
case "status":
    Client.status(json: args.contains("--json"))
case "off":
    Client.end(args.count > 1 ? args[1] : nil)
case "suspend":
    Client.suspend()
case "resume":
    Client.resume()
case "floor":
    guard args.count == 2, let v = Int(args[1]) else { Client.die("usage: awake floor <percent>") }
    Client.setFloor(v)
case "display":
    Client.keepDisplay(Array(args.dropFirst()))
case "check":
    Client.check(args.count > 1 ? args[1] : nil)
case "allow":
    Client.resolveLid(true, args.count > 1 ? args[1] : nil)
case "deny":
    Client.resolveLid(false, args.count > 1 ? args[1] : nil)
case "notify":
    Client.notifyHook(Array(args.dropFirst()))
case "updates":
    Client.updates(Array(args.dropFirst()))
case "hotkey":
    Hotkey.run(Array(args.dropFirst()))
case "help", "-h", "--help":
    print(usage)
default:
    Client.engage(args)
}
