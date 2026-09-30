import AwakeKit
import Foundation

/// The one vocabulary every surface speaks about claims: the menu, the CLI, notices,
/// tooltips, logs. Pure: time is an argument, so a scene renders exactly what the
/// daemon would at that instant.
public enum Words {
    public static func interval(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded(.up)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    public struct Summary: Equatable, Sendable {
        public let owner: String
        public let label: String
        /// Every claim of the owner on its own line, for tooltips.
        public let detail: String
    }

    /// Menu/notification-grade summaries: one line per OWNER, "you" first, pids
    /// demoted to a count. That surface answers who holds the Mac awake and until
    /// when, and a process-table number answers neither. CLI rows keep pids (the
    /// scripting surface; `awake off <pid>` needs them).
    public static func summarize(_ claims: [Claim], now: Date) -> [Summary] {
        var order: [String] = []
        var groups: [String: [Claim]] = [:]
        for c in claims {
            if groups[c.owner] == nil {
                if c.owner == Claim.humanOwner {
                    order.insert(c.owner, at: 0)
                } else {
                    order.append(c.owner)
                }
            }
            groups[c.owner, default: []].append(c)
        }
        return order.map { owner in
            let g = groups[owner]!
            let label: String
            if g.count == 1 {
                let c = g[0]
                let how: String
                switch c.term {
                case .indefinite: how = "indefinite"
                case .until(let d): how = "\(interval(d.timeIntervalSince(now))) left"
                case .whilePid: how = "while it runs"
                }
                label = "\(owner) · \(how)\(marks(c))"
            } else if g.allSatisfy({
                if case .whilePid = $0.term { return true } else { return false }
            }) {
                label = "\(owner) · while \(g.count) processes run"
            } else {
                label = "\(owner) · \(g.count) claims"
            }
            return Summary(
                owner: owner, label: label,
                detail: g.map { describe($0, now: now) }.joined(separator: "\n"))
        }
    }

    /// The full per-claim line for the CLI, logs and tooltips: owner first, then how
    /// it ends (pid included, `awake off <pid>` needs it), then the flares.
    public static func describe(_ c: Claim, now: Date) -> String {
        let how: String
        switch c.term {
        case .indefinite: how = "indefinite"
        case .until(let d): how = "\(interval(d.timeIntervalSince(now))) left"
        case .whilePid(let pid, _): how = "while it runs (pid \(pid))"
        }
        return "\(c.owner) · \(how)\(marks(c))"
    }

    /// The flares a claim line carries beyond owner + term.
    public static func marks(_ c: Claim) -> String {
        var out = ""
        if c.modes.contains(.display) { out += " · display on" }
        if c.wantsLid { out += c.lidGranted ? " · lid granted" : " · asks lid" }
        return out
    }
}
