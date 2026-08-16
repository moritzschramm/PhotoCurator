import Foundation

/// Pure diff between a filesystem enumeration and the representations already known
/// to the database — no I/O, so it's trivially unit-testable. Matches by relative
/// path first, then by the provisional key (filename+size+mtime), which together
/// catch the overwhelming majority of unchanged files and simple moves/renames
/// without ever reading a byte (spec §5, §7.1).
///
/// Content-hash-based move detection (spec §5) additionally happens, but only for
/// files that are already local — see `ReconciliationService.applyNewFile`, since
/// hashing requires reading bytes and this planner must not do that.
public enum ReconciliationPlanner {

    public struct Plan: Sendable {
        public struct NewFile: Sendable {
            public var file: EnumeratedFile
            public var kind: RepresentationKind
            public var basename: String
        }

        public struct Move: Sendable {
            public var representationId: Int64
            public var file: EnumeratedFile
        }

        public struct LocalStatusChange: Sendable {
            public var representationId: Int64
            public var isLocal: Bool
        }

        public var newFiles: [NewFile] = []
        public var moved: [Move] = []
        public var localStatusChanges: [LocalStatusChange] = []
        /// Representation ids present in the database but not matched to any
        /// enumerated file. `ReconciliationService` may still rescue some of these
        /// via content-hash matching before treating them as truly gone.
        public var unmatchedExistingIds: Set<Int64> = []
    }

    public static func diff(files: [EnumeratedFile], existing: [Representation]) -> Plan {
        var plan = Plan()

        let byPath = Dictionary(uniqueKeysWithValues: existing.map { ($0.relativePath, $0) })
        var byProvisional: [ProvisionalKey: Representation] = [:]
        for rep in existing {
            byProvisional[ProvisionalKey(representation: rep)] = rep
        }

        var matchedIds = Set<Int64>()

        for file in files {
            guard let kind = RepresentationFileType.kind(forExtension: file.fileExtension) else { continue }

            if let existingAtPath = byPath[file.relativePath] {
                if let id = existingAtPath.id {
                    matchedIds.insert(id)
                    if existingAtPath.isLocal != file.isLocal {
                        plan.localStatusChanges.append(.init(representationId: id, isLocal: file.isLocal))
                    }
                }
                continue
            }

            let provisional = ProvisionalKey(
                filename: file.filename,
                fileSize: file.fileSize,
                fileMtime: file.fileMtimeEpoch
            )
            if let match = byProvisional[provisional], let id = match.id, !matchedIds.contains(id) {
                matchedIds.insert(id)
                plan.moved.append(.init(representationId: id, file: file))
                continue
            }

            plan.newFiles.append(.init(file: file, kind: kind, basename: basename(for: file.filename)))
        }

        let allExistingIds = Set(existing.compactMap(\.id))
        plan.unmatchedExistingIds = allExistingIds.subtracting(matchedIds)

        return plan
    }

    public static func basename(for filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }
}
