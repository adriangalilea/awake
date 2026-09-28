import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Why claims ended without being asked to. One reason per end event; the daemon
/// composes the human message from (reason, ended claims, remaining claims).
public enum EndReason: Sendable {
    case requested  // CLI/menu said stop
    case expired  // timed claim ran out
    case pidExited(Int32)  // -w target is gone
    case batteryFloor(Int)  // percent at trip time; always wins, ends everything
    case lowPowerMode  // ends unforced claims only
    case thermal  // critical thermal pressure; ends every claim holding the lid
    case externalOff  // someone flipped the flag off under us; they win
    case shutdown  // daemon quitting

    /// The word a per-claim on-end hook receives as its argument.
    public var label: String {
        switch self {
        case .requested: return "requested"
        case .expired: return "expired"
        case .pidExited(let pid): return "pid-exited:\(pid)"
        case .batteryFloor(let p): return "battery-floor:\(p)"
        case .lowPowerMode: return "low-power-mode"
        case .thermal: return "thermal"
        case .externalOff: return "external-off"
        case .shutdown: return "shutdown"
        }
    }

    /// Safety-net ends fire behind a closed lid where the screen informs nobody;
    /// these also go through the out-of-band notify hook.
    public var outOfBand: Bool {
        switch self {
        case .batteryFloor, .lowPowerMode, .thermal: return true
        default: return false
        }
    }
}

public enum EngageError: Error, Equatable, Sendable {
    case grantMissing
    case belowFloor(percent: Int, floor: Int)
    case thermalCritical
    case lidFailed(String)

    public var message: String {
        switch self {
        case .grantMissing:
            return "The sudoers grant is missing. Run: awake grant"
        case .belowFloor(let percent, let floor):
            return "Battery \(percent)% is at or below your \(floor)% floor. Not arming."
        case .thermalCritical:
            return "The Mac is at critical heat. Not arming lid-closed survival until it cools."
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
    /// The standing "keep the display on" preference: while ANY claim holds the
    /// machine awake, the display is held too. Distinct from a claim carrying
    /// `.display` itself (the CLI's one-shot `--display`).
    public var keepDisplay: Bool
    /// Mirrors of the machine's computed truths, so every client renders from the
    /// same arithmetic instead of re-deriving it.
    public var lidArmed: Bool
    public var askPending: Bool
    /// `ProcessInfo.thermalState == .critical`: lid claims are ended and refused.
    public var thermalCritical: Bool
    /// The human's "let it sleep" switch (right-click, hotkey, `awake suspend`):
    /// every claim is kept but inert until resumed. nil = not suspended.
    public var suspendedSince: Date?
    /// The daily version check (awake.untitled.garden/appcast.xml) and the
    /// newest version it has reported, nil until the first successful check.
    public var updateCheck: Bool
    public var latestVersion: String?
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
        let valid = persisted.filter { $0.isValid() }
        for dropped in persisted where !valid.contains(dropped) {
            log("startup: dropping stale claim \(dropped)")
        }
        claims = valid.map { normalized($0) }
        if !claims.isEmpty {
            log("startup: re-arming \(claims.count) persisted claim(s)")
            let result = apply()
            if result != .ok {
                log("startup: re-arm lid flip failed (\(result)), dropping lid mode")
                for i in claims.indices {
                    claims[i].modes.remove(.lid)
                    claims[i].lidGranted = false
                }
                _ = apply()
            }
            persist()
        } else if Kernel.sleepDisabled() {
            log("startup: kernel flag on with no claims, adopting as indefinite")
            claims = [
                Claim(owner: Claim.adoptedOwner, forced: false, modes: [.lid], term: .indefinite)
            ]
            persist()
        } else {
            persist()  // clears a file that held only stale claims
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

    /// ENFORCED IN THE MACHINE, not in callers: lid-closed survival is the
    /// human's to grant. A named claim (any programmatic caller: a cron job,
    /// build, script, coding agent) carrying `.lid` gets it demoted to a recorded
    /// ask — whatever client sent it, and whatever binary persisted it before
    /// this rule existed. The machine's own "external" adoption is exempt.
    /// Idempotent by construction.
    private func normalized(_ claim: Claim) -> Claim {
        guard claim.owner != Claim.humanOwner, claim.owner != Claim.adoptedOwner,
            claim.modes.contains(.lid)
        else { return claim }
        var c = claim
        c.modes.remove(.lid)
        c.wantsLid = true
        return c
    }

    public func engage(_ claim: Claim) -> Result<Engaged, EngageError> {
        var claim = normalized(claim)
        // A same-key refresh (a hook re-arming its process watch) keeps the
        // human's grant: the answer was given to the WORK, not to one engage call.
        if let prior = claims.first(where: { $0.key == claim.key }),
            prior.lidGranted, claim.wantsLid
        {
            claim.lidGranted = true
        }
        // Don't arm what the thermal guard tears down on the next tick.
        if claim.effectiveModes.contains(.lid), Self.thermalCritical {
            return .failure(.thermalCritical)
        }
        let power = Battery.snapshot()
        if power.discharging, config.batteryFloorPercent > 0,
            power.percent <= config.batteryFloorPercent
        {
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
            log(
                "engaged \(claim)"
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
        _ = apply()  // teardown can't fail meaningfully; flag-off errors are logged in apply
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
        // The tick above skipped the guard (nothing held the lid); lifting must not
        // arm the lid for a poll interval at critical heat.
        thermalGuard()
        let result = apply()
        if result != .ok { log("resume: lid flip failed (\(result))") }
        log("resumed by the human (\(claims.count) claim(s) back in effect)")
        onChange?()
    }

    /// SIGTERM path: restore effect, KEEP intent on disk. launchd bounces the daemon
    /// on every `mise run install` and on crashes; parking lets startup reconciliation
    /// re-arm the claims so an upgrade never silently eats them. Explicit quit and
    /// user-facing ends go through `end`, which clears. Reboots are guarded by
    /// `Claim.isValid`'s boot-time check, not by clearing here.
    public func park() {
        guard !claims.isEmpty else { return }
        let kept = claims
        claims = []
        _ = apply()
        claims = kept  // disk still holds them; only the effect was released
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
        _ = apply()
    }

    /// Lid is ARMED when some claim's effective modes include it and the human's
    /// suspend switch is up. The burning glyph, and the state that must be visible
    /// before a lid ever closes.
    public var lidArmed: Bool {
        !suspended && claims.contains { $0.effectiveModes.contains(.lid) }
    }

    /// An unanswered ask with no lid in effect — the "?" glyph and the menu's lead
    /// item. Computed, never stored: when a covering grant or your own session
    /// ends, a standing want resurfaces here by itself.
    public var askPending: Bool {
        !lidArmed && claims.contains { $0.wantsLid && !$0.lidGranted }
    }

    /// The human's answer to a lid ask. Grant flips `lidGranted` on the wanting
    /// claims; deny clears the want (and any grant — deny after grant is revoke).
    /// Idempotent; the grant dies with the claim.
    @discardableResult
    public func resolveLidWant(_ ids: Set<UUID>, granted: Bool) -> Result<[Claim], EngageError> {
        if granted, Self.thermalCritical { return .failure(.thermalCritical) }
        let before = claims
        var touched: [Claim] = []
        for i in claims.indices where ids.contains(claims[i].id) && claims[i].wantsLid {
            if granted {
                if claims[i].lidGranted { continue }
                claims[i].lidGranted = true
            } else {
                claims[i].wantsLid = false
                claims[i].lidGranted = false
            }
            touched.append(claims[i])
        }
        guard !touched.isEmpty else { return .success([]) }
        switch apply() {
        case .ok:
            persist()
            log("\(granted ? "granted lid to" : "denied lid for") \(touched)")
            onChange?()
            return .success(touched)
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

    /// The out-of-band hook. Set through here, never by editing config.json by hand:
    /// the daemon holds config in memory and the next save would clobber the edit.
    public func setNotifyCommand(_ command: String) {
        config.notifyCommand = command.trimmingCharacters(in: .whitespaces)
        config.save()
        log(
            config.notifyCommand.isEmpty
                ? "notify hook cleared"
                : "notify hook set to \(config.notifyCommand)")
    }

    public func setFloor(_ percent: Int) {
        let clamped = max(Config.floorRange.lowerBound, min(Config.floorRange.upperBound, percent))
        config.batteryFloorPercent = clamped
        config.save()
        log("floor set to \(clamped)%")
        tick()  // a raised floor may immediately end the running claims
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
                claims = [
                    Claim(
                        owner: Claim.adoptedOwner, forced: false, modes: [.lid], term: .indefinite)
                ]
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
        if !flagOn, !suspended, claims.contains(where: { $0.effectiveModes.contains(.lid) }) {
            endAll(.externalOff)
            return
        }

        thermalGuard()

        let expired = claims.filter {
            if case .until(let d) = $0.term { return d <= Date() }
            return false
        }
        if !expired.isEmpty { end(Set(expired.map(\.id)), .expired) }

        for claim in claims {
            if case .whilePid(let pid, let started) = claim.term,
                procStartTime(pid) != started
            {
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

    public static var thermalCritical: Bool {
        ProcessInfo.processInfo.thermalState == .critical
    }

    /// The heat net. The lid flag is the one thing that keeps a closed Mac awake in
    /// a bag, and macOS only steps in at Thermal Emergency Sleep: 2026-09-25 sat at
    /// `.critical` from 20:12 to 23:05, die at 95 °C, battery at 37 %. At `.critical`
    /// every claim holding the lid ends, whatever its owner or `forced`; claims
    /// without the lid keep running (lid open, macOS throttles). `.serious` is
    /// ordinary sustained load and would end legitimate lid-closed work on a desk.
    /// Nothing re-arms on cooling: engage and grant refuse while critical, and
    /// after that re-arming is a human or caller act.
    private func thermalGuard() {
        guard !suspended, Self.thermalCritical else { return }
        let holding = claims.filter { $0.effectiveModes.contains(.lid) }
        guard !holding.isEmpty else { return }
        end(Set(holding.map(\.id)), .thermal)
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
            power.percent <= config.batteryFloorPercent
        else { return }
        guard CGDisplayIsAsleep(CGMainDisplayID()) != 0 else { return }
        log(
            "below floor (\(power.percent)% <= \(config.batteryFloorPercent)%), no claims, display dark, still awake: forcing sleep"
        )
        onForcedSleep?(power.percent)
        let r = run("/usr/bin/pmset", ["sleepnow"])
        if r.status != 0 {
            log(
                "pmset sleepnow failed (\(r.status)): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    public func status() -> Status {
        tick()
        return Status(
            claims: claims.sorted { $0.startedAt < $1.startedAt },
            sleepDisabled: Kernel.sleepDisabled(),
            power: Battery.snapshot(),
            floor: config.batteryFloorPercent,
            notifyCommand: config.notifyCommand,
            keepDisplay: config.menuDisplay,
            lidArmed: lidArmed,
            askPending: askPending,
            thermalCritical: Self.thermalCritical,
            suspendedSince: suspendedSince,
            updateCheck: config.updateCheck,
            latestVersion: config.latestVersion)
    }

    // MARK: - Update check (the active-install ping, and the human's upgrade nudge)

    public func setUpdateCheck(_ on: Bool) {
        config.updateCheck = on
        config.save()
        log("update check \(on ? "on (daily)" : "off")")
    }

    public var updateCheckDue: Bool {
        config.updateCheck && (config.nextUpdateCheck.map { $0 <= Date() } ?? true)
    }

    /// Record a feed read. Returns the version to announce, if this one is
    /// newer than `running` and has not been announced before.
    public func recordUpdateCheck(latest: String?, running: String) -> String? {
        if let latest {
            config.nextUpdateCheck = Date().addingTimeInterval(24 * 3600)
            config.latestVersion = latest
            var announce: String? = nil
            if versionIsNewer(latest, than: running), config.updateAnnounced != latest {
                config.updateAnnounced = latest
                announce = latest
            }
            config.save()
            log(
                "update check: latest \(latest), running \(running)\(announce != nil ? ", announcing" : "")"
            )
            return announce
        }
        config.nextUpdateCheck = Date().addingTimeInterval(3600)
        config.save()
        return nil
    }

    // MARK: - The choke point

    /// Converge effect to intent. The wanted set is the UNION over all claims —
    /// every party's wish held simultaneously, exactly like kernel assertions.
    /// Computes the delta against what the kernel/process currently does and
    /// executes exactly that delta.
    private func apply() -> LidResult {
        // Suspended: intent stands, effect is nothing. Same choke point, so the
        // delta logic below releases exactly what is held, and nothing else changes.
        var wanted =
            suspended
            ? Set<Mode>()
            : claims.reduce(into: Set<Mode>()) { $0.formUnion($1.effectiveModes) }
        // The standing "keep display on" preference rides ANY effect, whoever owns
        // the claims — a checked box while the screen sleeps is a lie. Battery burn
        // is the floor's job, not this toggle's.
        if config.menuDisplay, !wanted.isEmpty { wanted.insert(.display) }

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
