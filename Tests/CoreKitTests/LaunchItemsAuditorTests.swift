import Foundation
import Testing
@testable import CoreKit

@Suite("LaunchItemsAuditor helpers")
struct LaunchItemsAuditorTests {
    @Test func shellQuoteHandlesSpacesAndSingleQuotes() {
        #expect(LaunchItemsAuditor.quote("/Library/LaunchAgents/com.example.foo.plist")
                == "'/Library/LaunchAgents/com.example.foo.plist'")
        // A path with a single quote must be escaped, not break out of the quoting.
        let quoted = LaunchItemsAuditor.quote("/path/with/'/foo.plist")
        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
        // The dangerous sequence that would close the quoted string early must be escaped.
        #expect(!quoted.contains("''") || quoted.contains("'\\''"))
    }

    @Test func domainTargetsAreDomainAware() {
        let userTarget = LaunchItem.Domain.userAgent.domainTarget(label: "com.example.x")
        #expect(userTarget.hasPrefix("gui/"))
        #expect(userTarget.hasSuffix("/com.example.x"))
        #expect(LaunchItem.Domain.systemDaemon.domainTarget(label: "com.example.d")
                == "system/com.example.d")
        #expect(LaunchItem.Domain.systemAgent.domainTarget(label: "com.example.a")
                == "system/com.example.a")
    }

    @Test func disabledFolderIsPerDomain() {
        let user = LaunchItemsAuditor.disabledFolder(for: .userAgent)
        let daemon = LaunchItemsAuditor.disabledFolder(for: .systemDaemon)
        let agent = LaunchItemsAuditor.disabledFolder(for: .systemAgent)
        #expect(user == LaunchItemsAuditor.disabledFolder)
        #expect(daemon.path.contains("SystemDaemons"))
        #expect(agent.path.contains("SystemAgents"))
        #expect(daemon != agent)
        #expect(daemon != user)
    }

    @Test func allDomainsAreToggleable() {
        for domain in LaunchItem.Domain.allCases {
            #expect(domain.isToggleable)
            #expect(domain.requiresAdmin == (domain != .userAgent))
        }
    }
}