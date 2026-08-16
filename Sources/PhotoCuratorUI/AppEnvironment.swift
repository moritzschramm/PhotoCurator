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
    public let sdVolumeDetector: SDVolumeDetector

    public var launchPhase: LaunchPhase = .notStarted
    public var folderAccess = FolderAccessStatus(photoLibrary: nil, exportTarget: nil)
    public var gridEntries: [PhotoGridEntry] = []
    public var albums: [Album] = []
    public var mountedVolumePendingImport: MountedVolume?

    public var photoLibraryRootURL: URL? { folderAccess.photoLibrary?.url }
    public var exportFolderURL: URL? { folderAccess.exportTarget?.url }
    public func photo(id: Int64) -> PhotoWithRepresentations? {
        gridEntries.first { $0.id == id }?.photo
    }

    private var photosObservationTask: Task<Void, Never>?
    private var albumsObservationTask: Task<Void, Never>?
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
        sdVolumeDetector = SDVolumeDetector()
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

        sdVolumeDetector.onVolumeMounted = { [weak self] volume in
            Task { @MainActor in self?.mountedVolumePendingImport = volume }
        }
        sdVolumeDetector.start()

        launchPhase = .awaitingFolderAccess
        do {
            folderAccess = try await BookmarkStore.resolveAll(database: database)
        } catch {
            launchPhase = .failed("Could not resolve folder access: \(error.localizedDescription)")
            return
        }
        guard folderAccess.isFullyGranted else { return }
        await proceedPastGate()
    }

    /// First-run (or any-run, if a bookmark had to be re-granted) folder pickers call
    /// this once they've already turned the picked URL into bookmark `Data`
    /// *synchronously*, in the picker's own completion handler (spec §9: hard-gate
    /// until both are granted). See `BookmarkStore.makeBookmarkData` for why that
    /// step can't be deferred into this `async` method.
    public func grantAccess(bookmarkData: Data, role: FolderRole) async {
        do {
            try await BookmarkStore.saveBookmarkData(bookmarkData, role: role, database: database)
            folderAccess = try await BookmarkStore.resolveAll(database: database)
        } catch {
            launchPhase = .failed("Could not save folder access: \(error.localizedDescription)")
            return
        }
        if folderAccess.isFullyGranted {
            await proceedPastGate()
        }
    }

    private func proceedPastGate() async {
        guard let photoLibrary = folderAccess.photoLibrary, let exportTarget = folderAccess.exportTarget else {
            launchPhase = .awaitingFolderAccess
            return
        }
        beginPersistentAccess(photoLibrary)
        beginPersistentAccess(exportTarget)

        startObservingDatabase()

        launchPhase = .reconciling(.init(phase: .enumeratingPhotoLibrary))
        do {
            try await reconciliationService.reconcile(
                photoFolder: photoLibrary.url,
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
        let root = photoLibrary.url
        Task.detached(priority: .utility) {
            await queue.processLocalBacklog(photoRoot: root)
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
    }

    // MARK: Mutations (all schedule a debounced snapshot — spec §3)

    public func setLifecycle(photoIds: [Int64], state: LifecycleState) async {
        guard !photoIds.isEmpty else { return }
        do {
            switch state {
            case .reviewed: try await LifecycleActions.markReviewed(photoIds: photoIds, database: database)
            case .candidate: try await LifecycleActions.markCandidate(photoIds: photoIds, database: database)
            case .rejected: try await LifecycleActions.markRejected(photoIds: photoIds, database: database)
            case .new, .published: break // system/export-only states, not user-assignable
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

    // MARK: Import

    public func scanImportCandidates(sourceFolder: URL) async throws -> [ImportGroup] {
        try await importPipeline.scan(sourceFolder: sourceFolder)
    }

    public func runImport(
        groups: [ImportGroup],
        subdirectoryOverrides: [String: String],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [ImportFileOutcome] {
        guard let photoLibraryRootURL else { return [] }
        let outcomes = await importPipeline.importGroups(
            groups,
            chosenSubdirectories: subdirectoryOverrides,
            protonFolderURL: photoLibraryRootURL,
            onProgress: onProgress
        )
        scheduleSnapshotSoon()
        let queue = derivationQueue
        Task.detached(priority: .utility) {
            await queue.processLocalBacklog(photoRoot: photoLibraryRootURL)
        }
        return outcomes
    }

    // MARK: Export

    public func runExport(photoIds: [Int64], category: String?) async -> [ExportItemResult] {
        guard let photoLibraryRootURL, let exportFolderURL else { return [] }
        let results = await exportService.exportPhotos(
            photoIds: photoIds,
            category: category,
            exportFolderURL: exportFolderURL,
            photoLibraryRootURL: photoLibraryRootURL
        )
        scheduleSnapshotSoon()
        return results
    }

    // MARK: Snapshot lifecycle

    private func scheduleSnapshotSoon() {
        guard let photoLibraryRootURL else { return }
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
        if let photoLibraryRootURL {
            await snapshotService.requestSnapshot(protonFolderURL: photoLibraryRootURL)
        }
        sdVolumeDetector.stop()
        for url in accessStartedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessStartedURLs.removeAll()
    }
}
