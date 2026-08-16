import SwiftUI
import PhotoCuratorCore

/// Export / publish review (spec §7.6): exports the JPG representation of each
/// selected photo into a category subdirectory of the gallery target.
struct ExportSheetView: View {
    let photoIds: [Int64]
    let defaultCategory: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var category: String = ""
    @State private var isExporting = false
    @State private var results: [ExportItemResult]?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export \(photoIds.count) photo(s)")
                .font(.headline)

            if let results {
                resultsSummary(results)
            } else {
                TextField("Category (subdirectory)", text: $category)
                    .textFieldStyle(.roundedBorder)
                Text("Copies the JPG representation of each photo into the gallery target, skipping anything already published to this category.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Spacer()
                if results != nil {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        Task { await runExport() }
                    } label: {
                        if isExporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Export")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isExporting)
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 260)
        .onAppear { category = defaultCategory }
    }

    private func resultsSummary(_ results: [ExportItemResult]) -> some View {
        let exported = results.filter { $0.success && !$0.skippedAsDuplicate }.count
        let duplicates = results.filter { $0.skippedAsDuplicate }.count
        let failed = results.filter { !$0.success }
        return VStack(alignment: .leading, spacing: 8) {
            Label("\(exported) exported", systemImage: "checkmark.circle")
            if duplicates > 0 {
                Label("\(duplicates) already published to this category", systemImage: "arrow.triangle.2.circlepath")
            }
            if !failed.isEmpty {
                Label("\(failed.count) failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                ScrollView {
                    ForEach(failed, id: \.photoId) { item in
                        Text(item.errorDescription ?? "Unknown error")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func runExport() async {
        isExporting = true
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        results = await environment.runExport(photoIds: photoIds, category: trimmedCategory.isEmpty ? nil : trimmedCategory)
        isExporting = false
    }
}
