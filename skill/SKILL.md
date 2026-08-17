---
name: awake
description: Keep a Mac awake, lid closed included, via the `awake` CLI. Trigger on ANY mention of preventing sleep in ANY form ("keep awake", "don't sleep", "prevent sleep", "caffeinate", "amphetamine", "pmset disablesleep", "lid closed", "stay on while X runs", "will this survive closing the lid") and BEFORE running any long job that must outlive the lid closing (builds, downloads, agents, watchers). NEVER run `caffeinate`, `sudo pmset -a disablesleep`, or any other sleep hack directly: caffeinate dies at lid close, and raw pmset bypasses the safety nets that stop a forgotten flag from draining the battery. Examples: "keep the mac awake for 2 hours", "don't let it sleep while this build runs", "I'm closing the lid, keep it working", "restore normal sleep", "is the mac staying awake right now".
---

# awake

One state machine for keep-awake, lid closed included. A launchd daemon owns intent and the menu bar cup; `awake` and `asleep` are socket clients. Intent is a set of CLAIMS: every party that wants the Mac awake holds its own claim, the effect is their union, and sleep restores when the last claim ends. Architecture: the CLAUDE.md in this repository.

## Commands

```bash
awake                 # indefinite claim (lid + idle), owner "you"
awake 2h | 90m | 45   # timed claim (bare number = minutes)
awake --until 18:00   # until wall-clock time (tomorrow if past)
awake -w PID          # while a process lives — THE form for jobs and agents
awake --label NAME .. # name a timed/indefinite claim (who wants this)
awake --display ...   # also keep the display on for this claim
awake suspend         # HUMAN gesture: let it sleep, claims kept inert (= right-click / ⌃⌥⌘A)
awake resume          # HUMAN gesture: lift it
asleep                # end EVERY claim, restore normal sleep (= awake off)
awake off WHO         # end matching claims only (owner prefix or pid)
awake status --json   # machine-readable claims + effect + battery
awake floor N         # battery floor percent (0 disables)
awake updates [on|off] # daily version check (one GET a day; the human's setting, leave it)
```

## Rules for agents

- **Wrapping a long job**: start it, then `awake -w <pid>`. The claim names itself after the process, ends itself when the pid dies (matched on start time as well as pid so reuse cannot fool it), and coexists with every other claim. Never use a timed claim for a job of unknown length.
- **Arm without checking**: claims cannot clobber each other, so there is no status check before `awake -w` — the old check-then-act guard is exactly the race the claims engine removed. Re-arming the same pid replaces that pid's claim atomically.
- **Name your timed claims**: `awake --label "release build" 2h`. An unlabeled claim reads as the human's ("you") in the menu bar and notifications; a labeled one tells the human who wants the Mac awake. `-w` claims name themselves.
- **Never `asleep`/`awake off` (bare) programmatically**: it ends EVERY claim including the human's. End only your own: `awake off <label|pid>`. `-w` claims need no ending at all.
- **Never `awake suspend`/`awake resume`**: that is the human's "let it sleep" switch (right-click, hotkey). If `awake status` says `sleeping — suspended by you`, your claim was still added and is waiting; do not fight it, do not report it as failure, and do not resume on the human's behalf.
- **A covered claim is still a claim**: engaging under someone's indefinite claim replies "already covered" but the claim is added, and it takes over if the covering claim ends. That is correct; do not treat the covered reply as failure.
- `caffeinate` does NOT survive lid close. If something died when the lid closed, this is almost always why, and the answer is `awake`, not more caffeinate.
- Safety nets belong to the daemon, not to you: the battery floor (default 15%) always wins and ends everything, Low Power Mode ends unforced claims, and everything resets on reboot by design. If claims ended "mysteriously", `awake status` and `~/Library/Logs/awake/service.log` say which net fired.
- Sleep restored is not the same as display on: the screen dimming during a claim is normal. `--display` is per-claim and explicit from the CLI; the menu's "Keep display on" preference applies only to the human's menu/hotkey claims, never to yours.
- Keeping the lid-closed flag set needs one privileged grant. If a command reports the grant is missing, tell the user to run `awake grant` themselves; it opens a native authentication prompt and is not something to automate.
