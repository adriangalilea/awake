import AwakeKit
import Foundation

/// The banners. (reason, ended, remaining) → one honest sentence, or silence.
public enum Notice {
    /// "Sleep restored" is said ONLY when the last claim is gone. An agent's claim
    /// ending under other claims is a non-event (log-only); YOUR claim ending while
    /// others keep the Mac awake says so explicitly. Safety-net ends always speak.
    public static func compose(
        _ reason: EndReason, ended: [Claim], remaining: [Claim], now: Date
    ) -> String? {
        let still =
            remaining.isEmpty
            ? "Sleep restored."
            : "Still awake: \(Words.summarize(remaining, now: now).map(\.label).joined(separator: ", "))."
        switch reason {
        case .requested, .shutdown:
            return nil
        case .batteryFloor(let p):
            return "Battery at \(p)%. Sleep restored."
        case .lowPowerMode:
            return "Low Power Mode is on. \(still)"
        case .thermal:
            // What happened and what it means for the Mac, in the person's terms:
            // only the lid-closed claims end, so with nothing else holding it the
            // Mac sleeps; with something still holding it, it stays awake only
            // while the lid is open.
            return remaining.isEmpty
                ? "Too hot with the lid closed, so awake let your Mac sleep."
                : "Too hot with the lid closed: shutting it now sleeps the Mac. \(still)"
        case .externalOff:
            return "Sleep was re-enabled outside awake. All claims ended."
        case .expired:
            guard remaining.isEmpty || ended.contains(where: { $0.owner == Claim.humanOwner })
            else { return nil }  // an agent's timer lapsing under other claims is a non-event
            let labels = ended.map { expiredLabel($0) }.joined(separator: " and ")
            return "\(labels) expired. \(still)"
        case .pidExited(let pid):
            // The last claim explaining why sleep came back is signal; an agent
            // hand-off while others hold the machine is noise.
            guard remaining.isEmpty, let claim = ended.first else { return nil }
            return "\(claim.owner) (pid \(pid)) exited. Sleep restored."
        }
    }

    /// The floor's second net: below the floor, display dark, still awake.
    public static func forcedSleep(percent: Int) -> String {
        "Battery at \(percent)%, under the floor, still awake with the display dark. Sleeping now."
    }

    public static func updateAvailable(_ latest: String, running: String) -> String {
        "awake \(latest) is out, you run \(running). brew upgrade --cask awake, or awake.untitled.garden"
    }

    /// "Your 2h claim" / "release's 8h claim": the owner and the span it asked for.
    private static func expiredLabel(_ c: Claim) -> String {
        var span = ""
        if case .until(let d) = c.term {
            span = " \(Words.interval(d.timeIntervalSince(c.startedAt)))"
        }
        return c.owner == Claim.humanOwner ? "Your\(span) claim" : "\(c.owner)'s\(span) claim"
    }
}
