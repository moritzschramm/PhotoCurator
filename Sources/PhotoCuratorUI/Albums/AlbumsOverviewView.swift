import SwiftUI
import Observation
import GRDB
import PhotoCuratorCore

@MainActor
@Observable
final class AlbumSummariesStore {
    private(set) var summaries: [AlbumSummary] = []
    private let observationTask = CancellableTaskBox()
    private var hasStarted = false

    /// Without this the observation outlives the store — it holds only a `weak self`,
    /// so nothing keeps the store alive, but nothing cancels the task either — and
    /// GRDB keeps recomputing every album's summary on every database write for the
    /// rest of the session.
    deinit {
        observationTask.cancel()
    }

    func start(database: AppDatabase) {
        guard !hasStarted else { return }
        hasStarted = true
        observationTask.replace(with: Task { [weak self] in
            let observation = ValueObservation.tracking { db in try AlbumRepository.fetchAllAlbumSummaries(in: db) }
            do {
                for try await value in observation.values(in: database.dbPool) {
                    guard !Task.isCancelled else { return }
                    self?.summaries = value
                }
            } catch { }
        })
    }
}

/// Third primary surface, overview half (spec §7.5, §8): every album at a glance,
/// with a cover thumbnail and count; tapping one opens the browse view (a
/// `PhotoGridScreen` scoped to that album).
///
/// A `LazyVGrid` of cards, with each column's width computed explicitly from the
/// available width (`GeometryReader` + `.fixed(itemWidth)`) rather than
/// `GridItem(.adaptive(...))` — an earlier attempt using `.adaptive` consistently
/// rendered oversized and positionally offset in this NavigationSplitView detail
/// column, and explicit `.frame`/`GeometryReader` sizing on top of `.adaptive`
/// columns didn't resolve it. Fixed, explicitly-computed column widths sidestep
/// whatever `.adaptive` was doing wrong instead of fighting it further.
struct AlbumsOverviewView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store = AlbumSummariesStore()
    let onSelectAlbum: (Int64) -> Void

    private let minCardWidth: CGFloat = 180
    private let maxCardWidth: CGFloat = 260
    private let gridSpacing: CGFloat = 20
    private let gridPadding: CGFloat = 20

    var body: some View {
        Group {
            if store.summaries.isEmpty {
                ContentUnavailableView(
                    "No Albums Yet",
                    systemImage: "square.stack",
                    description: Text("Create an album from the Library grid to see it here.")
                )
            } else {
                GeometryReader { geometry in
                    let availableWidth = geometry.size.width - gridPadding * 2
                    let columnCount = max(1, Int((availableWidth + gridSpacing) / (minCardWidth + gridSpacing)))
                    let itemWidth = min(
                        maxCardWidth,
                        (availableWidth - gridSpacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
                    )
                    let columns = Array(repeating: GridItem(.fixed(itemWidth), spacing: gridSpacing), count: columnCount)

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: gridSpacing) {
                            ForEach(store.summaries) { summary in
                                Button {
                                    onSelectAlbum(summary.album.id ?? -1)
                                } label: {
                                    AlbumCard(summary: summary, width: itemWidth)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(gridPadding)
                    }
                }
            }
        }
        .navigationTitle("Albums")
        .task {
            store.start(database: environment.database)
        }
    }
}

private struct AlbumCard: View {
    let summary: AlbumSummary
    let width: CGFloat

    /// Loaded through the shared cache rather than `NSImage(contentsOfFile:)` inline:
    /// a `body` runs on the main thread and re-runs on every layout pass, so reading
    /// the file there put a synchronous disk read per card into each one.
    @State private var coverImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                if let coverImage {
                    Image(nsImage: coverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: width)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "square.stack")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: width, height: width)
            .task(id: summary.coverThumbnailPath) {
                guard let path = summary.coverThumbnailPath else {
                    coverImage = nil
                    return
                }
                coverImage = await ThumbnailImageCache.load(path)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.album.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("^[\(summary.photoCount) photo](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}
