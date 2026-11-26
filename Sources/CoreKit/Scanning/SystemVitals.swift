import Foundation
import Darwin
import IOKit
import IOKit.ps

/// Honest, read-only system vitals: CPU load, thermal pressure, and battery
/// health. Every field degrades gracefully when unavailable (e.g. battery is
/// nil on desktop Macs).
public enum SystemVitals {
    public enum ThermalLevel: String, Sendable, Comparable, CaseIterable {
        case nominal, fair, serious, critical

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rank < rhs.rank
        }

        private var rank: Int {
            switch self {
            case .nominal: 0
            case .fair: 1
            case .serious: 2
            case .critical: 3
            }
        }

        public var displayName: String {
            switch self {
            case .nominal: "Nominal"
            case .fair: "Fair"
            case .serious: "Serious"
            case .critical: "Critical"
            }
        }

        public var summary: String {
            switch self {
            case .nominal: "Cool and quiet — no thermal throttling."
            case .fair: "Warm under load; performance is normal."
            case .serious: "Hot — fans running high or throttling likely."
            case .critical: "Critical heat — macOS is throttling performance."
            }
        }

        public init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: self = .nominal
            }
        }
    }

    public struct CPUTicks: Sendable, Equatable {
        public let user: UInt64
        public let system: UInt64
        public let idle: UInt64
        public let nice: UInt64

        public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
            self.user = user
            self.system = system
            self.idle = idle
            self.nice = nice
        }

        public static func read() -> CPUTicks? {
            var cpuCount: natural_t = 0
            var cpuInfo: processor_info_array_t?
            var cpuInfoCount: mach_msg_type_number_t = 0
            let kr = host_processor_info(
                mach_host_self(),
                PROCESSOR_CPU_LOAD_INFO,
                &cpuCount,
                &cpuInfo,
                &cpuInfoCount
            )
            guard kr == KERN_SUCCESS, let info = cpuInfo else { return nil }
            defer {
                let byteCount = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), byteCount)
            }

            var user: UInt64 = 0
            var system: UInt64 = 0
            var idle: UInt64 = 0
            var nice: UInt64 = 0
            let stride = Int(CPU_STATE_MAX)
            for core in 0..<Int(cpuCount) {
                let base = core * stride
                guard base + Int(CPU_STATE_NICE) < Int(cpuInfoCount) else { break }
                user += UInt64(bitPattern: Int64(info[base + Int(CPU_STATE_USER)]))
                system += UInt64(bitPattern: Int64(info[base + Int(CPU_STATE_SYSTEM)]))
                idle += UInt64(bitPattern: Int64(info[base + Int(CPU_STATE_IDLE)]))
                nice += UInt64(bitPattern: Int64(info[base + Int(CPU_STATE_NICE)]))
            }
            return CPUTicks(user: user, system: system, idle: idle, nice: nice)
        }

        /// Aggregate CPU utilization (0...100) across all cores between two samples.
        public static func usagePercent(previous: CPUTicks, current: CPUTicks) -> Double? {
            guard current.user >= previous.user,
                  current.system >= previous.system,
                  current.idle >= previous.idle,
                  current.nice >= previous.nice else { return nil }
            let dUser = current.user - previous.user
            let dSystem = current.system - previous.system
            let dIdle = current.idle - previous.idle
            let dNice = current.nice - previous.nice
            let total = dUser + dSystem + dIdle + dNice
            guard total > 0 else { return nil }
            let busy = dUser + dSystem + dNice
            return min(100, max(0, (Double(busy) / Double(total)) * 100))
        }
    }

    public struct CPUVitals: Sendable, Equatable {
        public let usagePercent: Double?
        public let load1m: Double
        public let load5m: Double
        public let load15m: Double
        public let coreCount: Int
        public let uptimeSeconds: TimeInterval
        public let chipName: String?

        public init(
            usagePercent: Double?,
            load1m: Double,
            load5m: Double,
            load15m: Double,
            coreCount: Int,
            uptimeSeconds: TimeInterval,
            chipName: String?
        ) {
            self.usagePercent = usagePercent
            self.load1m = load1m
            self.load5m = load5m
            self.load15m = load15m
            self.coreCount = coreCount
            self.uptimeSeconds = uptimeSeconds
            self.chipName = chipName
        }
    }

    public struct BatteryVitals: Sendable, Equatable {
        public let chargePercent: Int
        public let isCharging: Bool
        public let isPluggedIn: Bool
        public let isFullyCharged: Bool
        public let cycleCount: Int?
        public let designCycleCount: Int?
        public let designCapacityMAh: Int?
        public let maxCapacityMAh: Int?
        public let adapterWatts: Int?
        public let timeRemainingMinutes: Int?

        public init(
            chargePercent: Int,
            isCharging: Bool,
            isPluggedIn: Bool,
            isFullyCharged: Bool,
            cycleCount: Int? = nil,
            designCycleCount: Int? = nil,
            designCapacityMAh: Int? = nil,
            maxCapacityMAh: Int? = nil,
            adapterWatts: Int? = nil,
            timeRemainingMinutes: Int? = nil
        ) {
            self.chargePercent = chargePercent
            self.isCharging = isCharging
            self.isPluggedIn = isPluggedIn
            self.isFullyCharged = isFullyCharged
            self.cycleCount = cycleCount
            self.designCycleCount = designCycleCount
            self.designCapacityMAh = designCapacityMAh
            self.maxCapacityMAh = maxCapacityMAh
            self.adapterWatts = adapterWatts
            self.timeRemainingMinutes = timeRemainingMinutes
        }

        /// Percentage of original design capacity still held (0...100).
        public var healthPercent: Int? {
            guard let max = maxCapacityMAh, let design = designCapacityMAh, design > 0 else { return nil }
            return min(100, Swift.max(0, Int((Double(max) / Double(design) * 100).rounded())))
        }

        /// Pure parser from `AppleSmartBattery` registry properties and optional
        /// `IOPSGetPowerSourceDescription` dictionary. Returns nil when no battery
        /// is present (e.g. desktop Macs).
        public static func parse(registry: [String: Any], powerSource: [String: Any]? = nil) -> BatteryVitals? {
            let batteryData = registry["BatteryData"] as? [String: Any]
            let psCurrent = intValue(powerSource?[kIOPSCurrentCapacityKey as String])
            let psMax = intValue(powerSource?[kIOPSMaxCapacityKey as String])

            let rawCurrent = intValue(registry["CurrentCapacity"]) ?? intValue(batteryData?["CurrentCapacity"])
            let rawMax = intValue(registry["MaxCapacity"]) ?? intValue(batteryData?["MaxCapacity"])

            let chargePercent: Int
            if let cur = psCurrent, let max = psMax, max > 0 {
                chargePercent = min(100, Swift.max(0, Int((Double(cur) / Double(max) * 100).rounded())))
            } else if let cur = rawCurrent, let max = rawMax, max > 0 {
                chargePercent = min(100, Swift.max(0, Int((Double(cur) / Double(max) * 100).rounded())))
            } else if let cur = rawCurrent, (0...100).contains(cur) {
                chargePercent = cur
            } else {
                return nil
            }

            let isPluggedIn = boolValue(registry["ExternalConnected"])
                ?? ((powerSource?[kIOPSPowerSourceStateKey as String] as? String) == kIOPSACPowerValue)
            let isCharging = boolValue(registry["IsCharging"])
                ?? boolValue(powerSource?[kIOPSIsChargingKey as String])
                ?? false
            let isFullyCharged = boolValue(registry["FullyCharged"])
                ?? boolValue(batteryData?["FullyCharged"])
                ?? boolValue(powerSource?[kIOPSIsChargedKey as String])
                ?? (isPluggedIn && !isCharging && chargePercent >= 99)

            let cycleCount = intValue(registry["CycleCount"])
            let designCycleCount = intValue(registry["DesignCycleCount9C"])

            // Apple Silicon nests mAh capacity inside BatteryData; Intel often
            // puts AppleRawMaxCapacity & DesignCapacity at the top level.
            let designCap = intValue(batteryData?["DesignCapacity"]) ?? intValue(registry["DesignCapacity"])
            let maxCap = intValue(batteryData?["AppleRawMaxCapacity"])
                ?? intValue(batteryData?["FullChargeCapacity"])
                ?? intValue(registry["AppleRawMaxCapacity"])
                ?? intValue(registry["NominalChargeCapacity"])

            let adapterDetails = registry["AdapterDetails"] as? [String: Any]
            let watts = intValue(adapterDetails?["Watts"]).flatMap { $0 > 0 ? $0 : nil }

            let psTimeKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let psMinutes = intValue(powerSource?[psTimeKey as String])
            let avgEmpty = intValue(batteryData?["AvgTimeToEmpty"]) ?? intValue(registry["AvgTimeToEmpty"])
            let rawMinutes = psMinutes ?? (!isPluggedIn ? avgEmpty : nil)
            let timeMinutes = rawMinutes.flatMap { ($0 > 0 && $0 < 6000) ? $0 : nil }

            return BatteryVitals(
                chargePercent: chargePercent,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                isFullyCharged: isFullyCharged,
                cycleCount: cycleCount,
                designCycleCount: designCycleCount,
                designCapacityMAh: designCap,
                maxCapacityMAh: maxCap,
                adapterWatts: isPluggedIn ? watts : nil,
                timeRemainingMinutes: timeMinutes
            )
        }

        private static func intValue(_ value: Any?) -> Int? {
            if let i = value as? Int { return i }
            if let n = value as? NSNumber { return n.intValue }
            return nil
        }

        private static func boolValue(_ value: Any?) -> Bool? {
            if let b = value as? Bool { return b }
            if let n = value as? NSNumber { return n.boolValue }
            return nil
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public let cpu: CPUVitals
        public let thermal: ThermalLevel
        public let battery: BatteryVitals?
        public let capturedAt: Date

        public init(cpu: CPUVitals, thermal: ThermalLevel, battery: BatteryVitals?, capturedAt: Date = Date()) {
            self.cpu = cpu
            self.thermal = thermal
            self.battery = battery
            self.capturedAt = capturedAt
        }
    }

    /// Reads current CPU, thermal, and battery telemetry. Pass the previous
    /// `CPUTicks` to compute percentage CPU usage over the interval.
    public static func sample(previousTicks: CPUTicks? = nil) -> (snapshot: Snapshot, ticks: CPUTicks?) {
        let ticks = CPUTicks.read()
        let usage: Double? = if let prev = previousTicks, let cur = ticks {
            CPUTicks.usagePercent(previous: prev, current: cur)
        } else {
            nil
        }
        var loads = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loads, 3)
        let cpu = CPUVitals(
            usagePercent: usage,
            load1m: loadCount >= 1 ? loads[0] : 0,
            load5m: loadCount >= 2 ? loads[1] : 0,
            load15m: loadCount >= 3 ? loads[2] : 0,
            coreCount: ProcessInfo.processInfo.processorCount,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            chipName: chipBrand()
        )
        let thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
        let battery = readBattery()
        return (Snapshot(cpu: cpu, thermal: thermal, battery: battery), ticks)
    }

    public static func readBattery() -> BatteryVitals? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return BatteryVitals.parse(registry: props, powerSource: primaryPowerSource())
    }

    private static func primaryPowerSource() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in list {
            if let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
               (desc[kIOPSTypeKey as String] as? String) == kIOPSInternalBatteryType {
                return desc
            }
        }
        return nil
    }

    private static func chipBrand() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let raw = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}
