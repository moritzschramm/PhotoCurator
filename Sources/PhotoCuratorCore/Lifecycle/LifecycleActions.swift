import Foundation

/// Named, keyboard-review-friendly entry points over `Photo.lifecycleState` (spec §6,
/// §8: "rate/flag/reject"). `new` is only ever set by reconciliation/import — it's
/// deliberately absent here so the UI can't assign it directly. "Currently exported"
/// is tracked separately, in the `exports` log (see `ExportService`), independent of
/// whichever of these verdicts a photo currently carries.
public enum LifecycleActions {
    public static func markAccepted(photoId: Int64, database: AppDatabase) async throws {
        try await setState(.accepted, photoIds: [photoId], database: database)
    }

    public static func markCandidate(photoId: Int64, database: AppDatabase) async throws {
        try await setState(.candidate, photoIds: [photoId], database: database)
    }

    public static func markRejected(photoId: Int64, database: AppDatabase) async throws {
        try await setState(.rejected, photoIds: [photoId], database: database)
    }

    public static func markAccepted(photoIds: [Int64], database: AppDatabase) async throws {
        try await setState(.accepted, photoIds: photoIds, database: database)
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
