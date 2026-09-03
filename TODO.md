# TODO

- [ ] **Double-clicking awake.app with no daemon dies silently.** A Finder/Spotlight launch runs the binary with no arguments, which is the CLI's "indefinite claim"; with the agent booted out (menu quit does exactly that) `Client.engage` dies with "daemon unreachable" inside an LSUIElement bundle, so the user sees nothing and concludes the app is broken. Detect the app launch (no args + `Bundle.main` is a bundle, or LaunchServices' `-psn` style marker) and run `agent install` there, so a double click IS the recovery from quit. Stumbled into 2026-09-03 with four copies in Spotlight, none of which "opened".

- [ ] **Demo gif in the README.** The one thing that explains the lid-closed case faster than three paragraphs.

- [ ] **Rethink the sudoers model for other people's machines.** The rule is pinned to the installing user, which is right for a single-user Mac and unexamined for anything else: per-user rules mean any of them can disable sleep for everyone. The adopt / external-writer reconciliation already converges multiple writers, so the state machine is fine; the grant model is what needs a decision.
