import Foundation
import CryptoKit

/// Content identity: SHA-256 of file bytes, computed on materialization — when a file
/// is opened, becomes a candidate, is published, or is derived from the SD card
/// (spec §5). Reading bytes is exactly what materializes an online-only file, so
/// callers must only hash files the user explicitly acted on, or files already local.
public enum ContentHasher {
    public static func sha256(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
