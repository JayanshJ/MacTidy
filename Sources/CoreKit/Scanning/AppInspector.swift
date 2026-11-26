import Foundation

/// Read-only unified inspector for an application bundle: binary architecture
/// (Apple Silicon / Universal / Intel Rosetta 2), signing identity, running
/// processes & listening ports, launch agents, ~/Library data, and privacy
/// usage declarations with System Settings deep links.
public enum AppInspector {
    public enum BinaryArchitecture: String, Sendable, Equatable, CaseIterable {
        case appleSilicon = "Apple Silicon"
        case universal = "Universal"
        case intel = "Intel (Rosetta 2)"
        case unknown = "Unknown"

        public var isIntelOnly: Bool { self == .intel }

        /// Parses the Mach-O header (thin or fat/universal) from the first
        /// bytes of an executable. Pure and unit-testable.
        public static func detect(machOHeader data: Data) -> BinaryArchitecture {
            guard data.count >= 8 else { return .unknown }
            let magicBE = readUInt32BE(data, at: 0)
            let magicLE = readUInt32LE(data, at: 0)

            let cpuARM64: UInt32 = 0x0100_000C
            let cpuX86_64: UInt32 = 0x0100_0007
            let cpuX86: UInt32 = 7

            func classify(_ types: Set<UInt32>) -> BinaryArchitecture {
                let hasARM = types.contains(cpuARM64)
                let hasIntel = types.contains(cpuX86_64) || types.contains(cpuX86)
                switch (hasARM, hasIntel) {
                case (true, true): return .universal
                case (true, false): return .appleSilicon
                case (false, true): return .intel
                case (false, false): return .unknown
                }
            }

            if magicLE == 0xFEED_FACF || magicLE == 0xFEED_FACE {
                return classify([readUInt32LE(data, at: 4)])
            }
            if magicBE == 0xFEED_FACF || magicBE == 0xFEED_FACE {
                return classify([readUInt32BE(data, at: 4)])
            }
            if magicBE == 0xCAFE_BABE || magicBE == 0xCAFE_BABF {
                let entrySize = (magicBE == 0xCAFE_BABF) ? 32 : 20
                let nfat = Int(readUInt32BE(data, at: 4))
                guard (1...16).contains(nfat), data.count >= 8 + nfat * entrySize else {
                    return .unknown
                }
                var types = Set<UInt32>()
                for i in 0..<nfat {
                    types.insert(readUInt32BE(data, at: 8 + i * entrySize))
                }
                return classify(types)
            }
            return .unknown
        }

        public static func detect(appURL: URL) -> BinaryArchitecture {
            let infoURL = appURL.appending(path: "Contents/Info.plist")
            guard let data = try? Data(contentsOf: infoURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let exeName = plist["CFBundleExecutable"] as? String,
                  !exeName.isEmpty else {
                return .unknown
            }
            let exeURL = appURL.appending(path: "Contents/MacOS").appending(path: exeName)
            guard let handle = try? FileHandle(forReadingFrom: exeURL) else { return .unknown }
            defer { try? handle.close() }
            let header = (try? handle.read(upToCount: 512)) ?? Data()
            return detect(machOHeader: header)
        }

        private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
            UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }

        private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
            (UInt32(data[offset]) << 24)
                | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8)
                | UInt32(data[offset + 3])
        }
    }

    public struct PrivacyDeclaration: Identifiable, Sendable, Hashable {
        public let id: String
        public let title: String
        public let reason: String
        public let settingsURL: URL

        public init(id: String, title: String, reason: String, settingsURL: URL) {
            self.id = id
            self.title = title
            self.reason = reason
            self.settingsURL = settingsURL
        }

        private static let knownKeys: [(key: String, title: String, pane: String)] = [
            ("NSCameraUsageDescription", "Camera", "Privacy_Camera"),
            ("NSMicrophoneUsageDescription", "Microphone", "Privacy_Microphone"),
            ("NSAppleEventsUsageDescription", "Automation", "Privacy_Automation"),
            ("NSContactsUsageDescription", "Contacts", "Privacy_Contacts"),
            ("NSCalendarsUsageDescription", "Calendars", "Privacy_Calendars"),
            ("NSCalendarsFullAccessUsageDescription", "Calendars", "Privacy_Calendars"),
            ("NSRemindersUsageDescription", "Reminders", "Privacy_Reminders"),
            ("NSPhotoLibraryUsageDescription", "Photos", "Privacy_Photos"),
            ("NSLocationWhenInUseUsageDescription", "Location Services", "Privacy_LocationServices"),
            ("NSLocationAlwaysUsageDescription", "Location Services", "Privacy_LocationServices"),
            ("NSDesktopFolderUsageDescription", "Desktop Folder", "Privacy_FilesAndFolders"),
            ("NSDocumentsFolderUsageDescription", "Documents Folder", "Privacy_FilesAndFolders"),
            ("NSDownloadsFolderUsageDescription", "Downloads Folder", "Privacy_FilesAndFolders"),
            ("NSSystemAdministrationUsageDescription", "System Administration", "Privacy_AllFiles"),
        ]

        public static func declarations(from infoPlist: [String: Any]) -> [PrivacyDeclaration] {
            var seen = Set<String>()
            var result: [PrivacyDeclaration] = []
            for entry in knownKeys {
                guard let reason = infoPlist[entry.key] as? String else { continue }
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(entry.title).inserted,
                      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(entry.pane)") else {
                    continue
                }
                result.append(PrivacyDeclaration(id: entry.key, title: entry.title, reason: trimmed, settingsURL: url))
            }
            return result
        }
    }

    public struct PrivacyPaneLink: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let symbol: String
        public let url: URL

        public static let standardPanes: [PrivacyPaneLink] = [
            ("Full Disk Access", "externaldrive.badge.checkmark", "Privacy_AllFiles"),
            ("Screen Recording", "rectangle.dashed.badge.record", "Privacy_ScreenCapture"),
            ("Accessibility", "accessibility", "Privacy_Accessibility"),
            ("Camera", "camera", "Privacy_Camera"),
            ("Microphone", "mic", "Privacy_Microphone"),
            ("Automation", "gearshape.2", "Privacy_Automation"),
        ].compactMap { title, symbol, pane in
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return nil }
            return PrivacyPaneLink(id: pane, title: title, symbol: symbol, url: url)
        }
    }

    public struct SigningSummary: Sendable, Equatable {
        public let authority: String?
        public let teamID: String?
        public let isAdHoc: Bool

        public init(authority: String?, teamID: String?, isAdHoc: Bool) {
            self.authority = authority
            self.teamID = teamID
            self.isAdHoc = isAdHoc
        }

        public var label: String {
            if isAdHoc { return "Ad-hoc signed" }
            if let authority { return authority }
            if let teamID { return "Team \(teamID)" }
            return "Signed"
        }

        public static func parseCodesignOutput(_ stderr: String) -> SigningSummary {
            var authority: String?
            var teamID: String?
            var isAdHoc = false
            for raw in stderr.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("Authority=") && authority == nil {
                    let value = String(line.dropFirst("Authority=".count))
                    if !value.isEmpty { authority = value }
                } else if line.hasPrefix("TeamIdentifier=") {
                    let value = String(line.dropFirst("TeamIdentifier=".count))
                    if !value.isEmpty && value != "not set" { teamID = value }
                } else if line == "Signature=adhoc" {
                    isAdHoc = true
                }
            }
            return SigningSummary(authority: authority, teamID: teamID, isAdHoc: isAdHoc)
        }

        public static func read(appURL: URL) -> SigningSummary? {
            guard let output = Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", appURL.path]) else {
                return nil
            }
            let combined = output.stderr.isEmpty ? output.stdout : output.stderr
            guard !combined.isEmpty else { return nil }
            return parseCodesignOutput(combined)
        }
    }

    public struct Report: Identifiable, Sendable {
        public let appURL: URL
        public let name: String
        public let bundleID: String?
        public let version: String?
        public let architecture: BinaryArchitecture
        public let bundleSizeBytes: Int64
        public let dataPaths: [AppFootprint.Path]
        public let runningProcesses: [RunningProcess]
        public let listeningPorts: [PortEntry]
        public let launchItems: [LaunchItem]
        public let privacyDeclarations: [PrivacyDeclaration]
        public let signing: SigningSummary?

        public var id: String { appURL.path }
        public var totalDataBytes: Int64 { dataPaths.reduce(0) { $0 + $1.sizeBytes } }
        public var cpuPercent: Double { runningProcesses.reduce(0) { $0 + $1.cpuPercent } }
        public var memoryBytes: Int64? {
            guard !runningProcesses.isEmpty, runningProcesses.allSatisfy({ $0.physicalFootprintBytes != nil }) else {
                return nil
            }
            return runningProcesses.reduce(0) { $0 + ($1.physicalFootprintBytes ?? 0) }
        }
    }

    public static func inspect(
        appURL: URL,
        processes: [RunningProcess],
        ports: [PortEntry],
        launchItems: [LaunchItem],
        footprints: [AppFootprint]
    ) -> Report {
        let infoURL = appURL.appending(path: "Contents/Info.plist")
        let plist = (try? Data(contentsOf: infoURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]

        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let bundleID = plist["CFBundleIdentifier"] as? String
        let shortVer = plist["CFBundleShortVersionString"] as? String
        let buildVer = plist["CFBundleVersion"] as? String
        let version: String? = switch (shortVer, buildVer) {
        case (let s?, let b?) where s != b && !b.isEmpty: "\(s) (\(b))"
        case (let s?, _): s
        case (_, let b?): b
        default: nil
        }

        let arch = BinaryArchitecture.detect(appURL: appURL)
        let matchedFootprint = footprints.first { $0.app.url.path == appURL.path }
        let bundleSize = matchedFootprint?.app.sizeBytes ?? DiskScanner.allocatedSize(of: appURL)
        let dataPaths = (matchedFootprint?.paths ?? []).sorted { $0.sizeBytes > $1.sizeBytes }

        let procs = processes.filter { $0.appBundlePath == appURL.path }
        let pids = Set(procs.map(\.pid))
        let matchedPorts = ports.filter { pids.contains($0.pid) }
        let matchedLaunch = matchingLaunchItems(appURL: appURL, bundleID: bundleID, launchItems: launchItems)
        let privacy = PrivacyDeclaration.declarations(from: plist)
        let signing = SigningSummary.read(appURL: appURL)

        return Report(
            appURL: appURL,
            name: name,
            bundleID: bundleID,
            version: version,
            architecture: arch,
            bundleSizeBytes: bundleSize,
            dataPaths: dataPaths,
            runningProcesses: procs,
            listeningPorts: matchedPorts,
            launchItems: matchedLaunch,
            privacyDeclarations: privacy,
            signing: signing
        )
    }

    public static func matchingLaunchItems(
        appURL: URL,
        bundleID: String?,
        launchItems: [LaunchItem]
    ) -> [LaunchItem] {
        let bundlePrefix = appURL.path.hasSuffix("/") ? appURL.path : appURL.path + "/"
        return launchItems.filter { item in
            if let exe = item.executablePath, exe.hasPrefix(bundlePrefix) { return true }
            if let bundleID, !bundleID.isEmpty,
               item.label.lowercased().hasPrefix(bundleID.lowercased()) {
                return true
            }
            return false
        }
    }
}
