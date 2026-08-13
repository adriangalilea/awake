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
  awake -w PID          while a process lives (agents, builds); named after it
  awake --label NAME .. name the claim (who wants this; default "you", -w names itself)
  awake --display ...   also keep the display on for this claim
  asleep | awake off    end EVERY claim, restore normal sleep
  awake off WHO         end matching claims only (owner prefix or pid)
  awake status [--json] all claims + effect + battery, honestly
  awake floor N         battery floor percent (0 disables)
  awake display [on|off] standing "keep the screen on" for menu/hotkey sessions
  awake notify [CMD]    out-of-band hook for closed-lid ends (--clear removes)
  awake hotkey [COMBO]  show/remap the global toggle (--reset for default)
  awake grant           install the scoped sudoers grant (once)
  awake grant --remove  remove it · --force reinstalls over an existing rule
  awake agent install   write + bootstrap the launchd agent for THIS binary
  awake agent uninstall stop it and remove the plist

Global hotkey (default ⌃⌥⌘A) and right-click on the menu bar cup toggle: end
every claim if any exist, else start yours at the last menu-chosen duration.
"""

let rawArgs = CommandLine.arguments
let invocation = URL(fileURLWithPath: rawArgs[0]).lastPathComponent
let args = Array(rawArgs.dropFirst())

if invocation == "asleep" {
    Client.end(args.first)
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
    Client.end(args.count > 1 ? args[1] : nil)
case "floor":
    guard args.count == 2, let v = Int(args[1]) else { Client.die("usage: awake floor <percent>") }
    Client.setFloor(v)
case "display":
    Client.keepDisplay(Array(args.dropFirst()))
case "notify":
    Client.notifyHook(Array(args.dropFirst()))
case "hotkey":
    Hotkey.run(Array(args.dropFirst()))
case "help", "-h", "--help":
    print(usage)
default:
    Client.engage(args)
}
