import Foundation
import AppKit
import DiskArbitration

public struct MountedVolume: Sendable, Equatable {
    public var url: URL
    public var volumeName: String
    public var isRemovable: Bool
}

/// SD-card mount detection (spec §1, §9): `NSWorkspace.didMountNotification` tells us
/// *something* mounted; DiskArbitration tells us whether it's removable/ejectable
/// media, so we don't surface the import UI for every disk image or network share.
/// Removable-media entitlement access resolves at the point of first read, not at
/// first run, so detection itself never needs a folder grant (spec §9).
@MainActor
public final class SDVolumeDetector {
    public var onVolumeMounted: (@Sendable (MountedVolume) -> Void)?

    private var observer: NSObjectProtocol?
    private let session: DASession?

    public init() {
        session = DASessionCreate(kCFAllocatorDefault)
        if let session {
            DASessionSetDispatchQueue(session, DispatchQueue.main)
        }
    }

    public func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // `queue: .main` guarantees this runs on the main thread, so it's safe to
            // assume MainActor isolation here even though the closure type itself
            // isn't statically annotated as such.
            MainActor.assumeIsolated {
                self?.handleMount(notification)
            }
        }
    }

    public func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    private func handleMount(_ notification: Notification) {
        guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        guard let volume = Self.describeVolume(at: url, session: session), volume.isRemovable else { return }
        onVolumeMounted?(volume)
    }

    private static func describeVolume(at url: URL, session: DASession?) -> MountedVolume? {
        let resourceValues = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey])
        let name = resourceValues?.volumeName ?? url.lastPathComponent

        if let isRemovableByResourceValue = resourceValues?.volumeIsRemovable,
           let isEjectableByResourceValue = resourceValues?.volumeIsEjectable,
           isRemovableByResourceValue || isEjectableByResourceValue {
            return MountedVolume(url: url, volumeName: name, isRemovable: true)
        }

        guard let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            return MountedVolume(url: url, volumeName: name, isRemovable: false)
        }
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else {
            return MountedVolume(url: url, volumeName: name, isRemovable: false)
        }

        let isRemovable = (description[kDADiskDescriptionMediaRemovableKey as String] as? Bool) ?? false
        let isEjectable = (description[kDADiskDescriptionMediaEjectableKey as String] as? Bool) ?? false

        return MountedVolume(url: url, volumeName: name, isRemovable: isRemovable || isEjectable)
    }
}
