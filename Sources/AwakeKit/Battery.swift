import Foundation
import IOKit.ps

public struct PowerSnapshot: Codable, Equatable, Sendable {
    public let hasBattery: Bool
    public let onAC: Bool
    public let discharging: Bool
    public let percent: Int
    public let lowPowerMode: Bool
}

public enum Battery {
    /// One IOPS read. Desktop Macs (no battery) report hasBattery=false and every
    /// battery-based guard becomes a no-op.
    public static func snapshot() -> PowerSnapshot {
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
            let source = list.first,
            let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
        else {
            return PowerSnapshot(
                hasBattery: false, onAC: true, discharging: false,
                percent: 100, lowPowerMode: lpm)
        }
        let state = desc[kIOPSPowerSourceStateKey] as? String
        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
        let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        precondition(max > 0, "IOPS max capacity is 0")
        let onAC = state == kIOPSACPowerValue
        return PowerSnapshot(
            hasBattery: true,
            onAC: onAC,
            discharging: !onAC && !charging,
            percent: current * 100 / max,
            lowPowerMode: lpm)
    }
}
