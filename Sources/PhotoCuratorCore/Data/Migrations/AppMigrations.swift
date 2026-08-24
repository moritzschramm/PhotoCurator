import Foundation
import GRDB

/// Registers every schema migration for the app database (spec §4). Schema evolves
/// only through named migrations registered here — never by mutating the schema
/// out of band. Migration bodies intentionally use literal SQL/strings rather than
/// referencing current model types, so a later rename of a Swift type can never change
/// the meaning of a migration that already shipped.
public enum AppMigrations {
    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "photos") { t in
                t.column("id", .integer).primaryKey()
                t.column("basename", .text).notNull()
                t.column("source_dir", .text).notNull()
                t.column("capture_date", .integer)
                t.column("lifecycle_state", .text).notNull().defaults(to: "new")
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }
            try db.create(index: "idx_photos_basename", on: "photos", columns: ["basename"])
            try db.create(index: "idx_photos_state", on: "photos", columns: ["lifecycle_state"])
            // Enforces "one logical Photo per shot" (spec §4): a RAW+JPG pair groups under
            // a single Photo row scoped to its camera subdirectory. Two different cameras
            // can legitimately reuse the same basename (e.g. DSC_0001), so the uniqueness
            // is scoped to (source_dir, basename), not basename alone — the spec's own
            // idx_photos_basename is kept above as a plain lookup index.
            try db.create(
                index: "idx_photos_dir_basename",
                on: "photos",
                columns: ["source_dir", "basename"],
                unique: true
            )

            try db.create(table: "representations") { t in
                t.column("id", .integer).primaryKey()
                t.column("photo_id", .integer).notNull().references("photos", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("relative_path", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("file_size", .integer)
                t.column("file_mtime", .integer)
                t.column("content_hash", .text)
                t.column("is_local", .boolean).notNull().defaults(to: false)
                t.column("derivation_state", .text).notNull().defaults(to: "underived")
                t.column("indexed_at", .integer).notNull()
            }
            try db.create(index: "idx_rep_photo", on: "representations", columns: ["photo_id"])
            try db.create(index: "idx_rep_hash", on: "representations", columns: ["content_hash"])
            try db.create(
                index: "idx_rep_path",
                on: "representations",
                columns: ["relative_path"],
                unique: true
            )

            try db.create(table: "exif") { t in
                t.column("representation_id", .integer).primaryKey()
                    .references("representations", onDelete: .cascade)
                t.column("camera_model", .text)
                t.column("lens", .text)
                t.column("iso", .integer)
                t.column("aperture", .double)
                t.column("shutter", .text)
                t.column("focal_length", .double)
                t.column("orientation", .integer)
                t.column("gps_lat", .double)
                t.column("gps_lng", .double)
            }

            try db.create(table: "albums") { t in
                t.column("id", .integer).primaryKey()
                t.column("name", .text).notNull()
                t.column("cover_photo_id", .integer).references("photos", onDelete: .setNull)
                t.column("created_at", .integer).notNull()
            }

            try db.create(table: "photo_albums") { t in
                t.column("photo_id", .integer).notNull().references("photos", onDelete: .cascade)
                t.column("album_id", .integer).notNull().references("albums", onDelete: .cascade)
                t.column("added_at", .integer).notNull()
                t.primaryKey(["photo_id", "album_id"])
            }

            try db.create(table: "exports") { t in
                t.column("id", .integer).primaryKey()
                t.column("photo_id", .integer).notNull().references("photos", onDelete: .cascade)
                t.column("representation_id", .integer).notNull()
                    .references("representations", onDelete: .cascade)
                t.column("content_hash", .text).notNull()
                t.column("category", .text)
                t.column("destination_path", .text).notNull()
                t.column("exported_at", .integer).notNull()
            }
            try db.create(index: "idx_exports_hash", on: "exports", columns: ["content_hash"])
            // Dedup key used by ExportService (spec §7.6): the same bytes already
            // published under the same category should not be re-copied, but exporting
            // the same photo into a *different* category is legitimate.
            try db.create(
                index: "idx_exports_hash_category",
                on: "exports",
                columns: ["content_hash", "category"]
            )

            try db.create(table: "thumbnails") { t in
                t.column("representation_id", .integer).notNull()
                    .references("representations", onDelete: .cascade)
                t.column("size_class", .text).notNull()
                t.column("cache_path", .text).notNull()
                t.primaryKey(["representation_id", "size_class"])
            }

            try db.create(table: "app_state") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text)
            }
        }

        // Manual drag-and-drop ordering within an album (spec: order must be
        // user-controlled and persisted, not derived from capture date or add
        // time). Existing rows are backfilled in their current (added_at, then
        // photo_id as a tiebreaker) order, so pre-existing albums keep their
        // present-day sequence until the user first drags something.
        migrator.registerMigration("v2_photo_album_position") { db in
            try db.alter(table: "photo_albums") { t in
                t.add(column: "position", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: """
                UPDATE photo_albums
                SET position = (
                    SELECT COUNT(*) FROM photo_albums AS p2
                    WHERE p2.album_id = photo_albums.album_id
                    AND (p2.added_at < photo_albums.added_at
                         OR (p2.added_at = photo_albums.added_at AND p2.photo_id < photo_albums.photo_id))
                )
                """)
        }

        // Multiple registered photo-library root directories, replacing the single
        // `photo_folder_bookmark` app_state row. `Photo.sourceDir` and
        // `Representation.relativePath` were previously root-relative with no stored
        // pointer to *which* root — two libraries could otherwise collide on
        // identical relative paths, hence the new `library_id` column and rebuilt
        // unique indexes below (scoped per library instead of globally).
        migrator.registerMigration("v3_multi_photo_library") { db in
            try db.create(table: "photo_libraries") { t in
                t.column("id", .integer).primaryKey()
                t.column("name", .text).notNull()
                t.column("bookmark_data", .blob).notNull()
                t.column("display_order", .integer).notNull()
                t.column("created_at", .integer).notNull()
            }

            // Migrate the legacy single bookmark (app_state, base64-encoded TEXT —
            // see AppStateRepository.setData) into library id 1, so existing installs
            // keep working without re-onboarding. A brand-new install has no such
            // row, and thus no existing photos to backfill either — nothing to do.
            if let base64 = try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'photo_folder_bookmark'"),
               let bookmarkData = Data(base64Encoded: base64) {
                // Best-effort: name the library after its actual folder, not a
                // generic placeholder — resolving the bookmark just decodes the
                // stored path, no live security-scoped access needed for that.
                // `AppEnvironment.bootstrap()` also carries a runtime fallback that
                // fixes this up post-hoc if resolution fails here for any reason.
                var isStale = false
                let name = (try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ))?.lastPathComponent ?? "Photo Library"
                try db.execute(
                    sql: """
                        INSERT INTO photo_libraries (id, name, bookmark_data, display_order, created_at)
                        VALUES (1, ?, ?, 0, ?)
                        """,
                    arguments: [name, bookmarkData, Int64(Date().timeIntervalSince1970)]
                )
                try db.execute(sql: "DELETE FROM app_state WHERE key = 'photo_folder_bookmark'")
            }

            // Defaults to 1 for the ALTER TABLE's own sake (SQLite requires a default
            // for a NOT NULL column added to a possibly-non-empty table); a fresh
            // install has zero existing rows to default, and only ever gets a real
            // library_id assigned at actual insert time, once the user has added at
            // least one library through onboarding.
            try db.alter(table: "photos") { t in
                t.add(column: "library_id", .integer)
                    .notNull().defaults(to: 1)
                    .references("photo_libraries", onDelete: .cascade)
            }
            try db.alter(table: "representations") { t in
                t.add(column: "library_id", .integer)
                    .notNull().defaults(to: 1)
                    .references("photo_libraries", onDelete: .cascade)
            }

            try db.drop(index: "idx_photos_dir_basename")
            try db.create(
                index: "idx_photos_dir_basename",
                on: "photos",
                columns: ["library_id", "source_dir", "basename"],
                unique: true
            )
            try db.drop(index: "idx_rep_path")
            try db.create(
                index: "idx_rep_path",
                on: "representations",
                columns: ["library_id", "relative_path"],
                unique: true
            )
        }

        // `LifecycleState.published` no longer exists — exporting a photo used to
        // overwrite its review verdict entirely, which made it impossible to notice
        // "this was accepted and exported, but has since been downgraded to
        // candidate/rejected" (needed to know when to remove it from the export
        // folder). "Currently exported" is now derived from the `exports` log
        // instead, independent of the review verdict, so photos that were
        // `published` become `reviewed` (i.e. `.accepted`, same raw string as
        // before) — the closest honest description of "this one was considered
        // good enough to export."
        migrator.registerMigration("v4_lifecycle_accepted") { db in
            try db.execute(sql: "UPDATE photos SET lifecycle_state = 'reviewed' WHERE lifecycle_state = 'published'")
        }

        // Two lookups that had no index to serve them. `exports` is queried by
        // (photo_id, category) throughout `ExportService` but was only indexed by
        // content hash; `photo_albums` is queried by `album_id` alone (album
        // contents, counts, membership) while its primary key leads with `photo_id`,
        // which a B-tree can't use for an album-only lookup.
        migrator.registerMigration("v5_export_and_album_lookup_indexes") { db in
            try db.create(
                index: "idx_exports_photo_category",
                on: "exports",
                columns: ["photo_id", "category"]
            )
            try db.create(
                index: "idx_photo_albums_album",
                on: "photo_albums",
                columns: ["album_id"]
            )
        }

        return migrator
    }
}
