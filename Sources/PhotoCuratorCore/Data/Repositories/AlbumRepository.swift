import Foundation
import GRDB

/// Albums are logical only (spec §7.5): everything here is DB relations, never files.
public enum AlbumRepository {

    public static func fetchAllAlbums(in db: Database) throws -> [Album] {
        // Plain `.asc` uses SQLite's default BINARY collation (byte-order,
        // case-sensitive), which sorts all-uppercase names before any lowercase
        // one — e.g. "Vacation" before "family photos" — and looks essentially
        // random once album names have mixed casing. `localizedStandardCompare` is
        // the same "natural sort" Finder uses: case-insensitive, and numeric-aware
        // (so "Trip 2" sorts before "Trip 10"). GRDB registers it automatically on
        // every connection, no setup needed.
        try Album.order(Album.Columns.name.collating(.localizedStandardCompare).asc).fetchAll(db)
    }

    public static func fetchAlbum(id: Int64, in db: Database) throws -> Album? {
        try Album.fetchOne(db, key: id)
    }

    public static func photoCount(albumId: Int64, in db: Database) throws -> Int {
        try PhotoAlbum.filter(Column("album_id") == albumId).fetchCount(db)
    }

    /// One row per album for the albums overview (spec §7.5, §8): count plus a cover
    /// thumbnail — the album's explicit `coverPhotoId` if set, else its most recently
    /// added photo.
    public static func fetchAllAlbumSummaries(in db: Database) throws -> [AlbumSummary] {
        try fetchAllAlbums(in: db).map { album in
            guard let albumId = album.id else {
                return AlbumSummary(album: album, photoCount: 0, coverThumbnailPath: nil)
            }
            return AlbumSummary(
                album: album,
                photoCount: try photoCount(albumId: albumId, in: db),
                coverThumbnailPath: try coverThumbnailPath(album: album, albumId: albumId, in: db)
            )
        }
    }

    private static func coverThumbnailPath(album: Album, albumId: Int64, in db: Database) throws -> String? {
        let coverPhotoId: Int64?
        if let explicit = album.coverPhotoId {
            coverPhotoId = explicit
        } else {
            coverPhotoId = try PhotoAlbum
                .filter(Column("album_id") == albumId)
                .order(Column("added_at").desc)
                .fetchOne(db)?.photoId
        }
        guard let coverPhotoId else { return nil }

        let reps = try Representation.filter(Representation.Columns.photoId == coverPhotoId).fetchAll(db)
        guard let preferredRepId = (reps.first { $0.kind == .jpg } ?? reps.first)?.id else { return nil }

        return try ThumbnailRecord
            .filter(Column("representation_id") == preferredRepId && Column("size_class") == ThumbnailSizeClass.grid.rawValue)
            .fetchOne(db)?.cachePath
    }

    /// All photos in an album, joined with their representations, in the album's
    /// manual drag-and-drop order (`PhotoAlbum.position`) — not capture date or
    /// add time. `Photo.filter(ids.contains(...))` doesn't preserve the order of
    /// `ids`, so the final array is rebuilt by walking `orderedPhotoIds` rather
    /// than mapping the fetched `photos` directly.
    public static func photos(albumId: Int64, in db: Database) throws -> [PhotoWithRepresentations] {
        let orderedPhotoIds = try PhotoAlbum
            .filter(PhotoAlbum.Columns.albumId == albumId)
            .order(PhotoAlbum.Columns.position.asc)
            .fetchAll(db)
            .map(\.photoId)
        guard !orderedPhotoIds.isEmpty else { return [] }

        let photos = try Photo.filter(orderedPhotoIds.contains(Photo.Columns.id)).fetchAll(db)
        let photosById = Dictionary(uniqueKeysWithValues: photos.compactMap { photo in photo.id.map { ($0, photo) } })
        let allReps = try Representation.filter(orderedPhotoIds.contains(Representation.Columns.photoId)).fetchAll(db)
        let repsByPhoto = Dictionary(grouping: allReps, by: { $0.photoId })

        return orderedPhotoIds.compactMap { photoId in
            guard let photo = photosById[photoId] else { return nil }
            return PhotoWithRepresentations(photo: photo, representations: repsByPhoto[photoId] ?? [])
        }
    }

    /// An album's photo ids in manual drag-and-drop order, with none of `photos(albumId:in:)`'s
    /// extra representation joins — used to capture "before" state ahead of a
    /// reorder, for undo.
    public static func orderedPhotoIds(albumId: Int64, in db: Database) throws -> [Int64] {
        try PhotoAlbum
            .filter(PhotoAlbum.Columns.albumId == albumId)
            .order(PhotoAlbum.Columns.position.asc)
            .fetchAll(db)
            .map(\.photoId)
    }

    /// An album's raw membership rows (id + position, not joined with photo data) —
    /// used to snapshot before a delete, for undo.
    public static func fetchMemberships(albumId: Int64, in db: Database) throws -> [PhotoAlbum] {
        try PhotoAlbum.filter(PhotoAlbum.Columns.albumId == albumId).fetchAll(db)
    }

    /// Re-inserts a previously-deleted album at its exact original primary key —
    /// used by undo, so a redo of anything performed against the original id (e.g.
    /// adding photos to it) still targets the same album. GRDB inserts at an
    /// explicit non-nil `id` rather than auto-incrementing.
    public static func restore(_ album: Album, in db: Database) throws {
        var album = album
        try album.insert(db)
    }

    /// Re-inserts previously-deleted membership rows at their exact original
    /// values — used by undo alongside `restore(_:in:)`.
    public static func restore(_ memberships: [PhotoAlbum], in db: Database) throws {
        for membership in memberships {
            try membership.insert(db)
        }
    }

    /// Persists a manual drag-and-drop reorder: `orderedPhotoIds` is the
    /// complete, already-final desired order (not a delta), so this just
    /// re-numbers every membership row to match its index in it.
    public static func reorderPhotos(albumId: Int64, orderedPhotoIds: [Int64], in db: Database) throws {
        for (index, photoId) in orderedPhotoIds.enumerated() {
            try db.execute(
                sql: "UPDATE photo_albums SET position = ? WHERE album_id = ? AND photo_id = ?",
                arguments: [Int64(index), albumId, photoId]
            )
        }
    }

    private static func nextPosition(albumId: Int64, in db: Database) throws -> Int64 {
        let maxPosition = try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(position), -1) FROM photo_albums WHERE album_id = ?",
            arguments: [albumId]
        ) ?? -1
        return maxPosition + 1
    }

    /// Every album a given photo currently belongs to.
    public static func albumIds(photoId: Int64, in db: Database) throws -> Set<Int64> {
        let rows = try PhotoAlbum.filter(Column("photo_id") == photoId).fetchAll(db)
        return Set(rows.map(\.albumId))
    }

    /// Batch variant for a multi-select "Add to Album" menu, so it can show a
    /// checkmark per album without one query per selected photo.
    public static func albumIds(photoIds: [Int64], in db: Database) throws -> [Int64: Set<Int64>] {
        let rows = try PhotoAlbum.filter(photoIds.contains(Column("photo_id"))).fetchAll(db)
        return Dictionary(grouping: rows, by: \.photoId).mapValues { Set($0.map(\.albumId)) }
    }

    @discardableResult
    public static func createAlbum(name: String, now: Int64, in db: Database) throws -> Album {
        var album = Album(name: name, createdAt: now)
        try album.insert(db)
        return album
    }

    public static func renameAlbum(id: Int64, name: String, in db: Database) throws {
        try Album.filter(Album.Columns.id == id).updateAll(db, Album.Columns.name.set(to: name))
    }

    public static func setCoverPhoto(albumId: Int64, photoId: Int64?, in db: Database) throws {
        try Album.filter(Album.Columns.id == albumId)
            .updateAll(db, Album.Columns.coverPhotoId.set(to: photoId))
    }

    public static func deleteAlbum(id: Int64, in db: Database) throws {
        _ = try Album.deleteOne(db, key: id)
    }

    /// Adding a photo to an album creates one `photo_albums` row — no file copy, no
    /// directory (spec §7.5). Idempotent: re-adding an already-member photo is a
    /// no-op (position included — it doesn't get bumped to the end again).
    /// Appended after everything already in the album.
    public static func addPhoto(photoId: Int64, albumId: Int64, now: Int64, in db: Database) throws {
        let exists = try PhotoAlbum
            .filter(Column("photo_id") == photoId && Column("album_id") == albumId)
            .fetchCount(db) > 0
        guard !exists else { return }
        let position = try nextPosition(albumId: albumId, in: db)
        let membership = PhotoAlbum(photoId: photoId, albumId: albumId, addedAt: now, position: position)
        try membership.insert(db)
    }

    /// Adds several photos to an album in one batch, appended after everything
    /// already in the album. The batch's own initial relative order is
    /// alphabetical by filename (not selection/click order, which would
    /// otherwise look arbitrary) — photos already in the album are left
    /// untouched, both in membership and position.
    public static func addPhotos(photoIds: [Int64], albumId: Int64, now: Int64, in db: Database) throws {
        guard !photoIds.isEmpty else { return }
        let existingMemberIds = Set(
            try PhotoAlbum
                .filter(PhotoAlbum.Columns.albumId == albumId && photoIds.contains(PhotoAlbum.Columns.photoId))
                .fetchAll(db)
                .map(\.photoId)
        )
        let newIds = photoIds.filter { !existingMemberIds.contains($0) }
        guard !newIds.isEmpty else { return }

        let photos = try Photo.filter(newIds.contains(Photo.Columns.id)).fetchAll(db)
        let basenameById = Dictionary(uniqueKeysWithValues: photos.compactMap { photo in photo.id.map { ($0, photo.basename) } })
        let sortedIds = newIds.sorted { a, b in
            (basenameById[a] ?? "").localizedStandardCompare(basenameById[b] ?? "") == .orderedAscending
        }

        var position = try nextPosition(albumId: albumId, in: db)
        for photoId in sortedIds {
            try PhotoAlbum(photoId: photoId, albumId: albumId, addedAt: now, position: position).insert(db)
            position += 1
        }
    }

    public static func removePhoto(photoId: Int64, albumId: Int64, in db: Database) throws {
        _ = try PhotoAlbum
            .filter(Column("photo_id") == photoId && Column("album_id") == albumId)
            .deleteAll(db)
    }

    /// Batch counterpart to `addPhotos`, for the multi-select "Add to Album" menu's
    /// toggle-off case.
    public static func removePhotos(photoIds: [Int64], albumId: Int64, in db: Database) throws {
        _ = try PhotoAlbum
            .filter(Column("album_id") == albumId && photoIds.contains(Column("photo_id")))
            .deleteAll(db)
    }

    /// Flips membership and reports the resulting state, for a close-up-view "in this
    /// album" checkbox/toggle.
    @discardableResult
    public static func toggleMembership(photoId: Int64, albumId: Int64, now: Int64, in db: Database) throws -> Bool {
        let exists = try PhotoAlbum
            .filter(Column("photo_id") == photoId && Column("album_id") == albumId)
            .fetchCount(db) > 0
        if exists {
            try removePhoto(photoId: photoId, albumId: albumId, in: db)
            return false
        } else {
            try addPhoto(photoId: photoId, albumId: albumId, now: now, in: db)
            return true
        }
    }
}
