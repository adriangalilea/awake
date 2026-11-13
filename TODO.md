# TODO

- [ ] **The battery read from swift-utils' MachineStates.** `Sources/AwakeKit/Battery.swift` is a battery reader of its own; MachineStates (swift-utils `Sources/MachineStates`) reads a Mac's power, and the floor and the menu read it from there, the app's own reader deleted.

- [ ] **Demo gif in the README.** The one thing that explains the lid-closed case faster than three paragraphs.

- [ ] **Rethink the sudoers model for other people's machines.** The rule is pinned to the installing user, which is right for a single-user Mac and unexamined for anything else: per-user rules mean any of them can disable sleep for everyone. The adopt / external-writer reconciliation already converges multiple writers, so the state machine is fine; the grant model is what needs a decision.
