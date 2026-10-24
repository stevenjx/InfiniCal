//
//  Battery.swift
//  Battery / adapter telemetry straight from the IORegistry (AppleSmartBattery).
//  Every field is taken from a documented or empirically verified source:
//    • AppleSmartBattery + AppleSmartBatteryPack  (capacity, cycles, current, voltage)
//    • AdapterDetails                             (charger name / watts / serial)
//    • PowerTelemetryData                         (system load, DC input power)
//    • SMC TB0T                                   (battery temperature, °C)
//

import Foundation
import IOKit

struct AdapterInfo: Equatable {
    var name: String = ""
    var manufacturer: String = ""
    var serial: String = ""
    var model: String = ""
    var watts: Int = 0            // negotiated maximum, W
    var maxVoltage: Double = 0    // V
    var maxCurrent: Double = 0    // A
    var voltage: Double = 0       // measured input voltage, V
    var current: Double = 0       // measured input current, A
    var power: Double = 0         // measured input power, W

    var isEmpty: Bool { name.isEmpty && watts == 0 }
}

struct BatterySnapshot: Equatable {
    var isPresent: Bool = false
    var percentage: Int = 0
    var hardwarePercentage: Int = 0     // SoC straight from the fuel gauge
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var fullyCharged: Bool = false
    var currentCapacity: Int = 0        // mAh
    var maxCapacity: Int = 0            // mAh (raw FCC)
    var designCapacity: Int = 0         // mAh
    var cycleCount: Int = 0
    var voltage: Double = 0             // V
    var amperage: Double = 0            // A, negative while discharging
    /// Instantaneous pack current. `amperage` is the filtered gauge value and
    /// lags real load steps, which is fine for a dashboard but not for
    /// resistance measurement or coulomb counting.
    var instantAmperage: Double = 0     // A, negative while discharging
    var power: Double = 0               // W, negative while discharging
    var temperature: Double = 0         // °C
    var batterySerial: String = ""
    var cellVoltages: [Double] = []     // V per series cell group
    var timeToEmpty: Int? = nil         // minutes
    var timeToFull: Int? = nil          // minutes
    var systemLoad: Double = 0          // W
    var systemPowerIn: Double = 0       // W (DC input)
    var systemVoltageIn: Double = 0     // V
    var systemCurrentIn: Double = 0     // A
    var batteryPower: Double = 0        // W from telemetry
    var adapterEfficiencyLoss: Double = 0
    var adapter: AdapterInfo = AdapterInfo()
    var lowPowerMode: Bool = false
    var timestamp = Date()

    var healthPercent: Int {
        guard designCapacity > 0, maxCapacity > 0 else { return 0 }
        return Int((Double(maxCapacity) / Double(designCapacity) * 100).rounded())
    }

    var conditionText: String {
        if !isPresent { return "—" }
        if healthPercent > 0 && healthPercent < 80 { return "Service Recommended" }
        return "Normal"
    }


    /// Energy currently stored in the pack, in watt-hours.
    /// `mAh / 1000 × V` — the same arithmetic every battery monitor uses.
    var energyWattHours: Double {
        guard currentCapacity > 0, voltage > 0 else { return 0 }
        return Double(currentCapacity) / 1000 * voltage
    }

    /// Hours the machine can run at `power` watts on the charge it has left.
    /// Returns nil when either term is unknown, so the UI can print "—" instead
    /// of inventing a number.
    func remainingHours(atPower power: Double) -> Double? {
        guard power > 0.5, energyWattHours > 0 else { return nil }
        return energyWattHours / power
    }
}

enum BatteryReader {

    static func read() -> BatterySnapshot {
        var snap = BatterySnapshot()
        snap.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        guard let props = registryProperties(for: "AppleSmartBattery") else { return snap }

        snap.isPresent = (props["BatteryInstalled"] as? Bool) ?? true
        snap.percentage = intValue(props["CurrentCapacity"]) ?? 0
        snap.isPluggedIn = (props["ExternalConnected"] as? Bool) ?? false
        snap.isCharging = (props["IsCharging"] as? Bool) ?? false
        snap.fullyCharged = (props["FullyCharged"] as? Bool) ?? false
        snap.cycleCount = intValue(props["CycleCount"]) ?? 0
        snap.voltage = Double(intValue(props["Voltage"]) ?? 0) / 1000.0
        snap.amperage = Double(intValue(props["Amperage"]) ?? 0) / 1000.0
        if snap.amperage == 0, let instant = intValue(props["InstantAmperage"]), instant != 0 {
            snap.amperage = Double(instant) / 1000.0
        }
        snap.instantAmperage = Double(intValue(props["InstantAmperage"]) ?? 0) / 1000.0
        if snap.instantAmperage == 0 { snap.instantAmperage = snap.amperage }
        snap.power = snap.voltage * snap.amperage
        snap.batterySerial = (props["Serial"] as? String) ?? ""

        if let data = props["BatteryData"] as? [String: Any] {
            snap.designCapacity = intValue(data["DesignCapacity"]) ?? 0
            snap.maxCapacity = intValue(data["FullChargeCapacity"]) ?? 0
            snap.currentCapacity = intValue(data["RemainingCapacity"]) ?? 0
            if snap.percentage == 0 { snap.percentage = intValue(data["CurrentCapacity"]) ?? 0 }
            if let cells = data["CellVoltage"] as? [NSNumber], !cells.isEmpty {
                snap.cellVoltages = cells.map { $0.doubleValue / 1000.0 }
            }
        }

        if let remaining = intValue(props["TimeRemaining"]), remaining > 0, remaining != 65535 {
            snap.timeToEmpty = remaining
        }
        if let toEmpty = intValue(props["AvgTimeToEmpty"]), toEmpty > 0, toEmpty != 65535, snap.timeToEmpty == nil {
            snap.timeToEmpty = toEmpty
        }
        if let toFull = intValue(props["AvgTimeToFull"]), toFull > 0, toFull != 65535 {
            snap.timeToFull = toFull
        }

        if let telemetry = props["PowerTelemetryData"] as? [String: Any] {
            snap.systemLoad = Double(intValue(telemetry["SystemLoad"]) ?? 0) / 1000.0
            snap.systemPowerIn = Double(intValue(telemetry["SystemPowerIn"]) ?? 0) / 1000.0
            snap.systemVoltageIn = Double(intValue(telemetry["SystemVoltageIn"]) ?? 0) / 1000.0
            snap.systemCurrentIn = Double(intValue(telemetry["SystemCurrentIn"]) ?? 0) / 1000.0
            snap.batteryPower = Double(intValue(telemetry["BatteryPower"]) ?? 0) / 1000.0
            snap.adapterEfficiencyLoss = Double(intValue(telemetry["AdapterEfficiencyLoss"]) ?? 0) / 1000.0
        }
        if snap.batteryPower == 0 && snap.amperage != 0 {
            snap.batteryPower = snap.power
        }

        if let adapter = props["AdapterDetails"] as? [String: Any], !adapter.isEmpty {
            var info = AdapterInfo()
            info.name = (adapter["Name"] as? String) ?? ""
            info.manufacturer = (adapter["Manufacturer"] as? String) ?? ""
            info.serial = (adapter["SerialString"] as? String) ?? ""
            info.model = (adapter["Model"] as? String) ?? ""
            info.watts = intValue(adapter["Watts"]) ?? 0
            info.maxVoltage = Double(intValue(adapter["AdapterVoltage"]) ?? 0) / 1000.0
            info.maxCurrent = Double(intValue(adapter["Current"]) ?? 0) / 1000.0
            info.voltage = snap.systemVoltageIn
            info.current = snap.systemCurrentIn
            info.power = snap.systemPowerIn
            snap.adapter = info
        }

        // Pack level data: raw capacity and the fuel gauge temperature.
        if let pack = registryProperties(for: "AppleSmartBatteryPack"),
           let data = pack["BatteryData"] as? [String: Any] {
            if let rawMax = intValue(data["AppleRawMaxCapacity"]), rawMax > 0 {
                snap.maxCapacity = rawMax
            }
            if let rawNow = intValue(data["AppleRawCurrentCapacity"]), rawNow > 0 {
                snap.currentCapacity = rawNow
            }
            if let soc = intValue(data["StateOfCharge"]), soc > 0 {
                snap.hardwarePercentage = soc
            }
            if snap.cellVoltages.isEmpty, let cells = data["CellVoltage"] as? [NSNumber], !cells.isEmpty {
                snap.cellVoltages = cells.map { $0.doubleValue / 1000.0 }
            }
            if let temp = intValue(data["Temperature"]), temp > 0 {
                // Fuel gauge reports centi-degrees Celsius on Apple Silicon.
                snap.temperature = Double(temp) / 100.0
            }
        }
        if snap.hardwarePercentage == 0 { snap.hardwarePercentage = snap.percentage }

        // SMC battery temperature is the value Apple's own UI agrees with.
        if let t = try? SMC.shared.readDouble("TB0T"), t > -20, t < 120 {
            snap.temperature = t
        }
        return snap
    }

    // MARK: - IORegistry helpers

    static func registryProperties(for className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return dictionary
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? Int64 { return Int(n) }
        if let n = any as? Int32 { return Int(n) }
        if let n = any as? UInt32 { return Int(n) }
        if let n = any as? UInt64 { return Int(n) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
