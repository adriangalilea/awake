import AwakeKit
import Foundation

import enum Grant.Standing  // scoped: Grant's own Claim would shadow AwakeKit's

/// What a menu row does when clicked. The daemon performs it on the live machine
/// (`StateMachine.perform`); a scene performs it on a scripted one.
public enum MenuAction: Equatable, Sendable {
    case finishSetup
    case notifications
    case allowLid([UUID])
    case denyLid([UUID])
    case endClaims([UUID])
    case endYours
    case endAll
    case suspend
    case resume
    case engage(minutes: Int)
    case toggleDisplay
    case floor(Int)
    case quit
}

/// One row of the menu bar menu, as data. The daemon draws it with NSMenu, a scene
/// writes it out for the web; both read this, so they cannot disagree.
public struct MenuRow: Equatable, Sendable {
    public var title: String
    public var separator: Bool
    public var action: MenuAction?
    public var submenu: [MenuRow]?
    public var checked: Bool
    /// Wears the toggle chord: the one item right-click and the global hotkey do.
    public var toggle: Bool
    public var hidden: Bool
    public var tooltip: String?

    /// Clickable, or opens a submenu. Everything else is information.
    public var enabled: Bool { action != nil || submenu != nil }

    static func item(
        _ title: String, _ action: MenuAction? = nil, checked: Bool = false,
        toggle: Bool = false, hidden: Bool = false, tooltip: String? = nil,
        submenu: [MenuRow]? = nil
    ) -> MenuRow {
        MenuRow(
            title: title, separator: false, action: action, submenu: submenu, checked: checked,
            toggle: toggle, hidden: hidden, tooltip: tooltip)
    }

    static func separator(hidden: Bool = false) -> MenuRow {
        MenuRow(
            title: "", separator: true, action: nil, submenu: nil, checked: false, toggle: false,
            hidden: hidden, tooltip: nil)
    }
}

/// Everything the menu shows that is not in `Status`: the clock, the two grants the
/// daemon probes, and the human's last menu-chosen duration.
public struct MenuInput: Sendable {
    public var status: Status
    public var now: Date
    public var sudoers: Standing
    public var notifications: Standing
    public var lastMinutes: Int

    public init(
        status: Status, now: Date, sudoers: Standing, notifications: Standing, lastMinutes: Int
    ) {
        self.status = status
        self.now = now
        self.sudoers = sudoers
        self.notifications = notifications
        self.lastMinutes = lastMinutes
    }
}

public enum Menu {
    public static let durations: [(title: String, minutes: Int)] = [
        ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120),
        ("4 hours", 240), ("8 hours", 480), ("Indefinite", 0),
    ]
    public static let floors = [0, 10, 15, 20, 30, 50]

    /// The sudoers grant in Grant's vocabulary: one click raises the system's own
    /// admin sheet, so missing is an offer, never a failure.
    public static func sudoersStanding(ready: Bool) -> Standing {
        ready
            ? .good
            : .askable(
                "Allow lid-closed awake\u{2026}",
                note:
                    "One-time admin approval. Installs a sudoers rule scoped to exactly two pmset commands, validated by visudo first."
            )
    }

    /// The first line: effect, then who.
    public static func header(_ claims: [Claim], suspended: Bool, now: Date) -> String {
        let summaries = Words.summarize(claims, now: now)
        if suspended {
            return claims.isEmpty
                ? "Sleeping · suspended by you"
                : "Sleeping · \(claims.count) claim\(claims.count == 1 ? "" : "s") suspended by you"
        }
        switch summaries.count {
        case 0: return "Asleep · normal sleep"
        case 1: return "Awake · " + summaries[0].label
        default: return "Awake · \(claims.count) claims"
        }
    }

    public static func rows(_ input: MenuInput) -> [MenuRow] {
        let st = input.status
        let now = input.now
        let suspended = st.suspendedSince != nil
        var rows: [MenuRow] = []

        // The grants lead: a row only when one needs the human, the action title
        // saying what the click does, the note as tooltip.
        let setup = grantRow("Finish setup", input.sudoers, .finishSetup)
        let notifications = grantRow(
            input.notifications.grade == .broken ? "Notifications off" : "Notifications",
            input.notifications, .notifications)
        rows += [setup, notifications, .separator(hidden: setup.hidden && notifications.hidden)]

        rows.append(
            .item(
                header(st.claims, suspended: suspended, now: now),
                tooltip: st.claims.isEmpty
                    ? nil : st.claims.map { Words.describe($0, now: now) }.joined(separator: "\n")))
        // The roster: one line per OWNER, who wants the Mac awake and until when.
        // Each row's submenu holds the granular controls: lid verbs per owner (the
        // ask groups per owner), ending per claim (a single stuck session dies alone).
        for s in Words.summarize(st.claims, now: now) {
            let group = st.claims.filter { $0.owner == s.owner }
            rows.append(
                .item("   " + s.label, tooltip: s.detail, submenu: ownerControls(group, now: now)))
        }
        if st.power.hasBattery {
            rows.append(
                .item(
                    "Battery \(st.power.percent)%\(st.power.onAC ? " (AC)" : "")"
                        + (st.floor > 0 ? " · floor \(st.floor)%" : "")))
        }
        if st.thermalCritical {
            rows.append(.item("Critical heat · lid refused until it cools"))
        }
        rows.append(.separator())

        // The ask leads the verbs: a named claim wants lid-closed survival, the glyph
        // says "?", answering is one click. One ask per OWNER, the roster's grammar:
        // six sessions of one program are one question, answered together.
        let asks = st.claims.filter { $0.wantsLid && !$0.lidGranted }
        if !suspended, !asks.isEmpty {
            var owners: [String] = []
            for c in asks where !owners.contains(c.owner) { owners.append(c.owner) }
            for owner in owners {
                let group = asks.filter { $0.owner == owner }
                let ids = group.map(\.id)
                let allWhilePid = group.allSatisfy {
                    if case .whilePid = $0.term { return true } else { return false }
                }
                rows.append(
                    .item(
                        "\(owner) asks: survive lid close"
                            + (group.count > 1 ? " (\(group.count))" : ""),
                        tooltip: group.map { Words.describe($0, now: now) }.joined(
                            separator: "\n")))
                rows.append(
                    .item(
                        allWhilePid
                            ? (group.count > 1 ? "Allow while they run" : "Allow while it runs")
                            : "Allow", .allowLid(ids)))
                rows.append(.item("Ignore", .denyLid(ids)))
            }
            rows.append(.separator())
        }

        // The toggle gesture lands on exactly one item, and that item wears the
        // chord: "Resume" while suspended, "End your session" while you hold a
        // claim, else the duration it would start. "Let it sleep" and "End all
        // claims" are the machine-level verbs, explicit and unbadged.
        let yourClaims = st.claims.filter { $0.owner == Claim.humanOwner }
        if suspended {
            rows.append(
                .item(
                    "Resume" + (st.claims.isEmpty ? "" : " (\(st.claims.count) waiting)"), .resume,
                    toggle: true))
            rows.append(.separator())
        } else if !st.claims.isEmpty {
            if !yourClaims.isEmpty {
                rows.append(
                    .item(
                        "End your session", .endYours, toggle: true,
                        tooltip: "Ends only your claim (lid disarms); named claims keep working"))
            }
            rows.append(
                .item(
                    "Let it sleep", .suspend,
                    tooltip: "Sleep normally now; every claim is kept and comes back on Resume"))
            if st.claims.count > yourClaims.count {
                rows.append(.item(st.claims.count > 1 ? "End all claims" : "End session", .endAll))
            }
            rows.append(.separator())
        }

        // The checkmark is STATE: your running claim's duration, nothing else. A
        // checkmark on a mere default reads as a claim that isn't there.
        let yours = yourDurationMinutes(st.claims)
        for (title, minutes) in durations {
            rows.append(
                .item(
                    title, .engage(minutes: minutes), checked: yours == minutes,
                    toggle: yourClaims.isEmpty && !suspended && input.lastMinutes == minutes))
        }
        rows.append(.separator())

        rows.append(.item("Keep display on", .toggleDisplay, checked: st.keepDisplay))
        rows.append(
            .item(
                "Battery floor",
                submenu: floors.map {
                    .item($0 == 0 ? "Off" : "\($0)%", .floor($0), checked: st.floor == $0)
                }))
        rows.append(.separator())
        rows.append(.item("Quit awake", .quit))
        return rows
    }

    private static func grantRow(_ title: String, _ standing: Standing, _ action: MenuAction)
        -> MenuRow
    {
        .item(
            "\(title) · \(standing.actionTitle)", action, hidden: !standing.grade.needsUser,
            tooltip: standing.note)
    }

    /// "End" ends the CLAIM, never the watched process: the title and tooltip say
    /// so, or the row reads as a kill switch.
    private static func ownerControls(_ group: [Claim], now: Date) -> [MenuRow] {
        var sub: [MenuRow] = []
        let asking = group.filter { $0.wantsLid && !$0.lidGranted }
        let granted = group.filter { $0.wantsLid && $0.lidGranted }
        if !asking.isEmpty {
            sub.append(.item("Allow lid-closed survival", .allowLid(asking.map(\.id))))
            sub.append(.item("Dismiss ask", .denyLid(asking.map(\.id))))
        }
        if !granted.isEmpty {
            sub.append(.item("Revoke lid grant", .denyLid(granted.map(\.id))))
        }
        if !sub.isEmpty { sub.append(.separator()) }
        let claimTip =
            "Ends only the keep-awake claim; the process keeps running and the Mac may idle-sleep under it"
        if group.count > 1 {
            sub.append(
                .item(
                    "End all claims (\(group.count))", .endClaims(group.map(\.id)),
                    tooltip: claimTip))
            for c in group {
                let how: String =
                    switch c.term {
                    case .whilePid(let pid, _): "pid \(pid)"
                    case .until(let d): "\(Words.interval(d.timeIntervalSince(now))) left"
                    case .indefinite: "indefinite"
                    }
                sub.append(.item("End claim · \(how)", .endClaims([c.id]), tooltip: claimTip))
            }
        } else if let c = group.first {
            sub.append(.item("End claim", .endClaims([c.id]), tooltip: claimTip))
        }
        return sub
    }

    /// The duration of YOUR active claim, bucketed in minutes (0 = indefinite), nil
    /// when you hold none.
    private static func yourDurationMinutes(_ claims: [Claim]) -> Int? {
        guard let c = claims.first(where: { $0.owner == Claim.humanOwner }) else { return nil }
        switch c.term {
        case .indefinite: return 0
        case .until(let d): return Int((d.timeIntervalSince(c.startedAt) / 60).rounded())
        case .whilePid: return nil
        }
    }
}

/// The menu bar glyph: ONE symbol, four states, two axes.
///   cup ink = is anything holding the Mac awake (outline = no, filled = yes)
///   steam   = the LID axis and nothing else. None: closing the lid sleeps it. A
///             "?": a named claim asks for lid-closed survival. Burning: lid armed,
///             don't bag it.
/// Suspended reads as off: the glyph is EFFECT, the tooltip carries the intent.
public enum Glyph: String, CaseIterable, Sendable {
    case off, on, ask, lid

    public init(claimsEmpty: Bool, suspended: Bool, lidArmed: Bool, askPending: Bool) {
        self =
            claimsEmpty || suspended ? .off : lidArmed ? .lid : askPending ? .ask : .on
    }

    public static func tooltip(_ claims: [Claim], suspended: Bool, now: Date) -> String {
        let roster = claims.map { Words.describe($0, now: now) }.joined(separator: "\n")
        if suspended {
            return "awake: suspended by you, Mac sleeps normally"
                + (claims.isEmpty
                    ? ""
                    : "\nwaiting: " + roster.replacingOccurrences(of: "\n", with: "\nwaiting: "))
        }
        return claims.isEmpty ? "awake: off, Mac sleeps normally" : "awake: " + roster
    }
}
