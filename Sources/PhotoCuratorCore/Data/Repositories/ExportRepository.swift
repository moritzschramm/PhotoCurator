import Foundation
import GRDB

/// The `exports` table is the source of truth for "already published" (spec §7.6).
/// Dedup is always by content hash — target files are never re-hashed, since the
/// separate gallery-builder may rewrite them after export.
public enum ExportRepository {

    /// True if this exact content has already been exported under this category.
    /// Exporting the same photo into a *different* category is allowed.
    public static func alreadyExported(contentHash: String, category: String?, in db: Database) throws -> Bool {
        var request = ExportRecord.filter(ExportRecord.Columns.contentHash == contentHash)
        if let category {
            request = request.filter(ExportRecord.Columns.category == category)
        } else {
            request = request.filter(ExportRecord.Columns.category == nil)
        }
        return try request.fetchCount(db) > 0
    }

    @discardableResult
    public static func logExport(_ record: ExportRecord, in db: Database) throws -> ExportRecord {
        var record = record
        try record.insert(db)
        return record
    }

    public static func fetchAll(in db: Database) throws -> [ExportRecord] {
        try ExportRecord.fetchAll(db)
    }

    public static func deleteExport(id: Int64, in db: Database) throws {
        _ = try ExportRecord.deleteOne(db, key: id)
    }

    public static func exports(photoId: Int64, in db: Database) throws -> [ExportRecord] {
        try ExportRecord.filter(ExportRecord.Columns.photoId == photoId).fetchAll(db)
    }
}
