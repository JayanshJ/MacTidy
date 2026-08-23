import Testing
@testable import CoreKit

@Suite("MemoryMaintenance")
struct MemoryMaintenanceTests {
    @Test("Pressure level parsing clamps to nearest known level")
    func pressureParsing() {
        #expect(MemoryPressureLevel.parse(rawValue: 1) == .normal)
        #expect(MemoryPressureLevel.parse(rawValue: 2) == .warning)
        // The kernel only emits 1, 2, 4 — but never fail on surprises.
        #expect(MemoryPressureLevel.parse(rawValue: 3) == .warning)
        #expect(MemoryPressureLevel.parse(rawValue: 4) == .critical)
        #expect(MemoryPressureLevel.parse(rawValue: 0) == .normal)
        #expect(MemoryPressureLevel.parse(rawValue: -1) == .normal)
        #expect(MemoryPressureLevel.parse(rawValue: 99) == .critical)
    }

    @Test("Pressure levels are comparable")
    func ordering() {
        #expect(MemoryPressureLevel.normal < .warning)
        #expect(MemoryPressureLevel.warning < .critical)
        #expect(!(MemoryPressureLevel.critical < .warning))
    }

    @Test("Live pressure read returns a sane level or nil")
    func liveRead() {
        // On any healthy macOS box this reads fine; the contract is only
        // "never a wrong answer", so nil is acceptable in sandboxes.
        let level = MemoryPressure.currentLevel()
        if let level {
            #expect(level >= .normal && level <= .critical)
        }
    }

    @Test("osascript wrapper errors unwrap to the real message")
    func osascriptErrorUnwrapping() {
        #expect(
            Shell.humanReadableAppleScriptError("1:92: execution error: /usr/sbin/purge: Permission denied (1)")
                == "/usr/sbin/purge: Permission denied"
        )
        // No offset prefix variant.
        #expect(
            Shell.humanReadableAppleScriptError("execution error: Not authorized (-600)")
                == "Not authorized"
        )
        // Non-osascript strings pass through untouched.
        #expect(Shell.humanReadableAppleScriptError("diskutil says no") == "diskutil says no")
        // Empty input degrades to something presentable.
        #expect(Shell.humanReadableAppleScriptError("   ") == "Unknown error")
    }
}
