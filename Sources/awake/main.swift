import AwakeKit
import Foundation

let usage = """
awake — keep the Mac awake, lid closed included. One state machine, menu bar + CLI.

  awake                 indefinite session (lid + idle)
  awake 2h | 90m | 45   timed session (bare number = minutes)
  awake --until HH:MM   until a wall-clock time (tomorrow if already past)
  awake -w PID          while a process lives (agents, builds)
  awake --display ...   also keep the display on this once
  asleep | awake off    end the session, restore normal sleep
  awake status [--json] intent + effect + battery, honestly
  awake floor N         battery floor percent (0 disables)
  awake notify [CMD]    out-of-band hook for closed-lid ends (--clear removes)
  awake hotkey [COMBO]  show/remap the global toggle (--reset for default)
  awake grant           install the scoped sudoers grant (once)
  awake grant --remove  remove it · --force reinstalls over an existing rule
  awake agent install   write + bootstrap the launchd agent for THIS binary
  awake agent uninstall stop it and remove the plist

Global hotkey (default ⌃⌥⌘A) and right-click on the menu bar cup both
toggle a session at the last-used duration. The menu's "Keep display on"
preference applies to every engagement; --display is the one-shot form.
"""

let rawArgs = CommandLine.arguments
let invocation = URL(fileURLWithPath: rawArgs[0]).lastPathComponent
let args = Array(rawArgs.dropFirst())

if invocation == "asleep" {
    Client.end()
    exit(0)
}

switch args.first {
case "daemon":
    Daemon.main() // never returns
case "grant":
    Grant.run(remove: args.contains("--remove"), force: args.contains("--force"))
case "agent":
    Agent.run(Array(args.dropFirst()))
case "status":
    Client.status(json: args.contains("--json"))
case "off":
    Client.end()
case "floor":
    guard args.count == 2, let v = Int(args[1]) else { Client.die("usage: awake floor <percent>") }
    Client.setFloor(v)
case "notify":
    Client.notifyHook(Array(args.dropFirst()))
case "hotkey":
    Hotkey.run(Array(args.dropFirst()))
case "help", "-h", "--help":
    print(usage)
default:
    Client.engage(args)
}
