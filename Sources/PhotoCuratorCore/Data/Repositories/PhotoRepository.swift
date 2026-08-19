import Foundation
import GRDB

/// Pure, synchronous data-access functions over an open `Database` connection. Callers
/// (services, view models) are responsible for dispatching these through
/// `AppDatabase.read`/`write` — repositories never own threading concerns, which keeps
/// them trivially testable against an in-memory `DatabaseQueue`.
public enum PhotoRepository {

    // MARK: Reads

    /// All photos, newest capture date first, joined with their representations.
    /// Two plain queries + in-memory grouping rather than a GRDB association fetch,
    /// so the shape of the result is easy to reason about and test. `libraryId: nil`
    /// (the default) means every registered library, matching the grid's "All
    /// Libraries" filter; a specific id scopes to just that one.
    public static func fetchAllPhotosWithRepresentations(_ db: Database, libraryId: Int64? = nil) throws -> [PhotoWithRepresentations] {
        var request = Photo.order(Photo.Columns.captureDate.desc, Photo.Columns.basename.asc, Photo.Columns.id.asc)
        if let libraryId {
            request = request.filter(Photo.Columns.libraryId == libraryId)
        }
        let photos = try request.fetchAll(db)
        return try attachRepresentations(to: photos, db)
    }

    /// All photos with their best-available cached grid thumbnail already attached,
    /// so the grid never needs a per-cell database query while scrolling.
    public static func fetchGridEntries(_ db: Database, libraryId: Int64? = nil) throws -> [PhotoGridEntry] {
        try attachGridThumbnails(to: fetchAllPhotosWithRepresentations(db, libraryId: libraryId), db)
    }

    /// Photos that have been reviewed (accepted or candidate — rejected and
    /// never-reviewed photos don't belong here) but don't yet belong to any album —
    /// the "Unassigned Photos" surface for filing reviewed photos into a category.
    /// Global across every registered library, matching "All Albums".
    public static func fetchUnassignedGridEntries(_ db: Database) throws -> [PhotoGridEntry] {
        let reviewedStates = [LifecycleState.accepted.rawValue, LifecycleState.candidate.rawValue]
        let assignedPhotoIds = try Int64.fetchSet(db, sql: "SELECT DISTINCT photo_id FROM photo_albums")
        let photos = try Photo
            .filter(reviewedStates.contains(Photo.Columns.lifecycleState))
            .filter(!assignedPhotoIds.contains(Photo.Columns.id))
            .order(Photo.Columns.captureDate.desc, Photo.Columns.basename.asc, Photo.Columns.id.asc)
            .fetchAll(db)
        return try attachGridThumbnails(to: attachRepresentations(to: photos, db), db)
    }

    /// Same idea, scoped to an already-fetched photo list (e.g. one album's photos).
    public static func attachGridThumbnails(to photos: [PhotoWithRepresentations], _ db: Database) throws -> [PhotoGridEntry] {
        let representationIds = photos.flatMap { $0.representations.compactMap(\.id) }
        guard !representationIds.isEmpty else {
            return photos.map { PhotoGridEntry(photo: $0, gridThumbnailPath: nil) }
        }

        let thumbnails = try ThumbnailRecord
            .filter(Column("size_class") == ThumbnailSizeClass.grid.rawValue)
            .filter(representationIds.contains(Column("representation_id")))
            .fetchAll(db)
        let pathByRepresentationId = Dictionary(uniqueKeysWithValues: thumbnails.map { ($0.representationId, $0.cachePath) })

        return photos.map { photo in
            // Prefer the JPG's thumbnail (the fast display path, spec §7.4); fall
            // back to the RAW's embedded-preview-derived thumbnail.
            let path = photo.jpg?.id.flatMap { pathByRepresentationId[$0] }
                ?? photo.raw?.id.flatMap { pathByRepresentationId[$0] }
            return PhotoGridEntry(photo: photo, gridThumbnailPath: path)
        }
    }

    public static func fetchPhoto(id: Int64, in db: Database) throws -> Photo? {
        try Photo.fetchOne(db, key: id)
    }

    public static func fetchPhotoWithRepresentations(id: Int64, in db: Database) throws -> PhotoWithRepresentations? {
        guard let photo = try fetchPhoto(id: id, in: db) else { return nil }
        let reps = try representations(photoId: id, in: db)
        return PhotoWithRepresentations(photo: photo, representations: reps)
    }

    public static func findPhoto(libraryId: Int64, basename: String, sourceDir: String, in db: Database) throws -> Photo? {
        try Photo
            .filter(Photo.Columns.libraryId == libraryId)
            .filter(Photo.Columns.basename == basename && Photo.Columns.sourceDir == sourceDir)
            .fetchOne(db)
    }

    /// Whether `libraryId` already has any photo sitting directly in its root
    /// (`source_dir == ""`) — drives auto-detecting a flat import (no per-camera
    /// subdirectory) when importing into a library that's already organized that way.
    public static func libraryHasRootLevelPhotos(libraryId: Int64, in db: Database) throws -> Bool {
        try Photo
            .filter(Photo.Columns.libraryId == libraryId && Photo.Columns.sourceDir == "")
            .fetchCount(db) > 0
    }

    public static func representations(photoId: Int64, in db: Database) throws -> [Representation] {
        try Representation
            .filter(Representation.Columns.photoId == photoId)
            .fetchAll(db)
    }

    public static func fetchRepresentation(id: Int64, in db: Database) throws -> Representation? {
        try Representation.fetchOne(db, key: id)
    }

    public static func findRepresentation(relativePath: String, in db: Database) throws -> Representation? {
        try Representation
            .filter(Representation.Columns.relativePath == relativePath)
            .fetchOne(db)
    }

    public static func findRepresentation(contentHash: String, in db: Database) throws -> Representation? {
        try Representation
            .filter(Representation.Columns.contentHash == contentHash)
            .fetchOne(db)
    }

    /// Same lookup, restricted to one library — for callers that are reasoning about
    /// a single library's own files (reconciliation's move/rename rescue) and must
    /// not match a byte-identical file that lives under a *different* registered
    /// root, since those are two real, separately-tracked files on disk.
    public static func findRepresentation(contentHash: String, libraryId: Int64, in db: Database) throws -> Representation? {
        try Representation
            .filter(Representation.Columns.contentHash == contentHash && Representation.Columns.libraryId == libraryId)
            .fetchOne(db)
    }

    /// Indexes every representation by relative path, for O(1) lookups while diffing a
    /// large directory enumeration against the database (spec §7.1).
    public static func allRepresentationsByRelativePath(in db: Database) throws -> [String: Representation] {
        let all = try Representation.fetchAll(db)
        return Dictionary(all.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Indexes every representation that already has a content hash, for move/rename
    /// detection during reconciliation (spec §5).
    public static func allRepresentationsByContentHash(in db: Database) throws -> [String: Representation] {
        let all = try Representation
            .filter(Representation.Columns.contentHash != nil)
            .fetchAll(db)
        return Dictionary(all.compactMap { rep in rep.contentHash.map { ($0, rep) } }, uniquingKeysWith: { first, _ in first })
    }

    public static func fetchExif(representationId: Int64, in db: Database) throws -> ExifRecord? {
        try ExifRecord.fetchOne(db, key: representationId)
    }

    public static func fetchThumbnail(
        representationId: Int64,
        sizeClass: ThumbnailSizeClass,
        in db: Database
    ) throws -> ThumbnailRecord? {
        try ThumbnailRecord
            .filter(Column("representation_id") == representationId && Column("size_class") == sizeClass.rawValue)
            .fetchOne(db)
    }

    // MARK: Writes

    /// Finds the Photo grouping `basename`+`sourceDir`, creating it (as `.new`) if this
    /// is the first representation ever seen for that shot. Never duplicates (spec §5).
    @discardableResult
    public static func upsertPhoto(
        libraryId: Int64,
        basename: String,
        sourceDir: String,
        captureDate: Int64?,
        now: Int64,
        in db: Database
    ) throws -> Photo {
        if var existing = try findPhoto(libraryId: libraryId, basename: basename, sourceDir: sourceDir, in: db) {
            if existing.captureDate == nil, let captureDate {
                existing.captureDate = captureDate
                existing.updatedAt = now
                try existing.update(db)
            }
            return existing
        }
        var photo = Photo(
            libraryId: libraryId,
            basename: basename,
            sourceDir: sourceDir,
            captureDate: captureDate,
            lifecycleState: .new,
            createdAt: now,
            updatedAt: now
        )
        try photo.insert(db)
        return photo
    }

    /// Fills in a photo's capture date from freshly-extracted EXIF once derivation
    /// catches up, but only if we didn't already have one (e.g. from the filesystem
    /// date at index time).
    /// EXIF's `DateTimeOriginal` is strictly more accurate than the filesystem mtime
    /// photos are provisionally sorted by until derivation catches up, so — unlike a
    /// plain "fill if missing" backfill — this always overwrites once EXIF is
    /// available (skipping the write only when the value wouldn't actually change).
    public static func backfillCaptureDate(photoId: Int64, captureDate: Int64, now: Int64, in db: Database) throws {
        guard var photo = try fetchPhoto(id: photoId, in: db), photo.captureDate != captureDate else { return }
        photo.captureDate = captureDate
        photo.updatedAt = now
        try photo.update(db)
    }

    @discardableResult
    public static func insertRepresentation(_ representation: Representation, in db: Database) throws -> Representation {
        var rep = representation
        try rep.insert(db)
        return rep
    }

    /// Plain single-row delete, no empty-photo cascade — used by import undo, which
    /// separately decides via `deletePhotoIfEmpty` whether the shared photo row also
    /// needs removing (unlike `deleteRepresentationCascadingEmptyPhoto`, it needs the
    /// deleted photo row back, not just a fire-and-forget cascade).
    public static func deleteRepresentation(id: Int64, in db: Database) throws {
        _ = try Representation.deleteOne(db, key: id)
    }

    /// Re-inserts a previously-deleted photo row at its exact original primary key —
    /// used by import undo's redo path, alongside `restoreRepresentation`.
    public static func restorePhoto(_ photo: Photo, in db: Database) throws {
        var photo = photo
        try photo.insert(db)
    }

    /// Re-inserts a previously-deleted representation row at its exact original
    /// primary key.
    public static func restoreRepresentation(_ representation: Representation, in db: Database) throws {
        var representation = representation
        try representation.insert(db)
    }

    public static func updateRepresentation(_ representation: Representation, in db: Database) throws {
        try representation.update(db)
    }

    /// Deletes a representation; if that was the photo's last one, deletes the photo
    /// too (cascading album membership and export history with it). This only fires
    /// when a file genuinely disappears from the filesystem — originals are never
    /// touched by the app itself (spec §2).
    public static func deleteRepresentationCascadingEmptyPhoto(id: Int64, in db: Database) throws {
        guard let rep = try Representation.fetchOne(db, key: id) else { return }
        _ = try Representation.deleteOne(db, key: id)
        try deletePhotoIfEmpty(photoId: rep.photoId, in: db)
    }

    /// Deletes a photo if it has zero remaining representations — used after a
    /// representation is reassigned to a different photo during a move/rename so the
    /// old, now-empty grouping doesn't linger (spec §5, §7.1). Returns the deleted
    /// row (rather than just a `Bool`) so callers that need to undo the deletion —
    /// import's undo, in particular — have the exact row to reinsert on redo.
    @discardableResult
    public static func deletePhotoIfEmpty(photoId: Int64, in db: Database) throws -> Photo? {
        let remaining = try Representation
            .filter(Representation.Columns.photoId == photoId)
            .fetchCount(db)
        guard remaining == 0 else { return nil }
        guard let photo = try Photo.fetchOne(db, key: photoId) else { return nil }
        _ = try Photo.deleteOne(db, key: photoId)
        return photo
    }

    /// One-time-per-photo backfill: fills `capture_date` from the earliest known
    /// file mtime among a photo's representations, for photos that still have no
    /// capture date at all — e.g. ones indexed before this backfill existed, or
    /// still waiting on EXIF derivation to catch up. Safe to call on every
    /// reconciliation: a no-op for any photo that already has a capture date.
    @discardableResult
    public static func backfillMissingCaptureDatesFromMtime(now: Int64, in db: Database) throws -> Int {
        try db.execute(
            sql: """
                UPDATE photos
                SET capture_date = (
                    SELECT MIN(file_mtime) FROM representations
                    WHERE representations.photo_id = photos.id AND representations.file_mtime IS NOT NULL
                ),
                updated_at = ?
                WHERE capture_date IS NULL
                AND EXISTS (
                    SELECT 1 FROM representations
                    WHERE representations.photo_id = photos.id AND representations.file_mtime IS NOT NULL
                )
                """,
            arguments: [now]
        )
        return db.changesCount
    }

    public static func updateLocalStatus(representationId: Int64, isLocal: Bool, in db: Database) throws {
        try Representation
            .filter(Representation.Columns.id == representationId)
            .updateAll(db, Representation.Columns.isLocal.set(to: isLocal))
    }

    public static func markDerived(
        representationId: Int64,
        contentHash: String,
        in db: Database
    ) throws {
        try Representation
            .filter(Representation.Columns.id == representationId)
            .updateAll(
                db,
                Representation.Columns.contentHash.set(to: contentHash),
                Representation.Columns.derivationState.set(to: DerivationState.derived.rawValue),
                Representation.Columns.isLocal.set(to: true)
            )
    }

    public static func saveExif(_ exif: ExifRecord, in db: Database) throws {
        try exif.save(db)
    }

    public static func saveThumbnail(_ thumbnail: ThumbnailRecord, in db: Database) throws {
        try thumbnail.save(db)
    }

    /// Each photo's current lifecycle state — used to capture "before" state ahead of
    /// a `setLifecycleState` call, so it can be undone back to each photo's own prior
    /// state rather than one shared value (a multi-select undo can start from a mix).
    public static func fetchLifecycleStates(photoIds: [Int64], in db: Database) throws -> [Int64: LifecycleState] {
        let photos = try Photo.filter(photoIds.contains(Photo.Columns.id)).fetchAll(db)
        return Dictionary(uniqueKeysWithValues: photos.compactMap { photo in
            photo.id.map { ($0, photo.lifecycleState) }
        })
    }

    public static func setLifecycleState(photoId: Int64, state: LifecycleState, now: Int64, in db: Database) throws {
        try Photo
            .filter(Photo.Columns.id == photoId)
            .updateAll(
                db,
                Photo.Columns.lifecycleState.set(to: state.rawValue),
                Photo.Columns.updatedAt.set(to: now)
            )
    }

    public static func setLifecycleState(photoIds: [Int64], state: LifecycleState, now: Int64, in db: Database) throws {
        try Photo
            .filter(photoIds.contains(Photo.Columns.id))
            .updateAll(
                db,
                Photo.Columns.lifecycleState.set(to: state.rawValue),
                Photo.Columns.updatedAt.set(to: now)
            )
    }

    /// First-run baseline (spec §6): every photo discovered by the initial index
    /// becomes `accepted`, not `new`. Idempotent — only touches rows still at `.new`.
    @discardableResult
    public static func markAllAsAcceptedBaseline(now: Int64, in db: Database) throws -> Int {
        try Photo
            .filter(Photo.Columns.lifecycleState == LifecycleState.new.rawValue)
            .updateAll(
                db,
                Photo.Columns.lifecycleState.set(to: LifecycleState.accepted.rawValue),
                Photo.Columns.updatedAt.set(to: now)
            )
    }

    // MARK: Helpers

    private static func attachRepresentations(to photos: [Photo], _ db: Database) throws -> [PhotoWithRepresentations] {
        let allReps = try Representation.fetchAll(db)
        let grouped = Dictionary(grouping: allReps, by: { $0.photoId })
        return photos.map { photo in
            PhotoWithRepresentations(
                photo: photo,
                representations: photo.id.flatMap { grouped[$0] } ?? []
            )
        }
    }
}
