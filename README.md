# awake

**Close the lid. Your Mac stays awake.** One state machine, a menu bar cup and a CLI on top of it.

![Claude Code starts a long migration; ⌃⌥⌘A keeps the Mac awake, the lid closes, and the agent keeps working until it is done](https://cdn.untitled.garden/media/awake/films/hero.webp)

Every assertion-based tool (caffeinate, KeepingYouAwake, Lungo) dies the moment you close the lid, by design. Apple's own clamshell mode needs AC power plus an external display plus an input device. awake covers the case none of them do: a laptop on battery, lid shut, still working.

```
awake            # keep awake indefinitely
awake 2h         # ...for two hours
awake --until 23:30
awake -w 4821    # ...while process 4821 lives (the claim names itself after it)
awake --lid ...  # a named claim ASKS for lid-closed survival; you grant it
awake allow      # grant a pending ask (also one click in the menu)
awake --display  # keep the screen on too
awake suspend    # let it sleep now; every claim is kept and comes back on resume
awake resume     # lift that switch
asleep           # END every claim, back to normal sleep
awake off make   # end just the claims matching an owner name or pid
awake status     # every claim, what's true right now (--json for scripts)
awake check 4821 # is that wish honored right now? exit 0 in effect · 2 inert · 3 gone
awake --on-end 'notify done' -w 4821   # be told when the claim ends, any reason
```

Intent is a set of **claims**: yours, an agent's process watch and a build's timer coexist instead of replacing each other. The Mac stays awake while any claim lives, sleep restores when the last one ends, and the menu bar lists who is holding it awake and why.

**Closing the lid stays yours.** Your own claims survive it; a named claim (any program: a cron job, a build, a coding agent) keeps the Mac awake lid-open only, and may *ask* for lid-closed survival (`--lid`). The cup grows a "?" and the menu leads with the ask; one click answers it, and the grant dies with the claim it answered. The cup itself tells you what closing the lid will do: outline = sleeping normally, filled = held awake but bag-safe, burning = it will keep running with the lid shut.

Right-click the menu bar cup, or press ⌃⌥⌘A anywhere, to toggle **your claim and nothing else**: with yours running it ends it (the lid disarms, named claims keep working); with none it starts yours at the checkmarked duration (which arms lid). Putting the whole machine to sleep is a separate, explicit act: "Let it sleep" in the menu (`awake suspend`) keeps every claim inert until Resume, and "End all claims" (`asleep`) is the nuke. Each roster row opens into its own controls: allow, dismiss or revoke a lid ask, end one stuck session or all of an owner's. Left-click for the menu.

## Install

Requires macOS 26.

```
brew install --cask adriangalilea/tap/awake
awake grant
```

Or the dmg from [awake.untitled.garden](https://awake.untitled.garden), or from source:

```
git clone https://github.com/adriangalilea/awake
cd awake && mise run install     # needs mise (brew install mise); the verbs live in mise.toml
awake grant
```

Either path installs the app and puts `awake` and `asleep` on your PATH. The daemon that owns the state machine is a launch agent the app registers itself (SMAppService, listed under Login Items), the first time you open awake or run any `awake` command. From then on it keeps itself current: after an upgrade it restarts into the new version, and if you delete the app it restores normal sleep and stops itself.

`awake grant` asks once, with the native authorization prompt, to install a sudoers rule scoped to exactly two commands:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

That is the whole privilege footprint. `awake grant --remove` deletes it, `mise run uninstall` removes everything else.

## With coding agents

awake ships an [agent skill](skill/SKILL.md) for Claude Code and Codex. It teaches the agent to hold the Mac awake for exactly as long as its work runs (`awake -w <pid>`), to ask you before it keeps going with the lid shut, and never to reach for `caffeinate`, which dies when the lid closes.

```
awake skill install
```

links it into `~/.claude/skills` and `~/.codex/skills`, for whichever of the two is on your Mac. The link points into the app, so every upgrade of awake upgrades the skill. `awake skill` shows where it is installed, `awake skill remove` takes it away, and deleting the app removes it too.

## How it actually works

Closing the lid is the hard part, and only one thing survives it: `pmset -a disablesleep 1`, which sets the kernel's `SleepDisabled` flag. It is undocumented in `pmset(1)` but real, and it needs root, which is what the sudoers rule buys. The flag is runtime-only and resets on reboot; that is a safety feature, not a limitation, and awake never re-arms across a reboot without live intent.

Lid-open keep-awake uses ordinary IOPMAssertions, which die with the process holding them.

Because a flag that outlives its owner is dangerous, a resident daemon guards it:

- **Effect** lives in the kernel. **Intent** lives in the daemon and is mirrored to disk, so a crashed daemon re-arms honestly instead of leaving your Mac permanently awake.
- A **battery floor** (15% by default, `awake floor N`) always wins and ends every claim. And because ending claims only *lets* the Mac sleep, if it is still awake below the floor with the display dark, something else (audio on the speakers, a download) is holding an idle assertion, and awake puts the Mac to sleep itself rather than watch it drain from the floor to hibernation.
- Low Power Mode ends claims nobody forced.
- **Critical heat** ends every claim that holds the lid, forced or not, and refuses new ones until the Mac cools. A closed Mac in a bag can sit at critical thermal pressure for hours before macOS forces an emergency sleep; awake lets go the moment it gets there. Claims without the lid keep running, and nothing re-arms on its own.
- `-w PID` matches the process start time as well as the pid, so a recycled pid can never keep a dead process's claim alive.
- If you flip the flag by hand with `pmset`, awake adopts it as a claim rather than silently undoing you.

This is why it is a daemon and not a one-shot command: a command that has exited cannot guard anything.

## Update check

Once a day the daemon fetches `awake.untitled.garden/appcast.xml`. That GET is the entire payload: no identifier, no usage data, nothing about your Mac. The server keeps a salted, non-reversible hash of the caller's IP for that day so the garden can count active installs (never the IP itself), and answers with the feed. If the feed names a newer version than the one you run, awake says so once, on screen, and points at `brew upgrade --cask awake`. `awake status` shows the same nudge. `awake updates off` stops the check, and with it the ping.

## Notifications

Claims that end on their own say so on screen when it matters: when sleep was actually restored, or when yours ended while others still hold the Mac awake. An agent's claim quietly handing off under yours is a non-event and stays out of your face. Banners are real system notifications, posted by a tiny helper app inside the bundle (macOS refuses them to a launchd agent, which the daemon has to be); the one-time permission prompt comes at install, with a first banner that says what will arrive there. If notifications are off (denied at that prompt, or allowed with the alert style set to None, which shows nothing), the menu leads with a row saying so that opens awake's page in System Settings, and `awake status` says it too. It goes away the moment they are back on. Three of those ends, the battery floor, Low Power Mode and critical heat, are exactly the ones that fire while the lid is shut, where a screen notification informs nobody. So you can point awake at any executable and it will be called with a single message argument:

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

The verbs are mise tasks (`mise.toml`; `mise tasks` lists them):

```
mise check           # format + compile, the fast gate
mise run install     # build + install + restart the daemon
mise notes           # draft notes/<version>.md from the commits
mise run release     # signed, notarized, stapled dmg → tag → GitHub Release → garden → cask
mise scene           # compile scenes/*.scene into the timelines the web plays
mise film            # film each scene (WebP + mp4) and publish it to the CDN
```

The films above are not screen recordings. Each `scenes/*.scene` is a short story (the lid closes, the battery drops, you open the menu) that `awake-scene` plays through awake's real engine against a scripted Mac. Every menu row, terminal line and banner in them is what awake itself produces, and a scene that clicks a row the menu no longer has fails to compile.

Releasing is deliberately local: it needs a Developer ID certificate and an App Store Connect notary key, neither of which belongs in CI, so CI only runs `mise check`. Both live in the keychain, nothing on disk and nothing in this repo. Set the notary profile up once:

```
xcrun notarytool store-credentials awake \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> --issuer <ISSUER-UUID>
```

`notes/<version>.md` is the release notes, written by hand and committed. git-cliff only drafts it. The dmg is served through `awake.untitled.garden/releases/<file>` (the cask points there too), which counts each download before redirecting to the CDN; GitHub keeps a copy of the asset.

## Prior art

[Sleepless](https://github.com/Aboudjem/Sleepless) is the closest thing and the source of several lessons here, including judging the privileged toggle by sudo's exit status rather than by re-reading the flag. [Newt](https://github.com/acheris-labs/newt) has the structurally safest crash story, a root XPC helper whose connection-drop handler restores sleep. Neither ships a CLI; the shell tools in this space ship no resident guard.

MIT.
