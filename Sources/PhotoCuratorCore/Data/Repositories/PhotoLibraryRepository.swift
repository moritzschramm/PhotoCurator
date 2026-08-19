import Foundation
import GRDB

/// A full capture of everything `PhotoLibraryRepository.delete(id:in:)` would cascade
/// away for a given library — produced by `snapshot(id:in:)` before deleting, consumed
/// by `restore(_:in:)` to undo it.
public struct PhotoLibrarySnapshot: Sendable {
    public var library: PhotoLibrary
    public var photos: [Photo]
    public var representations: [Representation]
    public var exifRecords: [ExifRecord]
    public var thumbnails: [ThumbnailRecord]
    public var photoAlbums: [PhotoAlbum]
    public var exports: [ExportRecord]
    /// `(albumId, photoId)` pairs whose `cover_photo_id` pointed at one of this
    /// library's photos — `ON DELETE SET NULL` clears these on delete, so they need
    /// restoring separately from the row re-inserts above.
    public var nulledCoverPhotoIds: [(albumId: Int64, photoId: Int64)]
}

/// CRUD over the registered photo-library directories (see `PhotoLibrary`). Deleting a
/// library cascades through `photos.library_id ON DELETE CASCADE` to every
/// representation/exif/thumbnail/album-membership/export row for its photos — the app
/// never touches the underlying files, only its own records of them.
public enum PhotoLibraryRepository {

    public static func fetchAll(in db: Database) throws -> [PhotoLibrary] {
        try PhotoLibrary.order(PhotoLibrary.Columns.displayOrder.asc).fetchAll(db)
    }

    public static func fetchOne(id: Int64, in db: Database) throws -> PhotoLibrary? {
        try PhotoLibrary.fetchOne(db, key: id)
    }

    @discardableResult
    public static func create(name: String, bookmarkData: Data, now: Int64, in db: Database) throws -> PhotoLibrary {
        let order = try nextDisplayOrder(in: db)
        var library = PhotoLibrary(name: name, bookmarkData: bookmarkData, displayOrder: order, createdAt: now)
        try library.insert(db)
        return library
    }

    public static func rename(id: Int64, name: String, in db: Database) throws {
        try PhotoLibrary.filter(PhotoLibrary.Columns.id == id).updateAll(db, PhotoLibrary.Columns.name.set(to: name))
    }

    /// Re-persists a fresh bookmark for an existing library — mirrors
    /// `BookmarkStore.resolve`'s stale-bookmark handling for the export target.
    public static func updateBookmarkData(id: Int64, bookmarkData: Data, in db: Database) throws {
        try PhotoLibrary
            .filter(PhotoLibrary.Columns.id == id)
            .updateAll(db, PhotoLibrary.Columns.bookmarkData.set(to: bookmarkData))
    }

    /// Deletes the library row, which cascades (via `photos.library_id ON DELETE
    /// CASCADE`) through every photo/representation/album-membership/export record
    /// for it. The library's original files on disk are never touched.
    public static func delete(id: Int64, in db: Database) throws {
        _ = try PhotoLibrary.deleteOne(db, key: id)
    }

    /// Everything `delete(id:in:)` is about to cascade away, captured beforehand so
    /// undo can restore it exactly. Deleting a library never touches any file on
    /// disk — not even the thumbnail cache (its `cache_path` rows cascade away, but
    /// the actual cached JPEGs are never removed) — so restoring these rows with
    /// their original primary keys makes everything valid again with no file work.
    public static func snapshot(id: Int64, in db: Database) throws -> PhotoLibrarySnapshot? {
        guard let library = try fetchOne(id: id, in: db) else { return nil }
        let photos = try Photo.filter(Photo.Columns.libraryId == id).fetchAll(db)
        let photoIds = photos.compactMap(\.id)
        // Matched by *either* FK path (representations.library_id OR
        // representations.photo_id → one of these photos) — both independently
        // cascade on delete, so the snapshot covers the union even if the two ever
        // drifted out of sync.
        let representations = try Representation
            .filter(Representation.Columns.libraryId == id || photoIds.contains(Representation.Columns.photoId))
            .fetchAll(db)
        let representationIds = representations.compactMap(\.id)
        let exifRecords = try ExifRecord.filter(representationIds.contains(Column("representation_id"))).fetchAll(db)
        let thumbnails = try ThumbnailRecord.filter(representationIds.contains(Column("representation_id"))).fetchAll(db)
        let photoAlbums = try PhotoAlbum.filter(photoIds.contains(Column("photo_id"))).fetchAll(db)
        let exports = try ExportRecord.filter(photoIds.contains(ExportRecord.Columns.photoId)).fetchAll(db)
        let nulledCoverPhotoIds = try Album
            .filter(photoIds.contains(Album.Columns.coverPhotoId))
            .fetchAll(db)
            .compactMap { album -> (albumId: Int64, photoId: Int64)? in
                guard let albumId = album.id, let coverPhotoId = album.coverPhotoId else { return nil }
                return (albumId, coverPhotoId)
            }
        return PhotoLibrarySnapshot(
            library: library, photos: photos, representations: representations,
            exifRecords: exifRecords, thumbnails: thumbnails, photoAlbums: photoAlbums,
            exports: exports, nulledCoverPhotoIds: nulledCoverPhotoIds
        )
    }

    /// Re-inserts every row from a `snapshot(id:in:)` at its exact original primary
    /// key, in FK-safe order, then restores any `cover_photo_id` that the delete
    /// had `SET NULL`'d.
    public static func restore(_ snapshot: PhotoLibrarySnapshot, in db: Database) throws {
        var library = snapshot.library
        try library.insert(db)
        for var photo in snapshot.photos { try photo.insert(db) }
        for var representation in snapshot.representations { try representation.insert(db) }
        for exif in snapshot.exifRecords { try exif.insert(db) }
        for thumbnail in snapshot.thumbnails { try thumbnail.insert(db) }
        for photoAlbum in snapshot.photoAlbums { try photoAlbum.insert(db) }
        for var export in snapshot.exports { try export.insert(db) }
        for (albumId, photoId) in snapshot.nulledCoverPhotoIds {
            try Album.filter(Album.Columns.id == albumId).updateAll(db, Album.Columns.coverPhotoId.set(to: photoId))
        }
    }

    private static func nextDisplayOrder(in db: Database) throws -> Int64 {
        let maxOrder = try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(display_order), -1) FROM photo_libraries"
        ) ?? -1
        return maxOrder + 1
    }
}
