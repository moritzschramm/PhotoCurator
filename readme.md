# PhotoCurator

A native macOS app for reviewing camera photos synced through a directory,
curating them into albums, and exporting selected JPGs to a gallery target.
Implements `specification.md` in full (see that file for the authoritative behavior spec).
This README covers how the implementation is organized and how to build/run/test it.

- DISCLAIMER: this project was fully implemented by Claude Code

## Requirements

- macOS 14 (Sonoma) or later, Xcode 16+ / Swift 5.10 toolchain.
- No Xcode project file — this is a plain Swift Package. Open it in Xcode with
  `open Package.swift`, or build entirely from the command line.

## Build & run

**Quick dev loop** (fast, but unsandboxed — fine for iterating on logic/UI):
```sh
swift run PhotoCurator
```

**Real sandboxed app** (matches how it'll actually run — entitlements, security-scoped
bookmarks, the works):
```sh
Scripts/build_app.sh debug      # or: release
open .build/app/PhotoCurator.app
```
The script compiles the SwiftPM executable, wraps it in a proper `.app` bundle with
`Resources/Info.plist`, and ad-hoc codesigns it with `Resources/PhotoCurator.entitlements`.
No paid Apple Developer account is needed to run it locally this way — only to
notarize/distribute via Developer ID or the App Store later.

**Tests:**
```sh
swift test
```

On first launch the app hard-gates on two folder grants (the Proton photo library and
the export/gallery target) — pick any two folders to get past onboarding during
development.

## Module layout

Three SwiftPM targets, following spec §10:

- **`PhotoCuratorCore`** — everything except UI. No SwiftUI/AppKit dependency other
  than `CoreImage`/`ImageIO` for rendering, so it stays independently testable.
  - `Data/` — GRDB records (`Models/`), `Repositories/` (plain functions over an open
    `Database`, no threading concerns of their own), `AppMigrations`, `AppDatabase`
    (owns the `DatabasePool`), `SnapshotService` (`VACUUM INTO` backups).
  - `Identity/` — provisional key (filename+size+mtime) and `CryptoKit` content hashing.
  - `Storage/` — security-scoped bookmarks, directory enumeration, online-only detection.
  - `Reconcile/` — `ReconciliationPlanner` (pure diff, no I/O — see tests) and
    `ReconciliationService` (applies the plan transactionally).
  - `Import/` — SD volume detection, the copy→verify→derive→place pipeline.
  - `Derivation/` — thumbnail (ImageIO) and EXIF extraction, plus the queue that runs
    them immediately for local files / lazily on first view for online-only ones.
  - `Rendering/` — the `CIRAWFilter` wrapper.
  - `Export/`, `Lifecycle/` — publish pipeline, lifecycle transition helpers.
- **`PhotoCuratorUI`** — SwiftUI shell + the AppKit `NSCollectionView` grid
  (`Grid/PhotoGridViewController.swift`), wrapped for SwiftUI via
  `NSViewControllerRepresentable`. `AppEnvironment` (`@Observable`) wires the Core
  services together and is the one piece of app-wide state, injected via
  `.environment(_:)`.
- **`PhotoCuratorApp`** — thin executable target: `@main` App struct +
  `AppDelegate` (owns `AppEnvironment`, hooks quit-time snapshot via the
  `.terminateLater` pattern).

`Tests/PhotoCuratorCoreTests` covers migrations (schema, FK cascades, unique
constraints), identity (content hashing against direct CryptoKit computation,
provisional-key equality), the reconciliation diff in isolation, and an
integration suite that runs `ReconciliationService` against real files in a temp
directory (new/unchanged/moved/removed, idempotency).
