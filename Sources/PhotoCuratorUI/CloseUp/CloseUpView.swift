import SwiftUI
import PhotoCuratorCore

/// Second of the app's three primary surfaces (spec §8): one photo at a time, arrow
/// keys to move between photos, JPG↔RAW toggle, lifecycle actions, add-to-album.
struct CloseUpView: View {
    let scope: GridScope

    @State private var currentPhotoId: Int64
    @State private var loader = CloseUpImageLoader()
    @State private var albumStore = AlbumScopeStore()
    @State private var exif: ExifRecord?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    init(photoId: Int64, scope: GridScope) {
        self.scope = scope
        _currentPhotoId = State(initialValue: photoId)
    }

    private var orderedIds: [Int64] {
        switch scope {
        case .library: return environment.gridEntries.map(\.id)
        case .album: return albumStore.entries.map(\.id)
        }
    }

    private var pwr: PhotoWithRepresentations? {
        environment.photo(id: currentPhotoId)
    }

    var body: some View {
        VStack(spacing: 0) {
            imageArea
            if let exif {
                exifBar(exif)
            }
        }
        .navigationTitle(pwr?.jpg?.filename ?? pwr?.raw?.filename ?? "Photo")
        .toolbar { toolbarContent }
        .task(id: scope) {
            if case .album(let albumId) = scope {
                albumStore.start(albumId: albumId, database: environment.database)
            }
        }
        .task(id: currentPhotoId) {
            exif = nil
            guard let pwr, let photoRoot = environment.photoLibraryRootURL else { return }
            loader.load(pwr: pwr, photoRoot: photoRoot, database: environment.database, derivationQueue: environment.derivationQueue)
            if let repId = (pwr.jpg ?? pwr.raw)?.id {
                exif = try? await environment.database.read { db in try PhotoRepository.fetchExif(representationId: repId, in: db) }
            }
        }
    }

    @ViewBuilder
    private var imageArea: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let image = loader.displayImage {
                ZoomableImageView(image: image, resetKey: currentPhotoId)
            } else if loader.loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.system(size: 40))
                    Text("Not available")
                }
                .foregroundStyle(.white.opacity(0.7))
            } else if loader.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if loader.isRenderingRaw {
                statusPill("Developing RAW…", systemImage: "camera.aperture")
            } else if loader.rawRenderFailed && loader.isShowingRaw {
                statusPill("RAW render failed — showing JPG", systemImage: "exclamationmark.triangle")
            }

            if loader.displayImage != nil {
                VStack {
                    HStack {
                        Spacer()
                        formatBadge
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    /// Always-visible indicator of which format is currently on screen — the toggle
    /// button's label alone isn't enough of a signal on its own.
    private var formatBadge: some View {
        Text(loader.isShowingRaw ? "RAW" : "JPG")
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(loader.isShowingRaw ? Color.orange.opacity(0.85) : Color.gray.opacity(0.65), in: Capsule())
            .foregroundStyle(.white)
    }

    private func statusPill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
            .padding(.bottom, 12)
    }

    private func exifBar(_ exif: ExifRecord) -> some View {
        HStack(spacing: 16) {
            if let camera = exif.cameraModel { label("camera", camera) }
            if let lens = exif.lens { label("camera.aperture", lens) }
            if let iso = exif.iso { label("dial.low", "ISO \(iso)") }
            if let aperture = exif.aperture { label("camera.aperture", String(format: "ƒ/%.1f", aperture)) }
            if let shutter = exif.shutter { label("timer", shutter) }
            if let focalLength = exif.focalLength { label("arrow.left.and.right", "\(Int(focalLength))mm") }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
    }

    private func step(by delta: Int) {
        guard let index = orderedIds.firstIndex(of: currentPhotoId) else { return }
        let newIndex = index + delta
        guard orderedIds.indices.contains(newIndex) else { return }
        currentPhotoId = orderedIds[newIndex]
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // A real Button bound via `.keyboardShortcut`, not `.onKeyPress` — button
        // key-equivalents are registered at the window level and work regardless of
        // where first-responder focus happens to be, whereas `.onKeyPress` only
        // fires for a view that actually holds keyboard focus, which this view
        // never explicitly claims. That mismatch is why arrow-key navigation (also
        // wired via `.keyboardShortcut` below) works but a bare `.onKeyPress(.escape)`
        // silently didn't.
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }

        ToolbarItemGroup {
            Button {
                step(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled((orderedIds.firstIndex(of: currentPhotoId) ?? 0) <= 0)

            Button {
                step(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!orderedIds.indices.contains((orderedIds.firstIndex(of: currentPhotoId) ?? -1) + 1))

            Divider()

            Button {
                loader.toggleRawJpg()
            } label: {
                Label(loader.isShowingRaw ? "RAW" : "JPG", systemImage: "camera.aperture")
            }
            .keyboardShortcut("r", modifiers: [])
            .disabled(!loader.canToggleRaw)
            .help("Toggle JPG / RAW (R)")

            Divider()

            Button {
                Task { await environment.setLifecycle(photoIds: [currentPhotoId], state: .candidate) }
            } label: {
                Label("Candidate", systemImage: "star")
            }
            .keyboardShortcut("c", modifiers: [])

            Button {
                Task { await environment.setLifecycle(photoIds: [currentPhotoId], state: .rejected) }
            } label: {
                Label("Reject", systemImage: "xmark.circle")
            }
            .keyboardShortcut("x", modifiers: [])

            Button {
                Task { await environment.setLifecycle(photoIds: [currentPhotoId], state: .reviewed) }
            } label: {
                Label("Reviewed", systemImage: "checkmark")
            }
            .keyboardShortcut("u", modifiers: [])

            Menu {
                ForEach(environment.albums) { album in
                    let albumId = album.id ?? -1
                    Button {
                        Task { await environment.toggleAlbumMembership(photoId: currentPhotoId, albumId: albumId) }
                    } label: {
                        Text(album.name)
                    }
                }
            } label: {
                Label("Add to Album", systemImage: "square.stack.3d.up")
            }
            .disabled(environment.albums.isEmpty)
        }
    }
}
