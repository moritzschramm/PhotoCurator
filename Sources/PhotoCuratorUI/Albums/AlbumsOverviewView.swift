import SwiftUI
import Observation
import GRDB
import PhotoCuratorCore

@MainActor
@Observable
final class AlbumSummariesStore {
    private(set) var summaries: [AlbumSummary] = []
    private var task: Task<Void, Never>?

    func start(database: AppDatabase) {
        guard task == nil else { return }
        task = Task { [weak self] in
            let observation = ValueObservation.tracking { db in try AlbumRepository.fetchAllAlbumSummaries(in: db) }
            do {
                for try await value in observation.values(in: database.dbPool) {
                    guard !Task.isCancelled else { return }
                    self?.summaries = value
                }
            } catch { }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                if let path = summary.coverThumbnailPath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
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
