import AppKit
import AwakeKit
import AwakeSurface
import Foundation
import IOKit.ps
import Keymap
import Security
import SwiftUI

/// The resident brain: owns the StateMachine, the menu bar item, the socket, the
/// timers. Run by launchd (`garden.untitled.awake`), KeepAlive restarts it on crash
/// and startup reconciliation makes that restart honest. Every word it shows comes
/// from AwakeSurface; this file only draws it and routes the clicks.
@MainActor
final class Daemon: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: Daemon!

    let machine = StateMachine(world: HostWorld())
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var pollTimer: Timer!
    private var expiryTimer: Timer?
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead!
    private var signalSources: [DispatchSourceSignal] = []
    /// Ticks the open menu's rows: NSMenu never redraws otherwise.
    private var menuTicker: Timer?
    /// The state the open menu was built from. The ticker redraws countdowns and
    /// grant rows against it; the claims themselves refresh on the next open.
    private var openStatus: Status?
    /// Verified-live at launch and re-probed while broken: false = the sudoers
    /// grant is missing, the menu leads with the setup row, and any keep-awake
    /// gesture raises the admin sheet instead of failing into a notification
    /// nobody granted permission to show (the first-run dead-icon bug).
    private var grantReady = true
    private var grantInFlight = false
    private var keymapStore: KeymapStore<AwakeAction>!
    private var hotkeys: GlobalHotkeys<AwakeAction>!

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
        machine.onForcedSleep = { Daemon.notifyForcedSleep(percent: $0) }

        log(
            "notifications: \(Notifier.app.map { "awake-notifier at \($0.path)" } ?? "log only (bare binary, no bundle)")"
        )

        keymapStore = KeymapStore<AwakeAction>()
        hotkeys = GlobalHotkeys(store: keymapStore) { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleSession: self.run(self.machine.toggle())
            }
        }
        // Carbon refuses a combo another app owns; Keymap only records it here.
        log(
            keymapStore.deadGlobals.isEmpty
                ? "hotkey registered"
                : "hotkey NOT registered, another app owns it: \(keymapStore.deadGlobals)")

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
                Wire.acceptAndServe(listenFd: d.listenFd) { d.machine.serve($0) }
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
        let iops = IOPSNotificationCreateRunLoopSource(
            { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Daemon.shared.machine.tick() }
                }
            }, nil
        ).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), iops, .defaultMode)
        NotificationCenter.default.addObserver(
            self, selector: #selector(environmentChanged),
            name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(environmentChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

        pollTimer = Timer.scheduledTimer(
            timeInterval: 60, target: self,
            selector: #selector(pollTick),
            userInfo: nil, repeats: true)
        _ = Self.image  // the image and identity as launched, before anything can replace them
        _ = Self.selfRequirement
        // Startup re-armed persisted claims before the hooks existed; the nets judge
        // them now, with notifications wired, not a poll interval later.
        machine.tick()
        grantReady = Sudoers.works()
        Notifier.launch(["--probe"])
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        machine.park()
    }

    @objc private func pollTick() {
        watchImage()
        machine.tick()
        checkForUpdate()
    }

    // MARK: - Own lifecycle

    /// The executable this process runs, identified by inode: an upgrade puts a
    /// different file at the same path.
    private static let image: (path: String, inode: ino_t) = {
        let path = Bundle.main.executablePath!
        var st = stat()
        precondition(stat(path, &st) == 0, "own executable unreadable at \(path)")
        return (path, st.st_ino)
    }()
    private var imageGoneTicks = 0

    /// The bundle on disk against the image running. Replaced (an upgrade, a
    /// reinstall) → park and exit: KeepAlive restarts into the new image and startup
    /// re-arms the claims. Gone two ticks in a row (an uninstall; a single absent tick
    /// is the instant an upgrade swaps bundles) → end every claim, which restores
    /// sleep, then bootout: a deleted app leaves its job loaded, and launchd would
    /// retry the missing binary forever. Nothing else is awake to do it
    /// (cask steps are sandboxed; a Trash drag runs no hook at all).
    private func watchImage() {
        let (path, inode) = Self.image
        var st = stat()
        guard stat(path, &st) == 0 else {
            imageGoneTicks += 1
            log("executable missing at \(path) (\(imageGoneTicks)/2)")
            guard imageGoneTicks >= 2 else { return }
            log("app uninstalled: ending every claim and leaving launchd")
            machine.endAll(.shutdown)
            Agent.bootoutSelf()  // launchd kills this process inside the call
            exit(0)
        }
        imageGoneTicks = 0
        guard st.st_ino != inode else { return }
        // Restart only into a bundle that is whole and signed as this one is: an
        // installer writing in place (Finder copying file by file, a signing step
        // still to come) leaves an image launchd refuses with a launch constraint
        // violation, and after a few refusals launchd drops the job for good.
        guard Self.bundleSignedAsSelf() else {
            log("executable replaced at \(path), bundle not yet validly signed, waiting")
            return
        }
        log("executable replaced at \(path), restarting into the new image")
        machine.park()
        exit(0)
    }

    /// This process's designated requirement (identifier + Team ID), captured at
    /// launch: the one identity a replacement bundle must satisfy.
    private static let selfRequirement: SecRequirement = {
        var me: SecCode?
        var meOnDisk: SecStaticCode?
        var requirement: SecRequirement?
        precondition(SecCodeCopySelf([], &me) == errSecSuccess, "SecCodeCopySelf failed")
        precondition(
            SecCodeCopyStaticCode(me!, [], &meOnDisk) == errSecSuccess, "own static code unreadable"
        )
        precondition(
            SecCodeCopyDesignatedRequirement(meOnDisk!, [], &requirement) == errSecSuccess,
            "own designated requirement unreadable")
        return requirement!
    }()

    private static func bundleSignedAsSelf() -> Bool {
        var code: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess
        else { return false }
        return SecStaticCodeCheckValidity(
            code!, SecCSFlags(rawValue: kSecCSCheckNestedCode), selfRequirement) == errSecSuccess
    }

    // MARK: - Update check

    /// The bundle's own version; nil for the bare development binary, which
    /// therefore never phones anywhere.
    static let runningVersion: String? =
        Bundle.main.bundleIdentifier == nil
        ? nil
        : Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    private static let feed = URL(string: "https://awake.untitled.garden/appcast.xml")!
    private var updateInFlight = false

    /// One GET a day against the owned appcast (`updates off` stops it). The
    /// GET is the whole payload: the server counts it as an active install for
    /// the day under a salted IP hash and 302s to the feed. If the feed names a
    /// newer version than this bundle, say so once, through the notifier, and
    /// point at brew. Failure reschedules an hour out and is log-only.
    private func checkForUpdate() {
        guard let running = Self.runningVersion, machine.updateCheckDue, !updateInFlight else {
            return
        }
        updateInFlight = true
        var req = URLRequest(url: Self.feed, timeoutInterval: 10)
        req.setValue("awake/\(running)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let latest: String? = {
                guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
                    let data, let text = String(data: data, encoding: .utf8)
                else { return nil }
                // Element form (our hand-written feed) or attribute form (generate_appcast).
                let m = text.range(
                    of: #"shortVersionString(?:>|=")(\d+\.\d+\.\d+)"#, options: .regularExpression)
                return m.flatMap {
                    text[$0].range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map {
                        String(text[$0])
                    }
                }
            }()
            if latest == nil {
                log(
                    "update check failed: \(error.map { "\($0)" } ?? "unparseable feed / HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")"
                )
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let d = Daemon.shared!
                    d.updateInFlight = false
                    if let announce = d.machine.recordUpdateCheck(latest: latest, running: running)
                    {
                        Daemon.screenNotify(Notice.updateAvailable(announce, running: running))
                    }
                }
            }
        }.resume()
    }

    @objc nonisolated private func environmentChanged() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Daemon.shared.machine.tick() }
        }
    }

    // MARK: - Menu bar

    private func render() {
        rearmExpiryTimer()
        guard let button = statusItem.button else { return }
        button.image =
            Glyph(
                claimsEmpty: machine.claims.isEmpty, suspended: machine.suspended,
                lidArmed: machine.lidArmed, askPending: machine.askPending
            ).image
        button.toolTip = Glyph.tooltip(machine.claims, suspended: machine.suspended, now: Date())
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
        expiryTimer = Timer.scheduledTimer(
            timeInterval: interval, target: self,
            selector: #selector(pollTick),
            userInfo: nil, repeats: false)
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            run(machine.toggle())
            return
        }
        statusItem.menu = menu
        statusItem.button!.performClick(nil)
        statusItem.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        openStatus = machine.status()  // the heartbeat first: never render stale state
        // Re-probe only while broken (covers a CLI `awake grant` under a live
        // daemon); once ready, ready. The setup row IS the onboarding: no
        // terminal, one click, the system's own admin sheet.
        if !grantReady { grantReady = Sudoers.works() }
        // The notifier re-reads its reach off-main (an LS launch); the row follows
        // within a menu tick, so returning from System Settings clears it live.
        DispatchQueue.global(qos: .userInitiated).async { Notifier.launch(["--probe"]) }
        menu.removeAllItems()
        for row in menuRows() { menu.addItem(item(row)) }
    }

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
        openStatus = nil
    }

    private func menuTick() {
        guard openStatus != nil else { return }
        refresh(menu.items, menuRows())
    }

    private func menuRows() -> [MenuRow] {
        Menu.rows(
            MenuInput(
                status: openStatus!, now: Date(),
                sudoers: Menu.sudoersStanding(ready: grantReady),
                notifications: NotifierGrant().standing,
                lastMinutes: machine.config.lastMinutes))
    }

    private func item(_ row: MenuRow) -> NSMenuItem {
        guard !row.separator else {
            let s = NSMenuItem.separator()
            s.isHidden = row.hidden
            return s
        }
        let item = NSMenuItem(
            title: row.title, action: row.action == nil ? nil : #selector(rowClicked(_:)),
            keyEquivalent: "")
        item.target = self
        item.representedObject = row.action.map(ActionBox.init)
        style(item, row)
        if let rows = row.submenu {
            let sub = NSMenu()
            for r in rows { sub.addItem(self.item(r)) }
            item.submenu = sub
        }
        return item
    }

    /// Everything about a row that can change while the menu is open. Pressing the
    /// chord with the menu open does what the global hotkey does, so the badge is the
    /// live binding, remaps included.
    private func style(_ item: NSMenuItem, _ row: MenuRow) {
        item.title = row.title
        item.isHidden = row.hidden
        item.toolTip = row.tooltip
        item.state = row.checked ? .on : .off
        let chord = row.toggle ? keymapStore.combos(for: .toggleSession, .global).first : nil
        item.keyEquivalent = chord.map { String($0.keyEquivalent.character) } ?? ""
        item.keyEquivalentModifierMask = chord.map { Self.modifierFlags($0.eventModifiers) } ?? []
    }

    private static func modifierFlags(_ m: EventModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if m.contains(.control) { flags.insert(.control) }
        if m.contains(.option) { flags.insert(.option) }
        if m.contains(.shift) { flags.insert(.shift) }
        if m.contains(.command) { flags.insert(.command) }
        return flags
    }

    /// Redraw in place while the shape holds; a changed shape waits for the next open.
    private func refresh(_ items: [NSMenuItem], _ rows: [MenuRow]) {
        guard items.count == rows.count else { return }
        for (item, row) in zip(items, rows) {
            guard item.isSeparatorItem == row.separator else { return }
            if row.separator {
                item.isHidden = row.hidden
                continue
            }
            style(item, row)
            if let rows = row.submenu, let sub = item.submenu { refresh(sub.items, rows) }
        }
    }

    @objc private func rowClicked(_ sender: NSMenuItem) {
        run(machine.perform((sender.representedObject as! ActionBox).action))
    }

    /// What a gesture leaves for the host.
    private func run(_ effect: Effect?) {
        switch effect {
        case nil: break
        case .offerGrant(let minutes): offerGrant(retryMinutes: minutes)
        case .notify(let message): Daemon.screenNotify(message)
        case .notificationsGrant: NotifierGrant().act()
        case .quit: quit()
        }
    }

    /// The in-app grant flow: the same native admin sheet as `awake grant`,
    /// off-main (osascript blocks until the user decides). Success retries the
    /// gesture that triggered it; cancel is the user's answer and stays quiet.
    private func offerGrant(retryMinutes: Int?) {
        guard !grantInFlight else { return }
        grantInFlight = true
        Task.detached {
            let outcome = Sudoers.installInteractively()
            await MainActor.run {
                let d = Daemon.shared!
                d.grantInFlight = false
                switch outcome {
                case .installed:
                    d.grantReady = true
                    if let minutes = retryMinutes { d.run(d.machine.engageYours(minutes: minutes)) }
                case .cancelled:
                    break
                case .failed(let e):
                    Daemon.screenNotify("setup failed: \(e)")
                }
            }
        }
    }

    private func quit() {
        machine.endAll(.shutdown)
        // Bypass launchd KeepAlive: bootout unloads the agent instead of exit(0),
        // which would just resurrect us. `mise run install` brings it back.
        _ = AwakeKit.run(
            "/bin/launchctl",
            ["bootout", "gui/\(getuid())/\(Paths.launchdLabel)"])
        exit(0)  // only reached if bootout failed (e.g. running outside launchd)
    }

    // MARK: - Notifications

    /// Routes a composed end (Notice) to the screen, and the closed-lid ones (battery
    /// floor, LPM, heat) also out of band through the configured notify hook, sent
    /// BEFORE the flag drops so the push leaves on an awake network stack.
    static func notify(_ reason: EndReason, ended: [Claim], remaining: [Claim]) {
        // Per-claim hooks fire for EVERY reason: the caller asked to know, and
        // "requested" (a human ending it) is exactly the case it cannot see
        // otherwise. Synchronous like the global hook: a closing end must reach
        // its caller before the machine is allowed to sleep.
        for c in ended where !c.onEnd.isEmpty {
            var env = ProcessInfo.processInfo.environment
            env["AWAKE_END_REASON"] = reason.label
            let r = AwakeKit.run(
                "/bin/sh", ["-c", c.onEnd, "awake-on-end", reason.label], env: env)
            if r.status != 0 { log("on-end hook (\(c.owner)) failed: \(r.err)") }
        }
        guard
            let message = Notice.compose(reason, ended: ended, remaining: remaining, now: Date())
        else { return }
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

    /// The floor's second net spoke: out of band always (the display is dark by
    /// construction, nobody sees a banner), screen too for the log of record.
    static func notifyForcedSleep(percent: Int) {
        let message = Notice.forcedSleep(percent: percent)
        screenNotify(message)
        let hook = Daemon.shared.machine.config.notifyCommand
        guard !hook.isEmpty, FileManager.default.isExecutableFile(atPath: hook) else { return }
        let r = AwakeKit.run(hook, ["awake: \(message)"])
        if r.status != 0 { log("notify hook failed: \(r.err)") }
    }

    /// A banner on screen, through the notifier (see `Notifier`).
    static func screenNotify(_ message: String) {
        Notifier.launch([message])
    }
}

/// A MenuAction riding an NSMenuItem's representedObject.
private final class ActionBox: NSObject {
    let action: MenuAction
    init(_ action: MenuAction) { self.action = action }
}
