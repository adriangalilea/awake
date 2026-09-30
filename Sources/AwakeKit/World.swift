import CoreGraphics
import Foundation
import Grant
import IOKit.pwr_mgt

/// Everything the machine reads or changes outside itself. `HostWorld` is this Mac;
/// a scene (`awake-scene`) plays the same engine against a scripted one, so every
/// frame it records is what this code does, never a copy of it.
@MainActor
public protocol World: AnyObject {
    var now: Date { get }
    /// Claims never span a reboot: anything started before this is stale.
    var bootTime: Date { get }
    func power() -> PowerSnapshot
    var thermalCritical: Bool { get }
    /// Kernel start time of a process, nil once it is gone.
    func processStartTime(_ pid: Int32) -> Double?
    var displayAsleep: Bool { get }

    /// The lid flag (pmset disablesleep): read without root, written through the
    /// sudoers grant.
    func sleepDisabled() -> Bool
    func setSleepDisabled(_ on: Bool) -> LidResult
    func sleepNow()
    func createAssertion(_ mode: Mode) -> IOPMAssertionID
    func releaseAssertion(_ id: IOPMAssertionID)

    func loadClaims() -> [Claim]
    func saveClaims(_ claims: [Claim])
    func loadSuspended() -> Date?
    func saveSuspended(_ since: Date?)
    func loadConfig() -> Config
    func saveConfig(_ config: Config)
    /// The notifier's last recorded reach; nil = never recorded.
    func notificationReach() -> NotificationReach?
}

/// This Mac: IOKit, pmset, sysctl, and the state files under `Paths`.
public final class HostWorld: World {
    public init() {}

    public var now: Date { Date() }
    public var bootTime: Date { AwakeKit.bootTime() }
    public func power() -> PowerSnapshot { Battery.snapshot() }
    public var thermalCritical: Bool { ProcessInfo.processInfo.thermalState == .critical }
    public func processStartTime(_ pid: Int32) -> Double? { procStartTime(pid) }
    public var displayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    public func sleepDisabled() -> Bool { Kernel.sleepDisabled() }
    public func setSleepDisabled(_ on: Bool) -> LidResult { Kernel.setSleepDisabled(on) }
    public func sleepNow() {
        let r = run("/usr/bin/pmset", ["sleepnow"])
        if r.status != 0 {
            log(
                "pmset sleepnow failed (\(r.status)): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }
    public func createAssertion(_ mode: Mode) -> IOPMAssertionID { Kernel.createAssertion(mode) }
    public func releaseAssertion(_ id: IOPMAssertionID) { Kernel.releaseAssertion(id) }

    public func loadClaims() -> [Claim] { ClaimStore.load() }
    public func saveClaims(_ claims: [Claim]) { ClaimStore.save(claims) }
    public func loadSuspended() -> Date? { SuspendStore.load() }
    public func saveSuspended(_ since: Date?) { SuspendStore.save(since) }
    public func loadConfig() -> Config { Config.load() }
    public func saveConfig(_ config: Config) { config.save() }
    public func notificationReach() -> NotificationReach? { NotificationStore.load() }
}
