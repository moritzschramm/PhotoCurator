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

        return migrator
    }
}
