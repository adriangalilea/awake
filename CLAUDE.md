# awake

One state machine for keeping the Mac awake, lid closed included. Menu bar and CLI are two mouths on the same brain. Replaces Amphetamine and the old `awake`/`asleep` fish functions.

## The mechanism (ground truth)

- `sudo pmset -a disablesleep 1` sets the kernel flag `SleepDisabled` (IORegistry). It is UNDOCUMENTED in pmset(1) but real, and it is the ONLY thing that survives closing the lid on battery with no external display.
- The flag is runtime-only: it resets to 0 on reboot. That is a safety feature we lean on, never re-arm across reboots without live intent.
- IOPMAssertions (`PreventUserIdleSystemSleep`, `PreventUserIdleDisplaySleep`) handle lid-OPEN keep-awake and die with the process holding them. `caffeinate` and every assertion-based app (KeepingYouAwake, Lungo) cannot survive lid close, by design.
- Native clamshell mode needs AC + external display + input device, which is exactly the complaint that started this.
- Read state without root: `pmset -g | grep SleepDisabled`. Absent line = off.

## Architecture

- **Effect** lives in the kernel (`pmset -g`, held assertion IDs). **Intent** lives in the daemon (`Session`), mirrored to `~/.local/state/awake/session.json` so a crashed daemon re-arms honestly. Never conflate them.
- Every mutation goes through `StateMachine.apply()`, the single choke point. No other code path touches pmset or assertions.
- The daemon (`awake daemon`, launchd `garden.untitled.awake`, KeepAlive) owns the state machine, the menu bar item, the socket (`~/.local/state/awake/awake.sock`, 0600, one JSON line per connection). The CLI never mutates state itself; unreachable daemon → `launchctl kickstart -k` → retry → loud failure.
- Reconciliation rules (StateMachine):
  - startup, valid persisted session → re-arm; stale → restore sleep, clear.
  - startup or tick, flag ON with no session → ADOPT as indefinite unforced session (converge with manual `pmset` use, never silently undo a human).
  - tick, session wants lid but flag OFF → external writer wins, session ends (`.externalOff`), notification fires.
- Safety nets (tick: 60s poll + IOPS power callbacks + LPM notification + precise expiry timer): battery floor always wins even over `forced`; Low Power Mode yields to `forced`; `-w` matches pid AND kernel start time (`procStartTime`, sysctl), so a recycled PID can never keep a dead process's session alive. Refuse to arm below the floor, don't arm what the floor immediately tears down.
- Park vs end: SIGTERM (install bounce, launchd teardown) PARKS — effect restored, intent kept on disk — so `make install` never eats a running session; startup reconciliation re-arms it. Explicit quit and every user-facing end CLEAR. Reboots are guarded structurally: `Session.isValid` rejects any session predating `kern.boottime`, which is what keeps "the flag resets on reboot" a real safety property.
- Sudo result semantics: the lid flip is judged from sudo's REAL exit status + stderr (`sudo -n`, stdin `/dev/null`, drain pipes to EOF before waiting). NEVER by re-reading `SleepDisabled` afterward, a safety net legitimately flipping sleep back on is observationally identical to a failed toggle, and confusing them causes spurious grant re-prompts (Sleepless shipped that bug; see prior art).

## Privilege

`/etc/sudoers.d/awake` (440 root:wheel), installed by `awake grant` via one `do shell script … with administrator privileges` (native auth sheet), validated with `visudo -c -f` on a temp file BEFORE landing (a broken sudoers file locks sudo machine-wide). Pinned to the installing user, the narrowest rule that works:

```
<installing-user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

`awake grant` verifies by flipping the flag to its CURRENT value (proves the grant, changes nothing). The rule content is 440 root and unreadable as the user, so tightening an installed rule needs `awake grant --force` (unconditional reinstall). `awake grant --remove` deletes it. The same shape works for any tool needing one narrow root capability.

## Ops

- Build/install: `make check` (0-warning gate) · `make install` (assembles `~/Applications/awake.app` by hand — no Xcode — Developer ID signed with ad-hoc fallback, CLI symlinks into the bundle, then `awake agent install` for the launchd plist; ALWAYS bounces the daemon so it never runs a stale image, and waits for the async bootout to finish or bootstrap fails EIO) · `make uninstall`. The bundle exists for identity (defaults domain shared by CLI and daemon, stable signature); it is NOT enough for real notifications — see below.
- Logs: `~/Library/Logs/awake/service.log` (every transition, before/after state).
- Screaming survives release: world-model violations use `precondition`/`fatalError`, never `assert` — `assert` compiles out under `-c release`, which is what `make install` ships. A daemon that cannot bind its socket must die loudly (KeepAlive restarts it, the log says why), not run deaf.
- Menu bar: left-click = menu, right-click = toggle session at last-used duration (Amphetamine's gesture). Glyph by silhouette: cup+steam = awake, cup on saucer = normal sleep.
- Global hotkey: ⌃⌥⌘A = same toggle, via swift-utils Keymap (`ActionSet` + `KeymapStore` + `GlobalHotkeys`, Carbon underneath, permission-free). Remap from the CLI: `awake hotkey ctrl+alt+cmd+a` (`--reset` restores the spec default) — it writes the daemon's own defaults domain (the CLI symlink resolves into the bundle) and bounces the daemon so Carbon re-registers.
- Notifications, the honest architecture: screen alerts go through **osascript** — deliberately, not as a stopgap. `UNUserNotificationCenter` is structurally unavailable to launchd agents (Apple DTS, forums thread 804854: TCC only arbitrates the permission for LS-launched user-context apps; verified empirically 2026-08 — Developer ID signature, lsregister, and an LS launch all still end in UNErrorDomain Code=1 under launchd). The alternatives are a two-process split (overkill here) or trading launchd `KeepAlive` for an SMAppService login item — and KeepAlive is load-bearing: it IS the crash-restore story. The code requests authorization at startup anyway and auto-upgrades to real notifications if it is ever granted (e.g. under a future login-item architecture). Consequence to know: osascript banners ride Script Editor's notification permission; if that's ever off, screen alerts vanish silently — the phone push is the channel that matters anyway. Battery-floor and Low Power Mode ends ALSO push to a phone, if `~/.local/bin/notify` exists (an OPTIONAL hook: any executable taking one message argument), sent BEFORE the flag drops so the request leaves on an awake network stack.
- CLI: `awake` · `awake 2h|90m|45` · `awake --until HH:MM` (next occurrence, tomorrow if past) · `awake -w PID` · `--display` · `asleep`/`awake off` · `awake status [--json]` (Status is Codable; the JSON form is the scripting surface) · `awake floor N` · `awake hotkey [COMBO]`. Fish aliases `caf`/`cof`/`coffee`/`amph` point at `awake`. End/engage replies carry the displaced session (`Reply.previous`) so breadcrumbs render from one round trip.
- Config (`~/.local/state/awake/config.json`): floor, last duration, display preference. Decode is per-key tolerant — adding a field never resets the rest. The display preference applies to EVERY engagement path (menu, right-click, hotkey, bare CLI); `--display` is the per-call opt-in on top.
- Menu: the countdown header ticks at 1 Hz while the menu is open (NSMenu freezes titles otherwise; the ticker rides `.common` runloop mode because menu tracking runs the event-tracking loop).
- GOTCHA: fish functions shadow PATH binaries. `~/.config/fish/functions/awake.fish`/`asleep.fish` must not exist (removed when this replaced them).
- Quit from the menu runs `launchctl bootout` (plain exit would just get resurrected by KeepAlive).

## Prior art (read before redesigning anything)

- **Sleepless** (`Aboudjem/Sleepless`, MIT, single-file AppKit, read in full 2026-07): source of the sudo-exit-status lesson above, the glyph-by-silhouette convention, LPM auto-off vs deliberate-user-intent (`forced`) split, battery floor, and "reboot resets the flag is a feature". Menu-bar only, no CLI.
- **Newt** (`acheris-labs/newt`, read in full 2026-07): SMAppService root XPC helper whose connection-drop handler restores sleep, code-signature-pinned. The structurally safest crash story, deliberately NOT copied: it demands stable signing and a second binary; launchd KeepAlive + startup reconciliation + persisted intent achieves the same honesty with none of that. Also source of refuse-to-arm-below-floor and live per-mode assertion add/drop.
- **nosleep** (`tmad4000/nosleep`, bash): the CLI UX bar (`nosleep on/off/3600`, scoped passwordless sudo, timed auto-revert). Rejected as a dependency (bash, 1-star supply chain), matched feature-wise.
- **solofan** (unpublished): the privilege pattern, one native auth prompt installs a scoped sudoers drop-in, passwordless forever.
- **strata** (unpublished sibling): the repo shape, SwiftPM engine-as-library + thin executables, Makefile with build mutex, argv[0] dispatch, launchd bounce on install.
- **Amphetamine** (closed source, replaced 2026-07): needed its separate open-source Enhancer for closed-lid at all; the right-click toggle gesture survives here.
- None of the open-source menu-bar tools ship a CLI, and the shell CLIs ship no resident guard. The whole reason this exists: safety nets need a resident process, and a one-shot command can't guard anything after it exits.

## Agent integration

- **Claude skill** (`skill/SKILL.md`, symlinked to `~/.claude/skills/awake` by `make install`, the `_core` skills convention): agents reach for `awake`, never `caffeinate`/raw `pmset`. Key rule taught: check `awake status --json` before arming programmatically; one session, engage replaces.
- **Agent harness integration**: a session-start hook that arms `awake -w <agent pid>` makes long unattended work survive the lid closing, which is the whole point. Guard it: never clobber an existing session, and never let the hook's own failure kill the session it runs in. Known limitation of the shape: with several concurrent agents, the FIRST one carries the arm and sleep returns when it exits.
- Claude Code's own `caffeinate -i -t 300` rolling assertions (the harness spawns them while sessions work) are harmless and redundant next to the lid flag; they die at lid close, which is exactly the gap the hook closes.

## Release

MIT, standalone repo, `swift-utils` consumed as a versioned URL dependency (`from: "0.1.2"`), so a fresh clone builds anywhere.

- **Releasing is LOCAL, by design**: `make release` needs the Developer ID in this keychain and the notary key in `~/.appstoreconnect/private_keys`, and neither belongs in CI. CI runs `make check` and nothing else, so the repo holds no secrets and needs none. Flipping to CI-side notarization later means uploading a p12 + ASC key to GitHub secrets; the shape it would take is specced in swift-utils' TODO (`mac-app-release.yml`).
- The Makefile's `VERSION` is the single source of truth: it stamps `Info.plist` and names the tag. An app has a native version field, so the manifest leads and the tag follows. (A Swift LIBRARY is the inverse: SwiftPM has no manifest version, so the tag IS the version. swift-utils works that way.)
- `notes/<version>.md` is the words gate: hand-written, committed, and the GitHub Release body. `make notes` drafts it from the commits with git-cliff; the draft is raw material, never prose users read. `make release` refuses without it, refuses on a dirty tree, refuses on an existing tag, refuses without a certificate or notary IDs.
- Notarization is judged by `stapler`, not by `notarytool`'s exit status: stapling can only succeed if a ticket was actually issued.
- `SIGN_ID` is discovered via `security find-identity`, never hardcoded, so a fork signs with its own certificate and `make install` still falls back to ad-hoc on a machine with none.
- Distribution is `brew install --cask adriangalilea/tap/awake`, plus the dmg on the GitHub Release for anyone who wants it directly. The recipe lives in `adriangalilea/homebrew-tap` (a separate repo because Homebrew only discovers taps by that name prefix; shared with the other apps as they arrive), working copy checked out alongside this one. `make cask` rewrites its version + sha256 and pushes; `make release` calls it last, since the sha can only exist once the dmg is public.
- **The launchd agent is owned by the BINARY** (`awake agent install`, `Agent.swift`), not by the Makefile, because there are now two installers: `make install` and the cask's `postflight`. A cask that only drops the app in `/Applications` leaves the daemon unbootstrapped, and the daemon IS the product. Cask uninstall boots the label out and deletes the plist; it deliberately leaves the sudoers grant, which would need a second auth prompt (`awake grant --remove`).

## Deliberately not built (decided, not forgotten)

- **Thermal guard** (end the session if the machine runs hot lid-closed): the failure it would prevent is already bounded twice — the battery floor caps how long a hot closed Mac can run unplugged, and the flag's reboot reset caps every runaway. Adding it would mean an SMC-reading root helper (the solofan helper is the precedent) for a third net that fires after the first two. If a real scorched-bag incident ever happens, that's the trigger to revisit; the hook is `tick()`, the data source is solofan's helper.
- **Multi-user concerns** (per-user daemons fighting over the one kernel flag): the sudoers rule is pinned to the installing user, so on a single-user machine the question never arises. A second user could not flip the flag at all. If this ever ships publicly, the adopt/external-writer reconciliation already converges multiple writers, but the grant model would need rethinking (per-user rules mean any of them can disable sleep for all).

## Verification (runnable reality, no test suite)

`make check` must print 0 warnings. Then: engage → `pmset -g` shows the flag + `pmset -g assertions` shows "awake"; `kill -9` the daemon mid-session → relaunch re-arms with correct remaining time; engage then `make install` → session parked and re-armed across the bounce; stale session.json on boot → sleep restored, file cleared; `sudo pmset -a disablesleep 1` by hand → adopted as a session; `awake -w <pid>` → ends when pid dies; 1-minute session → ends within ~1s of deadline with notification; ⌃⌥⌘A (synthesizable via System Events `key code 0 using {control down, option down, command down}`) → toggles a session at the remembered duration; engage-over-engage prints `replaced:`, end prints `ended:`. All verified 2026-07-30. Floor/LPM trips remain log-inspection only (not simulatable without draining the battery).
