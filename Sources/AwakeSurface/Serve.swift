import AwakeKit
import Foundation

/// What a gesture leaves for the host to do beyond the machine: raise the admin
/// sheet, show a banner, open a grant, quit. The daemon does these for real; a scene
/// records them.
public enum Effect: Equatable, Sendable {
    /// The gesture meant "keep it awake" and the sudoers grant is missing:
    /// onboard, then complete it (`retryMinutes`), or just onboard (nil).
    case offerGrant(retryMinutes: Int?)
    case notify(String)
    case notificationsGrant
    case quit
}

extension StateMachine {
    /// One wire command → one reply. The daemon's socket and a scene's `$ awake`
    /// both land here.
    public func serve(_ cmd: Command) -> Reply {
        switch cmd {
        case .engage(let claim):
            // No duration memory here, deliberately: the toggle default is the
            // human's muscle memory and only menu/hotkey gestures may teach it.
            switch engage(claim) {
            case .success(let e):
                return Reply(
                    ok: true, status: status(), replaced: e.replaced, coveredBy: e.coveredBy)
            case .failure(let err):
                return Reply(ok: false, error: err.message, status: status())
            }
        case .end(let token):
            let targets: [Claim]
            if let token {
                targets = Claim.matching(token, in: claims)
                if targets.isEmpty {
                    let have = claims.map { Words.describe($0, now: world.now) }
                        .joined(separator: " · ")
                    return Reply(
                        ok: false,
                        error: claims.isEmpty
                            ? "no claims to end"
                            : "no claim matches '\(token)' (have: \(have))",
                        status: status())
                }
            } else {
                targets = claims
            }
            end(Set(targets.map(\.id)), .requested)
            return Reply(ok: true, status: status(), ended: targets)
        case .status:
            return Reply(ok: true, status: status())
        case .setFloor(let v):
            setFloor(v)
            return Reply(ok: true, status: status())
        case .setNotifyCommand(let c):
            setNotifyCommand(c)
            return Reply(ok: true, status: status())
        case .setKeepDisplay(let on):
            setMenuDisplay(on)
            return Reply(ok: true, status: status())
        case .allowLid(let token):
            return resolveLid(token, granted: true)
        case .denyLid(let token):
            return resolveLid(token, granted: false)
        case .suspend:
            suspend()
            return Reply(ok: true, status: status())
        case .resume:
            resume()
            return Reply(ok: true, status: status())
        case .setUpdateCheck(let on):
            setUpdateCheck(on)
            return Reply(ok: true, status: status())
        }
    }

    /// The human's answer to lid asks, from the shell. Allow targets unanswered
    /// asks; deny targets every want, so deny-after-grant is revoke.
    private func resolveLid(_ token: String?, granted: Bool) -> Reply {
        let pool = claims.filter { granted ? ($0.wantsLid && !$0.lidGranted) : $0.wantsLid }
        let targets = token.map { Claim.matching($0, in: pool) } ?? pool
        if targets.isEmpty {
            return Reply(
                ok: false,
                error: token.map { "no lid ask matches '\($0)'" }
                    ?? (granted ? "no pending lid asks" : "no lid asks to dismiss"),
                status: status())
        }
        switch resolveLidWant(Set(targets.map(\.id)), granted: granted) {
        case .success: return Reply(ok: true, status: status())
        case .failure(let err): return Reply(ok: false, error: err.message, status: status())
        }
    }

    /// A menu click.
    public func perform(_ action: MenuAction) -> Effect? {
        switch action {
        case .finishSetup: return .offerGrant(retryMinutes: nil)
        case .notifications: return .notificationsGrant
        case .allowLid(let ids): return answerAsk(ids, granted: true)
        case .denyLid(let ids): return answerAsk(ids, granted: false)
        case .endClaims(let ids): end(Set(ids), .requested)
        case .endYours:
            end(Set(claims.filter { $0.owner == Claim.humanOwner }.map(\.id)), .requested)
        case .endAll: endAll(.requested)
        case .suspend: suspend()
        case .resume: resume()
        case .engage(let minutes): return engageYours(minutes: minutes)
        case .toggleDisplay: setMenuDisplay(!config.menuDisplay)
        case .floor(let f): setFloor(f)
        case .quit: return .quit
        }
        return nil
    }

    /// Right-click and the global hotkey. The toggle is YOUR claim and nothing else:
    /// yours running → end it (lid disarms, named claims keep working); none → start
    /// yours at the last menu-chosen duration; suspended → resume, and start yours.
    /// "Let it sleep" and "End all claims" are explicit verbs, never this gesture.
    public func toggle() -> Effect? {
        if suspended {
            resume()
            return engageYours(minutes: config.lastMinutes)
        }
        let yours = claims.filter { $0.owner == Claim.humanOwner }
        if yours.isEmpty { return engageYours(minutes: config.lastMinutes) }
        end(Set(yours.map(\.id)), .requested)
        return nil
    }

    /// YOUR claim for `minutes` (0 = indefinite), the menu and hotkey gesture.
    public func engageYours(minutes: Int) -> Effect? {
        let now = world.now
        let term: Term =
            minutes == 0 ? .indefinite : .until(now.addingTimeInterval(TimeInterval(minutes * 60)))
        switch engage(
            Claim(
                owner: Claim.humanOwner, forced: true, modes: Claim.defaultModes, term: term,
                startedAt: now))
        {
        case .success:
            rememberDuration(minutes)
            return nil
        case .failure(.grantMissing):
            return .offerGrant(retryMinutes: minutes)
        case .failure(let err):
            return .notify(err.message)
        }
    }

    /// A missing sudoers grant raises the admin sheet; the ask stays in the menu,
    /// so completing setup and clicking Allow again finishes the thought.
    private func answerAsk(_ ids: [UUID], granted: Bool) -> Effect? {
        switch resolveLidWant(Set(ids), granted: granted) {
        case .success: return nil
        case .failure(.grantMissing): return .offerGrant(retryMinutes: nil)
        case .failure(let err): return .notify(err.message)
        }
    }
}
