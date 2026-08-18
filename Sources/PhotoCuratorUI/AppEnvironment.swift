import Foundation
import Observation
import GRDB
import PhotoCuratorCore

/// Everything the UI layer needs: the Core services, resolved folder access, and the
/// live, observable app state (photos, albums, launch progress). One instance lives
/// for the whole app session, owned by `AppDelegate`.
@MainActor
@Observable
public final class AppEnvironment {
    public enum LaunchPhase: Equatable {
        case notStarted
        /// Re-resolving previously-granted bookmarks on launch — brief and
        /// usually succeeds, so it shows a generic splash rather than the
        /// folder-picker UI (see `awaitingFolderAccess`), which would otherwise
        /// flash on screen every launch even though folders are already granted.
        case resolvingFolderAccess
        /// Resolution finished and at least one folder genuinely isn't granted —
        /// the real picker UI.
        case awaitingFolderAccess
        case reconciling(ReconciliationService.Progress)
        case ready
        case failed(String)
    }

    public let database: AppDatabase
    public let snapshotService: SnapshotService
    public let reconciliationService: ReconciliationService
    public let derivationService: DerivationService
    public let derivationQueue: DerivationQueue
    public let importPipeline: ImportPipeline
    public let exportService: ExportService

    public var launchPhase: LaunchPhase = .notStarted
    public var folderAccess = FolderAccessStatus(photoLibraries: [], exportTarget: nil)
    public var gridEntries: [PhotoGridEntry] = []
    public var albums: [Album] = []
    /// Reviewed (accepted/candidate) photos not yet filed into any album — the
    /// "Unassigned Photos" sidebar entry.
    public var unassignedGridEntries: [PhotoGridEntry] = []
    /// True while a post-launch reconcile is running in the background (see
    /// `proceedPastGate`) — the grid is already live and usable during this, so
    /// this is purely an informational "still syncing" signal, not a gate.
    public var isSyncingInBackground = false

    public var exportFolderURL: URL? { folderAccess.exportTarget?.url }
    /// Whichever library was registered first — used only as the single, fixed
    /// destination for the DB snapshot backup (spec §3). No user-facing "primary
    /// library" concept beyond that.
    public var primaryLibraryRootURL: URL? { folderAccess.photoLibraries.first?.url }

    public func libraryRootURL(for libraryId: Int64) -> URL? {
        folderAccess.photoLibraries.first { $0.id == libraryId }?.url
    }

    public func photo(id: Int64) -> PhotoWithRepresentations? {
        gridEntries.first { $0.id == id }?.photo
    }

    /// The grid's "All Libraries" vs. one-specific-library filter — an in-memory
    /// filter over the single already-loaded `gridEntries` observation, not a
    /// separate per-library query, since switching libraries should feel instant.
    public func gridEntries(libraryId: Int64?) -> [PhotoGridEntry] {
        guard let libraryId else { return gridEntries }
        return gridEntries.filter { $0.photo.photo.libraryId == libraryId }
    }

    private var photosObservationTask: Task<Void, Never>?
    private var albumsObservationTask: Task<Void, Never>?
    private var unassignedObservationTask: Task<Void, Never>?
    private var snapshotDebounceTask: Task<Void, Never>?
    private var accessStartedURLs: [URL] = []
    private var hasStartedBootstrap = false

    public init() throws {
        let db = try AppDatabase.openDefault()
        database = db
        snapshotService = SnapshotService(database: db)
        reconciliationService = ReconciliationService(database: db)
        let thumbnailCacheDirectory = (try? AppPaths.thumbnailCacheDirectory()) ?? FileManager.default.temporaryDirectory
        let derivation = DerivationService(database: db, thumbnailCacheDirectory: thumbnailCacheDirectory)
        derivationService = derivation
        let queue = DerivationQueue(database: db, derivationService: derivation)
        derivationQueue = queue
        importPipeline = ImportPipeline(database: db, derivationService: derivation)
        exportService = ExportService(database: db, derivationQueue: queue)
    }

    // MARK: Launch sequence

    public func bootstrap() async {
        // Idempotency guard, not just a caller-side check: this class is
        // MainActor-isolated, so the check-and-set here is atomic relative to any
        // other MainActor work — safe even if `bootstrap()` is called from two
        // independent places (AppDelegate *and* a SwiftUI `.task`, previously) whose
        // relative scheduling order isn't guaranteed. Without this, two concurrent
        // calls both pass a caller-side "already started?" check before either has
        // mutated state, both proceed to reconcile, the second hits
        // `ReconciliationService`'s `isRunning` guard and fails, and that failure
        // can overwrite (or be overwritten by) the first call's real completion —
        // which briefly flashes the failure screen right as the real one finishes.
        guard !hasStartedBootstrap else { return }
        hasStartedBootstrap = true

        launchPhase = .resolvingFolderAccess
        do {
            folderAccess = try await BookmarkStore.resolveAll(database: database)
        } catch {
            launchPhase = .failed("Could not resolve folder access: \(error.localizedDescription)")
            return
        }
        for library in folderAccess.photoLibraries {
            beginPersistentAccess(library.folder)
            // One-time correction: the pre-multi-library migration had no reliable
            // way to derive a real folder name for the single library it created
            // from the legacy bookmark, so it fell back to this literal placeholder.
            // Fix it up to the folder's actual name on first launch after upgrading
            // — a harmless no-op for anyone who's since renamed a library to
            // literally "Photo Library" themselves.
            if library.name == "Photo Library" {
                let actualName = library.url.lastPathComponent
                if actualName != library.name {
                    await renamePhotoLibrary(id: library.id, name: actualName)
                }
            }
        }
        guard folderAccess.isFullyGranted else {
            launchPhase = .awaitingFolderAccess
            return
        }
        await proceedPastGate()
    }

    /// The export-target picker calls this once it's already turned the picked URL
    /// into bookmark `Data` *synchronously*, in the picker's own completion handler
    /// (spec §9: hard-gate until fully granted). See `BookmarkStore.makeBookmarkData`
    /// for why that step can't be deferred into this `async` method.
    public func grantExportAccess(bookmarkData: Data) async {
        do {
            try await BookmarkStore.saveExportBookmarkData(bookmarkData, database: database)
            folderAccess.exportTarget = try await BookmarkStore.resolveExportTarget(database: database)
        } catch {
            launchPhase = .failed("Could not save folder access: \(error.localizedDescription)")
            return
        }
        if let exportTarget = folderAccess.exportTarget {
            beginPersistentAccess(exportTarget)
        }
        if folderAccess.isFullyGranted {
            await proceedPastGate()
        }
    }

    /// Changes the export target to a different, already-granted folder — unlike
    /// `grantExportAccess` (the onboarding path), this runs once the app is already
    /// `.ready`, so it releases access to the old folder and only reconciles the new
    /// export target itself rather than re-running the full launch sequence (no
    /// reason to re-scan every photo library just because the export folder moved).
    /// Same synchronous-bookmark-creation contract as `grantExportAccess`. Returns
    /// whether it succeeded, so the caller can surface an error inline.
    @discardableResult
    public func changeExportTarget(bookmarkData: Data) async -> Bool {
        let oldExportTarget = folderAccess.exportTarget
        do {
            try await BookmarkStore.saveExportBookmarkData(bookmarkData, database: database)
            folderAccess.exportTarget = try await BookmarkStore.resolveExportTarget(database: database)
        } catch {
            return false
        }
        guard let newExportTarget = folderAccess.exportTarget else { return false }
        beginPersistentAccess(newExportTarget)
        if let oldExportTarget, oldExportTarget.url != newExportTarget.url {
            oldExportTarget.url.stopAccessingSecurityScopedResource()
            accessStartedURLs.removeAll { $0 == oldExportTarget.url }
        }
        if folderAccess.isFullyGranted {
            startBackgroundReconcile(photoLibraries: [], exportFolder: newExportTarget.url)
        }
        return true
    }

    /// Registers a new photo library. Same synchronous-bookmark-creation contract as
    /// `grantExportAccess`. Returns whether it succeeded, so the caller (a "Manage
    /// Libraries" list) can surface an error inline.
    @discardableResult
    public func addPhotoLibrary(bookmarkData: Data, name: String) async -> Bool {
        do {
            let library = try await database.write { db in
                try PhotoLibraryRepository.create(name: name, bookmarkData: bookmarkData, now: Int64(Date().timeIntervalSince1970), in: db)
            }
            guard let id = library.id else { return false }
            var isStale = false
            let folder = SecurityScopedFolder(url: try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ))
            beginPersistentAccess(folder)
            let libraryFolder = PhotoLibraryFolder(id: id, name: name, folder: folder)
            folderAccess.photoLibraries.append(libraryFolder)

            if folderAccess.isFullyGranted, launchPhase == .ready {
                // Already up and running — index just the new library in the
                // background rather than re-scanning every already-registered one.
                startBackgroundReconcile(photoLibraries: [LibrarySource(id: id, url: libraryFolder.url)])
            } else if folderAccess.isFullyGranted {
                await proceedPastGate()
            }
            return true
        } catch {
            return false
        }
    }

    public func removePhotoLibrary(id: Int64) async {
        _ = try? await database.write { db in try PhotoLibraryRepository.delete(id: id, in: db) }
        folderAccess.photoLibraries.removeAll { $0.id == id }
    }

    public func renamePhotoLibrary(id: Int64, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? await database.write { db in try PhotoLibraryRepository.rename(id: id, name: trimmed, in: db) }
        if let index = folderAccess.photoLibraries.firstIndex(where: { $0.id == id }) {
            let existing = folderAccess.photoLibraries[index]
            folderAccess.photoLibraries[index] = PhotoLibraryFolder(id: id, name: trimmed, folder: existing.folder)
        }
    }

    private func proceedPastGate() async {
        guard folderAccess.isFullyGranted, let exportTarget = folderAccess.exportTarget else {
            launchPhase = .awaitingFolderAccess
            return
        }
        // Photo libraries already had `beginPersistentAccess` called on them either
        // in `bootstrap()` (resolved from persisted bookmarks) or `addPhotoLibrary`
        // (just granted) — only the export target's access is started here.
        beginPersistentAccess(exportTarget)

        startObservingDatabase()

        let librarySources = folderAccess.photoLibraries.map { LibrarySource(id: $0.id, url: $0.url) }

        // A genuine first-ever launch has an empty DB and nothing to show early
        // regardless, and `establishBaselineIfNeeded` (inside `reconcile`) must
        // run before any photo row is visible — otherwise every photo would
        // flash as an unreviewed "candidate" before baseline retroactively marks
        // it "reviewed". Every later launch already has last-known-good rows
        // sitting in the DB, which the live observation above is already
        // streaming into `gridEntries` — so there's no reason to block the grid
        // behind a fresh filesystem walk that (assuming little changed since
        // last quit) will mostly just confirm what's already on screen.
        let baselineEstablished = (try? await database.read { db in
            try AppStateRepository.getBool(AppStateKey.baselineEstablished, in: db)
        }) ?? false

        if baselineEstablished {
            launchPhase = .ready
            // Handles its own derivation backlog after reconcile completes (see
            // `startBackgroundReconcile`) — must not also fire it here, which would
            // run concurrently with reconcile's own writes instead of after them.
            startBackgroundReconcile(photoLibraries: librarySources, exportFolder: exportTarget.url)
        } else {
            launchPhase = .reconciling(.init(phase: .enumeratingPhotoLibrary))
            do {
                try await reconciliationService.reconcile(
                    photoLibraries: librarySources,
                    exportFolder: exportTarget.url
                ) { [weak self] progress in
                    Task { @MainActor in self?.launchPhase = .reconciling(progress) }
                }
            } catch {
                launchPhase = .failed("Startup indexing failed: \(error.localizedDescription)")
                return
            }
            launchPhase = .ready

            let queue = derivationQueue
            let roots = Dictionary(uniqueKeysWithValues: folderAccess.photoLibraries.map { ($0.id, $0.url) })
            Task.detached(priority: .utility) {
                await queue.processLocalBacklog(photoRoots: roots)
            }
        }
    }

    /// Runs reconciliation off to the side of an already-`.ready` UI, then derives
    /// thumbnails/hashes for whatever local files it just found — chained to run
    /// *after* reconcile completes, not concurrently, since starting both at once
    /// lets derivation's read of "local, underived" representations race reconcile's
    /// own writes and silently miss anything reconcile hasn't inserted yet. Errors
    /// from reconcile are swallowed rather than surfaced as `.failed`: the grid
    /// already reflects last-known-good state, so a transient failure here (e.g. a
    /// folder briefly unreachable) isn't worth interrupting the user over the way it
    /// is on the blocking first-launch path. `exportFolder` defaults to the current
    /// grant since a targeted single-library reconcile (e.g. right after
    /// `addPhotoLibrary`) still needs to reconcile the (unchanged) export target too.
    private func startBackgroundReconcile(photoLibraries: [LibrarySource], exportFolder: URL? = nil) {
        guard let exportFolder = exportFolder ?? folderAccess.exportTarget?.url else { return }
        isSyncingInBackground = true
        Task { [weak self, reconciliationService, derivationQueue] in
            try? await reconciliationService.reconcile(photoLibraries: photoLibraries, exportFolder: exportFolder)
            self?.isSyncingInBackground = false
            let roots = Dictionary(uniqueKeysWithValues: photoLibraries.map { ($0.id, $0.url) })
            await derivationQueue.processLocalBacklog(photoRoots: roots)
        }
    }

    private func beginPersistentAccess(_ folder: SecurityScopedFolder) {
        if folder.url.startAccessingSecurityScopedResource() {
            accessStartedURLs.append(folder.url)
        }
    }

    // MARK: Live state

    private func startObservingDatabase() {
        photosObservationTask?.cancel()
        photosObservationTask = Task { [weak self, database] in
            let observation = ValueObservation.tracking { db in try PhotoRepository.fetchGridEntries(db) }
            do {
                for try await entries in observation.values(in: database.dbPool) {
                    guard !Task.isCancelled else { return }
                    self?.gridEntries = entries
                }
            } catch {
                // Observation stops on unrecoverable DB errors; the rest of the app
                // still functions against whatever was last loaded.
            }
        }

        albumsObservationTask?.cancel()
        albumsObservationTask = Task { [weak self, database] in
            let observation = ValueObservation.tracking { db in try AlbumRepository.fetchAllAlbums(in: db) }
            do {
                for try await albums in observation.values(in: database.dbPool) {
                    guard !Task.isCancelled else { return }
                    self?.albums = albums
                }
            } catch { }
        }

        // Reads both `photos` and `photo_albums`, so GRDB's observation naturally
        // re-fires when either changes — a photo added to an album disappears from
        // here the moment that write commits, no separate invalidation needed.
        unassignedObservationTask?.cancel()
        unassignedObservationTask = Task { [weak self, database] in
            let observation = ValueObservation.tracking { db in try PhotoRepository.fetchUnassignedGridEntries(db) }
            do {
                for try await entries in observation.values(in: database.dbPool) {
                    guard !Task.isCancelled else { return }
                    self?.unassignedGridEntries = entries
                }
            } catch { }
        }
    }

    // MARK: Mutations (all schedule a debounced snapshot — spec §3)

    public func setLifecycle(photoIds: [Int64], state: LifecycleState) async {
        guard !photoIds.isEmpty else { return }
        do {
            switch state {
            case .accepted: try await LifecycleActions.markAccepted(photoIds: photoIds, database: database)
            case .candidate: try await LifecycleActions.markCandidate(photoIds: photoIds, database: database)
            case .rejected: try await LifecycleActions.markRejected(photoIds: photoIds, database: database)
            case .new: break // system-only state, not user-assignable
            }
            scheduleSnapshotSoon()
        } catch { }
    }

    public func toggleAlbumMembership(photoId: Int64, albumId: Int64) async {
        _ = try? await database.write { db in
            try AlbumRepository.toggleMembership(photoId: photoId, albumId: albumId, now: Int64(Date().timeIntervalSince1970), in: db)
        }
        scheduleSnapshotSoon()
    }

    /// Bulk "add selected photos to this album" (e.g. the grid's multi-select
    /// toolbar menu, used when a group of photos isn't already in the album at
    /// all) — sorts a fresh batch alphabetically by filename, appended after
    /// whatever's already there (see `AlbumRepository.addPhotos`).
    public func addPhotosToAlbum(photoIds: [Int64], albumId: Int64) async {
        guard !photoIds.isEmpty else { return }
        _ = try? await database.write { db in
            try AlbumRepository.addPhotos(photoIds: photoIds, albumId: albumId, now: Int64(Date().timeIntervalSince1970), in: db)
        }
        scheduleSnapshotSoon()
    }

    /// Which albums each of these photos already belongs to — for showing a
    /// checkmark per album in an "Add to Album" menu.
    public func albumIds(forPhotoIds photoIds: [Int64]) async -> [Int64: Set<Int64>] {
        (try? await database.read { db in try AlbumRepository.albumIds(photoIds: photoIds, in: db) }) ?? [:]
    }

    /// Toggles a whole selection's membership in one album at once: if every photo
    /// is already a member, removes all of them; otherwise adds all of them (the
    /// usual tri-state-checkbox convention for a mixed selection) — `allAreMembers`
    /// is computed by the caller from `albumIds(forPhotoIds:)`, which it already
    /// needed to render the checkmark in the first place.
    public func toggleAlbumMembershipForSelection(photoIds: [Int64], albumId: Int64, allAreMembers: Bool) async {
        guard !photoIds.isEmpty else { return }
        _ = try? await database.write { db in
            if allAreMembers {
                try AlbumRepository.removePhotos(photoIds: photoIds, albumId: albumId, in: db)
            } else {
                try AlbumRepository.addPhotos(photoIds: photoIds, albumId: albumId, now: Int64(Date().timeIntervalSince1970), in: db)
            }
        }
        scheduleSnapshotSoon()
    }

    /// Persists a drag-and-drop reorder within an album's browse grid.
    public func reorderAlbumPhotos(albumId: Int64, orderedPhotoIds: [Int64]) async {
        _ = try? await database.write { db in
            try AlbumRepository.reorderPhotos(albumId: albumId, orderedPhotoIds: orderedPhotoIds, in: db)
        }
        scheduleSnapshotSoon()
    }

    @discardableResult
    public func createAlbum(name: String) async -> Album? {
        let album = try? await database.write { db in
            try AlbumRepository.createAlbum(name: name, now: Int64(Date().timeIntervalSince1970), in: db)
        }
        scheduleSnapshotSoon()
        return album
    }

    public func deleteAlbum(id: Int64) async {
        _ = try? await database.write { db in try AlbumRepository.deleteAlbum(id: id, in: db) }
        scheduleSnapshotSoon()
    }

    public func renameAlbum(id: Int64, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? await database.write { db in try AlbumRepository.renameAlbum(id: id, name: trimmed, in: db) }
        scheduleSnapshotSoon()
    }

    // MARK: Import

    public func scanImportCandidates(sourceFolder: URL, targetLibraryId: Int64) async throws -> [ImportGroup] {
        try await importPipeline.scan(sourceFolder: sourceFolder, targetLibraryId: targetLibraryId)
    }

    public func runImport(
        groups: [ImportGroup],
        subdirectoryOverrides: [String: String],
        targetLibraryId: Int64,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [ImportFileOutcome] {
        guard let targetLibraryRootURL = libraryRootURL(for: targetLibraryId) else { return [] }
        let outcomes = await importPipeline.importGroups(
            groups,
            chosenSubdirectories: subdirectoryOverrides,
            targetLibraryId: targetLibraryId,
            protonFolderURL: targetLibraryRootURL,
            onProgress: onProgress
        )
        scheduleSnapshotSoon()
        let queue = derivationQueue
        Task.detached(priority: .utility) {
            await queue.processLocalBacklog(photoRoots: [targetLibraryId: targetLibraryRootURL])
        }
        return outcomes
    }

    // MARK: Export

    /// Dry run for the album Export button's confirmation dialog — `category` is
    /// always the album's current name.
    public func planAlbumExport(albumId: Int64, category: String) async -> AlbumExportPlan {
        guard let exportFolderURL else { return AlbumExportPlan() }
        return await exportService.planAlbumExport(albumId: albumId, category: category, exportFolderURL: exportFolderURL)
    }

    public func applyAlbumExportPlan(_ plan: AlbumExportPlan, category: String) async -> [ExportItemResult] {
        guard let exportFolderURL else { return [] }
        let roots = Dictionary(uniqueKeysWithValues: folderAccess.photoLibraries.map { ($0.id, $0.url) })
        let results = await exportService.applyAlbumExportPlan(
            plan, category: category, exportFolderURL: exportFolderURL, libraryRootURL: { roots[$0] }
        )
        scheduleSnapshotSoon()
        return results
    }

    // MARK: Snapshot lifecycle

    private func scheduleSnapshotSoon() {
        guard let photoLibraryRootURL = primaryLibraryRootURL else { return }
        snapshotDebounceTask?.cancel()
        snapshotDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            await self.snapshotService.requestSnapshot(protonFolderURL: photoLibraryRootURL)
        }
    }

    /// Called by `AppDelegate.applicationShouldTerminate` before allowing quit to
    /// proceed (spec §3: snapshot on quit).
    public func snapshotBeforeQuit() async {
        snapshotDebounceTask?.cancel()
        if let primaryLibraryRootURL {
            await snapshotService.requestSnapshot(protonFolderURL: primaryLibraryRootURL)
        }
        for url in accessStartedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessStartedURLs.removeAll()
    }
}
