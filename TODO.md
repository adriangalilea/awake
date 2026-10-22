# TODO

- [ ] **`main.swift`'s `byInstallation` becomes `AppInstallation.isInstallationLaunch(given)`** once swift-utils exports it (the patch after 0.37.14): the same fact, owned by the module that defines the arguments. The LaunchServices half (`getppid() == 1`, no verb) stays awake's.

- [ ] **Demo gif in the README.** The one thing that explains the lid-closed case faster than three paragraphs.

- [ ] **Rethink the sudoers model for other people's machines.** The rule is pinned to the installing user, which is right for a single-user Mac and unexamined for anything else: per-user rules mean any of them can disable sleep for everyone. The adopt / external-writer reconciliation already converges multiple writers, so the state machine is fine; the grant model is what needs a decision.
