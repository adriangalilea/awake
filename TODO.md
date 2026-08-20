# TODO

- [ ] **BUG, first-run on a fresh machine (M5, 2026-08-20): the menu bar icon is DEAD.** Installed via cask, icon appears, left-click and right-click both do nothing - no menu, no hint, nothing. The likely shape: the app assumes the CLI grant (`awake grant`, sudoers) already happened, and a virgin machine has no path to discover that from the icon. "Fully wrong, impossible to find" (Adrian). The icon must ALWAYS open a menu; on a machine without the grant, that menu's first row IS the onboarding: explain the one-time privileged step and run it through the system's own admin prompt (or hand the exact command to copy), then reconcile live. A menu bar app that needs a terminal first has its onboarding inverted.

- [ ] **Demo gif in the README.** The one thing that explains the lid-closed case faster than three paragraphs.

- [ ] **Rethink the sudoers model for other people's machines.** The rule is pinned to the installing user, which is right for a single-user Mac and unexamined for anything else: per-user rules mean any of them can disable sleep for everyone. The adopt / external-writer reconciliation already converges multiple writers, so the state machine is fine; the grant model is what needs a decision.
