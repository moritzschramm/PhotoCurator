import Foundation

/// Named, keyboard-review-friendly entry points over `Photo.lifecycleState` (spec §6,
/// §8: "rate/flag/reject"). `new` is only ever set by reconciliation/import and
/// `published` only by `ExportService` — both are deliberately absent here so the UI
/// can't assign them directly.
public enum LifecycleActions {
    public static func markReviewed(photoId: Int64, database: AppDatabase) async throws {
        try await setState(.reviewed, photoIds: [photoId], database: database)
    }

    public static func markCandidate(photoId: Int64, database: AppDatabase) async throws {
        try await setState(.candidate, photoIds: [photoId], database: database)
    }

    public static func markRejected(photoId: Int64, database: AppDatabase) async throws {
        try await setState(.rejected, photoIds: [photoId], database: database)
    }

    public static func markReviewed(photoIds: [Int64], database: AppDatabase) async throws {
        try await setState(.reviewed, photoIds: photoIds, database: database)
    }

    public static func markCandidate(photoIds: [Int64], database: AppDatabase) async throws {
        try await setState(.candidate, photoIds: photoIds, database: database)
    }

    public static func markRejected(photoIds: [Int64], database: AppDatabase) async throws {
        try await setState(.rejected, photoIds: photoIds, database: database)
    }

    private static func setState(_ state: LifecycleState, photoIds: [Int64], database: AppDatabase) async throws {
        guard !photoIds.isEmpty else { return }
        try await database.write { db in
            try PhotoRepository.setLifecycleState(
                photoIds: photoIds,
                state: state,
                now: Int64(Date().timeIntervalSince1970),
                in: db
            )
        }
    }
}
