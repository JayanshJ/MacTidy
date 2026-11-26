import Foundation
import Testing
@testable import CoreKit

@Suite("AppInspector and Broken Launch Items")
struct AppInspectorTests {
    private func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    @Test func detectsThinARM64MachO() {
        var bytes = le32(0xFEED_FACF) + le32(0x0100_000C)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))
        #expect(AppInspector.BinaryArchitecture.detect(machOHeader: Data(bytes)) == .appleSilicon)
    }

    @Test func detectsThinIntel64MachO() {
        var bytes = le32(0xFEED_FACF) + le32(0x0100_0007)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))
        #expect(AppInspector.BinaryArchitecture.detect(machOHeader: Data(bytes)) == .intel)
    }

    @Test func detectsUniversalFatMachO() {
        var bytes = be32(0xCAFE_BABE) + be32(2)
        // Fat arch 0: x86_64 (20 bytes per fat_arch)
        bytes += be32(0x0100_0007) + [UInt8](repeating: 0, count: 16)
        // Fat arch 1: arm64
        bytes += be32(0x0100_000C) + [UInt8](repeating: 0, count: 16)
        #expect(AppInspector.BinaryArchitecture.detect(machOHeader: Data(bytes)) == .universal)
    }

    @Test func ignoresJavaClassWithCafeBabeHeader() {
        let bytes = be32(0xCAFE_BABE) + be32(61) + [UInt8](repeating: 0, count: 64)
        #expect(AppInspector.BinaryArchitecture.detect(machOHeader: Data(bytes)) == .unknown)
    }

    @Test func parsesPrivacyDeclarationsAndDeduplicates() {
        let plist: [String: Any] = [
            "NSCameraUsageDescription": "Used for video calls.",
            "NSMicrophoneUsageDescription": "   ",
            "NSLocationWhenInUseUsageDescription": "Find nearby devices.",
            "NSLocationAlwaysUsageDescription": "Background location.",
        ]
        let decls = AppInspector.PrivacyDeclaration.declarations(from: plist)
        #expect(decls.count == 2)
        #expect(decls.map(\.title) == ["Camera", "Location Services"])
        #expect(decls.first?.settingsURL.scheme == "x-apple.systempreferences")
    }

    @Test func parsesCodesignOutput() {
        let signed = """
        Executable=/Applications/Example.app/Contents/MacOS/Example
        Authority=Developer ID Application: Example Corp (ABCD123456)
        Authority=Developer ID Certification Authority
        TeamIdentifier=ABCD123456
        """
        let summary = AppInspector.SigningSummary.parseCodesignOutput(signed)
        #expect(summary.isAdHoc == false)
        #expect(summary.teamID == "ABCD123456")
        #expect(summary.authority == "Developer ID Application: Example Corp (ABCD123456)")

        let adhoc = "Signature=adhoc\nTeamIdentifier=not set\n"
        let adhocSummary = AppInspector.SigningSummary.parseCodesignOutput(adhoc)
        #expect(adhocSummary.isAdHoc == true)
        #expect(adhocSummary.teamID == nil)
    }

    @Test func matchesLaunchItemsByBundlePathOrLabel() {
        let appURL = URL(fileURLWithPath: "/Applications/Acme.app")
        let items = [
            LaunchItem(url: URL(fileURLWithPath: "/tmp/a.plist"), label: "com.acme.helper",
                       program: "/usr/local/bin/helper", executablePath: "/usr/local/bin/helper",
                       executableExists: false, runAtLoad: true, isLoaded: false, domain: .userAgent),
            LaunchItem(url: URL(fileURLWithPath: "/tmp/b.plist"), label: "org.other.agent",
                       program: "/Applications/Acme.app/Contents/Library/LoginItems/Launcher",
                       executablePath: "/Applications/Acme.app/Contents/Library/LoginItems/Launcher",
                       executableExists: true, runAtLoad: true, isLoaded: true, domain: .userAgent),
            LaunchItem(url: URL(fileURLWithPath: "/tmp/c.plist"), label: "com.unrelated.app",
                       program: "/Applications/Other.app/Contents/MacOS/Other",
                       executablePath: "/Applications/Other.app/Contents/MacOS/Other",
                       executableExists: true, runAtLoad: false, isLoaded: false, domain: .userAgent),
        ]
        let matched = AppInspector.matchingLaunchItems(appURL: appURL, bundleID: "com.acme", launchItems: items)
        #expect(matched.count == 2)
        #expect(matched.first?.isBroken == true)
    }

    @Test func launchItemsExecutablePathAndBrokenCheck() {
        let plistWithArgs: [String: Any] = [
            "Label": "com.test.agent",
            "ProgramArguments": ["/Applications/Missing.app/Contents/MacOS/Agent", "--background"],
        ]
        let exe = LaunchItemsAuditor.parseExecutablePath(plist: plistWithArgs)
        #expect(exe == "/Applications/Missing.app/Contents/MacOS/Agent")
        #expect(LaunchItemsAuditor.checkExecutableExists(path: exe) { _ in false } == false)
        #expect(LaunchItemsAuditor.checkExecutableExists(path: exe) { _ in true } == true)
        #expect(LaunchItemsAuditor.checkExecutableExists(path: "open") { _ in false } == nil)
    }
}
