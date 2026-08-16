# Photo Curation App — v1 Implementation Specification

A native macOS application for reviewing camera photos, curating them into albums, and
exporting selected images to a website gallery. The photo library lives in a Proton Drive
folder with on-demand (online-only) sync; the app must operate without downloading the
whole library.

This document is a complete build spec. Implement exactly the v1 scope described. Items
under "Deferred (not v1)" must not be built yet.

## 1. Platform, language, and toolchain

- **Target:** macOS only. Deployment target macOS 14 (Sonoma) or later.
- **Language:** Swift only. No cross-platform core, no FFI, no bridging layer.
- **UI:** SwiftUI for the application shell, panels, and toolbars. The main photo grid must
  be an AppKit `NSCollectionView` wrapped in `NSViewRepresentable` for virtualized,
  high-cell-count scrolling. Do not build the primary grid with SwiftUI `LazyVGrid`.
- **Persistence:** SQLite via **GRDB.swift** (Swift Package Manager). Use GRDB's migration
  runner, WAL mode, and value observation.
- **Imaging:** System frameworks only — **ImageIO** and **Core Image** (`CIRAWFilter`) for
  decoding, thumbnails, and RAW rendering. No third-party RAW decoder.
- **Hashing:** **CryptoKit** SHA-256 for content hashing. No perceptual-hash library
  (exact hashes are sufficient in v1).
- **Volume / device:** **DiskArbitration** and `NSWorkspace.didMountNotification` for
  SD-card mount detection. **UniformTypeIdentifiers** for type handling.
- **Build:** Xcode. Dependency management via Swift Package Manager only (no CocoaPods,
  no Carthage). Profile the grid with Instruments early.

**Dependencies (SwiftPM):**
- `GRDB.swift` — the only expected external dependency in v1.
- Optional dev-only: SwiftLint, SwiftFormat (as SwiftPM build-tool plugins).

## 2. Core principles (non-negotiable invariants)

1. **Never modify or move originals.** All access to the Proton folder and the SD card is
   read-only. Every piece of app state lives in the database, never in file changes.
2. **Never trigger a mass download.** Directory enumeration (names, sizes, dates,
   online-only status) is free and must never open file bytes. Reading bytes materializes
   an online-only file — do this only for files the user explicitly acts on, or for local
   files that are already materialized.
3. **The database is the only irreplaceable asset.** Thumbnails, EXIF, and hashes are
   derived and can be rebuilt by rescanning. Lifecycle state, album membership, and the
   export log are user decisions and cannot be recovered — protect them.
4. **Front-load byte-dependent work while files are local.** Generate derivatives at
   import time (from the SD card) so steady-state browsing never touches the cloud.

## 3. Storage layout

- **Originals:** Untouched in the Proton Drive folder, in per-camera subdirectories.
  Proton's File Provider integration keeps them local or online-only (placeholders).
- **Live database + thumbnail cache:** In the app's **Application Support** directory
  (`~/Library/Application Support/<app>/`), never inside the Proton folder, never evicted.
  Use Application Support (not Caches) for thumbnails, because regenerating a thumbnail for
  an evicted original requires re-downloading it — expensive.
- **Database backup:** On quit, on idle, and after any significant state change (album
  edit, lifecycle change), write a **consistent snapshot** with `VACUUM INTO` to a single
  fixed file inside the Proton folder (overwrite the same filename each time). Proton
  versions that quiescent file safely. Never place the live `.db`/`-wal`/`-shm` files in
  the Proton folder.

## 4. Data model (SQLite via GRDB)

One logical **Photo** per shot, grouped by basename, owning one or more **Representation**
rows (RAW and/or JPG). The model must tolerate a photo with only one representation
(RAW-only or JPG-only).

Album membership is a **relation**, orthogonal to lifecycle. "In an album" is derived from
having at least one `photo_albums` row; do not add a redundant lifecycle value for it.

```sql
-- Curation status of a shot. "in album" is NOT a status here; it is derived from
-- photo_albums membership. A photo can be e.g. published AND in two albums.
-- lifecycle_state in ('new','reviewed','candidate','published','rejected')
-- check if these schemas make sense, change if necessary

CREATE TABLE photos (
    id            INTEGER PRIMARY KEY,
    basename      TEXT NOT NULL,            -- grouping key across representations
    source_dir    TEXT NOT NULL,            -- per-camera subdirectory (relative)
    capture_date  INTEGER,                  -- epoch seconds; from EXIF, else file date
    lifecycle_state TEXT NOT NULL DEFAULT 'new',
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
);
CREATE INDEX idx_photos_basename ON photos(basename);
CREATE INDEX idx_photos_state    ON photos(lifecycle_state);

CREATE TABLE representations (
    id             INTEGER PRIMARY KEY,
    photo_id       INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
    kind           TEXT NOT NULL,           -- 'raw' | 'jpg'
    relative_path  TEXT NOT NULL,           -- path within the photo root
    filename       TEXT NOT NULL,
    file_size      INTEGER,
    file_mtime     INTEGER,
    content_hash   TEXT,                    -- SHA-256, NULL until materialized+derived
    is_local       INTEGER NOT NULL DEFAULT 0,  -- 1 = materialized, 0 = online-only
    derivation_state TEXT NOT NULL DEFAULT 'underived', -- 'underived' | 'derived'
    indexed_at     INTEGER NOT NULL
);
CREATE INDEX idx_rep_photo   ON representations(photo_id);
CREATE INDEX idx_rep_hash    ON representations(content_hash);
CREATE UNIQUE INDEX idx_rep_path ON representations(relative_path);

CREATE TABLE exif (
    representation_id INTEGER PRIMARY KEY REFERENCES representations(id) ON DELETE CASCADE,
    camera_model  TEXT,
    lens          TEXT,
    iso           INTEGER,
    aperture      REAL,
    shutter       TEXT,
    focal_length  REAL,
    orientation   INTEGER,
    gps_lat       REAL,
    gps_lng       REAL
);

CREATE TABLE albums (
    id            INTEGER PRIMARY KEY,
    name          TEXT NOT NULL,
    cover_photo_id INTEGER REFERENCES photos(id) ON DELETE SET NULL,
    created_at    INTEGER NOT NULL
);

CREATE TABLE photo_albums (
    photo_id  INTEGER NOT NULL REFERENCES photos(id)  ON DELETE CASCADE,
    album_id  INTEGER NOT NULL REFERENCES albums(id)  ON DELETE CASCADE,
    added_at  INTEGER NOT NULL,
    PRIMARY KEY (photo_id, album_id)
);

-- Export log: source of truth for "already published". Do NOT re-hash target files.
CREATE TABLE exports (
    id                INTEGER PRIMARY KEY,
    photo_id          INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
    representation_id INTEGER NOT NULL REFERENCES representations(id) ON DELETE CASCADE,
    content_hash      TEXT NOT NULL,
    category          TEXT,                 -- target subdirectory / album name
    destination_path  TEXT NOT NULL,
    exported_at       INTEGER NOT NULL
);
CREATE INDEX idx_exports_hash ON exports(content_hash);

-- Thumbnails stored as files in Application Support; this table is the manifest.
CREATE TABLE thumbnails (
    representation_id INTEGER NOT NULL REFERENCES representations(id) ON DELETE CASCADE,
    size_class        TEXT NOT NULL,        -- 'grid' | 'preview'
    cache_path        TEXT NOT NULL,
    PRIMARY KEY (representation_id, size_class)
);

CREATE TABLE app_state (
    key   TEXT PRIMARY KEY,
    value TEXT
);
-- app_state keys include: baseline_established, folder bookmarks, last_snapshot_at.
```

**Schema versioning:** Register all migrations with GRDB's `DatabaseMigrator` from day one.
Every schema change is a new named migration. Never mutate the schema outside a migration.

## 5. Identity (two-phase)

- **Provisional identity** (for underived, possibly online-only files): `filename` plus
  `file_size` plus `file_mtime`. Filenames in the main library are stable and may be used
  as the grouping/identity basis. `basename` (filename without extension) groups a RAW and
  its JPG sibling into one Photo.
- **Content identity:** SHA-256 of the file bytes, computed on materialization (when a file
  is opened, becomes a candidate, is published, or is derived from the SD card). Store in
  `representations.content_hash` and upgrade the record. Content hashing is required
  wherever filenames are unreliable (export dedup).
- Reconciliation must **diff, not duplicate**: a moved or renamed file that matches an
  existing content hash updates the existing row rather than creating a new one.

## 6. Lifecycle state machine

States: `new → reviewed → candidate → published`, plus `rejected`. Album membership is a
separate relation (see §4).

- **First-run baseline:** On first launch, after the initial index, mark every existing
  photo as `reviewed` (baseline), not `new`. Set `app_state.baseline_established = true`.
  Only photos imported after this flag is set are marked `new`.
- **Rejected photos are shown**, not hidden, in the main grid. `candidate` and `published`
  photos are visually **highlighted** (badges).
- State changes never touch files.

## 7. Key workflows

### 7.1 Startup reconciliation
On launch, index both the photo directory and the export/gallery target directory:
1. Enumerate the Proton photo folder with `FileManager` directory enumerator, passing
   `includingPropertiesForKeys` to batch-fetch size, dates, and the online-only/dataless
   status in one pass. **Enumeration only — never open bytes.**
2. Diff filesystem state against the database: additions, removals, moves/renames.
   Reconcile (update existing rows) rather than duplicating.
3. Refresh each representation's `is_local` from the online-only status.
4. Enumerate the export target and reconcile the `exports` table if files there changed.
5. Run off the main thread; batch writes; report progress. Idempotent and resumable.

### 7.2 Import-on-insert
1. Detect SD mount via DiskArbitration / `NSWorkspace.didMountNotification`; surface the
   import UI. (Request SD access at insertion time, not at first run — see §9.)
2. Dedup candidate files against the database (provisional key, then content hash).
3. For each new file, in an idempotent, resumable pipeline: copy from card → verify by
   checksum → derive thumbnails/EXIF/content-hash **from the card while local** → mark
   imported → copy the original into the correct per-camera subdirectory of the Proton
   folder. Decouple "imported to local DB" from "uploaded by Proton" (Proton's concern
   once the file is in its folder).
4. New imports are marked `new`.

### 7.3 Lazy derivation and materialization (backlog)
- Local (materialized) files: derive immediately — thumbnails, EXIF, content hash.
- Online-only files: leave `underived` until the user first views or acts on one. On that
  action, materialize (read bytes → Proton downloads), derive, cache permanently, upgrade
  identity to content hash. Never bulk-download.
- All derivation runs on a background queue with a single DB writer; batched writes.

### 7.4 Display and the JPG→RAW swap
- Grid and close-up show the **JPG** first for speed. If no JPG exists, fall back to the
  RAW **embedded preview** via `CGImageSourceCreateThumbnailAtIndex`. Show whichever is
  available/faster first; handle both single-representation cases.
- When a RAW exists, lazily render it in the background via `CIRAWFilter` (the same
  ImageIO/Core Image engine Finder and Preview use, so it matches Quick Look). After a
  short delay (~2–3 s), replace the JPG view with the RAW render. A visible tonal/color
  shift on swap is acceptable (treat it like the image "developing").
- Provide a **toolbar button and a hotkey** to toggle manually between JPG and RAW.
- Verify camera support via `CIRAWFilter.supportedCameraModels` where that API is
  available; otherwise attempt the render and fall back to the embedded preview on failure.

### 7.5 Albums (logical only)
- Albums exist only in the database. Adding a photo to an album creates a `photo_albums`
  row — **no file copy, no directory**. A photo may belong to multiple albums.
- Provide an overview of all albums with their entries, and an album browse view.

### 7.6 Export / publish
- On user request, export selected photos (JPG representation in v1) into the gallery
  target, in per-category subdirectories.
- **Dedup against the `exports` table by content hash**, not by re-hashing target files
  (the separate gallery-builder may rewrite target files). Export only photos whose content
  hash is not already logged for that destination. Record each export in `exports`.
- Set exported photos' `lifecycle_state` to `published`.
- The website gallery itself is built by a separate, external app — out of scope here.

### 7.7 Failure handling
- Acting on an online-only file that fails to materialize (offline, download error, Proton
  not running): perform **one retry**, then display a placeholder ("not available") image.
  Never leave a representation in a half-materialized state.


## 8. UI

Symbol-driven, minimal text, intuitive without explanation. Three primary surfaces:

1. **Main grid:** one large, zoomable scrolling list of all photos, like the macOS Photos
   app (pinch / control to change thumbnail size). Virtualized via `NSCollectionView`.
   Online-only-and-underived tiles show filename + a cloud badge until derived. `candidate`
   and `published` photos are highlighted; `rejected` are shown (dimmed/badged, not hidden).
2. **Close-up view:** single photo, arrow-key navigation between photos, JPG↔RAW toggle
   (button + hotkey), lifecycle actions, add-to-album.
3. **Album view:** browse albums and their entries; overview of all albums.

Keyboard-first review (rate/flag/reject, next/previous) throughout.


## 9. Permissions, sandboxing, entitlements

- Decide App Sandbox vs. a non-sandboxed Developer ID build before wiring folder access.
- If sandboxed: enable App Sandbox, user-selected file access, and app-scoped
  **security-scoped bookmarks** for the two persisted folders (photo directory and export
  directory). **Request both at first run and hard-gate**: if either is not granted, the
  app does not operate and re-requests.
- **SD card:** removable-media access is entitlement-based and resolves when the mounted
  volume is first read at insertion time — it is not a first-run folder grant. Do not
  pre-request it at first run.
- Verify current entitlement keys (removable volumes, user-selected files) against Apple's
  documentation, as these are the most likely details to have changed.
- Signing: a free Apple ID suffices to run locally. A paid Apple Developer Program
  membership is needed only to notarize/distribute (Developer ID) or ship on the App Store.

---

## 10. Suggested module layout

- **Data:** GRDB records, `DatabaseMigrator`, repositories, snapshot (`VACUUM INTO`) service.
- **Storage:** Proton-folder enumeration, online-only detection (URL resource values),
  read-triggered materialization.
- **Import:** SD detection + copy + verify + derive pipeline.
- **Derivation:** thumbnails / EXIF / content-hash on a background queue.
- **Reconcile:** startup filesystem-vs-DB diff for photo and export directories.
- **Export:** export-log dedup and file copy.
- **Rendering:** ImageIO / `CIRAWFilter` wrappers, thumbnail cache manager.
- **UI:** grid (`NSViewRepresentable` + `NSCollectionView`), close-up, album views.

---

## 11. Deferred (NOT v1)

- ML auto-classification of photos into albums (Vision / Core ML embeddings).
- Cross-platform or mobile builds.
- RAW editing (exposure, highlight recovery, and other `CIRAWFilter` controls).
- Any full RAW processing beyond viewing.
- Writing back to / integrating with git or the gallery-builder.

---

## 12. Acceptance checklist for v1

- [ ] App runs sandboxed (or Developer ID), gates on the two folder grants at first run.
- [ ] Startup indexes photo + export directories by enumeration only, no bulk downloads.
- [ ] Every file (local and online-only) has a grid tile; online-only tiles are badged.
- [ ] Local files derive immediately; online-only files derive lazily on first use.
- [ ] SD insertion opens import; new files are copied, verified, derived, deduped.
- [ ] One logical photo per basename; RAW-only and JPG-only shots both display correctly.
- [ ] Close-up shows JPG then swaps to RAW render; button + hotkey toggle works.
- [ ] Albums are logical (DB relations); album overview and browse views work.
- [ ] Export copies only not-yet-published JPGs (export-log hash dedup); logs each export.
- [ ] Lifecycle states and first-run baseline behave as specified; rejected shown,
      candidate/published highlighted.
- [ ] Live DB is local; consistent snapshot written to the Proton folder on quit/idle/change.
- [ ] GRDB migrations registered; schema evolves only through migrations.
- [ ] Originals are never modified or moved; all state is in the DB.
