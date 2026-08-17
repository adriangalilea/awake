import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Why claims ended without being asked to. One reason per end event; the daemon
/// composes the human message from (reason, ended claims, remaining claims).
public enum EndReason: Sendable {
    case requested            // CLI/menu said stop
    case expired              // timed claim ran out
    case pidExited(Int32)     // -w target is gone
    case batteryFloor(Int)    // percent at trip time; always wins, ends everything
    case lowPowerMode         // ends unforced claims only
    case externalOff          // someone flipped the flag off under us; they win
    case shutdown             // daemon quitting

    /// Safety-net ends fire behind a closed lid where the screen informs nobody;
    /// these also go through the out-of-band notify hook.
    public var outOfBand: Bool {
        switch self {
        case .batteryFloor, .lowPowerMode: return true
        default: return false
        }
    }
}

public enum EngageError: Error, Equatable, Sendable {
    case grantMissing
    case belowFloor(percent: Int, floor: Int)
    case lidFailed(String)

    public var message: String {
        switch self {
        case .grantMissing:
            return "The sudoers grant is missing. Run: awake grant"
        case .belowFloor(let percent, let floor):
            return "Battery \(percent)% is at or below your \(floor)% floor. Not arming."
        case .lidFailed(let err):
            return "pmset failed: \(err)"
        }
    }
}

/// Wire-visible state: intent + effect + environment, in one honest struct.
public struct Status: Codable, Equatable, Sendable {
    public var claims: [Claim]
    public var sleepDisabled: Bool
    public var power: PowerSnapshot
    public var floor: Int
    /// Empty when no out-of-band hook is configured.
    public var notifyCommand: String
    /// The standing "keep the display on" preference for menu/hotkey engagements.
    /// Distinct from a claim merely holding `.display`.
    public var keepDisplay: Bool
    /// The human's "let it sleep" switch (right-click, hotkey, `awake suspend`):
    /// every claim is kept but inert until resumed. nil = not suspended.
    public var suspendedSince: Date?
}

/// THE state machine. Intent lives here (and mirrored to disk) as a SET of claims;
/// effect lives in the kernel as the union of their modes. Every path that touches
/// pmset or assertions goes through `apply` — the single choke point — so intent and
/// effect can never drift silently. Sleep restores when the LAST claim ends, which is
/// what makes "Sleep restored" a true sentence every time it is said.
@MainActor
public final class StateMachine {
    public private(set) var claims: [Claim] = []
    /// The human's override. While set, intent is KEPT (claims live, arrive, expire
    /// as usual) but the effect is nothing: the Mac sleeps normally. This is what
    /// the toggle gesture means: "let it sleep", not "forget what everyone wanted".
    /// Ending claims is a separate, explicit act (`asleep`, "End all claims").
    public private(set) var suspendedSince: Date?
    public var suspended: Bool { suspendedSince != nil }
    public private(set) var config: Config
    private var held: [Mode: IOPMAssertionID] = [:]

    /// UI refresh hook (menu bar glyph). Fired after every transition.
    public var onChange: (() -> Void)?
    /// Autonomous-transition hook: (reason, ended, remaining). The daemon composes
    /// the message and routes it (screen, and phone for out-of-band reasons).
    public var notify: ((EndReason, [Claim], [Claim]) -> Void)?
    /// The floor's second net fired: below the floor, no claim of ours, display
    /// dark, and the Mac still awake (another process holds an idle assertion:
    /// audio, a download). Argument: battery percent. Routed out of band too.
    public var onForcedSleep: ((Int) -> Void)?

    public init() {
        config = Config.load()
        suspendedSince = SuspendStore.load()
        reconcileStartup()
    }

    // MARK: - Startup reconciliation (the crash story)

    /// launchd KeepAlive restarts a crashed daemon; this makes the restart honest.
    /// Valid persisted claims: re-arm them. Stale ones: drop. No claims but the
    /// kernel flag is on: an external writer (or unclean death) set it — ADOPT it as
    /// an indefinite unforced claim instead of silently undoing someone's decision.
    private func reconcileStartup() {
        let persisted = ClaimStore.load()
        claims = persisted.filter { $0.isValid() }
        for dropped in persisted where !claims.contains(dropped) {
            log("startup: dropping stale claim \(dropped)")
        }
        if !claims.isEmpty {
            log("startup: re-arming \(claims.count) persisted claim(s)")
            let result = apply()
            if result != .ok {
                log("startup: re-arm lid flip failed (\(result)), dropping lid mode")
                for i in claims.indices { claims[i].modes.remove(.lid) }
                _ = apply()
            }
            persist()
        } else if Kernel.sleepDisabled() {
            log("startup: kernel flag on with no claims, adopting as indefinite")
            claims = [Claim(owner: "external", forced: false, modes: [.lid], term: .indefinite)]
            persist()
        } else {
            persist() // clears a file that held only stale claims
        }
        onChange?()
    }

    // MARK: - Public transitions

    /// What an engage did, for the caller's breadcrumb: the same-key claim it
    /// replaced, and the claim that already made it redundant (added anyway — a
    /// covered claim costs nothing now and carries the owner's want if the covering
    /// claim ends first; silently dropping it is how a machine sleeps under a
    /// running job).
    public struct Engaged: Sendable {
        public let replaced: Claim?
        public let coveredBy: Claim?
        /// The claim landed inert: the human's suspend switch is on.
        public let suspended: Bool
    }

    public func engage(_ claim: Claim) -> Result<Engaged, EngageError> {
        let power = Battery.snapshot()
        if power.discharging, config.batteryFloorPercent > 0,
           power.percent <= config.batteryFloorPercent {
            // Don't arm what the floor immediately tears down.
            return .failure(.belowFloor(percent: power.percent, floor: config.batteryFloorPercent))
        }
        let before = claims
        let replaced = claims.first { $0.key == claim.key }
        let coveredBy = claims.first { $0.key != claim.key && $0.covers(claim) }
        claims.removeAll { $0.key == claim.key }
        claims.append(claim)
        switch apply() {
        case .ok:
            persist()
            log("engaged \(claim)"
                + (replaced.map { " replacing \($0)" } ?? "")
                + (coveredBy.map { " (covered by \($0))" } ?? ""))
            onChange?()
            return .success(Engaged(replaced: replaced, coveredBy: coveredBy, suspended: suspended))
        case .grantMissing:
            claims = before
            _ = apply()
            return .failure(.grantMissing)
        case .failed(let err):
            claims = before
            _ = apply()
            return .failure(.lidFailed(err))
        }
    }

    /// End specific claims. The single exit path: computes ended/remaining, notifies
    /// BEFORE dropping the flag — a battery-floor/LPM end with the lid closed starts
    /// clamshell sleep seconds after the flag drops, and the phone push must leave on
    /// a network stack that is still awake.
    public func end(_ ids: Set<UUID>, _ reason: EndReason) {
        let ended = claims.filter { ids.contains($0.id) }
        guard !ended.isEmpty else { return }
        let remaining = claims.filter { !ids.contains($0.id) }
        notify?(reason, ended, remaining)
        claims = remaining
        _ = apply() // teardown can't fail meaningfully; flag-off errors are logged in apply
        persist()
        log("ended (\(reason)) \(ended) (remaining \(remaining.count))")
        onChange?()
    }

    public func endAll(_ reason: EndReason) {
        end(Set(claims.map(\.id)), reason)
    }

    /// The human's "let it sleep": effect off, intent kept. Idempotent.
    public func suspend() {
        guard !suspended else { return }
        suspendedSince = Date()
        SuspendStore.save(suspendedSince)
        _ = apply()
        log("suspended by the human (\(claims.count) claim(s) kept inert)")
        onChange?()
    }

    /// Lift the switch: every still-valid claim takes effect again.
    public func resume() {
        guard suspended else { return }
        // Sweep first, WHILE still suspended: claims that died meanwhile must not
        // come back, and the tick's external-writer check must still know the flag
        // is off because we hold it off (lifting first turned that check into a
        // false externalOff that ended every claim, 2026-08-17).
        tick()
        suspendedSince = nil
        SuspendStore.save(nil)
        let result = apply()
        if result != .ok { log("resume: lid flip failed (\(result))") }
        log("resumed by the human (\(claims.count) claim(s) back in effect)")
        onChange?()
    }

    /// SIGTERM path: restore effect, KEEP intent on disk. launchd bounces the daemon
    /// on every `make install` and on crashes; parking lets startup reconciliation
    /// re-arm the claims so an upgrade never silently eats them. Explicit quit and
    /// user-facing ends go through `end`, which clears. Reboots are guarded by
    /// `Claim.isValid`'s boot-time check, not by clearing here.
    public func park() {
        guard !claims.isEmpty else { return }
        let kept = claims
        claims = []
        _ = apply()
        claims = kept // disk still holds them; only the effect was released
        log("parked \(kept)")
    }

    /// UI-preference setters: persisted so right-click/hotkey muscle memory survives
    /// daemon restarts. Called ONLY from the menu/hotkey path — a wire client's timed
    /// claim teaching the human's toggle is how "right-click = 5 minutes" happened.
    public func rememberDuration(_ minutes: Int) {
        guard minutes != config.lastMinutes else { return }
        config.lastMinutes = minutes
        config.save()
    }

    public func setMenuDisplay(_ on: Bool) {
        guard on != config.menuDisplay else { return }
        config.menuDisplay = on
        config.save()
    }

    /// The out-of-band hook. Set through here, never by editing config.json by hand:
    /// the daemon holds config in memory and the next save would clobber the edit.
    public func setNotifyCommand(_ command: String) {
        config.notifyCommand = command.trimmingCharacters(in: .whitespaces)
        config.save()
        log(config.notifyCommand.isEmpty ? "notify hook cleared"
                                         : "notify hook set to \(config.notifyCommand)")
    }

    public func setFloor(_ percent: Int) {
        let clamped = max(Config.floorRange.lowerBound, min(Config.floorRange.upperBound, percent))
        config.batteryFloorPercent = clamped
        config.save()
        log("floor set to \(clamped)%")
        tick() // a raised floor may immediately end the running claims
        onChange?()
    }

    /// The heartbeat: expiry, pid liveness, battery floor, LPM, external writers.
    /// Runs every poll tick, on power-source change, and before every status render.
    public func tick() {
        let flagOn = Kernel.sleepDisabled()
        // A human at the terminal setting the flag by hand is the one voice that
        // outranks the suspend switch: adopt the flag AND lift the switch.
        if flagOn, suspended {
            log("tick: external writer turned the flag on while suspended, resuming")
            suspendedSince = nil
            SuspendStore.save(nil)
        }
        guard !claims.isEmpty else {
            if flagOn {
                log("tick: external writer turned the flag on, adopting")
                claims = [Claim(owner: "external", forced: false, modes: [.lid], term: .indefinite)]
                persist()
                onChange?()
                return
            }
            sweepBelowFloor()
            return
        }

        // An external writer flipping the flag OFF wins over every claim that wanted
        // it: silently re-flipping it would fight a human at the terminal. Under
        // the suspend switch the flag is off because WE keep it off; nothing to read.
        if !flagOn, !suspended, claims.contains(where: { $0.modes.contains(.lid) }) {
            endAll(.externalOff)
            return
        }

        let expired = claims.filter {
            if case .until(let d) = $0.term { return d <= Date() }
            return false
        }
        if !expired.isEmpty { end(Set(expired.map(\.id)), .expired) }

        for claim in claims {
            if case .whilePid(let pid, let started) = claim.term,
               procStartTime(pid) != started {
                end([claim.id], .pidExited(pid))
            }
        }

        let power = Battery.snapshot()
        if power.discharging, !claims.isEmpty {
            if config.batteryFloorPercent > 0, power.percent <= config.batteryFloorPercent {
                endAll(.batteryFloor(power.percent))
                return
            }
            if power.lowPowerMode {
                let yielding = claims.filter { !$0.forced }
                if !yielding.isEmpty { end(Set(yielding.map(\.id)), .lowPowerMode) }
            }
        }
    }

    /// The floor's second net. Ending our claims at the floor only LETS the Mac
    /// sleep; with the lid open, any other idle assertion (audio on the speakers,
    /// a download) keeps it awake and it drains from the floor to hibernation at
    /// 1% (2026-08-15, coreaudiod, 05:06 to 08:45). So: below the floor, on
    /// battery, no claim of ours, display already dark (nobody is watching), Mac
    /// still awake: sleep it. Runs on every tick until AC or sleep, so a wake back
    /// onto battery below the floor sleeps again within a minute. That IS the floor.
    private func sweepBelowFloor() {
        guard config.batteryFloorPercent > 0 else { return }
        let power = Battery.snapshot()
        guard power.hasBattery, power.discharging,
              power.percent <= config.batteryFloorPercent else { return }
        guard CGDisplayIsAsleep(CGMainDisplayID()) != 0 else { return }
        log("below floor (\(power.percent)% <= \(config.batteryFloorPercent)%), no claims, display dark, still awake: forcing sleep")
        onForcedSleep?(power.percent)
        let r = run("/usr/bin/pmset", ["sleepnow"])
        if r.status != 0 { log("pmset sleepnow failed (\(r.status)): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func status() -> Status {
        tick()
        return Status(claims: claims.sorted { $0.startedAt < $1.startedAt },
                      sleepDisabled: Kernel.sleepDisabled(),
                      power: Battery.snapshot(),
                      floor: config.batteryFloorPercent,
                      notifyCommand: config.notifyCommand,
                      keepDisplay: config.menuDisplay,
                      suspendedSince: suspendedSince)
    }

    // MARK: - The choke point

    /// Converge effect to intent. The wanted set is the UNION over all claims —
    /// every party's wish held simultaneously, exactly like kernel assertions.
    /// Computes the delta against what the kernel/process currently does and
    /// executes exactly that delta.
    private func apply() -> LidResult {
        // Suspended: intent stands, effect is nothing. Same choke point, so the
        // delta logic below releases exactly what is held, and nothing else changes.
        let wanted = suspended ? Set<Mode>()
            : claims.reduce(into: Set<Mode>()) { $0.formUnion($1.modes) }

        // Assertions: held by this process, delta is trivial.
        for mode in [Mode.idle, .display] {
            let want = wanted.contains(mode)
            let have = held[mode] != nil
            if want, !have { held[mode] = Kernel.createAssertion(mode) }
            if !want, have {
                Kernel.releaseAssertion(held[mode]!)
                held[mode] = nil
            }
        }

        // The lid flag: kernel-owned, root-gated.
        let wantLid = wanted.contains(.lid)
        let haveLid = Kernel.sleepDisabled()
        if wantLid != haveLid {
            let result = Kernel.setSleepDisabled(wantLid)
            if result != .ok {
                log("lid flip to \(wantLid) failed: \(result)")
            }
            return result
        }
        return .ok
    }

    private func persist() {
        ClaimStore.save(claims)
    }
}
