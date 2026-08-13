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
    /// Ticks the header + claim rows while the menu is open — NSMenu never redraws
    /// otherwise.
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
        machine.notify = { Daemon.notify($0, ended: $1, remaining: $2) }

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
                    log("signal \(sig), parking claims and exiting")
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
    // runs the event-tracking runloop) keeps countdowns honest while open.
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
        guard let header = menu.items.first, !machine.claims.isEmpty else { return }
        header.title = Self.headerTitle(machine.claims)
        let summaries = Client.summarize(machine.claims)
        for item in menu.items {
            guard let owner = item.representedObject as? String,
                  let s = summaries.first(where: { $0.owner == owner }) else { continue }
            item.title = "   " + s.label
        }
    }

    @objc nonisolated private func powerStateChanged() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Daemon.shared.machine.tick() }
        }
    }

    // MARK: - Wire

    private func handle(_ cmd: Command) -> Reply {
        switch cmd {
        case .engage(let claim):
            // No duration memory here, deliberately: the toggle default is the
            // human's muscle memory and only menu/hotkey gestures may teach it.
            switch machine.engage(claim) {
            case .success(let e):
                return Reply(ok: true, status: machine.status(),
                             replaced: e.replaced, coveredBy: e.coveredBy)
            case .failure(let err):
                return Reply(ok: false, error: err.message, status: machine.status())
            }
        case .end(let token):
            let targets: [Claim]
            if let token {
                targets = Self.match(token, in: machine.claims)
                if targets.isEmpty {
                    let have = machine.claims.map { Client.describe($0) }
                        .joined(separator: " · ")
                    return Reply(ok: false,
                                 error: machine.claims.isEmpty
                                     ? "no claims to end"
                                     : "no claim matches '\(token)' (have: \(have))",
                                 status: machine.status())
                }
            } else {
                targets = machine.claims
            }
            machine.end(Set(targets.map(\.id)), .requested)
            return Reply(ok: true, status: machine.status(), ended: targets)
        case .status:
            return Reply(ok: true, status: machine.status())
        case .setFloor(let v):
            machine.setFloor(v)
            return Reply(ok: true, status: machine.status())
        case .setNotifyCommand(let c):
            machine.setNotifyCommand(c)
            return Reply(ok: true, status: machine.status())
        case .setKeepDisplay(let on):
            setKeepDisplay(on)
            return Reply(ok: true, status: machine.status())
        }
    }

    /// `awake off WHO`: an owner-label prefix or a watched pid, every claim it names.
    private static func match(_ token: String, in claims: [Claim]) -> [Claim] {
        let t = token.lowercased()
        return claims.filter { claim in
            if claim.owner.lowercased().hasPrefix(t) { return true }
            if case .whilePid(let pid, _) = claim.term, String(pid) == token { return true }
            return false
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

    private static func headerTitle(_ claims: [Claim]) -> String {
        let summaries = Client.summarize(claims)
        switch summaries.count {
        case 0: return "Asleep · normal sleep"
        case 1: return "Awake · " + summaries[0].label
        default: return "Awake · \(claims.count) claims"
        }
    }

    /// The duration of YOUR active claim, bucketed in minutes (0 = indefinite),
    /// nil when you hold none. Drives the menu checkmark: state, never a default —
    /// a checked duration with no matching claim reads as a session that isn't there.
    private func yourDurationMinutes() -> Int? {
        guard let c = machine.claims.first(where: { $0.owner == Claim.humanOwner }) else {
            return nil
        }
        switch c.term {
        case .indefinite: return 0
        case .until(let d): return Int((d.timeIntervalSince(c.startedAt) / 60).rounded())
        case .whilePid: return nil
        }
    }

    private func render() {
        rearmExpiryTimer()
        guard let button = statusItem.button else { return }
        let claims = machine.claims
        button.image = claims.isEmpty ? Self.offGlyph : Self.onGlyph
        button.toolTip = claims.isEmpty
            ? "awake: off — Mac sleeps normally"
            : "awake: " + claims.map { Client.describe($0) }.joined(separator: "\n")
    }

    /// Expiry deserves second-precision, not poll-tick precision. Armed for the
    /// NEAREST deadline across all timed claims.
    private func rearmExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        let deadlines: [Date] = machine.claims.compactMap {
            if case .until(let d) = $0.term { return d }
            return nil
        }
        guard let next = deadlines.min() else { return }
        let interval = next.timeIntervalSinceNow + 0.5
        guard interval > 0 else { return }
        expiryTimer = Timer.scheduledTimer(timeInterval: interval, target: self,
                                           selector: #selector(pollTick),
                                           userInfo: nil, repeats: false)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        machine.tick() // never render stale state
        menu.removeAllItems()
        let st = machine.status()

        let header = NSMenuItem(title: Self.headerTitle(st.claims),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.toolTip = st.claims.isEmpty ? nil
            : st.claims.map { Client.describe($0) }.joined(separator: "\n")
        menu.addItem(header)
        // The roster: one line per OWNER — who wants the Mac awake, and until when.
        // A single owner already fits in the header; a crowd gets the list. Pids
        // live in the tooltip, not the row.
        let summaries = Client.summarize(st.claims)
        if summaries.count > 1 {
            for s in summaries {
                let item = NSMenuItem(title: "   " + s.label,
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.representedObject = s.owner
                item.toolTip = s.detail
                menu.addItem(item)
            }
        }
        if st.power.hasBattery {
            let battery = NSMenuItem(
                title: "Battery \(st.power.percent)%\(st.power.onAC ? " (AC)" : "")"
                    + (st.floor > 0 ? " · floor \(st.floor)%" : ""),
                action: nil, keyEquivalent: "")
            battery.isEnabled = false
            menu.addItem(battery)
        }
        menu.addItem(.separator())

        // The toggle gesture (right-click, ⌃⌥⌘A) lands on exactly one item, and that
        // item wears the hotkey badge: "End all claims" while anything runs, else
        // the duration it would start. Pressing the chord with the menu open does
        // the same thing the global hotkey does — the badge is never a lie.
        let toggleBadge = { (item: NSMenuItem) in
            item.keyEquivalent = "a"
            item.keyEquivalentModifierMask = [.control, .option, .command]
        }

        if !st.claims.isEmpty {
            let end = NSMenuItem(title: st.claims.count > 1 ? "End all claims" : "End session",
                                 action: #selector(endClicked), keyEquivalent: "")
            end.target = self
            toggleBadge(end)
            menu.addItem(end)
            menu.addItem(.separator())
        }

        // The checkmark is STATE: your running claim's duration, nothing else.
        // (A checkmark on a mere default reads as a claim that isn't there.)
        let yours = yourDurationMinutes()
        for (title, minutes) in Self.durations {
            let item = NSMenuItem(title: title, action: #selector(engageClicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            item.state = yours == minutes ? .on : .off
            if st.claims.isEmpty, machine.config.lastMinutes == minutes {
                toggleBadge(item)
            }
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

    /// Right-click and the global hotkey: the human kill switch, then the human
    /// starter. Any claims at all → end them ALL (the gesture means "let it sleep");
    /// none → start YOUR claim at the last menu-chosen duration.
    private func toggleSession() {
        if machine.claims.isEmpty {
            engage(minutes: machine.config.lastMinutes)
        } else {
            machine.endAll(.requested)
        }
    }

    private func engage(minutes: Int) {
        var modes = Claim.defaultModes
        if machine.config.menuDisplay { modes.insert(.display) }
        let term: Term = minutes == 0 ? .indefinite
            : .until(Date().addingTimeInterval(TimeInterval(minutes * 60)))
        switch machine.engage(Claim(owner: Claim.humanOwner, forced: true,
                                    modes: modes, term: term)) {
        case .success:
            machine.rememberDuration(minutes)
        case .failure(let err):
            Daemon.screenNotify(err.message)
        }
    }

    @objc private func engageClicked(_ sender: NSMenuItem) {
        engage(minutes: sender.representedObject as! Int)
    }

    @objc private func endClicked() { machine.endAll(.requested) }

    @objc private func displayToggled() {
        setKeepDisplay(!machine.config.menuDisplay)
    }

    /// The preference AND the running claims, together: flipping it while claims are
    /// up has to add or drop the assertion now, not at the next engagement. It moves
    /// the HUMAN's claims only — an agent's claim never lights the screen because a
    /// menu checkbox says so. Menu and CLI both land here so they cannot diverge.
    func setKeepDisplay(_ on: Bool) {
        machine.setMenuDisplay(on)
        for var claim in machine.claims where claim.owner == Claim.humanOwner {
            if on { claim.modes.insert(.display) } else { claim.modes.remove(.display) }
            if case .failure(let err) = machine.engage(claim) {
                Daemon.screenNotify(err.message)
            }
        }
    }

    @objc private func floorClicked(_ sender: NSMenuItem) {
        machine.setFloor(sender.representedObject as! Int)
    }

    @objc private func quitClicked() {
        machine.endAll(.shutdown)
        // Bypass launchd KeepAlive: bootout unloads the agent instead of exit(0),
        // which would just resurrect us. `make install` brings it back.
        _ = AwakeKit.run("/bin/launchctl",
                         ["bootout", "gui/\(getuid())/\(Paths.launchdLabel)"])
        exit(0) // only reached if bootout failed (e.g. running outside launchd)
    }

    // MARK: - Notifications

    /// The composer: (reason, ended, remaining) → one honest sentence, or silence.
    /// "Sleep restored" is said ONLY when the last claim is gone. An agent's claim
    /// ending under other claims is a non-event (log-only); YOUR claim ending while
    /// others keep the Mac awake says so explicitly. Safety-net ends always speak,
    /// and the closed-lid ones (battery floor, LPM) also go out of band through the
    /// configured notify hook — sent BEFORE the flag drops so the push leaves on an
    /// awake network stack.
    static func notify(_ reason: EndReason, ended: [Claim], remaining: [Claim]) {
        guard let message = composeMessage(reason, ended: ended, remaining: remaining) else {
            return
        }
        screenNotify(message)
        guard reason.outOfBand else { return }
        let hook = Daemon.shared.machine.config.notifyCommand
        guard !hook.isEmpty else { return }
        guard FileManager.default.isExecutableFile(atPath: hook) else {
            log("notify hook \(hook) is not executable")
            return
        }
        let r = AwakeKit.run(hook, ["awake: \(message)"])
        if r.status != 0 { log("notify hook failed: \(r.err)") }
    }

    static func composeMessage(_ reason: EndReason, ended: [Claim],
                               remaining: [Claim]) -> String? {
        let still = remaining.isEmpty
            ? "Sleep restored."
            : "Still awake: \(Client.summarize(remaining).map(\.label).joined(separator: ", "))."
        switch reason {
        case .requested, .shutdown:
            return nil
        case .batteryFloor(let p):
            return "Battery at \(p)%. Sleep restored."
        case .lowPowerMode:
            return "Low Power Mode is on. \(still)"
        case .externalOff:
            return "Sleep was re-enabled outside awake. All claims ended."
        case .expired:
            guard remaining.isEmpty || ended.contains(where: { $0.owner == Claim.humanOwner })
            else { return nil } // an agent's timer lapsing under other claims is a non-event
            let labels = ended.map { expiredLabel($0) }.joined(separator: " and ")
            return "\(labels) expired. \(still)"
        case .pidExited(let pid):
            // The last claim explaining why sleep came back is signal; an agent
            // hand-off while others hold the machine is noise.
            guard remaining.isEmpty, let claim = ended.first else { return nil }
            return "\(claim.owner) (pid \(pid)) exited. Sleep restored."
        }
    }

    /// "Your 2h claim" / "release's 8h claim" — the owner and the span it asked for.
    private static func expiredLabel(_ c: Claim) -> String {
        var span = ""
        if case .until(let d) = c.term {
            span = " \(Client.formatInterval(d.timeIntervalSince(c.startedAt)))"
        }
        return c.owner == Claim.humanOwner ? "Your\(span) claim" : "\(c.owner)'s\(span) claim"
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
