import AppKit
import AwakeKit
import Foundation
import PermissionGrants

/// The nested notifier app, the daemon's only way onto the screen. A banner is the
/// app LS-launched per message (`open -g -n`: background, fresh instance every time
/// so two ends in one second are two banners). UNUserNotificationCenter is only
/// reachable from an LS-launched user-context app, never from this launchd agent
/// (Apple DTS, forums 804854; verified 2026-08 with a Developer ID signature,
/// lsregister and an LS launch: UNErrorDomain Code=1 every time). The bare
/// development binary has no bundle and no helper: messages go to the log only.
enum Notifier {
    /// Present only when running from the assembled bundle (scripts/assemble.sh puts
    /// it in Contents/Helpers). nil = bare .build binary in dev.
    static let app: URL? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let url = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers/awake-notifier.app")
        return FileManager.default.isExecutableFile(
            atPath: url.appendingPathComponent("Contents/MacOS/awake-notifier").path) ? url : nil
    }()

    /// `[message]`, `["--prime"]` or `["--probe"]`. Returns once LaunchServices has
    /// the launch; the helper records the reach it reads on every run.
    static func launch(_ args: [String]) {
        guard let app else {
            log("notify (no bundle, no helper): \(args.joined(separator: " "))")
            return
        }
        let r = AwakeKit.run("/usr/bin/open", ["-g", "-n", "-a", app.path, "--args"] + args)
        if r.status != 0 {
            log(
                "awake-notifier launch failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }
}

extension PermissionGrant {
    /// Notifications through the nested helper: the helper reads the reach (the
    /// daemon cannot), NotificationStore carries it here, and the standing is the
    /// module's one mapping. Askable asks through the helper (the prompt belongs to
    /// the app that posts); broken opens the HELPER's row in System Settings.
    static let notifier = PermissionGrant(
        title: "Notifications",
        why: "Safety-net ends (battery floor, Low Power Mode, critical heat) say so on screen.",
        symbol: "bell.badge", required: false,
        standing: { Notifier.standing },
        act: {
            switch Notifier.standing.grade {
            case .askable: Notifier.launch(["--prime"])
            case .broken:
                PermissionGrant.Notifications.openSettings(bundleID: Paths.notifierBundleID)
            case .good, .unknown: break
            }
        })
}

extension Notifier {
    static var standing: PermissionGrant.Standing {
        app == nil
            ? .unknown(note: "Development binary: no notifier, messages go to the log.")
            : PermissionGrant.Notifications.standing(NotificationStore.load())
    }
}
