import AppKit
import AwakeKit
import Foundation
import IOKit.ps
import Keymap
import SwiftUI
import UserNotifications

/// The Keymap contract: one action, one spec. The global default follows the library's
/// modifier doctrine — a deliberate heavy chord on the identity initial (⌃⌥⌘A).
/// Remaps overlay via KeymapStore in UserDefaults; the spec IS the default.
enum AwakeAction: String, ActionSet {
    case toggleSession

    var spec: Spec {
        Spec(title: String(localized: "Toggle Awake Session"),
             symbol: "cup.and.heat.waves.fill",
             global: [KeyCombo("a", [.control, .option, .command])])
    }

    static var sections: [ActionSection<AwakeAction>] {
        [ActionSection("awake", [.toggleSession])]
    }
}

/// The resident brain: owns the StateMachine, the menu bar item, the socket, the
/// timers. Run by launchd (`garden.untitled.awake`), KeepAlive restarts it on crash
/// and startup reconciliation makes that restart honest.
@MainActor
final class Daemon: NSObject, NSApplicationDelegate, NSMenuDelegate,
                    UNUserNotificationCenterDelegate {
    static var shared: Daemon!
    /// True once UNUserNotificationCenter authorization is granted. Requires the .app
    /// bundle; nil bundle or denied auth falls back to osascript.
    private static var notificationsAuthorized = false

    let machine = StateMachine()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var pollTimer: Timer!
    private var expiryTimer: Timer?
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead!
    private var signalSources: [DispatchSourceSignal] = []
    /// Ticks the header item while the menu is open — NSMenu never redraws otherwise.
    private var menuTicker: Timer?
    private var keymapStore: KeymapStore<AwakeAction>!
    private var hotkeys: GlobalHotkeys<AwakeAction>!

    private static let durations: [(title: String, minutes: Int)] = [
        ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120),
        ("4 hours", 240), ("8 hours", 480), ("Indefinite", 0),
    ]
    private static let floors = [0, 10, 15, 20, 30, 50]

    static func main() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let daemon = Daemon()
        shared = daemon
        app.delegate = daemon
        app.run()
        fatalError("NSApp.run() returned")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("daemon up (pid \(ProcessInfo.processInfo.processIdentifier))")
        machine.onChange = { [weak self] in self?.render() }
        machine.notify = { Daemon.notify($0) }

        // Real notifications need the bundle; running the bare .build binary during
        // development keeps the osascript fallback.
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { granted, err in
                DispatchQueue.main.async {
                    Daemon.notificationsAuthorized = granted
                    if let err { log("notification authorization failed: \(err)") }
                    log("notifications: \(granted ? "UNUserNotificationCenter" : "osascript fallback")")
                }
            }
        }

        keymapStore = KeymapStore<AwakeAction>()
        hotkeys = GlobalHotkeys(store: keymapStore) { [weak self] action in
            switch action {
            case .toggleSession: self?.toggleSession()
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        precondition(statusItem.button != nil, "no status bar button")
        menu.delegate = self
        // No permanent statusItem.menu: the action decides. Left = menu (attached just
        // for the click, then detached so the action keeps firing), right = toggle.
        statusItem.button!.target = self
        statusItem.button!.action = #selector(statusClicked)
        statusItem.button!.sendAction(on: [.leftMouseUp, .rightMouseUp])

        listenFd = Wire.listen()
        acceptSource = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: .main)
        acceptSource.setEventHandler {
            MainActor.assumeIsolated {
                let d = Daemon.shared!
                Wire.acceptAndServe(listenFd: d.listenFd) { d.handle($0) }
            }
        }
        acceptSource.resume()

        // Quit is a transition like any other: restore sleep, then go.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    log("signal \(sig), parking session and exiting")
                    Daemon.shared.machine.park()
                    exit(0)
                }
            }
            src.resume()
            signalSources.append(src)
        }

        // Power events: AC/battery transitions and Low Power Mode flips both feed tick.
        let iops = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Daemon.shared.machine.tick() }
            }
        }, nil).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), iops, .defaultMode)
        NotificationCenter.default.addObserver(
            self, selector: #selector(powerStateChanged),
            name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)

        pollTimer = Timer.scheduledTimer(timeInterval: 60, target: self,
                                         selector: #selector(pollTick),
                                         userInfo: nil, repeats: true)
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        machine.park()
    }

    @objc private func pollTick() { machine.tick() }

    // NSMenu freezes its titles at open; a 1 Hz ticker in .common mode (menu tracking
    // runs the event-tracking runloop) keeps the countdown header honest while open.
    func menuWillOpen(_ menu: NSMenu) {
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Daemon.shared.menuTick() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        menuTicker = t
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTicker?.invalidate()
        menuTicker = nil
    }

    private func menuTick() {
        guard let header = menu.items.first, let s = machine.session else { return }
        header.title = "Awake — " + Client.describe(s)
    }

    @objc nonisolated private func powerStateChanged() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Daemon.shared.machine.tick() }
        }
    }

    // MARK: - Wire

    private func handle(_ cmd: Command) -> Reply {
        switch cmd {
        case .engage(let session):
            let previous = machine.session
            if let err = machine.engage(session) {
                return Reply(ok: false, error: err.message, status: machine.status())
            }
            if case .until(let d) = session.term {
                machine.rememberDuration(Int(d.timeIntervalSince(session.startedAt) / 60))
            } else if case .indefinite = session.term {
                machine.rememberDuration(0)
            }
            return Reply(ok: true, status: machine.status(), previous: previous)
        case .end:
            let previous = machine.session
            machine.end(.requested)
            return Reply(ok: true, status: machine.status(), previous: previous)
        case .status:
            return Reply(ok: true, status: machine.status())
        case .setFloor(let v):
            machine.setFloor(v)
            return Reply(ok: true, status: machine.status())
        case .setNotifyCommand(let c):
            machine.setNotifyCommand(c)
            return Reply(ok: true, status: machine.status())
        }
    }

    // MARK: - Menu bar

    /// ONE symbol both states (cup.and.heat.waves.fill — mixing variants shifts the
    /// menu bar): the steam IS the state. ON: cup in a subtle amber (alertness), steam
    /// in the bar's ink, full strength. OFF: palette [cup at 0.6 ink, steam fully
    /// clear] — steam gone, cup clearly translucent. Palette layer order verified by
    /// rendering: [cup, steam]. Neither image is a template — dynamic colors in the
    /// palettes re-resolve per menu-bar appearance at draw time.
    private static let onGlyph: NSImage = {
        // systemOrange full-on reads as a warning light; blending it 55/45 with the
        // bar's ink keeps the amber a tint, not a signal flare. The dynamic provider
        // re-blends per appearance — a plain blended() would bake the launch-time ink.
        let amber = NSColor(name: nil) { _ in
            NSColor.systemOrange.blended(withFraction: 0.45, of: .labelColor) ?? .systemOrange
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [amber, .labelColor]))
        let img = NSImage(systemSymbolName: "cup.and.heat.waves.fill",
                          accessibilityDescription: "awake")?.withSymbolConfiguration(cfg)
        precondition(img != nil, "SF Symbol cup.and.heat.waves.fill missing")
        return img!
    }()

    private static let offGlyph: NSImage = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [.labelColor.withAlphaComponent(0.6), .clear]))
        let img = NSImage(systemSymbolName: "cup.and.heat.waves.fill",
                          accessibilityDescription: "awake")?.withSymbolConfiguration(cfg)
        precondition(img != nil, "SF Symbol cup.and.heat.waves.fill missing")
        return img!
    }()

    private func render() {
        rearmExpiryTimer()
        guard let button = statusItem.button else { return }
        let active = machine.session != nil
        button.image = active ? Self.onGlyph : Self.offGlyph
        button.toolTip = active
            ? "awake: " + Client.describe(machine.session!)
            : "awake: off — Mac sleeps normally"
    }

    /// Expiry deserves second-precision, not poll-tick precision.
    private func rearmExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let s = machine.session, case .until(let d) = s.term else { return }
        let interval = d.timeIntervalSinceNow + 0.5
        guard interval > 0 else { return }
        expiryTimer = Timer.scheduledTimer(timeInterval: interval, target: self,
                                           selector: #selector(pollTick),
                                           userInfo: nil, repeats: false)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        machine.tick() // never render stale state
        menu.removeAllItems()
        let st = machine.status()

        let header = NSMenuItem(title: st.session.map { "Awake — " + Client.describe($0) }
                                    ?? "Asleep — normal sleep",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if st.power.hasBattery {
            let battery = NSMenuItem(
                title: "Battery \(st.power.percent)%\(st.power.onAC ? " (AC)" : "")"
                    + (st.floor > 0 ? " · floor \(st.floor)%" : ""),
                action: nil, keyEquivalent: "")
            battery.isEnabled = false
            menu.addItem(battery)
        }
        menu.addItem(.separator())

        if st.session != nil {
            let end = NSMenuItem(title: "End session", action: #selector(endClicked),
                                 keyEquivalent: "")
            end.target = self
            menu.addItem(end)
            menu.addItem(.separator())
        }

        for (title, minutes) in Self.durations {
            let item = NSMenuItem(title: title, action: #selector(engageClicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let display = NSMenuItem(title: "Keep display on",
                                 action: #selector(displayToggled), keyEquivalent: "")
        display.target = self
        display.state = machine.config.menuDisplay ? .on : .off
        menu.addItem(display)

        let floorMenu = NSMenu()
        for f in Self.floors {
            let item = NSMenuItem(title: f == 0 ? "Off" : "\(f)%",
                                  action: #selector(floorClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = f
            item.state = st.floor == f ? .on : .off
            floorMenu.addItem(item)
        }
        let floorItem = NSMenuItem(title: "Battery floor", action: nil, keyEquivalent: "")
        floorItem.submenu = floorMenu
        menu.addItem(floorItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit awake", action: #selector(quitClicked),
                              keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            toggleSession()
            return
        }
        statusItem.menu = menu
        statusItem.button!.performClick(nil)
        statusItem.menu = nil
    }

    /// Right-click and the global hotkey: Amphetamine's gesture, last-used duration.
    private func toggleSession() {
        if machine.session != nil {
            machine.end(.requested)
        } else {
            engage(minutes: machine.config.lastMinutes)
        }
    }

    private func engage(minutes: Int) {
        var modes = Session.defaultModes
        if machine.config.menuDisplay { modes.insert(.display) }
        let term: Term = minutes == 0 ? .indefinite
            : .until(Date().addingTimeInterval(TimeInterval(minutes * 60)))
        if let err = machine.engage(Session(modes: modes, term: term, forced: true)) {
            Daemon.screenNotify(err.message)
        } else {
            machine.rememberDuration(minutes)
        }
    }

    @objc private func engageClicked(_ sender: NSMenuItem) {
        engage(minutes: sender.representedObject as! Int)
    }

    @objc private func endClicked() { machine.end(.requested) }

    @objc private func displayToggled() {
        machine.setMenuDisplay(!machine.config.menuDisplay)
        if var s = machine.session {
            if machine.config.menuDisplay { s.modes.insert(.display) } else { s.modes.remove(.display) }
            if let err = machine.engage(s) { Daemon.screenNotify(err.message) }
        }
    }

    @objc private func floorClicked(_ sender: NSMenuItem) {
        machine.setFloor(sender.representedObject as! Int)
    }

    @objc private func quitClicked() {
        machine.end(.shutdown)
        // Bypass launchd KeepAlive: bootout unloads the agent instead of exit(0),
        // which would just resurrect us. `make install` brings it back.
        _ = AwakeKit.run("/bin/launchctl",
                         ["bootout", "gui/\(getuid())/\(Paths.launchdLabel)"])
        exit(0) // only reached if bootout failed (e.g. running outside launchd)
    }

    // MARK: - Notifications

    /// Screen always. The ends that fire while the lid is CLOSED also go out of
    /// band, because a screen notification behind a closed lid informs nobody.
    /// That channel is an OPTIONAL hook the user configures (`awake notify <path>`):
    /// any executable taking one message argument. Unset is the default.
    static func notify(_ reason: EndReason) {
        guard let message = reason.message else { return }
        screenNotify(message)
        switch reason {
        case .batteryFloor, .lowPowerMode:
            let hook = Daemon.shared.machine.config.notifyCommand
            guard !hook.isEmpty else { return }
            guard FileManager.default.isExecutableFile(atPath: hook) else {
                log("notify hook \(hook) is not executable")
                return
            }
            let r = AwakeKit.run(hook, ["awake: \(message)"])
            if r.status != 0 { log("notify hook failed: \(r.err)") }
        default:
            break
        }
    }

    static func screenNotify(_ message: String) {
        guard notificationsAuthorized else {
            precondition(!message.contains("\""), "notification message would break osascript quoting")
            let script = "display notification \"\(message)\" with title \"awake\""
            _ = AwakeKit.run("/usr/bin/osascript", ["-e", script])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "awake"
        content.body = message
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Accessory app counts as foreground — without this the banner never shows.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
