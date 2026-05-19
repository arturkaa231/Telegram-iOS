import Foundation
import UIKit
import Display
import AsyncDisplayKit
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import UniversalMediaPlayer
import AvatarNode

final class MediaBrowserPlayerNode: ASDisplayNode {
    private let context: AccountContext
    private var presentationData: PresentationData

    private let containerNode: ASDisplayNode
    private let previewContainer: ASDisplayNode
    private var previewNode: MediaPreviewNode?

    private let fileNameLabel: UILabel
    private let dateLabel: UILabel
    private let senderAvatarNode: AvatarNode

    private let muteButton: UIButton
    private let muteBackgroundView: UIView
    private let toggleSwitch: MediaBrowserToggleView

    private let avatarBackView: UIView
    private let avatarFrontView: UIView
    private let participantsCountLabel: UILabel
    private let block3TimeLabel: UILabel

    private let nightModeButton: UIButton
    private let expandButton: UIButton
    private let fitButton: UIButton
    private let shareButton: UIButton
    private let chatButton: UIButton
    private let deleteButton: UIButton
    private let listButton: UIButton

    private let playButton: UIButton
    private let loadingIndicator: UIActivityIndicatorView
    private let topShadeView: GradientView
    private let bottomShadeView: GradientView
    private let pulseGlowLayer: CALayer

    private let expandScrubbingNode: MediaPlayerScrubbingNode
    private let fitScrubbingNode: MediaPlayerScrubbingNode
    private let expandElapsedLabel: UILabel
    private let expandRemainingLabel: UILabel
    private var expandStatusDisposable = MetaDisposable()
    private var expandStatusValue: MediaPlayerStatus?

    private let block2ProgressTrack: UIView
    private let block2ProgressFill: UIView

    private let rewindButton: UIButton
    private let forwardButton: UIButton
    private let prevButton: UIButton
    private let nextButton: UIButton

    var onPresentGallery: ((MediaBrowserItem) -> Void)?
    var onShareMessage: ((MediaBrowserItem) -> Void)?
    var onJumpToMessage: ((MediaBrowserItem) -> Void)?
    var onDeleteMessage: ((MediaBrowserItem) -> Void)?
    var onPrevItem: (() -> Void)?
    var onNextItem: (() -> Void)?

    private var isMuted: Bool = false
    private var isPlaying: Bool = false
    private var isExpanded: Bool = false
    private var previewAspectRatio: CGFloat?
    private var lastSize: CGSize = .zero

    private var currentItem: MediaBrowserItem?

    var onToggleExpanded: (() -> Void)?

    init(context: AccountContext, presentationData: PresentationData) {
        self.context = context
        self.presentationData = presentationData

        self.containerNode = ASDisplayNode()
        self.containerNode.cornerRadius = 16.0
        self.containerNode.clipsToBounds = true

        self.previewContainer = ASDisplayNode()

        self.fileNameLabel = UILabel()
        self.fileNameLabel.font = UIFont.systemFont(ofSize: 28.0, weight: .regular)
        self.fileNameLabel.numberOfLines = 1
        self.fileNameLabel.lineBreakMode = .byTruncatingTail

        self.dateLabel = UILabel()
        self.dateLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .regular)

        self.senderAvatarNode = AvatarNode(font: avatarPlaceholderFont(size: 8.0))

        self.muteBackgroundView = UIView()
        self.muteBackgroundView.layer.cornerRadius = 18.0
        self.muteBackgroundView.isUserInteractionEnabled = false

        self.muteButton = UIButton(type: .custom)
        self.muteButton.setImage(UIImage(systemName: "speaker.wave.2.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17.0, weight: .regular)), for: .normal)
        self.muteButton.contentMode = .center

        self.toggleSwitch = MediaBrowserToggleView()
        self.toggleSwitch.setOn(true, animated: false)

        self.avatarBackView = UIView()
        self.avatarBackView.layer.cornerRadius = 10.0

        self.avatarFrontView = UIView()
        self.avatarFrontView.layer.cornerRadius = 10.0
        self.avatarFrontView.layer.borderWidth = 1.5

        self.participantsCountLabel = UILabel()
        self.participantsCountLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .regular)

        self.block3TimeLabel = UILabel()
        self.block3TimeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14.0, weight: .regular)
        self.block3TimeLabel.textAlignment = .right
        self.block3TimeLabel.isHidden = true

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 18.0, weight: .regular)

        self.nightModeButton = UIButton(type: .custom)
        self.nightModeButton.setImage(UIImage(systemName: "moon", withConfiguration: iconConfig), for: .normal)

        self.expandButton = UIButton(type: .custom)
        self.expandButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: iconConfig), for: .normal)

        self.fitButton = UIButton(type: .custom)
        self.fitButton.setImage(UIImage(systemName: "viewfinder", withConfiguration: iconConfig), for: .normal)

        self.listButton = UIButton(type: .custom)
        self.listButton.setImage(UIImage(systemName: "list.bullet", withConfiguration: iconConfig), for: .normal)

        self.shareButton = UIButton(type: .custom)
        self.shareButton.setImage(UIImage(systemName: "arrow.up.right", withConfiguration: iconConfig), for: .normal)

        self.chatButton = UIButton(type: .custom)
        self.chatButton.setImage(UIImage(systemName: "bubble.left", withConfiguration: iconConfig), for: .normal)

        self.deleteButton = UIButton(type: .custom)
        self.deleteButton.setImage(UIImage(systemName: "trash", withConfiguration: iconConfig), for: .normal)

        self.playButton = UIButton(type: .system)
        self.playButton.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
        self.playButton.contentVerticalAlignment = .fill
        self.playButton.contentHorizontalAlignment = .fill
        self.playButton.isHidden = true

        self.loadingIndicator = UIActivityIndicatorView(style: .large)
        self.loadingIndicator.hidesWhenStopped = true
        self.loadingIndicator.color = .white

        self.topShadeView = GradientView()
        self.topShadeView.setColors([UIColor.black.withAlphaComponent(0.55), UIColor.black.withAlphaComponent(0.0)])
        self.topShadeView.isHidden = true
        self.topShadeView.isUserInteractionEnabled = false

        self.bottomShadeView = GradientView()
        self.bottomShadeView.setColors([UIColor.black.withAlphaComponent(0.0), UIColor.black.withAlphaComponent(0.55)])
        self.bottomShadeView.isHidden = true
        self.bottomShadeView.isUserInteractionEnabled = false

        self.pulseGlowLayer = CALayer()
        self.pulseGlowLayer.borderColor = UIColor(rgb: 0x05614C).cgColor
        self.pulseGlowLayer.borderWidth = 2.0
        self.pulseGlowLayer.cornerRadius = 16.0
        self.pulseGlowLayer.shadowColor = UIColor(rgb: 0x2DA547).cgColor
        self.pulseGlowLayer.shadowOpacity = 0.8
        self.pulseGlowLayer.shadowRadius = 12.0
        self.pulseGlowLayer.shadowOffset = .zero
        self.pulseGlowLayer.isHidden = true

        self.expandScrubbingNode = MediaPlayerScrubbingNode(content: .standard(
            lineHeight: 4.0,
            lineCap: .round,
            scrubberHandle: .circle,
            backgroundColor: UIColor(rgb: 0x333333),
            foregroundColor: UIColor(rgb: 0xFF383C),
            bufferingColor: UIColor(rgb: 0xCCCCCC),
            chapters: []
        ))
        self.expandScrubbingNode.isHidden = true

        self.fitScrubbingNode = MediaPlayerScrubbingNode(content: .standard(
            lineHeight: 3.0,
            lineCap: .round,
            scrubberHandle: .circle,
            backgroundColor: UIColor(white: 0.5, alpha: 0.3),
            foregroundColor: UIColor(rgb: 0xFF383C),
            bufferingColor: UIColor(white: 0.5, alpha: 0.5),
            chapters: []
        ))
        self.fitScrubbingNode.isHidden = true

        self.expandElapsedLabel = UILabel()
        self.expandElapsedLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .regular)
        self.expandElapsedLabel.text = "00:00"
        self.expandElapsedLabel.isHidden = true

        self.expandRemainingLabel = UILabel()
        self.expandRemainingLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .regular)
        self.expandRemainingLabel.textAlignment = .right
        self.expandRemainingLabel.text = "-00:00"
        self.expandRemainingLabel.isHidden = true

        self.block2ProgressTrack = UIView()
        self.block2ProgressTrack.backgroundColor = UIColor(white: 0.5, alpha: 0.18)
        self.block2ProgressTrack.isHidden = true
        self.block2ProgressTrack.isUserInteractionEnabled = false

        self.block2ProgressFill = UIView()
        self.block2ProgressFill.backgroundColor = UIColor(rgb: 0xFF383C)
        self.block2ProgressFill.isUserInteractionEnabled = false

        self.rewindButton = UIButton(type: .custom)
        self.rewindButton.setImage(UIImage(systemName: "gobackward.15", withConfiguration: iconConfig), for: .normal)

        self.forwardButton = UIButton(type: .custom)
        self.forwardButton.setImage(UIImage(systemName: "goforward.15", withConfiguration: iconConfig), for: .normal)

        self.prevButton = UIButton(type: .custom)
        self.prevButton.setImage(UIImage(systemName: "backward.end", withConfiguration: iconConfig), for: .normal)

        self.nextButton = UIButton(type: .custom)
        self.nextButton.setImage(UIImage(systemName: "forward.end", withConfiguration: iconConfig), for: .normal)

        super.init()

        self.addSubnode(self.containerNode)
        self.containerNode.addSubnode(self.previewContainer)
        self.containerNode.layer.addSublayer(self.pulseGlowLayer)
        self.applyTheme(self.presentationData.theme)
    }

    deinit {
        self.expandStatusDisposable.dispose()
    }


    override func didLoad() {
        super.didLoad()

        let host = self.containerNode.view
        host.addSubview(self.topShadeView)
        host.addSubview(self.bottomShadeView)
        host.addSubview(self.loadingIndicator)
        host.addSubview(self.playButton)
        host.addSubview(self.fileNameLabel)
        host.addSubview(self.dateLabel)
        host.addSubview(self.senderAvatarNode.view)
        host.addSubview(self.muteBackgroundView)
        host.addSubview(self.muteButton)
        host.addSubview(self.toggleSwitch)
        host.addSubview(self.avatarBackView)
        host.addSubview(self.avatarFrontView)
        host.addSubview(self.participantsCountLabel)
        host.addSubview(self.block3TimeLabel)
        host.addSubview(self.nightModeButton)
        host.addSubview(self.expandButton)
        host.addSubview(self.fitButton)
        host.addSubview(self.shareButton)
        host.addSubview(self.chatButton)
        host.addSubview(self.deleteButton)
        host.addSubview(self.listButton)
        host.addSubview(self.expandScrubbingNode.view)
        host.addSubview(self.fitScrubbingNode.view)
        host.addSubview(self.expandElapsedLabel)
        host.addSubview(self.expandRemainingLabel)
        host.insertSubview(self.block2ProgressTrack, at: 0)
        self.block2ProgressTrack.addSubview(self.block2ProgressFill)
        host.addSubview(self.rewindButton)
        host.addSubview(self.forwardButton)
        host.addSubview(self.prevButton)
        host.addSubview(self.nextButton)

        self.playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        self.muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)
        self.expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        self.fitButton.addTarget(self, action: #selector(galleryTapped), for: .touchUpInside)
        self.shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        self.chatButton.addTarget(self, action: #selector(chatTapped), for: .touchUpInside)
        self.deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        self.listButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        self.rewindButton.addTarget(self, action: #selector(rewindTapped), for: .touchUpInside)
        self.forwardButton.addTarget(self, action: #selector(forwardTapped), for: .touchUpInside)
        self.prevButton.addTarget(self, action: #selector(prevTapped), for: .touchUpInside)
        self.nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        self.toggleSwitch.addTarget(self, action: #selector(pulseTogglecChanged), for: .valueChanged)

        self.expandScrubbingNode.seek = { [weak self] timestamp in
            self?.previewNode?.seek(to: timestamp)
        }
        self.fitScrubbingNode.seek = { [weak self] timestamp in
            self?.previewNode?.seek(to: timestamp)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(previewAreaTapped))
        self.previewContainer.view.isUserInteractionEnabled = true
        self.previewContainer.view.addGestureRecognizer(tap)
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.applyTheme(presentationData.theme)
        self.previewNode?.updatePresentationData(presentationData)
    }

    private func applyTheme(_ theme: PresentationTheme) {
        self.refreshColors()
    }

    private func refreshColors() {
        let theme = self.presentationData.theme
        let list = theme.list
        let themePrimary = list.itemPrimaryTextColor
        let themeSecondary = list.itemSecondaryTextColor
        let accent = list.itemSwitchColors.positiveColor
        let cardBg = list.itemBlocksBackgroundColor
        let overlay = self.isExpanded

        let chromePrimary: UIColor = overlay ? .white : themePrimary
        let chromeSecondary: UIColor = overlay ? UIColor.white.withAlphaComponent(0.85) : themeSecondary

        self.containerNode.backgroundColor = cardBg

        self.fileNameLabel.textColor = chromePrimary
        self.dateLabel.textColor = chromeSecondary

        let muteBg: UIColor
        if overlay {
            muteBg = UIColor.black.withAlphaComponent(0.35)
        } else {
            muteBg = themePrimary.withAlphaComponent(0.08)
        }
        self.muteBackgroundView.backgroundColor = muteBg
        self.muteButton.tintColor = chromePrimary

        self.toggleSwitch.trackColorOn = UIColor(rgb: 0x05614C)
        self.toggleSwitch.trackColorOff = list.itemSwitchColors.frameColor
        self.toggleSwitch.thumbColor = .white

        let avatarBg = chromeSecondary.withAlphaComponent(0.35)
        self.avatarBackView.backgroundColor = avatarBg
        self.avatarFrontView.backgroundColor = avatarBg
        self.avatarFrontView.layer.borderColor = accent.cgColor
        self.participantsCountLabel.textColor = chromePrimary

        for button in [self.nightModeButton, self.expandButton, self.fitButton, self.listButton] {
            button.tintColor = chromePrimary
            if overlay {
                button.layer.shadowColor = UIColor.black.cgColor
                button.layer.shadowOpacity = 0.45
                button.layer.shadowRadius = 3.0
                button.layer.shadowOffset = .zero
            } else {
                button.layer.shadowOpacity = 0.0
            }
        }
        self.deleteButton.tintColor = UIColor(rgb: 0xFF383C)
        if overlay {
            self.deleteButton.layer.shadowColor = UIColor.black.cgColor
            self.deleteButton.layer.shadowOpacity = 0.45
            self.deleteButton.layer.shadowRadius = 3.0
            self.deleteButton.layer.shadowOffset = .zero
        } else {
            self.deleteButton.layer.shadowOpacity = 0.0
        }
        self.expandElapsedLabel.textColor = chromePrimary
        self.expandRemainingLabel.textColor = chromePrimary
        self.block3TimeLabel.textColor = chromePrimary

        self.playButton.tintColor = chromePrimary
        self.loadingIndicator.color = chromePrimary
    }

    func showItem(_ item: MediaBrowserItem) {
        self.currentItem = item

        if let previewNode = self.previewNode {
            previewNode.detach()
            previewNode.displayNode.removeFromSupernode()
            self.previewNode = nil
        }
        self.previewAspectRatio = nil
        self.isPlaying = false
        self.playButton.isHidden = true
        self.loadingIndicator.stopAnimating()

        if let resolution = Self.resolutionString(for: item.message) {
            self.fileNameLabel.text = "\(item.fileName) · \(resolution)"
        } else {
            self.fileNameLabel.text = item.fileName
        }

        self.dateLabel.text = mediaBrowserDateString(item.timestamp, locale: Locale(identifier: self.presentationData.strings.baseLanguageCode))

        if let author = item.message.author {
            self.senderAvatarNode.setPeer(
                context: self.context,
                theme: self.presentationData.theme,
                peer: EnginePeer(author),
                displayDimensions: CGSize(width: 10.0, height: 10.0)
            )
            self.senderAvatarNode.isHidden = false
        } else {
            self.senderAvatarNode.isHidden = true
        }

        self.participantsCountLabel.text = "+24"
        self.block3TimeLabel.text = "00:00"

        let provider = MediaPreviewProviderRegistry.shared.provider(for: item)
        let preview = provider.makePreviewNode(item: item, context: self.context, presentationData: self.presentationData)
        preview.statusUpdated = { [weak self] status in
            self?.handlePreviewStatus(status)
        }
        preview.aspectRatioUpdated = { [weak self] ratio in
            guard let self = self else { return }
            self.previewAspectRatio = ratio
            if self.lastSize.width > 0 {
                self.updateLayout(size: self.lastSize, transition: .immediate)
            }
        }
        if let preloaded = preview.naturalAspectRatio {
            self.previewAspectRatio = preloaded
        }
        self.previewContainer.addSubnode(preview.displayNode)
        self.previewNode = preview

        let previewBounds = self.previewContainer.bounds.size
        if previewBounds.width > 0 && previewBounds.height > 0 {
            preview.displayNode.frame = CGRect(origin: .zero, size: previewBounds)
            preview.updateLayout(size: previewBounds, transition: .immediate)
        }

        if preview.canPlay {
            self.playButton.isHidden = false
        }
        self.bindExpandStatus(preview)

    }

    private func handlePreviewStatus(_ status: MediaPreviewPlaybackStatus) {
        switch status {
        case .idle:
            self.loadingIndicator.stopAnimating()
            self.refreshPlayButtonVisibility()
        case .loading:
            self.loadingIndicator.startAnimating()
            self.refreshPlayButtonVisibility()
        case .playing:
            self.isPlaying = true
            self.loadingIndicator.stopAnimating()
            self.refreshPlayButtonVisibility()
        case .paused:
            self.isPlaying = false
            self.loadingIndicator.stopAnimating()
            self.refreshPlayButtonVisibility()
        case .ended:
            self.isPlaying = false
            self.loadingIndicator.stopAnimating()
            self.refreshPlayButtonVisibility()
        case .error:
            self.isPlaying = false
            self.loadingIndicator.stopAnimating()
            self.refreshPlayButtonVisibility()
        }
    }

    private func refreshPlayButtonVisibility() {
        let canPlay = self.previewNode?.canPlay ?? false
        if self.isExpanded {
            if canPlay {
                self.playButton.isHidden = false
                let iconName = self.isPlaying ? "pause.fill" : "play.fill"
                self.playButton.setImage(UIImage(systemName: iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22.0, weight: .regular)), for: .normal)
            } else {
                self.playButton.isHidden = true
            }
        } else {
            self.playButton.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
            self.playButton.isHidden = !canPlay || self.isPlaying
        }
    }

    @objc private func playTapped() {
        guard let preview = self.previewNode, preview.canPlay else { return }
        preview.togglePlayPause()
    }

    @objc private func previewAreaTapped() {
        guard let preview = self.previewNode, preview.canPlay else { return }
        preview.togglePlayPause()
    }


    @objc private func muteTapped() {
        self.isMuted.toggle()
        let name = self.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        self.muteButton.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17.0, weight: .regular)), for: .normal)
        self.previewNode?.setSoundMuted(self.isMuted)
    }

    @objc private func expandTapped() {
        self.isExpanded.toggle()
        self.refreshExpandIcon()
        self.refreshColors()
        self.refreshPlayButtonVisibility()
        self.onToggleExpanded?()
    }

    @objc private func galleryTapped() {
        guard let item = self.currentItem else { return }
        self.onPresentGallery?(item)
    }

    @objc private func shareTapped() {
        guard let item = self.currentItem else { return }
        self.onShareMessage?(item)
    }

    @objc private func chatTapped() {
        guard let item = self.currentItem else { return }
        self.onJumpToMessage?(item)
    }

    @objc private func deleteTapped() {
        guard let item = self.currentItem else { return }
        self.onDeleteMessage?(item)
    }

    @objc private func rewindTapped() {
        guard let status = self.expandStatusValue, status.duration > 0 else { return }
        self.previewNode?.seek(to: max(0.0, status.timestamp - 15.0))
    }

    @objc private func forwardTapped() {
        guard let status = self.expandStatusValue, status.duration > 0 else { return }
        self.previewNode?.seek(to: min(status.duration, status.timestamp + 15.0))
    }

    @objc private func prevTapped() {
        self.onPrevItem?()
    }

    @objc private func nextTapped() {
        self.onNextItem?()
    }

    @objc private func pulseTogglecChanged() {
        self.pulseGlowLayer.isHidden = !self.toggleSwitch.isOn
    }

    private func bindExpandStatus(_ preview: MediaPreviewNode?) {
        guard let preview = preview, let status = preview.playbackStatus, preview.canPlay else {
            self.expandScrubbingNode.status = nil
            self.expandScrubbingNode.bufferingStatus = nil
            self.fitScrubbingNode.status = nil
            self.fitScrubbingNode.bufferingStatus = nil
            self.expandStatusDisposable.set(nil)
            return
        }
        self.expandScrubbingNode.status = status
        self.expandScrubbingNode.bufferingStatus = preview.bufferingStatus
        self.fitScrubbingNode.status = status
        self.fitScrubbingNode.bufferingStatus = preview.bufferingStatus
        self.expandStatusDisposable.set((status |> deliverOnMainQueue).startStrict(next: { [weak self] s in
            guard let self = self else { return }
            self.expandStatusValue = s
            let elapsed = max(0.0, s.timestamp)
            let total = max(0.0, s.duration)
            self.expandElapsedLabel.text = "\(Self.formatTime(elapsed)) / \(Self.formatTime(total))"
            self.expandRemainingLabel.text = ""
            self.updateBlock3Time(s)
        }))
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0.0, seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func updateBlock2Progress(_ status: MediaPlayerStatus) {
        guard status.duration > 0, self.containerNode.frame.width > 0 else { return }
        let progress = max(0.0, min(1.0, status.timestamp / status.duration))
        let trackWidth = self.containerNode.frame.width
        self.block2ProgressFill.frame = CGRect(x: 0, y: 0, width: trackWidth * progress, height: 2.0)
    }

    private func updateBlock3Time(_ status: MediaPlayerStatus) {
        let elapsed = max(0.0, status.timestamp)
        let total = max(0.0, status.duration)
        switch status.status {
        case .playing:
            self.block3TimeLabel.text = "\(Self.formatTime(elapsed)) / \(Self.formatTime(total))"
        case .paused, .buffering:
            self.block3TimeLabel.text = Self.formatTime(elapsed)
        }
    }

    private static func resolutionString(for message: Message) -> String? {
        for media in message.media {
            if let file = media as? TelegramMediaFile, let dims = file.dimensions, dims.width > 0 && dims.height > 0 {
                return "\(dims.width)×\(dims.height)"
            }
            if let image = media as? TelegramMediaImage, let representation = image.representations.last {
                let dims = representation.dimensions
                if dims.width > 0 && dims.height > 0 {
                    return "\(dims.width)×\(dims.height)"
                }
            }
        }
        return nil
    }

    private func refreshExpandIcon() {
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 18.0, weight: .regular)
        let name = self.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        self.expandButton.setImage(UIImage(systemName: name, withConfiguration: iconConfig), for: .normal)
    }

    func setExpandedState(_ value: Bool) {
        guard self.isExpanded != value else { return }
        self.isExpanded = value
        self.refreshExpandIcon()
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.updateLayout(size: size, safeInsets: .zero, transition: transition)
    }

    func updateLayout(size: CGSize, safeInsets: UIEdgeInsets, transition: ContainedViewLayoutTransition) {
        self.lastSize = size
        let overlay = self.isExpanded
        let canPlay = self.previewNode?.canPlay ?? false

        self.playButton.isHidden = !canPlay || self.isPlaying

        let containerFrame: CGRect
        let cornerRadius: CGFloat
        if overlay {
            containerFrame = CGRect(origin: .zero, size: size)
            cornerRadius = 16.0
        } else {
            let inset: CGFloat = 8.0
            containerFrame = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
            cornerRadius = 16.0
        }
        transition.updateFrame(node: self.containerNode, frame: containerFrame)
        transition.updateCornerRadius(node: self.containerNode, cornerRadius: cornerRadius)
        self.pulseGlowLayer.frame = CGRect(origin: .zero, size: containerFrame.size)
        self.pulseGlowLayer.cornerRadius = cornerRadius

        let innerWidth = containerFrame.width
        let innerHeight = containerFrame.height

        let previewFrame: CGRect
        if overlay {
            previewFrame = CGRect(origin: .zero, size: containerFrame.size)
        } else {
            let previewInset: CGFloat = 8.0
            let maxPreviewWidth = floor(innerWidth * 0.50)
            let maxPreviewHeight = innerHeight - previewInset * 2.0
            let aspectRatio = self.previewAspectRatio ?? (CGFloat(0.32) * innerWidth / maxPreviewHeight)
            var previewWidth: CGFloat
            var previewHeight: CGFloat
            if aspectRatio >= maxPreviewWidth / maxPreviewHeight {
                previewWidth = maxPreviewWidth
                previewHeight = floor(maxPreviewWidth / aspectRatio)
            } else {
                previewHeight = maxPreviewHeight
                previewWidth = floor(maxPreviewHeight * aspectRatio)
            }
            let previewY = previewInset + floor((maxPreviewHeight - previewHeight) / 2.0)
            previewFrame = CGRect(x: previewInset, y: previewY, width: previewWidth, height: previewHeight)
        }
        transition.updateFrame(node: self.previewContainer, frame: previewFrame)
        if let preview = self.previewNode {
            preview.displayNode.frame = CGRect(origin: .zero, size: previewFrame.size)
            preview.updateLayout(size: previewFrame.size, transition: transition)
        }

        let playSize: CGFloat = self.isExpanded ? 24.0 : 48.0
        if self.isExpanded {
            self.playButton.frame = CGRect(
                x: (safeInsets.left + 12.0),
                y: innerHeight - (safeInsets.bottom + 14.0) - 28.0 + (28.0 - playSize) / 2.0,
                width: playSize,
                height: playSize
            )
        } else {
            self.playButton.frame = CGRect(
                x: previewFrame.midX - playSize / 2.0,
                y: previewFrame.midY - playSize / 2.0,
                width: playSize,
                height: playSize
            )
        }
        self.loadingIndicator.center = CGPoint(x: previewFrame.midX, y: previewFrame.midY)

        if overlay {
            self.topShadeView.isHidden = false
            self.bottomShadeView.isHidden = false
            let topShadeHeight = (safeInsets.top + 12.0) + 36.0 + 80.0
            let bottomShadeHeight = (safeInsets.bottom + 14.0) + 32.0 + 60.0
            self.topShadeView.frame = CGRect(x: 0, y: 0, width: innerWidth, height: topShadeHeight)
            self.bottomShadeView.frame = CGRect(x: 0, y: innerHeight - bottomShadeHeight, width: innerWidth, height: bottomShadeHeight)
        } else {
            self.topShadeView.isHidden = true
            self.bottomShadeView.isHidden = true
        }

        let topInset: CGFloat = overlay ? (safeInsets.top + 12.0) : 12.0
        let bottomInset: CGFloat = overlay ? (safeInsets.bottom + 14.0) : 14.0
        let leftInset: CGFloat = overlay ? (safeInsets.left + 12.0) : 12.0
        let rightInset: CGFloat = overlay ? (safeInsets.right + 16.0) : 16.0

        let muteSize: CGFloat = 36.0
        let muteFrame = CGRect(x: leftInset, y: topInset, width: muteSize, height: muteSize)
        self.muteBackgroundView.frame = muteFrame
        self.muteButton.frame = muteFrame

        let switchSize = self.toggleSwitch.intrinsicContentSize
        self.toggleSwitch.frame = CGRect(
            x: innerWidth - rightInset - switchSize.width + 4.0,
            y: topInset + (muteSize - switchSize.height) / 2.0,
            width: switchSize.width,
            height: switchSize.height
        )

        let dateDotSize: CGFloat = 10.0
        let dateAttributes: [NSAttributedString.Key: Any] = [.font: self.dateLabel.font as Any]
        let dateTextWidth = ((self.dateLabel.text ?? "") as NSString).size(withAttributes: dateAttributes).width
        let dateLabelWidth = ceil(dateTextWidth) + 2.0
        let dateBlockWidth = dateLabelWidth + 6.0 + dateDotSize

        if overlay {
            self.fileNameLabel.textAlignment = .right
            self.dateLabel.textAlignment = .right
            let titleHeight = self.fileNameLabel.font.lineHeight * 2.0
            let titleTop = topInset + muteSize + 16.0
            let titleRight = innerWidth - rightInset
            let titleLeft = max(leftInset + muteSize + 16.0, innerWidth * 0.40)
            let titleWidth = max(120.0, titleRight - titleLeft)
            self.fileNameLabel.frame = CGRect(x: titleLeft, y: titleTop, width: titleWidth, height: titleHeight)

            let dateY = self.fileNameLabel.frame.maxY + 6.0
            self.dateLabel.frame = CGRect(x: titleRight - dateBlockWidth, y: dateY, width: dateLabelWidth, height: 20.0)
            self.senderAvatarNode.view.frame = CGRect(x: self.dateLabel.frame.maxX + 6.0, y: dateY + (20.0 - dateDotSize) / 2.0, width: dateDotSize, height: dateDotSize)
            self.senderAvatarNode.updateSize(size: CGSize(width: dateDotSize, height: dateDotSize))
        } else {
            self.fileNameLabel.textAlignment = .left
            self.dateLabel.textAlignment = .left
            let titleOverlap: CGFloat = 24.0
            let titleLeft = max(16.0, previewFrame.maxX - titleOverlap)
            let titleRight = innerWidth - 16.0
            let titleWidth = max(120.0, titleRight - titleLeft)
            let titleHeight = self.fileNameLabel.font.lineHeight * 2.0
            let titleY = floor((innerHeight - titleHeight) / 2.0) - 8.0
            self.fileNameLabel.frame = CGRect(x: titleLeft, y: titleY, width: titleWidth, height: titleHeight)

            let dateRight = innerWidth - 16.0
            let dateY = self.fileNameLabel.frame.maxY + 10.0
            self.dateLabel.frame = CGRect(x: dateRight - dateBlockWidth, y: dateY, width: dateLabelWidth, height: 20.0)
            self.senderAvatarNode.view.frame = CGRect(x: self.dateLabel.frame.maxX + 6.0, y: dateY + (20.0 - dateDotSize) / 2.0, width: dateDotSize, height: dateDotSize)
            self.senderAvatarNode.updateSize(size: CGSize(width: dateDotSize, height: dateDotSize))
        }

        let iconSize: CGFloat = 24.0
        let iconSpacing: CGFloat = 6.0
        let iconsRight = innerWidth - rightInset
        let iconsY = innerHeight - bottomInset - iconSize
        let canPlayPlayback = canPlay
        let iconButtons: [UIButton] = [
            self.nightModeButton,
            self.expandButton,
            self.fitButton,
            self.listButton
        ]
        for (index, button) in iconButtons.reversed().enumerated() {
            let x = iconsRight - CGFloat(index + 1) * iconSize - CGFloat(index) * iconSpacing
            button.frame = CGRect(x: x, y: iconsY, width: iconSize, height: iconSize)
        }
        self.rewindButton.isHidden = true
        self.forwardButton.isHidden = true
        self.prevButton.isHidden = true
        self.nextButton.isHidden = true
        self.shareButton.isHidden = true
        self.chatButton.isHidden = true
        self.deleteButton.isHidden = true
        _ = canPlayPlayback

        self.block2ProgressTrack.isHidden = true

        let scrubberVisible = self.isExpanded && canPlay
        self.expandRemainingLabel.isHidden = true
        if scrubberVisible {
            self.expandScrubbingNode.isHidden = false
            self.expandElapsedLabel.isHidden = false
            let scrubberHeight: CGFloat = 28.0
            let scrubberY = iconsY - 8.0 - scrubberHeight
            self.expandScrubbingNode.view.frame = CGRect(x: leftInset, y: scrubberY, width: innerWidth - leftInset - rightInset, height: scrubberHeight)
            let bottomPlaySize: CGFloat = 24.0
            let timeFontAttrs: [NSAttributedString.Key: Any] = [.font: self.expandElapsedLabel.font as Any]
            let timeText = self.expandElapsedLabel.text ?? "00:00 / 00:00"
            let timeWidth = ceil((timeText as NSString).size(withAttributes: timeFontAttrs).width) + 4.0
            let timeHeight = ceil((timeText as NSString).size(withAttributes: timeFontAttrs).height)
            self.expandElapsedLabel.frame = CGRect(x: leftInset + bottomPlaySize + 10.0, y: iconsY + (iconSize - timeHeight) / 2.0, width: timeWidth, height: timeHeight)
        } else {
            self.expandScrubbingNode.isHidden = true
            self.expandElapsedLabel.isHidden = true
        }

        let avatarSize: CGFloat = 20.0
        let avatarOverlap: CGFloat = 8.0
        let countSize = (self.participantsCountLabel.text ?? "").size(withAttributes: [.font: self.participantsCountLabel.font as Any])
        let countWidth = ceil(countSize.width)
        let avatarsBaseY = scrubberVisible ? self.expandScrubbingNode.view.frame.minY : iconsY
        let avatarsY = avatarsBaseY - avatarSize - 14.0
        let countX = iconsRight - countWidth
        let frontAvatarX = countX - 8.0 - avatarSize
        let backAvatarX = frontAvatarX - (avatarSize - avatarOverlap)
        self.avatarBackView.frame = CGRect(x: backAvatarX, y: avatarsY, width: avatarSize, height: avatarSize)
        self.avatarFrontView.frame = CGRect(x: frontAvatarX, y: avatarsY, width: avatarSize, height: avatarSize)
        self.participantsCountLabel.frame = CGRect(x: countX, y: avatarsY + (avatarSize - countSize.height) / 2.0, width: countWidth, height: ceil(countSize.height))

        if canPlay && !self.isExpanded {
            self.avatarBackView.isHidden = true
            self.avatarFrontView.isHidden = true
            self.participantsCountLabel.isHidden = true
            self.block3TimeLabel.isHidden = false
            let timeText = self.block3TimeLabel.text ?? ""
            let timeAttrs: [NSAttributedString.Key: Any] = [.font: self.block3TimeLabel.font as Any]
            let timeSize = (timeText as NSString).size(withAttributes: timeAttrs)
            let timeWidth = max(60.0, ceil(timeSize.width) + 4.0)
            let timeHeight = ceil(timeSize.height)
            self.block3TimeLabel.frame = CGRect(x: iconsRight - timeWidth, y: avatarsY + (avatarSize - timeHeight) / 2.0, width: timeWidth, height: timeHeight)

            self.fitScrubbingNode.isHidden = false
            let scrubberHeight: CGFloat = 22.0
            let scrubberRight = self.block3TimeLabel.frame.minX - 10.0
            let scrubberY = avatarsY + (avatarSize - scrubberHeight) / 2.0
            self.fitScrubbingNode.view.frame = CGRect(x: leftInset, y: scrubberY, width: max(40.0, scrubberRight - leftInset), height: scrubberHeight)
        } else {
            self.avatarBackView.isHidden = false
            self.avatarFrontView.isHidden = false
            self.participantsCountLabel.isHidden = false
            self.block3TimeLabel.isHidden = true
            self.fitScrubbingNode.isHidden = true
        }
    }
}
