import Foundation
import UserNotifications

// awake-notifier: the notification hop, and nothing else.
//
// UNUserNotificationCenter is structurally unavailable to a launchd agent (TCC only
// arbitrates the permission for LaunchServices-launched, user-context apps), and the
// daemon must stay a launchd agent because KeepAlive is its crash story. So the
// daemon hands each message to THIS app, LS-launched per event
// (`open -g -n -a awake-notifier.app --args "<message>"`), which checks the
// settings, posts, and exits. One process per banner; it lives for milliseconds, or
// as long as the first-run prompt stays on screen.
//
//   awake-notifier <message>   post it (asks authorization if never asked)
//   awake-notifier --prime     first-run only: ask now, in context, with an intro
//                              banner; a no-op once the person has answered.
//
// The permission ask follows Apple's guidance (usernotifications/asking-permission):
// ask in context (install time, human present, the intro says what will arrive
// here), request only what is used (alert + sound, no badge), check the settings
// before every post, and never go provisional: a safety-net message ("battery
// floor, sleep restored") must not be history-only.

let args = Array(CommandLine.arguments.dropFirst())
let prime = args.first == "--prime"
let message = prime
    ? "Sleep restored, a claim expired, the battery floor ended everything: it shows up here."
    : args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
guard !message.isEmpty else {
    FileHandle.standardError.write(Data("usage: awake-notifier <message> | --prime\n".utf8))
    exit(64)
}

/// Namespaced so the helpers are plain nonisolated statics: top-level functions in
/// main.swift are main-actor isolated and cannot be called from the @Sendable
/// completion handlers, which run on a background thread.
enum Notifier {
    /// The daemon's log, appended: an LS-launched app has no stderr anyone reads.
    static func log(_ text: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/awake")
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

    static func deliver(_ message: String, prime: Bool) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // The one moment the system prompt appears. With --prime this is
                // install time; otherwise it is the first real event, still "in
                // context" (the banner that follows IS the reason).
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        log("authorization failed: \(error)")
                        exit(1)
                    }
                    guard granted else {
                        log("notifications DENIED at the prompt. Re-enable: System Settings › Notifications › awake")
                        exit(2)
                    }
                    log("notifications authorized")
                    post(message)
                }
            case .authorized, .provisional, .ephemeral:
                if prime { exit(0) } // already answered; priming has nothing to say
                post(message)
            case .denied:
                log("notifications denied for awake; message dropped: \(message). Re-enable: System Settings › Notifications › awake")
                exit(2)
            @unknown default:
                log("unknown authorization status \(settings.authorizationStatus.rawValue); posting anyway")
                post(message)
            }
        }
    }
}

Notifier.deliver(message, prime: prime)

// Block on the run loop until a completion handler exits us. The ceiling is a
// first-run prompt left unanswered, not a normal path.
DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
    Notifier.log("no verdict in 120s (prompt unanswered?), giving up on: \(message)")
    exit(3)
}
dispatchMain()
