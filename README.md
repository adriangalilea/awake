# awake

Keep a Mac awake, **lid closed included**. One state machine, a menu bar cup and a CLI on top of it.

Every assertion-based tool (caffeinate, KeepingYouAwake, Lungo) dies the moment you close the lid, by design. Apple's own clamshell mode needs AC power plus an external display plus an input device. awake covers the case none of them do: a laptop on battery, lid shut, still working.

```
awake            # keep awake, last used duration
awake 2h         # ...for two hours
awake --until 23:30
awake -w 4821    # ...until process 4821 exits
awake --display  # keep the screen on too
asleep           # back to normal sleep
awake status     # what's true right now (--json for scripts)
```

Right-click the menu bar cup to toggle at the last duration, or press ⌃⌥⌘A anywhere. Left-click for the menu.

## Install

Requires macOS 26.

```
brew install --cask adriangalilea/tap/awake
awake grant
```

Or from source:

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
- A **battery floor** (15% by default, `awake floor N`) always wins, even over an explicitly forced session.
- Low Power Mode ends a session unless you forced it.
- `-w PID` matches the process start time as well as the pid, so a recycled pid can never keep a dead process's session alive.
- If you flip the flag by hand with `pmset`, awake adopts it as a session rather than silently undoing you.

This is why it is a daemon and not a one-shot command: a command that has exited cannot guard anything.

## Development

```
make check     # compile, the fast gate
make install   # build + install + restart the daemon
make notes     # draft notes/<version>.md from the commits
make release   # signed, notarized, stapled dmg → tag → GitHub Release
```

Releasing is deliberately local: it needs a Developer ID certificate and an App Store Connect notary key, neither of which belongs in CI, so CI only runs `make check`. Both live in the keychain, nothing on disk and nothing in this repo. Set the notary profile up once:

```
xcrun notarytool store-credentials awake \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> --issuer <ISSUER-UUID>
```

`notes/<version>.md` is the release notes, written by hand and committed. git-cliff only drafts it.

## Prior art

[Sleepless](https://github.com/Aboudjem/Sleepless) is the closest thing and the source of several lessons here, including judging the privileged toggle by sudo's exit status rather than by re-reading the flag. [Newt](https://github.com/acheris-labs/newt) has the structurally safest crash story, a root XPC helper whose connection-drop handler restores sleep. Neither ships a CLI; the shell tools in this space ship no resident guard.

MIT.
