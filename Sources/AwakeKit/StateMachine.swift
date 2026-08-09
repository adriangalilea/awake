import Foundation
import IOKit.pwr_mgt

/// Why a session ended without being asked to.
public enum EndReason: Sendable {
    case requested            // CLI/menu said stop
    case expired              // timed session ran out
    case pidExited(Int32)     // -w target is gone
    case batteryFloor(Int)    // percent at trip time; always wins, even over forced
    case lowPowerMode         // yields unless forced
    case externalOff          // someone flipped the flag off under us; they win
    case shutdown             // daemon quitting

    public var message: String? {
        switch self {
        case .requested, .shutdown: return nil
        case .expired: return "Session ended. Sleep restored."
        case .pidExited(let pid): return "Process \(pid) exited. Sleep restored."
        case .batteryFloor(let p): return "Battery at \(p)%. Sleep restored."
        case .lowPowerMode: return "Low Power Mode is on. Sleep restored."
        case .externalOff: return "Sleep was re-enabled outside awake. Session ended."
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
    public var session: Session?
    public var sleepDisabled: Bool
    public var power: PowerSnapshot
    public var floor: Int
}

/// THE state machine. Intent lives here (and mirrored to disk); effect lives in the
/// kernel. Every path that touches pmset or assertions goes through `apply` — the
/// single choke point — so intent and effect can never drift silently.
@MainActor
public final class StateMachine {
    public private(set) var session: Session?
    public private(set) var config: Config
    private var held: [Mode: IOPMAssertionID] = [:]

    /// UI refresh hook (menu bar glyph). Fired after every transition.
    public var onChange: (() -> Void)?
    /// Autonomous-transition hook: the daemon routes by reason (screen always, phone
    /// for the ends that fire while the lid is closed and the screen is invisible).
    public var notify: ((EndReason) -> Void)?

    public init() {
        config = Config.load()
        reconcileStartup()
    }

    // MARK: - Startup reconciliation (the crash story)

    /// launchd KeepAlive restarts a crashed daemon; this makes the restart honest.
    /// Valid persisted session: re-arm it. Stale one: tear down. No session but the
    /// kernel flag is on: an external writer (or unclean death) set it — ADOPT it as
    /// an indefinite unforced session instead of silently undoing someone's decision.
    private func reconcileStartup() {
        if let persisted = SessionStore.load() {
            if persisted.isValid() {
                log("startup: re-arming persisted session \(persisted)")
                session = persisted
                let result = apply()
                if result != .ok {
                    log("startup: re-arm lid flip failed (\(result)), dropping lid mode")
                    session?.modes.remove(.lid)
                    _ = apply()
                    persist()
                }
            } else {
                log("startup: persisted session is stale, restoring sleep")
                session = nil
                _ = apply()
                SessionStore.clear()
            }
        } else if Kernel.sleepDisabled() {
            log("startup: kernel flag on with no session, adopting as indefinite")
            session = Session(modes: [.lid], term: .indefinite, forced: false)
            persist()
        }
        onChange?()
    }

    // MARK: - Public transitions

    public func engage(_ s: Session) -> EngageError? {
        let power = Battery.snapshot()
        if power.discharging, config.batteryFloorPercent > 0,
           power.percent <= config.batteryFloorPercent {
            // Don't arm what the floor immediately tears down.
            return .belowFloor(percent: power.percent, floor: config.batteryFloorPercent)
        }
        let previous = session
        session = s
        switch apply() {
        case .ok:
            persist()
            log("engaged \(s) (was \(String(describing: previous)))")
            onChange?()
            return nil
        case .grantMissing:
            session = previous
            _ = apply()
            return .grantMissing
        case .failed(let err):
            session = previous
            _ = apply()
            return .lidFailed(err)
        }
    }

    public func end(_ reason: EndReason) {
        guard session != nil else { return }
        let previous = session
        // Notify BEFORE dropping the flag: a battery-floor/LPM end with the lid
        // closed starts clamshell sleep seconds after the flag drops, and the phone
        // push must leave on a network stack that is still awake — the lid-closed
        // case is the only reason that push exists.
        if reason.message != nil { notify?(reason) }
        session = nil
        _ = apply() // teardown can't fail meaningfully; flag-off errors are logged in apply
        SessionStore.clear()
        log("ended (\(reason)) (was \(String(describing: previous)))")
        onChange?()
    }

    /// SIGTERM path: restore effect, KEEP intent on disk. launchd bounces the daemon
    /// on every `make install` and on crashes; parking lets startup reconciliation
    /// re-arm the session so an upgrade never silently eats it. Explicit quit and
    /// user-facing ends go through `end`, which clears. Reboots are guarded by
    /// `Session.isValid`'s boot-time check, not by clearing here.
    public func park() {
        guard let s = session else { return }
        session = nil
        _ = apply()
        session = s // disk still holds it; only the effect was released
        log("parked \(s)")
    }

    /// UI-preference setters: persisted so right-click/hotkey muscle memory survives
    /// daemon restarts.
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

    public func setFloor(_ percent: Int) {
        let clamped = max(Config.floorRange.lowerBound, min(Config.floorRange.upperBound, percent))
        config.batteryFloorPercent = clamped
        config.save()
        log("floor set to \(clamped)%")
        tick() // a raised floor may immediately end the running session
        onChange?()
    }

    /// The heartbeat: expiry, pid liveness, battery floor, LPM, external writers.
    /// Runs every poll tick, on power-source change, and before every status render.
    public func tick() {
        let flagOn = Kernel.sleepDisabled()
        guard let s = session else {
            if flagOn {
                log("tick: external writer turned the flag on, adopting")
                session = Session(modes: [.lid], term: .indefinite, forced: false)
                persist()
                onChange?()
            }
            return
        }

        if s.modes.contains(.lid), !flagOn {
            end(.externalOff)
            return
        }
        switch s.term {
        case .until(let d) where d <= Date():
            end(.expired)
            return
        case .whilePid(let pid, let started) where procStartTime(pid) != started:
            end(.pidExited(pid))
            return
        default:
            break
        }
        let power = Battery.snapshot()
        if power.discharging {
            if config.batteryFloorPercent > 0, power.percent <= config.batteryFloorPercent {
                end(.batteryFloor(power.percent))
                return
            }
            if power.lowPowerMode, !s.forced {
                end(.lowPowerMode)
                return
            }
        }
    }

    public func status() -> Status {
        tick()
        return Status(session: session,
                      sleepDisabled: Kernel.sleepDisabled(),
                      power: Battery.snapshot(),
                      floor: config.batteryFloorPercent)
    }

    // MARK: - The choke point

    /// Converge effect to intent. Computes the delta between what `session` wants and
    /// what the kernel/process currently does, and executes exactly that delta.
    private func apply() -> LidResult {
        let wanted = session?.modes ?? []

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
        if let s = session { SessionStore.save(s) } else { SessionStore.clear() }
    }
}
