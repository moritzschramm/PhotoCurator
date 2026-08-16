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

    /// All photos in an album, joined with their representations, ordered by when
    /// they were added (most recent addition first).
    public static func photos(albumId: Int64, in db: Database) throws -> [PhotoWithRepresentations] {
        let photoIds = try PhotoAlbum
            .filter(Column("album_id") == albumId)
            .fetchAll(db)
            .map(\.photoId)

        // Newest capture date first, matching the main library grid — sorting by
        // when each photo was *added to the album* instead (the previous
        // behavior) tracks UI click order during multi-select, not anything about
        // the photos themselves, and looks arbitrary when browsing.
        let photos = try Photo
            .filter(photoIds.contains(Photo.Columns.id))
            .order(Photo.Columns.captureDate.desc, Photo.Columns.basename.asc, Photo.Columns.id.asc)
            .fetchAll(db)
        let allReps = try Representation.filter(photoIds.contains(Representation.Columns.photoId)).fetchAll(db)
        let repsByPhoto = Dictionary(grouping: allReps, by: { $0.photoId })

        return photos.map { photo in
            PhotoWithRepresentations(photo: photo, representations: repsByPhoto[photo.id ?? -1] ?? [])
        }
    }

    /// Every album a given photo currently belongs to.
    public static func albumIds(photoId: Int64, in db: Database) throws -> Set<Int64> {
        let rows = try PhotoAlbum.filter(Column("photo_id") == photoId).fetchAll(db)
        return Set(rows.map(\.albumId))
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
    /// directory (spec §7.5). Idempotent: re-adding an already-member photo is a no-op.
    public static func addPhoto(photoId: Int64, albumId: Int64, now: Int64, in db: Database) throws {
        let exists = try PhotoAlbum
            .filter(Column("photo_id") == photoId && Column("album_id") == albumId)
            .fetchCount(db) > 0
        guard !exists else { return }
        let membership = PhotoAlbum(photoId: photoId, albumId: albumId, addedAt: now)
        try membership.insert(db)
    }

    public static func removePhoto(photoId: Int64, albumId: Int64, in db: Database) throws {
        _ = try PhotoAlbum
            .filter(Column("photo_id") == photoId && Column("album_id") == albumId)
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
