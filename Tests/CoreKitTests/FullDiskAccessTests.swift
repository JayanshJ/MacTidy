import Foundation
import Testing
@testable import CoreKit

@Suite("Full Disk Access diagnosis")
struct FullDiskAccessTests {
    let app = AppLocation(path: "/Applications/MacTidy.app")
    let adHoc = SigningInfo(identifier: "com.jayansh.mactidy", cdhash: "bbbb", isAdHoc: true)
    let stable = SigningInfo(identifier: "com.jayansh.mactidy", cdhash: "bbbb", isAdHoc: false)

    @Test func cleanStableInstallHasNoIssues() {
        #expect(FullDiskAccess.diagnose(granted: true, signing: stable, location: app,
                                        lastGrantedCDHash: nil).isEmpty)
    }

    /// The bug users hit: an older build was granted, the Settings switch
    /// still shows on, and this rebuilt ad-hoc build is denied.
    @Test func deniedAdHocRebuildAfterEarlierGrantIsStale() {
        let issues = FullDiskAccess.diagnose(granted: false, signing: adHoc, location: app,
                                             lastGrantedCDHash: "aaaa")
        #expect(issues == [.staleGrant, .unstableSignature])
    }

    @Test func sameBuildOrStableSignatureIsNeverStale() {
        #expect(!FullDiskAccess.diagnose(granted: false, signing: adHoc, location: app,
                                         lastGrantedCDHash: "bbbb").contains(.staleGrant))
        #expect(!FullDiskAccess.diagnose(granted: false, signing: stable, location: app,
                                         lastGrantedCDHash: "aaaa").contains(.staleGrant))
        #expect(!FullDiskAccess.diagnose(granted: true, signing: adHoc, location: app,
                                         lastGrantedCDHash: "aaaa").contains(.staleGrant))
    }

    @Test func translocatedAndBareBinaryAreFlagged() {
        let moved = AppLocation(path: "/private/var/folders/x/T/AppTranslocation/ABC/d/MacTidy.app")
        #expect(FullDiskAccess.diagnose(granted: false, signing: stable, location: moved,
                                        lastGrantedCDHash: nil) == [.translocated])
        let bare = AppLocation(path: "/Users/me/MacTidy/.build/release")
        #expect(FullDiskAccess.diagnose(granted: false, signing: stable, location: bare,
                                        lastGrantedCDHash: nil) == [.notAppBundle])
    }

    /// Reads this test process's real signature; SwiftPM output is
    /// linker-signed ad-hoc, so it must come back ad-hoc with a hash.
    @Test func readsOwnSignature() {
        let me = SigningInfo.current()
        #expect(me.isAdHoc)
        #expect(me.cdhash?.count == 40)
    }

    @Test func grantRecordsHashForLaterStaleDetection() throws {
        let defaults = try #require(UserDefaults(suiteName: "mactidy-fda-\(UUID().uuidString)"))
        let status = FullDiskAccess.status(defaults: defaults)
        let recorded = defaults.string(forKey: FullDiskAccess.grantedHashKey)
        // Whatever this machine's FDA state, a hash is recorded iff granted.
        #expect((recorded != nil) == status.granted)
        if status.granted { #expect(recorded == status.signing.cdhash) }
    }
}
