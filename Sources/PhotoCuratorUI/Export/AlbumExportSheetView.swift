import SwiftUI
import PhotoCuratorCore

/// Whole-album export review — export always acts on the album's currently-accepted
/// photos, not a manual grid selection, so this shows exactly what will change
/// before committing: new exports, already-up-to-date skips, and removals for
/// photos no longer accepted (or no longer in the album at all).
struct AlbumExportSheetView: View {
    let albumId: Int64
    let category: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var plan: AlbumExportPlan?
    @State private var isApplying = false
    @State private var results: [ExportItemResult]?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 480, height: 460)
        .task { await loadPlan() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.and.arrow.up")
            Text("Export \"\(category)\"")
                .font(.headline)
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if let results {
            resultsSummary(results)
        } else if isApplying {
            centered { ProgressView("Exporting…") }
        } else if let plan {
            if plan.toExport.isEmpty && plan.toRemove.isEmpty {
                centered { Text("Already up to date — nothing to export or remove.").foregroundStyle(.secondary) }
            } else {
                planList(plan)
            }
        } else {
            centered { ProgressView("Checking what's changed…") }
        }
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        VStack { content() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func planList(_ plan: AlbumExportPlan) -> some View {
        List {
            if !plan.toExport.isEmpty {
                Section("Will export (\(plan.toExport.count))") {
                    ForEach(plan.toExport, id: \.photoId) { item in
                        Label(item.filename, systemImage: "arrow.up.circle")
                    }
                }
            }
            if !plan.toRemove.isEmpty {
                Section("Will remove (\(plan.toRemove.count))") {
                    ForEach(plan.toRemove, id: \.photoId) { item in
                        Label(item.filename, systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                }
            }
            if !plan.toSkip.isEmpty {
                Section("Already up to date (\(plan.toSkip.count))") {
                    ForEach(plan.toSkip, id: \.photoId) { item in
                        Label(item.filename, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func resultsSummary(_ results: [ExportItemResult]) -> some View {
        let exported = results.filter { $0.success && !$0.skippedAsDuplicate && !$0.wasRemoved }.count
        let removed = results.filter { $0.success && $0.wasRemoved }.count
        let failed = results.filter { !$0.success }
        return List {
            Section {
                Label("\(exported) exported", systemImage: "checkmark.circle")
                if removed > 0 {
                    Label("\(removed) removed", systemImage: "trash")
                }
            }
            if !failed.isEmpty {
                Section("Failed") {
                    ForEach(failed, id: \.photoId) { item in
                        Text(item.errorDescription ?? "Unknown error")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if results != nil {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") {
                    Task { await apply() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying || !hasChanges)
            }
        }
        .padding()
    }

    private var hasChanges: Bool {
        guard let plan else { return false }
        return !plan.toExport.isEmpty || !plan.toRemove.isEmpty
    }

    private func loadPlan() async {
        plan = await environment.planAlbumExport(albumId: albumId, category: category)
    }

    private func apply() async {
        guard let plan else { return }
        isApplying = true
        results = await environment.applyAlbumExportPlan(plan, category: category)
        isApplying = false
    }
}
