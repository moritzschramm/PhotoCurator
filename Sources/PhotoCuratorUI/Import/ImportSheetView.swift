import SwiftUI
import PhotoCuratorCore

/// SD-card import review (spec §7.2): shows each shot (grouped by basename so a
/// RAW+JPG pair stays together), flags already-imported duplicates, and lets the
/// user override the suggested per-camera subdirectory before committing.
struct ImportSheetView: View {
    let sourceFolderURL: URL
    let displayName: String
    let defaultLibraryId: Int64?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var selectedLibraryId: Int64?
    @State private var groups: [ImportGroup] = []
    @State private var subdirectoryOverrides: [String: String] = [:]
    /// Groups the user has unchecked — everything importable is ticked by default,
    /// so this tracks the exceptions rather than needing to pre-populate a "selected"
    /// set for every group as they're discovered.
    @State private var deselectedBasenames: Set<String> = []
    @State private var isScanning = true
    @State private var scanError: String?
    @State private var isImporting = false
    @State private var importProgress = (done: 0, total: 0)
    @State private var importResults: [ImportFileOutcome]?

    init(sourceFolderURL: URL, displayName: String, defaultLibraryId: Int64?) {
        self.sourceFolderURL = sourceFolderURL
        self.displayName = displayName
        self.defaultLibraryId = defaultLibraryId
        _selectedLibraryId = State(initialValue: defaultLibraryId)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 520)
        // Re-scans when the destination library changes — subdirectory suggestions
        // (flat vs. per-camera) depend on what that specific library already
        // contains (see `ImportPipeline.scan`'s `preferFlatImport`).
        .task(id: selectedLibraryId) { await scan() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sdcard")
                Text("Import from \(displayName)")
                    .font(.headline)
                Spacer()
            }
            if environment.folderAccess.photoLibraries.count > 1 {
                Picker("Import into:", selection: $selectedLibraryId) {
                    ForEach(environment.folderAccess.photoLibraries) { library in
                        Text(library.name).tag(Optional(library.id))
                    }
                }
                .frame(maxWidth: 320)
            }
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
                if !group.isFullyDuplicate {
                    Toggle("", isOn: selectionBinding(for: group))
                        .labelsHidden()
                }
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
                    TextField("Subdirectory (optional)", text: subdirectoryBinding(for: group))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .disabled(isDeselected(group))
                }
            }
            .opacity(isDeselected(group) ? 0.5 : 1)
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

    /// Only counts groups that are both importable (not already-duplicate) and still
    /// ticked — the footer/Import-button-enabled count should reflect what will
    /// actually be imported, not just what's technically available.
    private var newFileCount: Int {
        groups.reduce(0) { total, group in
            guard !isDeselected(group) else { return total }
            return total + group.newFileCount
        }
    }

    private func isDeselected(_ group: ImportGroup) -> Bool {
        deselectedBasenames.contains(group.basename)
    }

    private func selectionBinding(for group: ImportGroup) -> Binding<Bool> {
        Binding(
            get: { !deselectedBasenames.contains(group.basename) },
            set: { isSelected in
                if isSelected {
                    deselectedBasenames.remove(group.basename)
                } else {
                    deselectedBasenames.insert(group.basename)
                }
            }
        )
    }

    private func subdirectoryBinding(for group: ImportGroup) -> Binding<String> {
        Binding(
            get: { subdirectoryOverrides[group.basename] ?? group.suggestedSubdirectory },
            set: { subdirectoryOverrides[group.basename] = $0 }
        )
    }

    private func scan() async {
        guard let selectedLibraryId else {
            scanError = "No photo library to import into."
            isScanning = false
            return
        }
        isScanning = true
        // Cleared per attempt, not just set on failure: `content` renders the error
        // ahead of the group list, so a stale one from an earlier attempt would keep
        // the sheet stuck on the error screen even after a later scan succeeded.
        scanError = nil
        // A fresh scan means a fresh set of groups — stale basenames from a
        // previous scan (e.g. after switching the destination library) shouldn't
        // silently deselect an unrelated group that happens to share a name.
        deselectedBasenames = []
        do {
            groups = try await environment.scanImportCandidates(sourceFolder: sourceFolderURL, targetLibraryId: selectedLibraryId)
        } catch {
            scanError = "Could not scan \(displayName): \(error.localizedDescription)"
        }
        isScanning = false
    }

    private func runImport() async {
        guard let selectedLibraryId else { return }
        isImporting = true
        let selectedGroups = groups.filter { !isDeselected($0) }
        importResults = await environment.runImport(
            groups: selectedGroups,
            subdirectoryOverrides: subdirectoryOverrides,
            targetLibraryId: selectedLibraryId,
            onProgress: { done, total in
                Task { @MainActor in importProgress = (done, total) }
            }
        )
        isImporting = false
    }
}
