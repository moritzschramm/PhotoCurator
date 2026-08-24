import Foundation
import Observation
import GRDB
import PhotoCuratorCore

/// Live-updating photo list for one album, used by both the grid screen and the
/// close-up view when browsing within an album (spec §7.5). The whole-library case
/// doesn't need this — it reads `AppEnvironment.gridEntries` directly.
@MainActor
@Observable
final class AlbumScopeStore {
    private(set) var entries: [PhotoGridEntry] = []
    private let observationTask = CancellableTaskBox()
    private var observedAlbumId: Int64?

    /// Without this, the observation task outlives the store: it holds only a `weak
    /// self`, so nothing keeps the store alive, but nothing cancels the task either —
    /// GRDB keeps re-running the album's full photo+representation+thumbnail query on
    /// every database write, forever, with one more leaked observation per album ever
    /// visited.
    deinit {
        observationTask.cancel()
    }

    func start(albumId: Int64, database: AppDatabase) {
        guard observedAlbumId != albumId else { return }
        observedAlbumId = albumId
        observationTask.replace(with: Task { [weak self] in
            let observation = ValueObservation.tracking { db -> [PhotoGridEntry] in
                let photos = try AlbumRepository.photos(albumId: albumId, in: db)
                return try PhotoRepository.attachGridThumbnails(to: photos, db)
            }
            do {
                for try await value in observation.values(in: database.dbPool) {
                    guard !Task.isCancelled else { return }
                    self?.entries = value
                }
            } catch { }
        })
    }

    func stop() {
        observationTask.cancel()
        observedAlbumId = nil
    }
}
