import SwiftUI
import PhotoCuratorCore

/// SD-card import review (spec §7.2): shows each shot (grouped by basename so a
/// RAW+JPG pair stays together), flags already-imported duplicates, and lets the
/// user override the suggested per-camera subdirectory before committing.
struct ImportSheetView: View {
    let sourceFolderURL: URL
    let displayName: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var groups: [ImportGroup] = []
    @State private var subdirectoryOverrides: [String: String] = [:]
    @State private var isScanning = true
    @State private var scanError: String?
    @State private var isImporting = false
    @State private var importProgress = (done: 0, total: 0)
    @State private var importResults: [ImportFileOutcome]?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 520)
        .task { await scan() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "sdcard")
            Text("Import from \(displayName)")
                .font(.headline)
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if isScanning {
            centered { ProgressView("Scanning…") }
        } else if let scanError {
            centered { Text(scanError).foregroundStyle(.red) }
        } else if isImporting {
            centered {
                VStack(spacing: 12) {
                    ProgressView(value: Double(importProgress.done), total: Double(max(importProgress.total, 1)))
                        .frame(width: 260)
                    Text("Importing \(importProgress.done) of \(importProgress.total)…")
                        .font(.caption)
                }
            }
        } else if let importResults {
            resultsView(importResults)
        } else if groups.isEmpty {
            centered { Text("No new photos found on this volume.").foregroundStyle(.secondary) }
        } else {
            groupsList
        }
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        VStack { content() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groupsList: some View {
        List(groups) { group in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.basename)
                    Text(group.files.map(\.filename).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if group.isFullyDuplicate {
                    Text("Already imported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Subdirectory", text: subdirectoryBinding(for: group))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
        }
    }

    private func resultsView(_ results: [ImportFileOutcome]) -> some View {
        let succeeded = results.filter { $0.success && !$0.skippedAsDuplicate }.count
        let duplicates = results.filter { $0.skippedAsDuplicate }.count
        let failed = results.filter { !$0.success }
        return List {
            Section {
                Label("\(succeeded) imported", systemImage: "checkmark.circle")
                if duplicates > 0 {
                    Label("\(duplicates) duplicate(s) skipped", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if !failed.isEmpty {
                Section("Failed") {
                    ForEach(failed, id: \.sourceURL) { outcome in
                        Text("\(outcome.sourceURL.lastPathComponent): \(outcome.errorDescription ?? "Unknown error")")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if importResults == nil {
                Text("\(newFileCount) new file(s) to import.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if importResults != nil {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    Task { await runImport() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isScanning || isImporting || newFileCount == 0)
            }
        }
        .padding()
    }

    private var newFileCount: Int {
        groups.reduce(0) { $0 + $1.newFileCount }
    }

    private func subdirectoryBinding(for group: ImportGroup) -> Binding<String> {
        Binding(
            get: { subdirectoryOverrides[group.basename] ?? group.suggestedSubdirectory },
            set: { subdirectoryOverrides[group.basename] = $0 }
        )
    }

    private func scan() async {
        isScanning = true
        do {
            groups = try await environment.scanImportCandidates(sourceFolder: sourceFolderURL)
        } catch {
            scanError = "Could not scan \(displayName): \(error.localizedDescription)"
        }
        isScanning = false
    }

    private func runImport() async {
        isImporting = true
        importResults = await environment.runImport(
            groups: groups,
            subdirectoryOverrides: subdirectoryOverrides,
            onProgress: { done, total in
                Task { @MainActor in importProgress = (done, total) }
            }
        )
        isImporting = false
    }
}
