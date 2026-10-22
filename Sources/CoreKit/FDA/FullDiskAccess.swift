import AppKit
import Foundation
import Security

/// Full Disk Access: detection, self-diagnosis, and the fixes the UI offers.
///
/// There is no official "is FDA granted" API, so we probe TCC-protected
/// locations. We actually open/list them rather than using `access(2)`,
/// which can report stale results under TCC; `open(2)` is what TCC gates.
public enum FullDiskAccess {
    public static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Any one readable probe means granted. Two probes so a missing
        // file on some setup can't wedge the app in onboarding forever.
        let tccDB = home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db")
        if let handle = try? FileHandle(forReadingFrom: tccDB) {
            try? handle.close()
            return true
        }
        let safari = home.appending(path: "Library/Safari")
        return (try? FileManager.default.contentsOfDirectory(atPath: safari.path)) != nil
    }

    /// Current state plus everything that explains a denial. Records the
    /// running build's cdhash on success so a later denial can be recognized
    /// as a stale grant left behind by an older build.
    public static func status(defaults: UserDefaults = .standard) -> FDAStatus {
        let granted = isGranted
        let signing = SigningInfo.current()
        if granted, let hash = signing.cdhash {
            defaults.set(hash, forKey: grantedHashKey)
        }
        return FDAStatus(
            granted: granted,
            issues: diagnose(granted: granted, signing: signing,
                             location: AppLocation(path: Bundle.main.bundlePath),
                             lastGrantedCDHash: defaults.string(forKey: grantedHashKey)),
            signing: signing)
    }

    static let grantedHashKey = "MacTidy.fdaGrantedCDHash"

    /// Pure: why access is (or will keep being) a problem, most actionable first.
    public static func diagnose(
        granted: Bool, signing: SigningInfo, location: AppLocation, lastGrantedCDHash: String?
    ) -> [PermissionIssue] {
        var issues: [PermissionIssue] = []
        if location.isTranslocated { issues.append(.translocated) }
        if !location.isAppBundle { issues.append(.notAppBundle) }
        if !granted, signing.isAdHoc, let last = lastGrantedCDHash, last != signing.cdhash {
            issues.append(.staleGrant)
        }
        if signing.isAdHoc { issues.append(.unstableSignature) }
        return issues
    }

    @MainActor
    public static func openSettingsPane() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Removes this app's Full Disk Access record (the stale one macOS keeps
    /// showing as "on") so the user can add the current build fresh. Only
    /// ever revokes, never grants. Nil if tccutil can't be launched.
    public static func resetGrant(bundleID: String) -> Shell.Output? {
        Shell.run("/usr/bin/tccutil", ["reset", "SystemPolicyAllFiles", bundleID])
    }
}

public struct FDAStatus: Sendable, Equatable {
    public let granted: Bool
    public let issues: [PermissionIssue]
    public let signing: SigningInfo

    public init(granted: Bool, issues: [PermissionIssue], signing: SigningInfo) {
        self.granted = granted
        self.issues = issues
        self.signing = signing
    }
}

public enum PermissionIssue: Sendable, Equatable {
    /// macOS runs a quarantined download from a random read-only copy
    /// (App Translocation); grants to that copy don't stick.
    case translocated
    /// Running a bare binary (e.g. `swift run`): TCC attributes access to
    /// the parent terminal, not MacTidy.
    case notAppBundle
    /// A previous build had access. The "MacTidy" row in System Settings is
    /// that old build's record, so the switch shows on but this build is denied.
    case staleGrant
    /// Ad-hoc signed: macOS pins the grant to this exact build, so every
    /// rebuild or update needs it re-granted until `make cert` is run.
    case unstableSignature
}

/// Where the running bundle lives.
public struct AppLocation: Sendable, Equatable {
    public let path: String
    public init(path: String) { self.path = path }
    public var isTranslocated: Bool { path.contains("/AppTranslocation/") }
    public var isAppBundle: Bool { path.hasSuffix(".app") }
}

/// The running code's signature, read from the kernel's view of this process.
public struct SigningInfo: Sendable, Equatable {
    public let identifier: String?
    public let cdhash: String?
    public let isAdHoc: Bool

    public init(identifier: String?, cdhash: String?, isAdHoc: Bool) {
        self.identifier = identifier
        self.cdhash = cdhash
        self.isAdHoc = isAdHoc
    }

    public static func current() -> SigningInfo {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(
                  staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return SigningInfo(identifier: nil, cdhash: nil, isAdHoc: true) }

        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let hash = (dict[kSecCodeInfoUnique as String] as? Data)?
            .map { String(format: "%02x", $0) }.joined()
        return SigningInfo(
            identifier: dict[kSecCodeInfoIdentifier as String] as? String,
            cdhash: hash,
            // Unsigned counts as ad-hoc: same consequence, no stable identity.
            isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || dict[kSecCodeInfoIdentifier as String] == nil)
    }
}
