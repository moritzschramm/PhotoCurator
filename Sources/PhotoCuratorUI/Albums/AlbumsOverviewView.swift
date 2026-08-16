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
/// A `List` of rows, not a `LazyVGrid` of cards: the grid version consistently
/// rendered oversized and positionally offset in this NavigationSplitView detail
/// column (a `LazyVGrid` + `.adaptive` + `aspectRatio` sizing quirk that several
/// explicit `.frame`/`GeometryReader` attempts didn't resolve). `List` is already
/// proven correct in this exact split view — it's what the sidebar itself is built
/// from — so reusing it sidesteps the ambiguity entirely instead of chasing it further.
struct AlbumsOverviewView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store = AlbumSummariesStore()
    let onSelectAlbum: (Int64) -> Void

    var body: some View {
        Group {
            if store.summaries.isEmpty {
                ContentUnavailableView(
                    "No Albums Yet",
                    systemImage: "square.stack",
                    description: Text("Create an album from the Library grid to see it here.")
                )
            } else {
                List(store.summaries) { summary in
                    Button {
                        onSelectAlbum(summary.album.id ?? -1)
                    } label: {
                        AlbumRow(summary: summary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Albums")
        .task {
            store.start(database: environment.database)
        }
    }
}

private struct AlbumRow: View {
    let summary: AlbumSummary

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                if let path = summary.coverThumbnailPath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "square.stack")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.album.name)
                    .font(.headline)
                Text("^[\(summary.photoCount) photo](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
