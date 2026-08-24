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
        return hexString(hasher.finalize())
    }

    /// Copies `sourceURL` to `destinationURL`, hashing the bytes as they stream
    /// through, and returns the source's hash. Import needs both a copy and the
    /// source's digest (spec §7.2's copy→verify step); doing them in one pass saves
    /// re-reading the whole file just to hash it, which on an SD card full of RAWs is
    /// an entire extra read of every byte imported.
    ///
    /// Deliberately does not preserve file attributes the way
    /// `FileManager.copyItem` does — callers that care (import does: mtime seeds the
    /// provisional capture date) restore them afterwards.
    @discardableResult
    public static func copy(
        from sourceURL: URL,
        to destinationURL: URL,
        chunkSize: Int = 1 << 20
    ) throws -> String {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw ContentHasherError.cannotCreateDestination(destinationURL)
        }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        var hasher = SHA256()
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        return hexString(hasher.finalize())
    }

    private static func hexString(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ContentHasherError: Error, LocalizedError {
    case cannotCreateDestination(URL)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateDestination(let url):
            return "Could not create a file at \(url.lastPathComponent)"
        }
    }
}
