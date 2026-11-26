import Foundation
import Testing
@testable import CoreKit

@Suite("SystemVitals")
struct SystemVitalsTests {
    @Test func cpuTicksUsagePercentComputesDelta() {
        let prev = SystemVitals.CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let cur = SystemVitals.CPUTicks(user: 140, system: 60, idle: 1000, nice: 0)
        // Busy delta = 40 + 10 = 50, total delta = 50 + 150 = 200 -> 25%.
        let pct = SystemVitals.CPUTicks.usagePercent(previous: prev, current: cur)
        #expect(pct == 25.0)
    }

    @Test func cpuTicksUsagePercentRejectsZeroOrNegativeDelta() {
        let prev = SystemVitals.CPUTicks(user: 200, system: 50, idle: 1000, nice: 0)
        #expect(SystemVitals.CPUTicks.usagePercent(previous: prev, current: prev) == nil)
        let wrapped = SystemVitals.CPUTicks(user: 100, system: 50, idle: 1000, nice: 0)
        #expect(SystemVitals.CPUTicks.usagePercent(previous: prev, current: wrapped) == nil)
    }

    @Test func batteryParseReadsAppleSiliconRegistry() {
        let registry: [String: Any] = [
            "CurrentCapacity": 44,
            "MaxCapacity": 100,
            "ExternalConnected": false,
            "IsCharging": false,
            "CycleCount": 98,
            "DesignCycleCount9C": 1000,
            "BatteryData": [
                "DesignCapacity": 4629,
                "AppleRawMaxCapacity": 4537,
                "AvgTimeToEmpty": 213,
                "FullyCharged": false,
            ] as [String: Any],
        ]
        let batt = SystemVitals.BatteryVitals.parse(registry: registry)
        #expect(batt != nil)
        #expect(batt?.chargePercent == 44)
        #expect(batt?.isPluggedIn == false)
        #expect(batt?.isCharging == false)
        #expect(batt?.cycleCount == 98)
        #expect(batt?.designCycleCount == 1000)
        #expect(batt?.designCapacityMAh == 4629)
        #expect(batt?.maxCapacityMAh == 4537)
        #expect(batt?.healthPercent == 98)
        #expect(batt?.timeRemainingMinutes == 213)
        #expect(batt?.adapterWatts == nil)
    }

    @Test func batteryParseReadsChargingAdapterAndPowerSource() {
        let registry: [String: Any] = [
            "CurrentCapacity": 80,
            "MaxCapacity": 100,
            "ExternalConnected": true,
            "IsCharging": true,
            "CycleCount": 12,
            "DesignCapacity": 5000,
            "AppleRawMaxCapacity": 4950,
            "AdapterDetails": ["Watts": 70] as [String: Any],
        ]
        let powerSource: [String: Any] = [
            "Current Capacity": 80,
            "Max Capacity": 100,
            "Time to Full Charge": 28,
        ]
        let batt = SystemVitals.BatteryVitals.parse(registry: registry, powerSource: powerSource)
        #expect(batt?.isPluggedIn == true)
        #expect(batt?.isCharging == true)
        #expect(batt?.adapterWatts == 70)
        #expect(batt?.timeRemainingMinutes == 28)
        #expect(batt?.healthPercent == 99)
    }

    @Test func batteryParseReturnsNilWhenEmpty() {
        #expect(SystemVitals.BatteryVitals.parse(registry: [:]) == nil)
    }

    @Test func thermalLevelOrdering() {
        #expect(SystemVitals.ThermalLevel.nominal < .fair)
        #expect(SystemVitals.ThermalLevel.fair < .serious)
        #expect(SystemVitals.ThermalLevel.serious < .critical)
    }

    @Test func runningAppCPUAndGracefulQuitGuards() {
        let processes = [
            RunningProcess(pid: 1, name: "Helper", appBundlePath: "/Applications/Heavy.app",
                           residentBytes: 100, cpuPercent: 45.5, idleSeconds: 0, physicalFootprintBytes: 200_000_000),
            RunningProcess(pid: 2, name: "Heavy", appBundlePath: "/Applications/Heavy.app",
                           residentBytes: 100, cpuPercent: 12.5, idleSeconds: 0, physicalFootprintBytes: 300_000_000),
            RunningProcess(pid: 3, name: "Finder", appBundlePath: "/System/Library/CoreServices/Finder.app",
                           residentBytes: 100, cpuPercent: 2.0, idleSeconds: 0, physicalFootprintBytes: 900_000_000),
            RunningProcess(pid: 4, name: "MacTidy", appBundlePath: "/Applications/MacTidy.app",
                           residentBytes: 100, cpuPercent: 1.0, idleSeconds: 0, physicalFootprintBytes: 100_000_000),
        ]
        let top = RunningAppMemory.topByCPU(processes)
        #expect(top.first?.name == "Heavy")
        #expect(top.first?.cpuPercent == 58.0)
        #expect(top.first?.canQuitGracefully == true)

        let finder = top.first { $0.name == "Finder" }
        #expect(finder?.canQuitGracefully == false)

        let macTidy = top.first { $0.name == "MacTidy" }
        #expect(macTidy?.canQuitGracefully == false)
    }

    @Test func liveSampleReadsCPUCoreCount() {
        let (snapshot, ticks) = SystemVitals.sample()
        #expect(snapshot.cpu.coreCount > 0)
        #expect(ticks != nil)
    }
}
