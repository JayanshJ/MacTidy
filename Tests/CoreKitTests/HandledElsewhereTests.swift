import Darwin
import Foundation
import Testing
@testable import CoreKit

@Suite("Handled elsewhere: rules, scan, one owner per byte")
struct HandledElsewhereTests {
    let fm = FileManager.default

    func makeHome() throws -> URL {
        let home = fm.temporaryDirectory.appending(path: "mactidy-elsewhere-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "Library/Application Support"), withIntermediateDirectories: true)
        return home
    }

    func fill(_ home: URL, _ path: String, bytes: Int = 1_200_000) throws {
        let dir = home.appending(path: path)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: dir.appending(path: "data.bin"))
    }

    func file(_ home: URL, _ path: String, bytes: Int = 1_200_000) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    func scan(_ home: URL, fullDiskAccess: Bool = true) -> [ScanItem] {
        HandledElsewhereScanner.items(home: home, fullDiskAccess: fullDiskAccess, minimumBytes: 1_000_000)
    }

    /// Every path the brief names, one fixture each.
    func fillEverything(_ home: URL) throws {
        try fill(home, "Library/Application Support/Steam/steamapps/common/Elden Ring")
        try fill(home, "Library/Application Support/Steam/steamapps/common/Hades")
        try file(home, "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        try fill(home, "Library/Group Containers/HUAQ24HBR6.dev.orbstack/data")
        try fill(home, "Library/Containers/com.utmapp.UTM/Data/Documents/Ubuntu.utm")
        try fill(home, "Parallels")
        try fill(home, "VirtualBox VMs")
        try fill(home, ".vagrant.d/boxes")
        try fill(home, ".minikube")
        try fill(home, "Library/Application Support/multipassd")
        try fill(home, "Library/Messages/Attachments")
        try fill(home, "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media")
        try fill(home, "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram")
        try fill(home, "Library/Application Support/Telegram Desktop/tdata/user_data")
        try fill(home, "Library/Mobile Documents")
    }

    // MARK: Scan

    @Test func everyRuleFindsItsPathAndGamesAreRowsOfTheirOwn() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fillEverything(home)

        let items = scan(home)
        #expect(Set(items.compactMap(\.finding)) == Set(HandledElsewhere.rules.map(\.id)))
        let games = items.filter { $0.finding == "steamGames" }.map(\.url.lastPathComponent)
        #expect(Set(games) == ["Elden Ring", "Hades"])
        #expect(items.first { $0.finding == "dockerDisk" }?.isDirectory == false)
    }

    @Test func itemsCanNeverBeSelectedInBulk() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fillEverything(home)
        for item in scan(home) {
            #expect(item.category == nil)
            #expect(!item.isPreselectable)
            #expect(HandledElsewhere.rule(for: item) != nil)
        }
    }

    @Test func wildcardsMatchOnlyTheirOwnNames() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "Library/Containers/com.utmapp.UTM/Data/Documents/Notes")
        try fill(home, "Library/Group Containers/ABC.other.app/data")
        try fill(home, "Library/Group Containers/ABC.dev.orbstack/logs")
        #expect(scan(home).isEmpty)
    }

    @Test func missingPathsAndSmallItemsProduceNoRows() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, ".minikube", bytes: 100)
        #expect(scan(home).isEmpty)
    }

    @Test func unreadablePathsAreSkippedSilently() throws {
        let home = try makeHome()
        let locked = home.appending(path: "Library/Containers/com.utmapp.UTM/Data/Documents")
        try fill(home, "Library/Containers/com.utmapp.UTM/Data/Documents/Ubuntu.utm")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: home)
        }
        #expect(scan(home).isEmpty)
    }

    @Test func linksAreNotFollowed() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "elsewhere/vms")
        try fm.createSymbolicLink(at: home.appending(path: "Parallels"), withDestinationURL: home.appending(path: "elsewhere/vms"))
        #expect(scan(home).isEmpty)
    }

    @Test func withoutFullDiskAccessPrivacyProtectedTreesAreLeftAlone() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fillEverything(home)

        let items = scan(home, fullDiskAccess: false)
        #expect(Set(items.compactMap(\.finding)) == ["steamGames", "parallels", "virtualBox", "vagrant", "minikube", "multipass", "telegramDesktop"])
        #expect(!items.contains { path in
            ["Library/Containers", "Library/Group Containers", "Library/Messages", "Library/Mobile Documents"]
                .contains { path.url.path.contains("/" + $0 + "/") || path.url.path.hasSuffix("/" + $0) }
        })
    }

    @Test func ignoredPathsStayHidden() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, ".minikube")
        try fill(home, "Parallels")
        let ignore = IgnoreList(paths: [home.appending(path: ".minikube").path])
        let items = await CategoryScanner(home: home, devRoots: [], ignore: ignore)
            .handledElsewhereItems(fullDiskAccess: true, minimumBytes: 1_000_000)
        #expect(items.compactMap(\.finding) == ["parallels"])
    }

    @Test func walkingWithoutMaterializingKeepsSizesAndRestoresThePolicy() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "Library/Mobile Documents/a/b")
        let root = home.appending(path: "Library/Mobile Documents").path
        #expect(BulkWalker.allocatedSizes(of: [root], materializingDataless: false)
                == BulkWalker.allocatedSizes(of: [root]))

        let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        var inside: Int32 = -1
        BulkWalker.withoutMaterializingDataless {
            inside = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        }
        #expect(inside == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == before)
    }

    // MARK: One owner per byte

    @Test func aFullScanCountsNoneOfTheseBytes() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fillEverything(home)
        try fill(home, "Library/Group Containers/ABC.unrelated.app")

        let scanner = CategoryScanner(home: home, devRoots: [], ignore: IgnoreList(),
                                      installedApps: InstalledApps(bundleIDs: []))
        let results = await scanner.scanAll()
        let listed = results.flatMap(\.items).map(\.url.standardizedFileURL.path)
        let elsewhere = scan(home).map(\.url.standardizedFileURL.path)
        for path in elsewhere {
            #expect(!listed.contains { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }, "\(path)")
        }
        // The unrelated container is still offered; containers holding
        // something handled elsewhere are not.
        let containers = results.first { $0.category == .groupContainers }?.items.map(\.url.lastPathComponent)
        #expect(containers == ["ABC.unrelated.app"])
    }

    @Test func steamsOwnCachesStayCleanableBesideItsGames() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "Library/Application Support/Steam/steamapps/common/Hades")
        try fill(home, "Library/Application Support/Steam/steamapps/shadercache")
        let items = await CategoryScanner(home: home, devRoots: [], ignore: IgnoreList(),
                                          installedApps: InstalledApps(bundleIDs: [])).scan(.appSupport).items
        #expect(items.map(\.url.lastPathComponent) == ["shadercache"])
    }

    @Test func aDiskImageInsideAHandledFolderIsNotAlsoAVirtualDiskFinding() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fill(home, "Library/Application Support/multipassd/vault/primary.utm")
        try fill(home, "Library/Application Support/Other/vault/primary.utm")
        let root = home.appending(path: "Library/Application Support")
        let items = AppSupportScanner.items(in: root, installed: InstalledApps(bundleIDs: []))
        // The same bundle in a folder nobody else manages is still a finding.
        #expect(items.map(\.finding) == ["virtualDisk"])
        #expect(items.map(\.detail) == ["Other"])
    }

    @Test func noCleanupSourceOrNamedRuleOverlapsARule() {
        func overlaps(_ path: String, _ rule: ElsewhereRule) -> Bool {
            let source = path.split(separator: "/").map(String.init)
            return zip(source, rule.components).allSatisfy { HandledElsewhere.componentMatches($0, $1) }
        }
        for rule in HandledElsewhere.rules {
            for source in CleanSource.all {
                #expect(!overlaps(source.path, rule), "\(source.path) overlaps \(rule.id)")
            }
            for named in AppSupportRules.named {
                let path = [AppSupportRules.root, named.owner, named.path].filter { !$0.isEmpty }.joined(separator: "/")
                #expect(!overlaps(path, rule), "\(path) overlaps \(rule.id)")
            }
        }
    }

    // MARK: Rules

    @Test func ruleIDsAreUniqueAndUITextIsPlain() {
        let ids = HandledElsewhere.rules.map(\.id)
        #expect(Set(ids).count == ids.count)
        for rule in HandledElsewhere.rules {
            let text = [rule.owner, rule.label, rule.explanation, rule.managedIn,
                        rule.buttonTitle(appInstalled: true), rule.buttonTitle(appInstalled: false)]
            #expect(!text.contains { $0.contains("—") || $0.contains("–") }, "\(rule.id)")
        }
    }

    @Test func buttonsStartWithAVerbAndFallBackToRevealing() {
        for rule in HandledElsewhere.rules {
            for installed in [true, false] {
                let title = rule.buttonTitle(appInstalled: installed)
                #expect(title.hasPrefix("Open ") || title == "Show in Finder", "\(title)")
            }
        }
        let docker = HandledElsewhere.rule(id: "dockerDisk")
        #expect(docker?.destination == .dockerTab)
        #expect(docker?.buttonTitle(appInstalled: false) == "Open Docker Tab")
        let utm = HandledElsewhere.rule(id: "utm")
        #expect(utm?.buttonTitle(appInstalled: true) == "Open UTM")
        #expect(utm?.buttonTitle(appInstalled: false) == "Show in Finder")
        #expect(HandledElsewhere.rule(id: "minikube")?.buttonTitle(appInstalled: true) == "Show in Finder")
        #expect(HandledElsewhere.rule(id: "messages")?.buttonTitle(appInstalled: false) == "Open Storage Settings")
    }

    @Test func coveringMatchesTheRuleAnchoredAtHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        func covering(_ path: String) -> String? {
            HandledElsewhere.rule(covering: URL(fileURLWithPath: path), home: home)?.id
        }
        #expect(covering("/Users/me/.minikube") == "minikube")
        #expect(covering("/Users/me/.minikube/cache/images") == "minikube")
        #expect(covering("/Users/me/Library/Application Support/Steam/steamapps/common/Hades") == "steamGames")
        #expect(covering("/Users/me/Library/Application Support/Steam/steamapps/common") == "steamGames")
        #expect(covering("/Users/me/Library/Group Containers/HUAQ.dev.orbstack/data") == "orbstack")
        // A folder that merely shares the name, elsewhere, isn't managed.
        #expect(covering("/Users/me/Developer/app/.minikube") == nil)
        #expect(covering("/Users/me/Developer/Parallels") == nil)
        #expect(covering("/Users/other/.minikube") == nil)
        // Steam's other folders and the containing folder of a whole rule.
        #expect(covering("/Users/me/Library/Application Support/Steam/steamapps") == nil)
        #expect(covering("/Users/me/Library/Messages") == nil)
        #expect(covering("/Users/me/Library/Containers/com.utmapp.UTM/Data/Documents") == "utm")
        // Telegram's wildcard finds its container; it doesn't speak for every
        // container in the folder.
        #expect(covering("/Users/me/Library/Group Containers") == nil)
        #expect(covering("/Users/me/Library/Group Containers/ABC.ru.keepcoder.Telegram") == "telegram")
        #expect(covering("/Users/me") == nil)
    }

    @Test func rowsAreNamedByTheFolderOnlyWhereTheFolderMeansSomething() {
        func item(_ name: String, _ rule: String) -> ScanItem {
            ScanItem(url: URL(fileURLWithPath: "/x/\(name)"), sizeBytes: 1, isDirectory: true, finding: rule)
        }
        #expect(HandledElsewhere.rule(id: "steamGames")?.title(for: item("Hades", "steamGames")) == "Hades")
        #expect(HandledElsewhere.rule(id: "utm")?.title(for: item("Ubuntu.utm", "utm")) == "Ubuntu.utm")
        #expect(HandledElsewhere.rule(id: "telegram")?.title(for: item("ABC.ru.keepcoder.Telegram", "telegram")) == "Telegram's data")
        #expect(HandledElsewhere.rule(id: "dockerDisk")?.title(for: item("Docker.raw", "dockerDisk")) == "Docker's disk")
    }

    @Test func onlyContainersARuleLooksInsideAreClaimed() {
        #expect(HandledElsewhere.claimsGroupContainer("HUAQ24HBR6.dev.orbstack"))
        #expect(HandledElsewhere.claimsGroupContainer("group.net.whatsapp.WhatsApp.shared"))
        #expect(HandledElsewhere.claimsGroupContainer("6N38VWS5BX.ru.keepcoder.Telegram"))
        #expect(!HandledElsewhere.claimsGroupContainer("group.com.apple.notes"))
        #expect(!HandledElsewhere.claimsGroupContainer("group.net.whatsapp.family"))
    }

    @Test func groupsAreBiggestFirstAndUnknownRulesAreDropped() {
        func item(_ path: String, _ bytes: Int64, _ rule: String) -> ScanItem {
            ScanItem(url: URL(fileURLWithPath: path), sizeBytes: bytes, isDirectory: true, finding: rule)
        }
        let groups = HandledElsewhere.groups([
            item("/a/Hades", 5, "steamGames"), item("/a/Elden", 60, "steamGames"),
            item("/b", 40, "dockerDisk"), item("/c", 99, "ruleFromTheFuture"),
        ])
        #expect(groups.map(\.rule.id) == ["steamGames", "dockerDisk"])
        #expect(groups[0].bytes == 65)
        #expect(groups[0].items.map(\.url.lastPathComponent) == ["Elden", "Hades"])
    }

    @Test func summaryNamesTheBiggestOwners() {
        func groups(_ ids: [String]) -> [HandledElsewhere.Group] {
            HandledElsewhere.groups(ids.enumerated().map { index, id in
                ScanItem(url: URL(fileURLWithPath: "/\(id)"), sizeBytes: Int64(100 - index), isDirectory: true, finding: id)
            })
        }
        #expect(HandledElsewhere.summary(groups(["steamGames"])) == "Steam")
        #expect(HandledElsewhere.summary(groups(["steamGames", "dockerDisk"])) == "Steam and Docker")
        #expect(HandledElsewhere.summary(groups(["steamGames", "dockerDisk", "messages"])) == "Steam, Docker and Messages")
        #expect(HandledElsewhere.summary(groups(["steamGames", "dockerDisk", "messages", "utm", "vagrant"]))
                == "Steam, Docker, Messages and 2 more")
    }
}

@Suite("Growth nudges")
struct GrowthNudgeTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let gb: Int64 = 1_000_000_000

    func snap(daysAgo: Double, categories: [CoreKit.Category: Int64] = [:], folders: [String: Int64]? = nil) -> ScanSnapshot {
        ScanSnapshot(date: now.addingTimeInterval(-daysAgo * 86_400), reclaimableBytes: 0, itemCount: 0,
                     categories: Dictionary(uniqueKeysWithValues: categories.map { ($0.key.rawValue, $0.value) }),
                     folders: folders)
    }

    func nudges(_ history: [ScanSnapshot]) -> [GrowthNudge] {
        if case .growing(let nudges) = ScanHistory.growthReport(in: history) { return nudges }
        return []
    }

    @Test func saysSoWhenThereIsNothingToCompareWith() {
        #expect(ScanHistory.growthReport(in: []) == .noHistory)
        #expect(ScanHistory.growthReport(in: [snap(daysAgo: 0, categories: [.aiAgents: 9 * gb])]) == .noHistory)
        // A scan from an hour ago isn't history.
        #expect(ScanHistory.growthReport(in: [snap(daysAgo: 0, categories: [.aiAgents: 9 * gb]),
                                              snap(daysAgo: 0.04, categories: [.aiAgents: 1 * gb])]) == .noHistory)
    }

    @Test func historyFilesWrittenByOlderVersionsStillDecode() throws {
        let id = UUID().uuidString
        let json = """
        [{"id":"\(id)","date":0,"reclaimableBytes":5,"itemCount":1},
         {"id":"\(UUID().uuidString)","date":100000,"reclaimableBytes":5,"itemCount":1,"categories":{"aiAgents":5}}]
        """
        let decoded = try JSONDecoder().decode([ScanSnapshot].self, from: Data(json.utf8))
        #expect(decoded.count == 2)
        #expect(decoded.allSatisfy { $0.folders == nil })
        #expect(decoded[0].categories == nil)
        // The one tracked scan has nothing older to compare with.
        #expect(ScanHistory.growthReport(in: decoded) == .noHistory)
    }

    @Test func newSnapshotsRoundTripTheirFolders() throws {
        let snapshot = snap(daysAgo: 0, categories: [.aiAgents: 1], folders: ["appSupport:Claude": 7])
        let decoded = try JSONDecoder().decode(ScanSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.folders == ["appSupport:Claude": 7])
    }

    @Test func aFolderGrowingALotIsNamedPlainly() {
        let found = nudges([
            snap(daysAgo: 0, categories: [.appSupport: 12 * gb], folders: ["appSupport:Claude": 11 * gb]),
            snap(daysAgo: 7, categories: [.appSupport: 2 * gb], folders: ["appSupport:Claude": 1 * gb]),
        ])
        #expect(found.map(\.name) == ["Claude"])
        #expect(found[0].place == .category(.appSupport))
        #expect(found[0].delta == 10 * gb)
        #expect(found[0].current == 11 * gb)
        #expect(found[0].sentence(now: now) == "Claude grew 10 GB since last week")
    }

    @Test func applicationSupportFallsBackToTheCategoryForOlderScans() {
        let found = nudges([
            snap(daysAgo: 0, categories: [.appSupport: 12 * gb], folders: ["appSupport:Claude": 11 * gb]),
            snap(daysAgo: 7, categories: [.appSupport: 2 * gb]),
        ])
        #expect(found.map(\.name) == ["Application Support"])
    }

    @Test func smallGrowthAndSmallShareStayQuiet() {
        // Under a gigabyte; and a gigabyte on 200 GB is half a percent.
        #expect(ScanHistory.growthReport(in: [
            snap(daysAgo: 0, categories: [.aiAgents: 1_500_000_000, .devCaches: 201 * gb]),
            snap(daysAgo: 7, categories: [.aiAgents: 1 * gb, .devCaches: 200 * gb]),
        ]) == .steady)
    }

    @Test func topThreeBiggestFirstAndDeterministic() {
        let history = [
            snap(daysAgo: 0, categories: [.aiAgents: 5 * gb, .devCaches: 6 * gb, .nodeModules: 7 * gb, .userCaches: 8 * gb]),
            snap(daysAgo: 7, categories: [.aiAgents: 1 * gb, .devCaches: 1 * gb, .nodeModules: 1 * gb, .userCaches: 1 * gb]),
        ]
        #expect(nudges(history).map(\.name) == [CoreKit.Category.userCaches, .nodeModules, .devCaches].map(\.displayName))
        // Equal growth orders by name, not dictionary order.
        let tied = [
            snap(daysAgo: 0, categories: [.aiAgents: 5 * gb, .devCaches: 5 * gb]),
            snap(daysAgo: 7, categories: [.aiAgents: 1 * gb, .devCaches: 1 * gb]),
        ]
        #expect(nudges(tied).map(\.name) == [CoreKit.Category.aiAgents, .devCaches].map(\.displayName))
    }

    @Test func comparesWithTheOldestScanOfThePastWeek() {
        let history = [
            snap(daysAgo: 0, categories: [.aiAgents: 6 * gb]),
            snap(daysAgo: 1, categories: [.aiAgents: 5.5.gigabytes]),   // yesterday: only half a gigabyte
            snap(daysAgo: 6, categories: [.aiAgents: 2 * gb]),          // the week's start: 4 GB
            snap(daysAgo: 40, categories: [.aiAgents: 1 * gb]),         // too long ago to say "this week"
        ]
        let found = nudges(history)
        #expect(found.first?.delta == 4 * gb)
        #expect(found.first?.sentence(now: now) == "AI coding agents grew 4 GB in the last 6 days")
    }

    @Test func aLongGapStillComparesWithTheNewestOlderScan() {
        let found = nudges([
            snap(daysAgo: 0, categories: [.aiAgents: 6 * gb]),
            snap(daysAgo: 45, categories: [.aiAgents: 2 * gb]),
            snap(daysAgo: 90, categories: [.aiAgents: 1 * gb]),
        ])
        #expect(found.first?.delta == 4 * gb)
        #expect(found.first?.sentence(now: now) == "AI coding agents grew 4 GB since last month")
    }

    @Test func handledElsewhereGrowthLinksToItsPage() {
        let found = nudges([
            snap(daysAgo: 0, folders: ["elsewhere:dockerDisk": 30 * gb]),
            snap(daysAgo: 3, folders: ["elsewhere:dockerDisk": 10 * gb]),
        ])
        #expect(found.first?.name == "Docker's disk")
        #expect(found.first?.place == .handledElsewhere)
    }

    @Test func somethingFirstMeasuredInThisScanIsNotCalledGrowth() {
        // Granting Full Disk Access reveals 30 GB of Messages attachments: that
        // key wasn't in the earlier scan, so it wasn't measured then.
        let found = nudges([
            snap(daysAgo: 0, folders: ["elsewhere:messages": 30 * gb]),
            snap(daysAgo: 3, folders: ["elsewhere:steamGames": 10 * gb]),
        ])
        #expect(found.isEmpty)
        // A category a newer version added wasn't measured then either.
        #expect(nudges([
            snap(daysAgo: 0, categories: [.aiAgents: 30 * gb]),
            snap(daysAgo: 3, categories: [.devCaches: 1 * gb]),
        ]).isEmpty)
    }

    @Test func folderTotalsKeepMeasuredRulesAtZeroAndSkipRemovedApps() {
        func appSupport(_ owner: String, _ bytes: Int64) -> ScanItem {
            ScanItem(url: URL(fileURLWithPath: "/\(owner)"), sizeBytes: bytes, isDirectory: true,
                     category: .appSupport, detail: owner)
        }
        let results = [CategoryResult(category: .appSupport, items: [
            appSupport("Claude", 3), appSupport("Claude", 4), appSupport(AppSupportRules.removedAppsGroup, 9),
        ])]
        let game = ScanItem(url: URL(fileURLWithPath: "/g"), sizeBytes: 5, isDirectory: true, finding: "steamGames")

        let full = ScanHistory.folderTotals(results: results, elsewhere: [game], fullDiskAccess: true)
        #expect(full["appSupport:Claude"] == 7)
        #expect(full["appSupport:" + AppSupportRules.removedAppsGroup] == nil)
        #expect(full["elsewhere:steamGames"] == 5)
        #expect(full["elsewhere:messages"] == 0)

        let limited = ScanHistory.folderTotals(results: results, elsewhere: [game], fullDiskAccess: false)
        #expect(limited["elsewhere:messages"] == nil)
        #expect(limited["elsewhere:parallels"] == 0)
    }

    @Test(arguments: [
        (0.9, "since yesterday"), (1.5, "since yesterday"), (2.0, "in the last 2 days"), (6.5, "in the last 6 days"),
        (7.0, "since last week"), (13.0, "since last week"), (14.0, "in the last 2 weeks"), (27.0, "in the last 3 weeks"),
        (28.0, "since last month"), (59.0, "since last month"), (60.0, "in the last 2 months"),
    ])
    func periodsReadNaturally(days: Double, expected: String) {
        #expect(GrowthNudge.period(since: now.addingTimeInterval(-days * 86_400), now: now) == expected)
    }
}

private extension Double {
    var gigabytes: Int64 { Int64(self * 1_000_000_000) }
}
