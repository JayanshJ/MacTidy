import Foundation

/// One candidate for deletion, with the size the UI showed the user.
public struct DeletionCandidate: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let sizeBytes: Int64

    public init(url: URL, sizeBytes: Int64) {
        self.id = UUID()
        self.url = url
        self.sizeBytes = sizeBytes
    }

    public init(_ item: ScanItem) {
        self.init(url: item.url, sizeBytes: item.sizeBytes)
    }
}

/// The full set of paths a feature proposes to trash. The UI always renders
/// the complete plan (every path plus the total) before the user confirms.
public struct DeletionPlan: Sendable {
    public var candidates: [DeletionCandidate]

    public var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.sizeBytes } }
    public var isEmpty: Bool { candidates.isEmpty }

    public init(candidates: [DeletionCandidate]) {
        self.candidates = candidates
    }

    public init(items: [ScanItem]) {
        self.init(candidates: items.map(DeletionCandidate.init))
    }
}

public struct TrashedRecord: Identifiable, Sendable {
    public let id = UUID()
    public let original: URL
    /// Where the item landed in the Trash.
    public let trashLocation: URL?
}

public struct SkippedRecord: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let reason: String
}

public struct DeletionOutcome: Sendable {
    public let trashed: [TrashedRecord]
    public let skipped: [SkippedRecord]
    public let reclaimedBytes: Int64

    public init(trashed: [TrashedRecord], skipped: [SkippedRecord], reclaimedBytes: Int64) {
        self.trashed = trashed
        self.skipped = skipped
        self.reclaimedBytes = reclaimedBytes
    }
}

/// The single execution path for every destructive action in the app.
public struct DeletionExecutor: Sendable {
    public var policy: SafePathPolicy

    public init(policy: SafePathPolicy = SafePathPolicy()) {
        self.policy = policy
    }

    /// Validates every candidate against the SafePathPolicy, partitioning the
    /// plan into valid and rejected up front. Rejected candidates are reported
    /// as skipped (with the policy reason) and never touched; the rest execute
    /// — fail-closed per item instead of one bad path aborting the whole plan.
    /// Per-item trash failures after that are also skipped and reported, never
    /// hard-deleted.
    public func execute(_ plan: DeletionPlan) -> DeletionOutcome {
        var trashed: [TrashedRecord] = []
        var skipped: [SkippedRecord] = []
        var reclaimed: Int64 = 0

        for candidate in plan.candidates {
            switch policy.classify(candidate.url) {
            case .failure(let violation):
                skipped.append(SkippedRecord(url: candidate.url, reason: violation.description))
                continue
            case .success:
                break
            }

            do {
                let location = try Trasher.trash(candidate.url)
                trashed.append(TrashedRecord(original: candidate.url, trashLocation: location))
                reclaimed += candidate.sizeBytes
                NSLog("MacTidy: trashed %@ (%@)",
                      candidate.url.path, candidate.sizeBytes.formattedBytes)
            } catch {
                skipped.append(SkippedRecord(url: candidate.url,
                                             reason: error.localizedDescription))
            }
        }
        return DeletionOutcome(trashed: trashed,
                               skipped: skipped, reclaimedBytes: reclaimed)
    }
}
