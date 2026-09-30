import AwakeKit
import Foundation
import IOKit.pwr_mgt

import enum Grant.NotificationReach  // scoped: Grant's own Claim would shadow AwakeKit's

/// A Mac that does what the script says. Everything the engine reads comes from
/// here, so a scene is the real machine living through an invented evening.
final class ScriptedWorld: World {
    var now: Date
    let bootTime: Date
    var battery = 80
    var onAC = false
    var lowPower = false
    var thermalCritical = false
    var processes: [Int32: (started: Double, name: String)] = [:]
    var lidClosed = false
    /// The Mac went to sleep (`pmset sleepnow`, or the lid closing with nothing
    /// holding it). Opening the lid wakes it.
    var asleep = false
    var grant = true
    var reach: NotificationReach = .allowed

    private var flag = false
    private var nextAssertion: IOPMAssertionID = 1
    private var claims: [Claim] = []
    private var suspended: Date?
    private var config = Config()

    init(now: Date) {
        self.now = now
        bootTime = now.addingTimeInterval(-86_400)
    }

    func power() -> PowerSnapshot {
        PowerSnapshot(
            hasBattery: true, onAC: onAC, discharging: !onAC, percent: battery,
            lowPowerMode: lowPower)
    }
    func processStartTime(_ pid: Int32) -> Double? { processes[pid]?.started }
    var displayAsleep: Bool { lidClosed || asleep }

    func sleepDisabled() -> Bool { flag }
    func setSleepDisabled(_ on: Bool) -> LidResult {
        guard grant else { return .grantMissing }
        flag = on
        return .ok
    }
    func sleepNow() { asleep = true }
    func createAssertion(_ mode: Mode) -> IOPMAssertionID {
        defer { nextAssertion += 1 }
        return nextAssertion
    }
    func releaseAssertion(_ id: IOPMAssertionID) {}

    func loadClaims() -> [Claim] { claims }
    func saveClaims(_ claims: [Claim]) { self.claims = claims }
    func loadSuspended() -> Date? { suspended }
    func saveSuspended(_ since: Date?) { suspended = since }
    func loadConfig() -> Config { config }
    func saveConfig(_ config: Config) { self.config = config }
    func notificationReach() -> NotificationReach? { reach }
}
