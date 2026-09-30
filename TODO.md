# TODO

- [ ] **Delete the `~/Library/LaunchAgents` migration** (`Agent.removeUserAgentPlist` + its `stop()`, `Paths.userAgentPlist`). Trigger: every Mac that installed awake from source before 0.8.0 has run `mise run install` of 0.8.0 or later once; the migration prints `removed …/garden.untitled.awake.plist` when it fires. Done on the M5 (2026-09-30). Homebrew installs never need it: the pre-0.8 cask's own uninstall step deletes that plist during the upgrade.

- [ ] **Demo gif in the README.** The one thing that explains the lid-closed case faster than three paragraphs.

- [ ] **Rethink the sudoers model for other people's machines.** The rule is pinned to the installing user, which is right for a single-user Mac and unexamined for anything else: per-user rules mean any of them can disable sleep for everyone. The adopt / external-writer reconciliation already converges multiple writers, so the state machine is fine; the grant model is what needs a decision.
