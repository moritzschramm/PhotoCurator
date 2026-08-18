import Foundation
import GRDB

public enum DerivationQueueError: Error {
    case missingRepresentationId
}

/// Orchestrates *when* derivation runs (spec §7.3): immediately, a few files at a
/// time, for the backlog of local-but-underived representations, and on demand for a
/// single online-only representation the user just acted on.
public actor DerivationQueue {
    private let database: AppDatabase
    private let derivationService: DerivationService
    private var isProcessingBacklog = false

    public init(database: AppDatabase, derivationService: DerivationService) {
        self.database = database
        self.derivationService = derivationService
    }

    /// Derives every local-but-underived representation, several at a time. Meant to
    /// run right after reconciliation/import — local files derive immediately rather
    /// than waiting for the user to open them. `photoRoots` maps each library's id to
    /// its resolved root URL; a representation whose library isn't present (e.g.
    /// removed mid-backlog) is skipped rather than failing the whole batch.
    public func processLocalBacklog(photoRoots: [Int64: URL], maxConcurrent: Int = 4) async {
        guard !isProcessingBacklog else { return }
        isProcessingBacklog = true
        defer { isProcessingBacklog = false }

        guard let pending = try? await database.read({ db in
            try Representation
                .filter(Representation.Columns.derivationState == DerivationState.underived.rawValue)
                .filter(Representation.Columns.isLocal == true)
                .fetchAll(db)
        }) else { return }

        let derivationService = derivationService

        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()

            func startNext() {
                while let rep = iterator.next() {
                    guard let repId = rep.id, let photoRoot = photoRoots[rep.libraryId] else { continue }
                    group.addTask {
                        let url = rep.fileURL(photoRoot: photoRoot)
                        _ = try? await derivationService.derive(representationId: repId, fileURL: url, kind: rep.kind)
                    }
                    return
                }
            }

            for _ in 0..<max(1, maxConcurrent) { startNext() }
            while await group.next() != nil {
                startNext()
            }
        }
    }

    /// Materializes and derives a single representation on demand — the "online-only
    /// files derive lazily on first use" path. Reading `fileURL`'s bytes is exactly
    /// what triggers Proton to download it. One retry on failure (spec §7.7); the
    /// caller is responsible for showing a placeholder if this still throws.
    @discardableResult
    public func deriveOnDemand(representation: Representation, photoRoot: URL) async throws -> String {
        guard let repId = representation.id else { throw DerivationQueueError.missingRepresentationId }
        let url = representation.fileURL(photoRoot: photoRoot)
        do {
            return try await derivationService.derive(representationId: repId, fileURL: url, kind: representation.kind)
        } catch {
            return try await derivationService.derive(representationId: repId, fileURL: url, kind: representation.kind)
        }
    }
}
