# TODO

- [ ] **Kill the osascript notifications. THE blocker for telling anyone this exists.** Verdict 2026-08-01: works, but trash. The path that respects the launchd constraint is the two-process split Apple DTS points at: a tiny `awake-notifier.app` bundled inside the main bundle, LS-launched per event (`open -g … --args "<msg>"`), posting via UNUserNotificationCenter in user context (first launch triggers the real TCC prompt), then exiting. The daemon keeps launchd `KeepAlive`, which is load-bearing; only the notification hop changes. Today's banners ride Script Editor's notification permission, so if that is ever off they vanish silently.

- [ ] **Demo gif in the README.** The one thing that explains the lid-closed case faster than three paragraphs.

- [ ] **Rethink the sudoers model for other people's machines.** The rule is pinned to the installing user, which is right for a single-user Mac and unexamined for anything else: per-user rules mean any of them can disable sleep for everyone. The adopt / external-writer reconciliation already converges multiple writers, so the state machine is fine; the grant model is what needs a decision.
