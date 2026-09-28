import AwakeKit
import Foundation
import Grant
import UserNotifications

// awake-notifier: the notification hop, and the only eyes on its own permission.
//
// UNUserNotificationCenter is structurally unavailable to a launchd agent (TCC only
// arbitrates the permission for LaunchServices-launched, user-context apps), and the
// daemon must stay a launchd agent because KeepAlive is its crash story. So the
// daemon hands each message to THIS app, LS-launched per event
// (`open -g -n -a awake-notifier.app --args "<message>"`), which checks the
// settings, posts, and exits. One process per banner; it lives for milliseconds, or
// as long as the first-run prompt stays on screen. Every run records the reach it
// read (NotificationStore): the daemon cannot read it, and a denial that only
// reaches a log is a denial nobody ever learns about.
//
//   awake-notifier <message>   post it (asks authorization if never asked)
//   awake-notifier --prime     ask now, in context, with an intro banner; a no-op
//                              once the person has answered.
//   awake-notifier --probe     record the reach and exit; the daemon runs it when
//                              its menu opens, so the row follows System Settings.
//
// The permission ask follows Apple's guidance (usernotifications/asking-permission):
// ask in context (install time, human present, the intro says what will arrive
// here), request only what is used (alert + sound, no badge), check the settings
// before every post, and never go provisional: a safety-net message ("battery
// floor, sleep restored") must not be history-only.

let args = Array(CommandLine.arguments.dropFirst())
let prime = args.first == "--prime"
let probe = args.first == "--probe"
let message =
    prime
    ? "Sleep restored, a claim expired, the battery floor ended everything: it shows up here."
    : args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
guard probe || !message.isEmpty else {
    FileHandle.standardError.write(
        Data("usage: awake-notifier <message> | --prime | --probe\n".utf8))
    exit(64)
}

/// Namespaced so the helpers are plain nonisolated statics: top-level functions in
/// main.swift are main-actor isolated and cannot be called from the @Sendable
/// completion handlers, which run on a background thread.
enum Notifier {
    /// The daemon's log, appended: an LS-launched app has no stderr anyone reads.
    static func log(_ text: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Logs/awake")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) notifier: \(text)\n"
        let url = dir.appendingPathComponent("service.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static func post(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "awake"
        content.body = message
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { error in
            if let error {
                log("add failed: \(error)")
                exit(1)
            }
            exit(0)
        }
    }

    /// Record what the settings say, in the one place the daemon reads.
    static func record(_ settings: UNNotificationSettings) {
        guard let reach = Notifications.reach(of: settings) else {
            log(
                "unknown authorization status \(settings.authorizationStatus.rawValue), not recorded"
            )
            return
        }
        if NotificationStore.load() != reach { log("notification reach: \(reach.rawValue)") }
        NotificationStore.save(reach)
    }

    static func probe() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            record(settings)
            exit(0)
        }
    }

    static func deliver(_ message: String, prime: Bool) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            record(settings)
            switch settings.authorizationStatus {
            case .notDetermined:
                // The one moment the system prompt appears. With --prime this is
                // install time; otherwise it is the first real event, still "in
                // context" (the banner that follows IS the reason).
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
                    granted, error in
                    if let error {
                        log("authorization failed: \(error)")
                        exit(1)
                    }
                    // The answer changed the settings; record them as they now are
                    // (granted can still be silenced, alert style None).
                    UNUserNotificationCenter.current().getNotificationSettings { after in
                        record(after)
                        guard granted else {
                            log("notifications DENIED at the prompt")
                            exit(2)
                        }
                        post(message)
                    }
                }
            case .authorized, .provisional, .ephemeral:
                if prime { exit(0) }  // already answered; priming has nothing to say
                post(message)
            case .denied:
                if !prime { log("notifications denied for awake; message dropped: \(message)") }
                exit(2)
            @unknown default:
                log(
                    "unknown authorization status \(settings.authorizationStatus.rawValue); posting anyway"
                )
                post(message)
            }
        }
    }
}

if probe { Notifier.probe() } else { Notifier.deliver(message, prime: prime) }

// Block on the run loop until a completion handler exits us. The ceiling is a
// first-run prompt left unanswered, not a normal path.
DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
    Notifier.log("no verdict in 120s (prompt unanswered?), giving up on: \(message)")
    exit(3)
}
dispatchMain()
