# awake

Keep a Mac awake, **lid closed included**. One state machine, a menu bar cup and a CLI on top of it.

Every assertion-based tool (caffeinate, KeepingYouAwake, Lungo) dies the moment you close the lid, by design. Apple's own clamshell mode needs AC power plus an external display plus an input device. awake covers the case none of them do: a laptop on battery, lid shut, still working.

```
awake            # keep awake indefinitely
awake 2h         # ...for two hours
awake --until 23:30
awake -w 4821    # ...while process 4821 lives (the claim names itself after it)
awake --display  # keep the screen on too
awake suspend    # let it sleep now; every claim is kept and comes back on resume
awake resume     # lift that switch
asleep           # END every claim, back to normal sleep
awake off make   # end just the claims matching an owner name or pid
awake status     # every claim, what's true right now (--json for scripts)
```

Intent is a set of **claims**: yours, an agent's process watch and a build's timer coexist instead of replacing each other. The Mac stays awake while any claim lives, sleep restores when the last one ends, and the menu bar lists who is holding it awake and why.

Right-click the menu bar cup, or press ⌃⌥⌘A anywhere, to toggle: with claims running it **suspends** (the Mac sleeps normally, nothing anyone wanted is forgotten, and a claim that arrives meanwhile waits too); suspended, it resumes everything and starts your claim at the checkmarked duration; with nothing running it starts yours. Ending claims for good is a separate, explicit act (`asleep`, "End all claims" in the menu), never a gesture that reads as reversible. Left-click for the menu.

## Install

Requires macOS 26.

```
brew install --cask adriangalilea/tap/awake
awake grant
```

Or the dmg from [awake.untitled.garden](https://awake.untitled.garden), or from source:

```
git clone https://github.com/adriangalilea/awake
cd awake && make install
awake grant
```

Either path installs the app, puts `awake` and `asleep` on your PATH, and bootstraps the launchd agent that owns the state machine. The agent is installed by the binary itself (`awake agent install`), so both paths land exactly the same thing.

`awake grant` asks once, with the native authorization prompt, to install a sudoers rule scoped to exactly two commands:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

That is the whole privilege footprint. `awake grant --remove` deletes it, `make uninstall` removes everything else.

## How it actually works

Closing the lid is the hard part, and only one thing survives it: `pmset -a disablesleep 1`, which sets the kernel's `SleepDisabled` flag. It is undocumented in `pmset(1)` but real, and it needs root, which is what the sudoers rule buys. The flag is runtime-only and resets on reboot; that is a safety feature, not a limitation, and awake never re-arms across a reboot without live intent.

Lid-open keep-awake uses ordinary IOPMAssertions, which die with the process holding them.

Because a flag that outlives its owner is dangerous, a resident daemon guards it:

- **Effect** lives in the kernel. **Intent** lives in the daemon and is mirrored to disk, so a crashed daemon re-arms honestly instead of leaving your Mac permanently awake.
- A **battery floor** (15% by default, `awake floor N`) always wins and ends every claim. And because ending claims only *lets* the Mac sleep, if it is still awake below the floor with the display dark, something else (audio on the speakers, a download) is holding an idle assertion, and awake puts the Mac to sleep itself rather than watch it drain from the floor to hibernation.
- Low Power Mode ends claims nobody forced.
- `-w PID` matches the process start time as well as the pid, so a recycled pid can never keep a dead process's claim alive.
- If you flip the flag by hand with `pmset`, awake adopts it as a claim rather than silently undoing you.

This is why it is a daemon and not a one-shot command: a command that has exited cannot guard anything.

## Update check

Once a day the daemon fetches `awake.untitled.garden/appcast.xml`. That GET is the entire payload: no identifier, no usage data, nothing about your Mac. The server keeps a salted, non-reversible hash of the caller's IP for that day so the garden can count active installs (never the IP itself), and answers with the feed. If the feed names a newer version than the one you run, awake says so once, on screen, and points at `brew upgrade --cask awake`. `awake status` shows the same nudge. `awake updates off` stops the check, and with it the ping.

## Notifications

Claims that end on their own say so on screen when it matters: when sleep was actually restored, or when yours ended while others still hold the Mac awake. An agent's claim quietly handing off under yours is a non-event and stays out of your face. Banners are real system notifications, posted by a tiny helper app inside the bundle (macOS refuses them to a launchd agent, which the daemon has to be); the one-time permission prompt comes at install, with a first banner that says what will arrive there. Two of those ends, the battery floor and Low Power Mode, are exactly the ones that fire while the lid is shut, where a screen notification informs nobody. So you can point awake at any executable and it will be called with a single message argument:

```
awake notify ~/.local/bin/push-to-my-phone   # set it
awake notify                                 # show it
awake notify --clear                         # back to screen only
```

awake ships no such tool and has no opinion about which you use: a push service CLI, an SMS gateway, a two-line script that curls a webhook. Anything executable that accepts one string. The call is made **before** the kernel flag drops, so the request leaves while the network stack is still awake.

## In your shell prompt

`awake status --json` reports `"claims":[]` when nothing is running, which is all a prompt needs. Six lines of starship:

```toml
[custom.awake]
when = "awake status --json | grep -q '\"claims\":\\[{'"
command = "echo ☕"
shell = ["bash", "--noprofile", "--norc"]
format = "[$output]($style) "
style = "yellow"
```

## Development

```
make check     # compile, the fast gate
make install   # build + install + restart the daemon
make notes     # draft notes/<version>.md from the commits
make release   # signed, notarized, stapled dmg → tag → GitHub Release → garden → cask
```

Releasing is deliberately local: it needs a Developer ID certificate and an App Store Connect notary key, neither of which belongs in CI, so CI only runs `make check`. Both live in the keychain, nothing on disk and nothing in this repo. Set the notary profile up once:

```
xcrun notarytool store-credentials awake \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> --issuer <ISSUER-UUID>
```

`notes/<version>.md` is the release notes, written by hand and committed. git-cliff only drafts it. The dmg is served through `awake.untitled.garden/releases/<file>` (the cask points there too), which counts each download before redirecting to the CDN; GitHub keeps a copy of the asset.

## Prior art

[Sleepless](https://github.com/Aboudjem/Sleepless) is the closest thing and the source of several lessons here, including judging the privileged toggle by sudo's exit status rather than by re-reading the flag. [Newt](https://github.com/acheris-labs/newt) has the structurally safest crash story, a root XPC helper whose connection-drop handler restores sleep. Neither ships a CLI; the shell tools in this space ship no resident guard.

MIT.
