import AppKit
import PhotoCuratorCore

/// One grid tile. Plain AppKit view built programmatically (no XIB): a thumbnail,
/// a filename fallback + cloud badge for online-only-and-underived shots, and a
/// lifecycle badge — candidate/published highlighted, rejected dimmed but still
/// visible, never hidden (spec §6, §8).
final class PhotoGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoGridItem")

    private let thumbnailImageView = NSImageView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private let cloudBadge = NSImageView()
    private let stateBadge = NSImageView()
    private var currentThumbnailPath: String?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
    }

    private func setupViews() {
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = 6
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailImageView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false

        filenameLabel.font = .systemFont(ofSize: 10)
        filenameLabel.textColor = .white
        filenameLabel.alignment = .center
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.drawsBackground = false
        filenameLabel.isBordered = false
        filenameLabel.isEditable = false
        filenameLabel.isHidden = true
        filenameLabel.translatesAutoresizingMaskIntoConstraints = false

        cloudBadge.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: "Online only")
        cloudBadge.contentTintColor = .white
        cloudBadge.isHidden = true
        cloudBadge.translatesAutoresizingMaskIntoConstraints = false

        stateBadge.isHidden = true
        stateBadge.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(thumbnailImageView)
        view.addSubview(filenameLabel)
        view.addSubview(cloudBadge)
        view.addSubview(stateBadge)

        NSLayoutConstraint.activate([
            thumbnailImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnailImageView.topAnchor.constraint(equalTo: view.topAnchor),
            thumbnailImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            filenameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            filenameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            filenameLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),

            cloudBadge.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            cloudBadge.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            cloudBadge.widthAnchor.constraint(equalToConstant: 16),
            cloudBadge.heightAnchor.constraint(equalToConstant: 16),

            stateBadge.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            stateBadge.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            stateBadge.widthAnchor.constraint(equalToConstant: 16),
            stateBadge.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    func configure(with entry: PhotoGridEntry) {
        let pwr = entry.photo

        if let path = entry.gridThumbnailPath {
            currentThumbnailPath = path
            if let cached = ThumbnailImageCache.cached(path) {
                thumbnailImageView.image = cached
            } else {
                // Reading and decoding the file is off the main thread, so the cell
                // shows its placeholder background until the image arrives. Cells are
                // recycled while that's in flight, hence the path check on the way
                // back in — otherwise a slow load lands in whichever photo's cell
                // inherited this view.
                thumbnailImageView.image = nil
                ThumbnailImageCache.load(path) { [weak self] image in
                    guard let self, let image, self.currentThumbnailPath == path else { return }
                    self.thumbnailImageView.image = image
                }
            }
        } else {
            currentThumbnailPath = nil
            thumbnailImageView.image = nil
        }

        let showsCloudBadge = pwr.isFullyOnlineOnly && !pwr.hasAnyDerivedRepresentation
        cloudBadge.isHidden = !showsCloudBadge
        filenameLabel.isHidden = entry.gridThumbnailPath != nil
        filenameLabel.stringValue = pwr.jpg?.filename ?? pwr.raw?.filename ?? pwr.photo.basename

        switch pwr.photo.lifecycleState {
        case .candidate:
            stateBadge.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Candidate")
            stateBadge.contentTintColor = .systemYellow
            stateBadge.isHidden = false
        case .accepted:
            stateBadge.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Accepted")
            stateBadge.contentTintColor = .systemGreen
            stateBadge.isHidden = false
        case .rejected:
            stateBadge.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Rejected")
            stateBadge.contentTintColor = .systemRed
            stateBadge.isHidden = false
        case .new:
            stateBadge.isHidden = true
        }

        // Rejected photos are shown, not hidden — just visually deemphasized.
        view.alphaValue = pwr.photo.lifecycleState == .rejected ? 0.45 : 1.0
    }

    override var isSelected: Bool {
        didSet {
            // `borderWidth`/`borderColor` are implicitly-animatable CALayer
            // properties — without disabling actions, the selection box fades in
            // over ~0.25s instead of appearing the instant you click.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.borderWidth = isSelected ? 3 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            view.layer?.cornerRadius = 6
            CATransaction.commit()
        }
    }
}
