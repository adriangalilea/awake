---
name: awake
description: Keep a Mac awake, lid closed included, via the `awake` CLI. Trigger on ANY mention of preventing sleep in ANY form ("keep awake", "don't sleep", "prevent sleep", "caffeinate", "amphetamine", "pmset disablesleep", "lid closed", "stay on while X runs", "will this survive closing the lid") and BEFORE running any long job that must outlive the lid closing (builds, downloads, agents, watchers). NEVER run `caffeinate`, `sudo pmset -a disablesleep`, or any other sleep hack directly: caffeinate dies at lid close, and raw pmset bypasses the safety nets that stop a forgotten flag from draining the battery. Examples: "keep the mac awake for 2 hours", "don't let it sleep while this build runs", "I'm closing the lid, keep it working", "restore normal sleep", "is the mac staying awake right now".
---

# awake

One state machine for keep-awake, lid closed included. A launchd daemon owns intent and the menu bar cup; `awake` and `asleep` are socket clients. Architecture: the CLAUDE.md in this repository.

## Commands

```bash
awake                 # indefinite session (lid + idle)
awake 2h | 90m | 45   # timed (bare number = minutes)
awake --until 18:00   # until wall-clock time (tomorrow if past)
awake -w PID          # while a process lives — THE form for jobs and agents
awake --display ...   # also keep the display on this once
asleep                # end session, restore normal sleep (= awake off)
awake status --json   # machine-readable intent + effect + battery
awake floor N         # battery floor percent (0 disables)
```

## Rules for agents

- **Wrapping a long job**: start it, then `awake -w <pid>`. The session ends itself when the pid dies, matched on start time as well as pid so reuse cannot fool it. Never use a timed session for a job of unknown length.
- **One session at a time**: engaging REPLACES the current session, and the reply prints what was displaced. Check `awake status --json` before arming programmatically; if `.session` is non-null someone already holds it, so do not clobber it unless asked.
- `caffeinate` does NOT survive lid close. If something died when the lid closed, this is almost always why, and the answer is `awake`, not more caffeinate.
- Safety nets belong to the daemon, not to you: the battery floor (default 15%) always wins, Low Power Mode ends unforced sessions, and everything resets on reboot by design. If a session ended "mysteriously", `awake status` and `~/Library/Logs/awake/service.log` say which net fired.
- Sleep restored is not the same as display on: the screen dimming during a session is normal unless `--display` or the menu preference is set.
- Keeping the lid-closed flag set needs one privileged grant. If a command reports the grant is missing, tell the user to run `awake grant` themselves; it opens a native authentication prompt and is not something to automate.
