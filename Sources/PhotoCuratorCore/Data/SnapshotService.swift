import Foundation
import GRDB

/// Writes a consistent snapshot of the live database into the Proton folder via
/// `VACUUM INTO`, on quit/idle/significant state change (spec §3). The live
/// `.sqlite`/-wal/-shm files never leave Application Support — only this
/// single, fixed-name backup file is written into the synced folder, so Proton always
/// sees one quiescent file it can version safely.
public actor SnapshotService {
    private let database: AppDatabase
    private var isRunning = false
    private var pendingRequest = false

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Requests a snapshot. If one is already in flight, coalesces into a single
    /// follow-up run instead of overlapping `VACUUM INTO` calls — this makes it safe
    /// to call after every lifecycle/album edit without extra debouncing logic.
    public func requestSnapshot(protonFolderURL: URL) async {
        guard !isRunning else {
            pendingRequest = true
            return
        }
        await runSnapshot(protonFolderURL: protonFolderURL)
    }

    private func runSnapshot(protonFolderURL: URL) async {
        isRunning = true
        do {
            try await writeSnapshot(protonFolderURL: protonFolderURL)
        } catch {
            // Best-effort: the live database is the source of truth and is unaffected
            // by a failed backup attempt (e.g. Proton folder briefly unreachable).
        }
        isRunning = false
        if pendingRequest {
            pendingRequest = false
            await runSnapshot(protonFolderURL: protonFolderURL)
        }
    }

    /// Performs one `VACUUM INTO` snapshot and atomically swaps it into place at the
    /// fixed filename. `VACUUM INTO` refuses to write to a path that already exists, so
    /// this always targets a fresh temp path first.
    public func writeSnapshot(protonFolderURL: URL) async throws {
        let targetURL = protonFolderURL.appendingPathComponent(AppPaths.snapshotFilename)
        let tempURL = protonFolderURL.appendingPathComponent(
            ".\(AppPaths.snapshotFilename).tmp-\(UUID().uuidString)"
        )

        // `writeWithoutTransaction`, not `write`: GRDB wraps `write` in a transaction
        // and SQLite refuses to VACUUM inside one ("cannot VACUUM from within a
        // transaction"), which made every snapshot fail silently — the error was
        // swallowed by `runSnapshot`'s best-effort catch, so no backup was ever
        // produced.
        try await database.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [tempURL.path])
        }

        do {
            if FileManager.default.fileExists(atPath: targetURL.path) {
                _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: targetURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        try await database.write { db in
            try AppStateRepository.setInt64(
                Int64(Date().timeIntervalSince1970),
                forKey: AppStateKey.lastSnapshotAt,
                in: db
            )
        }
    }
}
