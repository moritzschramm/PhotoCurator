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

    /// Read directly by the Edit menu's Undo/Redo commands, which consult
    /// `canUndo`/`canRedo` on it live at click time rather than through any mirrored
    /// `@Observable` state here — see `PhotoCuratorApp`'s `.commands` for why.
    public let undoManager = UndoManager()

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
    /// Chains actual undo/redo mutation work sequentially — `canUndo`/`canRedo` only
    /// gate the menu's affordance, so anything that calls `undo()`/`redo()` twice in
    /// quick succession (a fast repeated keypress, a script) must still have both
    /// steps apply in order, not race or silently drop the second one.
    private var undoRedoQueueTail: Task<Void, Never>?
    /// Same serialize-by-chaining idea as `undoRedoQueueTail`, for background
    /// reconciles — see `startBackgroundReconcile`.
    private var backgroundReconcileTail: Task<Void, Never>?
    private var inFlightBackgroundReconciles = 0

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

        // Our registrations always happen well after the triggering NSEvent's own
        // extent (several run-loop turns removed, inside an already-awaited async
        // method), so Foundation's default event-based grouping has nothing
        // meaningful to key off — disabling it makes grouping fully deterministic.
        undoManager.groupsByEvent = false
        // Foundation defaults to unlimited; a "Remove Library" undo snapshot can hold
        // a large library's full row set in memory for the life of the stack.
        undoManager.levelsOfUndo = 25
    }

    /// Registers an undo/redo pair for a mutation this method just performed. See
    /// `UndoManager.registerReversiblePair` for the synchronous-registration/
    /// deferred-mutation split this relies on to keep undo/redo "ping-pong" correct.
    private func registerUndo(
        name: String,
        undo: @escaping @MainActor @Sendable (AppEnvironment) async -> Void,
        redo: @escaping @MainActor @Sendable (AppEnvironment) async -> Void
    ) {
        undoManager.registerReversiblePair(
            withTarget: self,
            actionName: name,
            undo: { env in await env.runSerializedUndoRedo { await undo(env) } },
            redo: { env in await env.runSerializedUndoRedo { await redo(env) } }
        )
    }

    private func runSerializedUndoRedo(_ work: @escaping @MainActor @Sendable () async -> Void) async {
        let previous = undoRedoQueueTail
        let task = Task { @MainActor in
            _ = await previous?.value
            await work()
        }
        undoRedoQueueTail = task
        await task.value
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

        // Awaited here, at the top, rather than fired off in the background: the
        // sweep can only tell a live thumbnail from an orphan by whether a row points
        // at it, so it has to finish before any derivation starts writing files whose
        // rows aren't committed yet. It's one directory listing plus one query, so
        // the cost is negligible next to the reconcile that follows.
        if let thumbnailCacheDirectory = try? AppPaths.thumbnailCacheDirectory() {
            await ThumbnailCacheMaintenance.sweepOrphans(directory: thumbnailCacheDirectory, database: database)
        }

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
                    // Not routed through the public `renamePhotoLibrary` — this is an
                    // automatic one-time migration fixup, not a user action, and
                    // shouldn't push a surprise "Rename Library" entry onto the undo
                    // stack the moment the app launches.
                    await applyRenamePhotoLibrary(id: library.id, name: actualName)
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
        // Captured as raw `Data`, not the current `SecurityScopedFolder` object —
        // the forward action below is about to release that object's security scope,
        // so undo must re-resolve a fresh grant from the bookmark bytes rather than
        // reuse an already-stopped one.
        let previousBookmarkData = try? await database.read { db in
            try AppStateRepository.getData(AppStateKey.exportFolderBookmark, in: db)
        }
        guard await applyChangeExportTarget(bookmarkData: bookmarkData) else { return false }

        registerUndo(
            name: "Change Export Folder",
            undo: { env in
                guard let previousBookmarkData else { return }
                _ = await env.applyChangeExportTarget(bookmarkData: previousBookmarkData)
            },
            redo: { env in _ = await env.applyChangeExportTarget(bookmarkData: bookmarkData) }
        )
        return true
    }

    @discardableResult
    private func applyChangeExportTarget(bookmarkData: Data) async -> Bool {
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
        guard let library = try? await database.write({ db in
            try PhotoLibraryRepository.create(name: name, bookmarkData: bookmarkData, now: Int64(Date().timeIntervalSince1970), in: db)
        }), let id = library.id else { return false }
        guard await applyAttachNewLibrary(id: id, name: name, bookmarkData: bookmarkData) else { return false }

        // Threads a snapshot between this ping-ponging pair: undo captures the
        // library's state fresh, right before deleting it — so anything
        // reconciliation found for it between the original add and the undo isn't
        // lost — and redo restores whatever undo most recently captured, not the
        // empty state from the moment of creation.
        let snapshotBox = LibrarySnapshotBox()
        registerUndo(
            name: "Add Library",
            undo: { env in snapshotBox.snapshot = await env.applyDeleteLibrary(id: id) },
            redo: { env in
                guard let snapshot = snapshotBox.snapshot else { return }
                _ = await env.applyRestoreLibrary(snapshot)
            }
        )
        return true
    }

    public func removePhotoLibrary(id: Int64) async {
        guard let snapshot = await applyDeleteLibrary(id: id) else { return }
        registerUndo(
            name: "Remove Library",
            undo: { env in _ = await env.applyRestoreLibrary(snapshot) },
            redo: { env in _ = await env.applyDeleteLibrary(id: id) }
        )
    }

    /// Deletes a library, capturing and returning everything it held so a
    /// subsequent undo can bring it back exactly.
    @discardableResult
    private func applyDeleteLibrary(id: Int64) async -> PhotoLibrarySnapshot? {
        guard let snapshot = try? await database.read({ db in try PhotoLibraryRepository.snapshot(id: id, in: db) }) else { return nil }
        _ = try? await database.write { db in try PhotoLibraryRepository.delete(id: id, in: db) }
        folderAccess.photoLibraries.removeAll { $0.id == id }
        return snapshot
    }

    /// Restores a full snapshot's rows, then reattaches its folder — used by
    /// undo-of-remove and redo-of-add.
    @discardableResult
    private func applyRestoreLibrary(_ snapshot: PhotoLibrarySnapshot) async -> Bool {
        _ = try? await database.write { db in try PhotoLibraryRepository.restore(snapshot, in: db) }
        return await applyAttachNewLibrary(id: snapshot.library.id, name: snapshot.library.name, bookmarkData: snapshot.library.bookmarkData)
    }

    /// Resolves a library's bookmark into a fresh security-scoped grant and wires it
    /// into `folderAccess`/reconciliation — the common tail shared by a brand-new
    /// `addPhotoLibrary` call and a snapshot-based restore.
    @discardableResult
    private func applyAttachNewLibrary(id: Int64?, name: String, bookmarkData: Data) async -> Bool {
        guard let id else { return false }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
        ) else { return false }
        let folder = SecurityScopedFolder(url: url)
        beginPersistentAccess(folder)
        let libraryFolder = PhotoLibraryFolder(id: id, name: name, folder: folder)
        if !folderAccess.photoLibraries.contains(where: { $0.id == id }) {
            folderAccess.photoLibraries.append(libraryFolder)
        }

        if folderAccess.isFullyGranted, launchPhase == .ready {
            // Already up and running — index just this library in the background
            // rather than re-scanning every already-registered one.
            startBackgroundReconcile(photoLibraries: [LibrarySource(id: id, url: libraryFolder.url)])
        } else if folderAccess.isFullyGranted {
            await proceedPastGate()
        }
        return true
    }

    public func renamePhotoLibrary(id: Int64, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let previousName = folderAccess.photoLibraries.first(where: { $0.id == id })?.name, previousName != trimmed else { return }

        await applyRenamePhotoLibrary(id: id, name: trimmed)
        registerUndo(
            name: "Rename Library",
            undo: { env in await env.applyRenamePhotoLibrary(id: id, name: previousName) },
            redo: { env in await env.applyRenamePhotoLibrary(id: id, name: trimmed) }
        )
    }

    private func applyRenamePhotoLibrary(id: Int64, name: String) async {
        _ = try? await database.write { db in try PhotoLibraryRepository.rename(id: id, name: name, in: db) }
        if let index = folderAccess.photoLibraries.firstIndex(where: { $0.id == id }) {
            let existing = folderAccess.photoLibraries[index]
            folderAccess.photoLibraries[index] = PhotoLibraryFolder(id: id, name: name, folder: existing.folder)
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
        // Queued behind whatever is already reconciling rather than started
        // immediately: `ReconciliationService` rejects a concurrent call outright
        // (`ReconciliationError.alreadyRunning`), and that error is swallowed by the
        // `try?` below — so adding a library while the launch reconcile is still
        // walking a large library used to leave the new one silently unindexed until
        // the next launch. Chaining also keeps the paired `processLocalBacklog` from
        // reading "local but underived" rows out from under a reconcile that hasn't
        // finished inserting them yet.
        inFlightBackgroundReconciles += 1
        isSyncingInBackground = true
        let previous = backgroundReconcileTail
        backgroundReconcileTail = Task { [weak self, reconciliationService, derivationQueue] in
            _ = await previous?.value
            try? await reconciliationService.reconcile(photoLibraries: photoLibraries, exportFolder: exportFolder)
            if let self {
                // Floored at zero rather than decremented blindly: `resetApp` zeroes
                // the counter while a reconcile may still be in flight, and a
                // decrement past zero would leave the `== 0` check below permanently
                // false — wedging the spinner on for the rest of the session.
                inFlightBackgroundReconciles = max(0, inFlightBackgroundReconciles - 1)
                // Only the last one still queued clears the indicator — an earlier
                // link finishing doesn't mean the chain is done.
                if inFlightBackgroundReconciles == 0 { isSyncingInBackground = false }
            }
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
        let previousStates = (try? await database.read { db in
            try PhotoRepository.fetchLifecycleStates(photoIds: photoIds, in: db)
        }) ?? [:]
        guard await applyLifecycleState(state, to: photoIds) else { return }

        registerUndo(
            name: "Set Lifecycle",
            undo: { env in await env.applyLifecycleStates(previousStates) },
            redo: { env in _ = await env.applyLifecycleState(state, to: photoIds) }
        )
    }

    @discardableResult
    private func applyLifecycleState(_ state: LifecycleState, to photoIds: [Int64]) async -> Bool {
        do {
            switch state {
            case .accepted: try await LifecycleActions.markAccepted(photoIds: photoIds, database: database)
            case .candidate: try await LifecycleActions.markCandidate(photoIds: photoIds, database: database)
            case .rejected: try await LifecycleActions.markRejected(photoIds: photoIds, database: database)
            case .new: try await LifecycleActions.markUnreviewed(photoIds: photoIds, database: database)
            }
        } catch { return false }
        scheduleSnapshotSoon()
        return true
    }

    /// Restores a mixed-state selection to each photo's own individual prior state
    /// (not one shared "previous state" — a multi-select undo can start from a mix
    /// of accepted/candidate/rejected/new).
    private func applyLifecycleStates(_ states: [Int64: LifecycleState]) async {
        let idsByState = Dictionary(grouping: states.keys, by: { states[$0]! })
        for (state, ids) in idsByState {
            _ = try? await database.write { db in
                try PhotoRepository.setLifecycleState(photoIds: Array(ids), state: state, now: Int64(Date().timeIntervalSince1970), in: db)
            }
        }
        scheduleSnapshotSoon()
    }

    public func toggleAlbumMembership(photoId: Int64, albumId: Int64) async {
        await applyToggleAlbumMembership(photoId: photoId, albumId: albumId)
        registerUndo(
            name: "Toggle Album Membership",
            // Self-inverse: toggling again exactly reverses it either direction.
            undo: { env in await env.applyToggleAlbumMembership(photoId: photoId, albumId: albumId) },
            redo: { env in await env.applyToggleAlbumMembership(photoId: photoId, albumId: albumId) }
        )
    }

    private func applyToggleAlbumMembership(photoId: Int64, albumId: Int64) async {
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
        // `addPhotos` is idempotent and only actually adds photos not already a
        // member — undo must remove exactly that subset, not every id passed in,
        // since some may have been pre-existing members that must stay.
        let existingMemberIds = (try? await database.read { db in
            try AlbumRepository.albumIds(photoIds: photoIds, in: db)
        }) ?? [:]
        let newlyAddedIds = photoIds.filter { !(existingMemberIds[$0]?.contains(albumId) ?? false) }
        guard !newlyAddedIds.isEmpty else { return }

        await applyAddPhotos(newlyAddedIds, albumId: albumId)
        registerUndo(
            name: "Add to Album",
            undo: { env in await env.applyRemovePhotos(newlyAddedIds, albumId: albumId) },
            redo: { env in await env.applyAddPhotos(newlyAddedIds, albumId: albumId) }
        )
    }

    private func applyAddPhotos(_ photoIds: [Int64], albumId: Int64) async {
        _ = try? await database.write { db in
            try AlbumRepository.addPhotos(photoIds: photoIds, albumId: albumId, now: Int64(Date().timeIntervalSince1970), in: db)
        }
        scheduleSnapshotSoon()
    }

    private func applyRemovePhotos(_ photoIds: [Int64], albumId: Int64) async {
        _ = try? await database.write { db in
            try AlbumRepository.removePhotos(photoIds: photoIds, albumId: albumId, in: db)
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
        if allAreMembers {
            await applyRemovePhotos(photoIds, albumId: albumId)
        } else {
            await applyAddPhotos(photoIds, albumId: albumId)
        }
        registerUndo(
            name: "Toggle Album Membership",
            undo: { env in
                if allAreMembers { await env.applyAddPhotos(photoIds, albumId: albumId) }
                else { await env.applyRemovePhotos(photoIds, albumId: albumId) }
            },
            redo: { env in
                if allAreMembers { await env.applyRemovePhotos(photoIds, albumId: albumId) }
                else { await env.applyAddPhotos(photoIds, albumId: albumId) }
            }
        )
    }

    /// Persists a drag-and-drop reorder within an album's browse grid.
    public func reorderAlbumPhotos(albumId: Int64, orderedPhotoIds: [Int64]) async {
        let previousOrder = (try? await database.read { db in
            try AlbumRepository.orderedPhotoIds(albumId: albumId, in: db)
        }) ?? []
        guard previousOrder != orderedPhotoIds else { return }

        await applyReorder(albumId: albumId, orderedPhotoIds: orderedPhotoIds)
        registerUndo(
            name: "Reorder Album",
            undo: { env in await env.applyReorder(albumId: albumId, orderedPhotoIds: previousOrder) },
            redo: { env in await env.applyReorder(albumId: albumId, orderedPhotoIds: orderedPhotoIds) }
        )
    }

    private func applyReorder(albumId: Int64, orderedPhotoIds: [Int64]) async {
        _ = try? await database.write { db in
            try AlbumRepository.reorderPhotos(albumId: albumId, orderedPhotoIds: orderedPhotoIds, in: db)
        }
        scheduleSnapshotSoon()
    }

    @discardableResult
    public func createAlbum(name: String) async -> Album? {
        guard let album = try? await database.write({ db in
            try AlbumRepository.createAlbum(name: name, now: Int64(Date().timeIntervalSince1970), in: db)
        }) else { return nil }
        scheduleSnapshotSoon()

        registerUndo(
            name: "Create Album",
            undo: { env in await env.applyDeleteAlbum(id: album.id ?? -1) },
            redo: { env in await env.applyRestoreAlbum(album, memberships: []) }
        )
        return album
    }

    public func deleteAlbum(id: Int64) async {
        guard let album = try? await database.read({ db in try AlbumRepository.fetchAlbum(id: id, in: db) }) else { return }
        let memberships = (try? await database.read { db in try AlbumRepository.fetchMemberships(albumId: id, in: db) }) ?? []

        await applyDeleteAlbum(id: id)
        registerUndo(
            name: "Delete Album",
            undo: { env in await env.applyRestoreAlbum(album, memberships: memberships) },
            redo: { env in await env.applyDeleteAlbum(id: id) }
        )
    }

    private func applyDeleteAlbum(id: Int64) async {
        _ = try? await database.write { db in try AlbumRepository.deleteAlbum(id: id, in: db) }
        scheduleSnapshotSoon()
    }

    private func applyRestoreAlbum(_ album: Album, memberships: [PhotoAlbum]) async {
        _ = try? await database.write { db in
            try AlbumRepository.restore(album, in: db)
            try AlbumRepository.restore(memberships, in: db)
        }
        scheduleSnapshotSoon()
    }

    public func renameAlbum(id: Int64, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let previousName = try? await database.read({ db in try AlbumRepository.fetchAlbum(id: id, in: db)?.name }) else { return }
        guard previousName != trimmed else { return }

        await applyRenameAlbum(id: id, name: trimmed)
        registerUndo(
            name: "Rename Album",
            undo: { env in await env.applyRenameAlbum(id: id, name: previousName) },
            redo: { env in await env.applyRenameAlbum(id: id, name: trimmed) }
        )
    }

    private func applyRenameAlbum(id: Int64, name: String) async {
        _ = try? await database.write { db in try AlbumRepository.renameAlbum(id: id, name: name, in: db) }
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

        let records = outcomes.compactMap(\.undoInfo)
        if !records.isEmpty {
            let batch = ImportUndoBatch(records: records)
            registerUndo(
                name: "Import Photos",
                undo: { env in await env.undoImportBatch(batch) },
                redo: { env in await env.redoImportBatch(batch, targetLibraryId: targetLibraryId, protonFolderURL: targetLibraryRootURL) }
            )
        }
        return outcomes
    }

    /// Trashes every imported file in the batch and removes its representation row,
    /// deleting the shared photo row too if that was its last remaining
    /// representation — `deletePhotoIfEmpty`'s own remaining-count check decides
    /// this per record, not which side originally created it (see `ImportUndoRecord`).
    private func undoImportBatch(_ batch: ImportUndoBatch) async {
        for record in batch.records {
            guard let representationId = record.representation.id else { continue }
            if let trashedURL = try? TrashDisposal.moveToTrash(record.destinationFileURL) {
                batch.trashedURLs[representationId] = trashedURL
            }
        }
        _ = try? await database.write { db in
            for record in batch.records {
                guard let representationId = record.representation.id else { continue }
                try PhotoRepository.deleteRepresentation(id: representationId, in: db)
                if let deletedPhoto = try PhotoRepository.deletePhotoIfEmpty(photoId: record.representation.photoId, in: db) {
                    batch.deletedPhotos[record.representation.photoId] = deletedPhoto
                }
            }
        }
        scheduleSnapshotSoon()
    }

    /// Restores whatever `undoImportBatch` most recently trashed/deleted — skips a
    /// record entirely (file and row) if its trashed file no longer exists, e.g. the
    /// user emptied Trash mid-session, rather than reinserting a row that points at
    /// nothing.
    private func redoImportBatch(_ batch: ImportUndoBatch, targetLibraryId: Int64, protonFolderURL: URL) async {
        var restoredIdsBuilder: Set<Int64> = []
        for record in batch.records {
            guard let representationId = record.representation.id,
                  let trashedURL = batch.trashedURLs[representationId],
                  FileManager.default.fileExists(atPath: trashedURL.path) else { continue }
            guard (try? TrashDisposal.restore(from: trashedURL, to: record.destinationFileURL)) != nil else { continue }
            restoredIdsBuilder.insert(representationId)
        }
        let restoredRepresentationIds = restoredIdsBuilder
        _ = try? await database.write { db in
            // A RAW+JPG pair shares one photo row, so both records name the same
            // `photoId` — restoring it twice violates the primary key and throws,
            // which would roll back every row restore in this transaction while the
            // files have already been moved back out of the Trash. Each photo row is
            // therefore restored at most once per batch.
            var restoredPhotoIds: Set<Int64> = []
            for record in batch.records {
                guard let representationId = record.representation.id, restoredRepresentationIds.contains(representationId) else { continue }
                let photoId = record.representation.photoId
                if !restoredPhotoIds.contains(photoId), let photo = batch.deletedPhotos[photoId] {
                    try PhotoRepository.restorePhoto(photo, in: db)
                    restoredPhotoIds.insert(photoId)
                }
                try PhotoRepository.restoreRepresentation(record.representation, in: db)
            }
        }
        batch.deletedPhotos.removeAll()
        scheduleSnapshotSoon()
        let queue = derivationQueue
        Task.detached(priority: .utility) {
            await queue.processLocalBacklog(photoRoots: [targetLibraryId: protonFolderURL])
        }
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

        let records = results.compactMap(\.undoInfo)
        if !records.isEmpty {
            // Threads where each undo trashed a file to a later redo — undoing
            // again after a redo works by simply calling `undoExport` on the SAME
            // original `records` a second time (a fresh trash each time), so only
            // this one box, not a growing chain, is ever needed.
            let trashedURLsBox = ExportTrashedURLsBox()
            registerUndo(
                name: "Export Album",
                undo: { env in
                    let (_, trashedURLs) = await env.exportService.undoExport(records, category: category, exportFolderURL: exportFolderURL)
                    trashedURLsBox.trashedURLs = trashedURLs
                    env.scheduleSnapshotSoon()
                },
                redo: { env in
                    _ = await env.exportService.redoExport(
                        records, trashedURLs: trashedURLsBox.trashedURLs, category: category, exportFolderURL: exportFolderURL
                    )
                    env.scheduleSnapshotSoon()
                }
            )
        }
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

    // MARK: Reset

    /// Wipes every photo library, album, and export record PhotoCurator knows about
    /// and takes the app back to first-run state — never touches any file on disk
    /// (original library files or already-exported files are outside the database
    /// entirely, see `AppReset`). Never itself undoable, and clears any pending undo
    /// history, since almost everything on the stack references rows or trashed
    /// files this wipe makes meaningless to reverse. The caller is expected to call
    /// `bootstrap()` again immediately after, which — since `hasStartedBootstrap` is
    /// reset here — re-runs the normal first-launch sequence and naturally lands on
    /// `.awaitingFolderAccess`, exactly like a fresh install.
    public func resetApp() async {
        undoManager.removeAllActions()

        photosObservationTask?.cancel()
        albumsObservationTask?.cancel()
        unassignedObservationTask?.cancel()
        snapshotDebounceTask?.cancel()
        // Dropped, not just cancelled: a queued reconcile chain re-registers the
        // wiped libraries' rows, and leaving the tail in place would make the next
        // chain link await a task belonging to the pre-reset session.
        backgroundReconcileTail?.cancel()
        backgroundReconcileTail = nil
        inFlightBackgroundReconciles = 0

        try? await AppReset.resetDatabase(database)
        if let thumbnailCacheDirectory = try? AppPaths.thumbnailCacheDirectory() {
            try? AppReset.resetThumbnailCache(directory: thumbnailCacheDirectory)
        }

        for url in accessStartedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessStartedURLs.removeAll()

        folderAccess = FolderAccessStatus(photoLibraries: [], exportTarget: nil)
        gridEntries = []
        albums = []
        unassignedGridEntries = []
        isSyncingInBackground = false
        hasStartedBootstrap = false
        launchPhase = .notStarted
    }
}

/// Threads a value between a ping-ponging undo/redo pair registered via
/// `AppEnvironment.registerUndo`, when redo needs whatever undo most recently
/// produced rather than a value fixed at registration time. `@unchecked Sendable` is
/// justified here: every access happens on `AppEnvironment`'s `@MainActor`, serialized
/// through `runSerializedUndoRedo`, so it's never touched concurrently.
private final class LibrarySnapshotBox: @unchecked Sendable {
    var snapshot: PhotoLibrarySnapshot?
}

/// Mutable state shared between an import's undo/redo pair — `undoImportBatch` fills
/// in `trashedURLs`/`deletedPhotos` as it works, and `redoImportBatch` reads them back.
/// Same `@unchecked Sendable` justification as `LibrarySnapshotBox`: MainActor-only,
/// serialized through `runSerializedUndoRedo`.
private final class ImportUndoBatch: @unchecked Sendable {
    let records: [ImportUndoRecord]
    var trashedURLs: [Int64: URL] = [:]
    var deletedPhotos: [Int64: Photo] = [:]

    init(records: [ImportUndoRecord]) {
        self.records = records
    }
}

/// Threads the trash locations `ExportService.undoExport` produces into a later
/// `redoExport` call. Same `@unchecked Sendable` justification as the boxes above.
private final class ExportTrashedURLsBox: @unchecked Sendable {
    var trashedURLs: [Int: URL] = [:]
}
