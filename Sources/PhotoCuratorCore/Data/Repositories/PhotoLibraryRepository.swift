import Foundation
import GRDB

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

    private static func nextDisplayOrder(in db: Database) throws -> Int64 {
        let maxOrder = try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(display_order), -1) FROM photo_libraries"
        ) ?? -1
        return maxOrder + 1
    }
}
