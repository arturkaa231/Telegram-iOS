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
    private static let minimumDisplayDuration: Double = 1.0

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
    private let toggleHitButton: UIButton

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
    var onPulseChanged: ((Bool) -> Void)?
    var onPlaybackStatusChanged: ((MediaPreviewPlaybackStatus) -> Void)?
    var onSeekRequested: ((Double, CGFloat) -> Void)?
    var onPlaybackPositionUpdated: ((Double, CGFloat, Bool) -> Void)?
    var onCloseMediaBrowser: (() -> Void)?
    var onToggleFocusMode: (() -> Void)?

    private var isMuted: Bool = false
    private var isPlaying: Bool = false
    private var isExpanded: Bool = false
    private var isFocusMode: Bool = false
    private var previewAspectRatio: CGFloat?
    private var lastSize: CGSize = .zero
    private let remoteSeekTolerance: Double = 1.5
    private var lastReportedPlaybackTimestamp: Double?
    private var lastReportedPlaybackProgress: CGFloat?
    private var lastReportedPlaybackIsPlaying: Bool?
    private var pendingInitialSeek: (messageId: EngineMessage.Id, position: Double)?
    private var hasBoundPlayablePreview: Bool = false

    private var currentItem: MediaBrowserItem?
    private var suppressPulseCallback: Bool = false

    var onToggleExpanded: ((Bool) -> Void)?

    private var usesEmbeddedPlaybackChrome: Bool {
        if case .youtube = self.currentItem?.playableSource {
            return true
        }
        if case .unsupportedUrl = self.currentItem?.playableSource {
            return self.usesGenericWebPlayback
        }
        return false
    }

    private var usesGenericWebPlayback: Bool {
        if case .unsupportedUrl = self.currentItem?.playableSource {
            return !(self.previewNode?.canPlay ?? false)
        }
        return false
    }

    private var shouldShowCompactEmbeddedAction: Bool {
        return self.usesEmbeddedPlaybackChrome && !self.usesGenericWebPlayback && !self.isExpanded && !self.isFocusMode
    }

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
        self.fileNameLabel.adjustsFontSizeToFitWidth = true
        self.fileNameLabel.minimumScaleFactor = 0.78

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
        self.toggleSwitch.setOn(false, animated: false)
        self.toggleHitButton = UIButton(type: .custom)
        self.toggleHitButton.backgroundColor = .clear
        self.toggleHitButton.isAccessibilityElement = true
        self.toggleHitButton.accessibilityLabel = "Пульт"
        self.toggleHitButton.accessibilityValue = "Выключен"

        self.participantsCountLabel = UILabel()
        self.participantsCountLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .regular)

        self.block3TimeLabel = UILabel()
        self.block3TimeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14.0, weight: .regular)
        self.block3TimeLabel.textAlignment = .right
        self.block3TimeLabel.adjustsFontSizeToFitWidth = true
        self.block3TimeLabel.minimumScaleFactor = 0.82
        self.block3TimeLabel.lineBreakMode = .byClipping
        self.block3TimeLabel.isHidden = true

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 18.0, weight: .regular)

        self.nightModeButton = UIButton(type: .custom)
        self.nightModeButton.setImage(UIImage(systemName: "moon", withConfiguration: iconConfig), for: .normal)
        self.nightModeButton.accessibilityLabel = "Режим фокусировки"

        self.expandButton = UIButton(type: .custom)
        self.expandButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: iconConfig), for: .normal)
        self.expandButton.accessibilityLabel = "Развернуть плеер"

        self.fitButton = UIButton(type: .custom)
        self.fitButton.setImage(UIImage(systemName: "viewfinder", withConfiguration: iconConfig), for: .normal)
        self.fitButton.accessibilityLabel = "Полноэкранный просмотр"

        self.listButton = UIButton(type: .custom)
        self.listButton.setImage(UIImage(systemName: "list.bullet", withConfiguration: iconConfig), for: .normal)
        self.listButton.accessibilityLabel = "Закрыть медиатеку"

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
        self.expandElapsedLabel.adjustsFontSizeToFitWidth = true
        self.expandElapsedLabel.minimumScaleFactor = 0.82
        self.expandElapsedLabel.lineBreakMode = .byClipping
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
        host.addSubview(self.toggleHitButton)
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
        self.nightModeButton.addTarget(self, action: #selector(focusTapped), for: .touchUpInside)
        self.expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        self.fitButton.addTarget(self, action: #selector(galleryTapped), for: .touchUpInside)
        self.shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        self.chatButton.addTarget(self, action: #selector(chatTapped), for: .touchUpInside)
        self.deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        self.listButton.addTarget(self, action: #selector(listTapped), for: .touchUpInside)
        self.rewindButton.addTarget(self, action: #selector(rewindTapped), for: .touchUpInside)
        self.forwardButton.addTarget(self, action: #selector(forwardTapped), for: .touchUpInside)
        self.prevButton.addTarget(self, action: #selector(prevTapped), for: .touchUpInside)
        self.nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        self.toggleSwitch.addTarget(self, action: #selector(pulseTogglecChanged), for: .valueChanged)
        self.toggleHitButton.addTarget(self, action: #selector(toggleHitButtonTapped), for: .touchUpInside)

        self.expandScrubbingNode.seek = { [weak self] timestamp in
            self?.seekPreview(to: timestamp, report: true)
        }
        self.fitScrubbingNode.seek = { [weak self] timestamp in
            self?.seekPreview(to: timestamp, report: true)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(previewAreaTapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
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
        let cardBg = list.itemBlocksBackgroundColor
        let overlay = self.isExpanded || self.isFocusMode

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

        self.participantsCountLabel.textColor = chromePrimary

        for button in [self.nightModeButton, self.expandButton, self.fitButton, self.listButton] {
            button.tintColor = chromePrimary
            button.alpha = button.isEnabled ? 1.0 : 0.32
            if overlay {
                button.layer.shadowColor = UIColor.black.cgColor
                button.layer.shadowOpacity = button.isEnabled ? 0.45 : 0.0
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

    var displayedItem: MediaBrowserItem? {
        return self.currentItem
    }

    func currentPlaybackPosition() -> Double {
        return max(0.0, self.expandStatusValue?.timestamp ?? 0.0)
    }

    func currentPlaybackProgress() -> CGFloat {
        guard let status = self.expandStatusValue, status.duration > 0.0 else {
            return 0.0
        }
        return CGFloat(max(0.0, min(1.0, status.timestamp / status.duration)))
    }

    func isPulseActive() -> Bool {
        return self.toggleSwitch.isOn
    }

    func isPlaybackActive() -> Bool {
        return self.isPlaying
    }

    func setPulseActive(_ active: Bool, animated: Bool) {
        self.suppressPulseCallback = true
        self.toggleSwitch.setOn(active, animated: animated)
        self.toggleHitButton.accessibilityValue = active ? "Включён" : "Выключен"
        if active {
            self.toggleHitButton.accessibilityTraits.insert(.selected)
        } else {
            self.toggleHitButton.accessibilityTraits.remove(.selected)
        }
        self.suppressPulseCallback = false
        self.pulseGlowLayer.isHidden = !active
    }

    func updateSessionAudience(participantCount: Int) {
        self.participantsCountLabel.text = participantCount > 0 ? "+\(participantCount)" : ""
        if self.lastSize.width > 0 {
            self.updateLayout(size: self.lastSize, transition: .immediate)
        }
    }

    func showItem(_ item: MediaBrowserItem, seekTo position: Double? = nil) {
        self.currentItem = item
        self.pendingInitialSeek = nil

        if let previewNode = self.previewNode {
            previewNode.detach()
            previewNode.displayNode.removeFromSupernode()
            self.previewNode = nil
        }
        self.previewAspectRatio = nil
        self.expandStatusValue = nil
        self.isPlaying = false
        self.lastReportedPlaybackTimestamp = nil
        self.lastReportedPlaybackProgress = nil
        self.lastReportedPlaybackIsPlaying = nil
        self.hasBoundPlayablePreview = false
        self.playButton.isHidden = true
        self.loadingIndicator.stopAnimating()

        self.fileNameLabel.text = item.fileName.isEmpty ? "Без названия" : item.fileName

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

        self.participantsCountLabel.text = ""
        self.block3TimeLabel.text = "00:00"
        self.participantsCountLabel.isHidden = true

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

        self.refreshPlayButtonVisibility()
        self.bindExpandStatus(preview)
        if let position = position, position > 0.0 {
            self.setPendingInitialSeek(position, for: item, preview: preview)
        }
        if self.lastSize.width > 0 {
            self.updateLayout(size: self.lastSize, transition: .immediate)
        }

    }

    func seekToSavedPosition(_ position: Double, for item: MediaBrowserItem) {
        guard self.currentItem?.messageId == item.messageId else {
            return
        }
        self.setPendingInitialSeek(position, for: item, preview: self.previewNode)
    }

    private func handlePreviewStatus(_ status: MediaPreviewPlaybackStatus) {
        let didBecomePlayable = self.previewNode?.canPlay == true && !self.hasBoundPlayablePreview
        if self.previewNode?.canPlay == true && !self.hasBoundPlayablePreview {
            self.bindExpandStatus(self.previewNode)
        }
        if didBecomePlayable && self.lastSize.width > 0.0 && self.lastSize.height > 0.0 {
            self.updateLayout(size: self.lastSize, transition: .immediate)
        }
        self.onPlaybackStatusChanged?(status)
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
            self.applyPendingInitialSeekIfPossible(bestEffort: false)
        case .paused:
            self.isPlaying = false
            self.loadingIndicator.stopAnimating()
            self.refreshPlayButtonVisibility()
            self.applyPendingInitialSeekIfPossible(bestEffort: false)
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
        if self.usesEmbeddedPlaybackChrome {
            if self.shouldShowCompactEmbeddedAction && canPlay {
                let iconName = self.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                self.playButton.setImage(UIImage(systemName: iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 48.0, weight: .regular)), for: .normal)
                self.playButton.isHidden = false
            } else {
                self.playButton.isHidden = true
            }
            return
        }
        if self.isExpanded || self.isFocusMode {
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
        if self.usesGenericWebPlayback {
            return
        }
        if self.usesEmbeddedPlaybackChrome {
            self.previewNode?.togglePlayPause()
            return
        }
        guard let preview = self.previewNode, preview.canPlay else { return }
        preview.togglePlayPause()
    }

    @objc private func previewAreaTapped() {
        if self.usesGenericWebPlayback {
            return
        }
        if self.usesEmbeddedPlaybackChrome {
            self.previewNode?.togglePlayPause()
            return
        }
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
        self.setExpanded(!self.isExpanded, notify: true)
    }

    @objc private func focusTapped() {
        self.onToggleFocusMode?()
    }

    @objc private func listTapped() {
        self.setExpanded(false, notify: true)
        self.onCloseMediaBrowser?()
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
        self.seekPreview(to: max(0.0, status.timestamp - 15.0), report: true)
    }

    @objc private func forwardTapped() {
        guard let status = self.expandStatusValue, status.duration > 0 else { return }
        self.seekPreview(to: min(status.duration, status.timestamp + 15.0), report: true)
    }

    func applyRemotePlaybackAction(position: Double, progress: CGFloat, isPlaying: Bool) {
        self.seekPreviewIfNeeded(to: position, tolerance: isPlaying ? self.remoteSeekTolerance : 0.35)
        if isPlaying {
            if !self.isPlaying {
                self.previewNode?.play()
            }
        } else {
            if self.isPlaying {
                self.previewNode?.pause()
            } else {
                self.previewNode?.pause()
            }
        }
    }

    func applyRemotePlaybackState(position: Double, progress: CGFloat) {
        self.seekPreviewIfNeeded(to: position, tolerance: self.remoteSeekTolerance)
    }

    private func seekPreview(to timestamp: Double, report: Bool) {
        self.previewNode?.seek(to: timestamp)
        if report {
            self.onSeekRequested?(timestamp, self.progress(for: timestamp))
        }
    }

    private func seekPreviewIfNeeded(to timestamp: Double, tolerance: Double) {
        let current = self.currentPlaybackPosition()
        guard abs(current - timestamp) > tolerance else {
            return
        }
        self.seekPreview(to: timestamp, report: false)
    }

    private func setPendingInitialSeek(_ position: Double, for item: MediaBrowserItem, preview: MediaPreviewNode?) {
        guard position > 0.0 else {
            self.pendingInitialSeek = nil
            return
        }
        self.pendingInitialSeek = (item.messageId, position)
        self.applyPendingInitialSeekIfPossible(bestEffort: false)
        self.schedulePendingInitialSeekRetry(preview: preview, delay: 0.15, bestEffort: false)
        self.schedulePendingInitialSeekRetry(preview: preview, delay: 0.45, bestEffort: false)
        self.schedulePendingInitialSeekRetry(preview: preview, delay: 1.0, bestEffort: true)
    }

    private func schedulePendingInitialSeekRetry(preview: MediaPreviewNode?, delay: Double, bestEffort: Bool) {
        Queue.mainQueue().after(delay) { [weak self, weak preview] in
            guard let self = self else {
                return
            }
            if let preview = preview, self.previewNode !== preview {
                return
            }
            self.applyPendingInitialSeekIfPossible(bestEffort: bestEffort)
        }
    }

    private func applyPendingInitialSeekIfPossible(bestEffort: Bool) {
        guard let pending = self.pendingInitialSeek else {
            return
        }
        guard self.currentItem?.messageId == pending.messageId else {
            self.pendingInitialSeek = nil
            return
        }
        guard let preview = self.previewNode, preview.canPlay else {
            return
        }

        let target: Double
        if let status = self.expandStatusValue, status.duration > 0.0 {
            target = min(pending.position, max(0.0, status.duration - 0.25))
            if abs(status.timestamp - target) <= 0.35 {
                self.pendingInitialSeek = nil
                return
            }
        } else if bestEffort {
            target = pending.position
        } else {
            return
        }

        self.seekPreview(to: target, report: false)
    }

    private func progress(for timestamp: Double) -> CGFloat {
        guard let status = self.expandStatusValue, status.duration > 0.0 else {
            return 0.0
        }
        return CGFloat(max(0.0, min(1.0, timestamp / status.duration)))
    }

    @objc private func prevTapped() {
        self.onPrevItem?()
    }

    @objc private func nextTapped() {
        self.onNextItem?()
    }

    @objc private func pulseTogglecChanged() {
        self.pulseGlowLayer.isHidden = !self.toggleSwitch.isOn
        self.toggleHitButton.accessibilityValue = self.toggleSwitch.isOn ? "Включён" : "Выключен"
        if self.toggleSwitch.isOn {
            self.toggleHitButton.accessibilityTraits.insert(.selected)
        } else {
            self.toggleHitButton.accessibilityTraits.remove(.selected)
        }
        if !self.suppressPulseCallback {
            self.onPulseChanged?(self.toggleSwitch.isOn)
        }
    }

    @objc private func toggleHitButtonTapped() {
        self.toggleSwitch.setOn(!self.toggleSwitch.isOn, animated: true)
        self.pulseTogglecChanged()
    }

    private func bindExpandStatus(_ preview: MediaPreviewNode?) {
        guard let preview = preview, let status = preview.playbackStatus, preview.canPlay else {
            self.hasBoundPlayablePreview = false
            self.expandScrubbingNode.status = nil
            self.expandScrubbingNode.bufferingStatus = nil
            self.fitScrubbingNode.status = nil
            self.fitScrubbingNode.bufferingStatus = nil
            self.expandStatusDisposable.set(nil)
            self.lastReportedPlaybackTimestamp = nil
            self.lastReportedPlaybackProgress = nil
            self.lastReportedPlaybackIsPlaying = nil
            return
        }
        self.hasBoundPlayablePreview = true
        self.expandScrubbingNode.status = status
        self.expandScrubbingNode.bufferingStatus = preview.bufferingStatus
        self.fitScrubbingNode.status = status
        self.fitScrubbingNode.bufferingStatus = preview.bufferingStatus
        self.expandStatusDisposable.set((status |> deliverOnMainQueue).startStrict(next: { [weak self] s in
            guard let self = self else { return }
            self.expandStatusValue = s
            let total = max(0.0, s.duration)
            let hasDisplayDuration = total >= Self.minimumDisplayDuration
            let elapsed = hasDisplayDuration ? min(max(0.0, s.timestamp), total) : max(0.0, s.timestamp)
            self.expandElapsedLabel.text = Self.elapsedRemainingString(elapsed: elapsed, duration: total)
            self.expandRemainingLabel.text = ""
            self.updateBlock3Time(s)
            self.updateBlock2Progress(s)
            self.applyPendingInitialSeekIfPossible(bestEffort: false)
            let progress: CGFloat
            if hasDisplayDuration {
                progress = CGFloat(max(0.0, min(1.0, elapsed / total)))
            } else {
                progress = 0.0
            }
            let isPlaying: Bool
            switch s.status {
            case .playing:
                isPlaying = true
            case .paused, .buffering:
                isPlaying = false
            }
            self.reportPlaybackPositionIfNeeded(timestamp: elapsed, progress: progress, isPlaying: isPlaying, duration: total)
        }))
    }

    private func reportPlaybackPositionIfNeeded(timestamp: Double, progress: CGFloat, isPlaying: Bool, duration: Double) {
        guard duration > 0.0, timestamp.isFinite, progress.isFinite else {
            return
        }
        let previousTimestamp = self.lastReportedPlaybackTimestamp
        let previousProgress = self.lastReportedPlaybackProgress
        let previousIsPlaying = self.lastReportedPlaybackIsPlaying
        let timestampChanged = previousTimestamp.map { abs(timestamp - $0) >= 0.25 } ?? true
        let progressChanged = previousProgress.map { abs(progress - $0) >= 0.0025 } ?? true
        let playbackChanged = previousIsPlaying.map { $0 != isPlaying } ?? true
        guard timestampChanged || progressChanged || playbackChanged else {
            return
        }
        self.lastReportedPlaybackTimestamp = timestamp
        self.lastReportedPlaybackProgress = progress
        self.lastReportedPlaybackIsPlaying = isPlaying
        self.onPlaybackPositionUpdated?(timestamp, progress, isPlaying)
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0.0, seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func elapsedRemainingString(elapsed: Double, duration: Double) -> String {
        guard duration >= Self.minimumDisplayDuration else {
            return Self.formatTime(elapsed)
        }
        let remaining = max(0.0, duration - elapsed)
        return "\(Self.formatTime(elapsed)) / -\(Self.formatTime(remaining))"
    }

    private func updateBlock2Progress(_ status: MediaPlayerStatus) {
        let trackWidth = self.block2ProgressTrack.bounds.width
        let trackHeight = max(2.0, self.block2ProgressTrack.bounds.height)
        guard status.duration >= Self.minimumDisplayDuration, trackWidth > 0.0 else {
            self.block2ProgressFill.frame = CGRect(x: 0, y: 0, width: 0.0, height: trackHeight)
            return
        }
        let progress = max(0.0, min(1.0, status.timestamp / status.duration))
        self.block2ProgressFill.frame = CGRect(x: 0, y: 0, width: trackWidth * progress, height: trackHeight)
    }

    private func updateBlock3Time(_ status: MediaPlayerStatus) {
        let total = max(0.0, status.duration)
        let elapsed = total >= Self.minimumDisplayDuration ? min(max(0.0, status.timestamp), total) : max(0.0, status.timestamp)
        self.block3TimeLabel.text = Self.elapsedRemainingString(elapsed: elapsed, duration: total)
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
        self.expandButton.accessibilityLabel = self.isExpanded ? "Свернуть плеер" : "Развернуть плеер"
        let focusName = self.isExpanded ? "moon.fill" : "moon"
        self.nightModeButton.setImage(UIImage(systemName: focusName, withConfiguration: iconConfig), for: .normal)
    }

    func setExpandedState(_ value: Bool) {
        self.setExpanded(value, notify: false)
    }

    private func setExpanded(_ value: Bool, notify: Bool) {
        guard self.isExpanded != value else { return }
        self.isExpanded = value
        self.refreshExpandIcon()
        self.refreshColors()
        self.refreshPlayButtonVisibility()
        if self.lastSize.width > 0.0 && self.lastSize.height > 0.0 {
            self.updateLayout(size: self.lastSize, transition: .immediate)
        }
        if notify {
            self.onToggleExpanded?(value)
        }
    }

    func setFocusMode(_ value: Bool) {
        guard self.isFocusMode != value else { return }
        self.isFocusMode = value
        self.refreshFocusIcon()
        self.refreshColors()
        self.refreshPlayButtonVisibility()
    }

    private func refreshFocusIcon() {
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 18.0, weight: .regular)
        let name = self.isFocusMode ? "moon.fill" : "moon"
        self.nightModeButton.setImage(UIImage(systemName: name, withConfiguration: iconConfig), for: .normal)
        self.nightModeButton.accessibilityLabel = self.isFocusMode ? "Выйти из режима фокусировки" : "Режим фокусировки"
        self.nightModeButton.accessibilityValue = self.isFocusMode ? "Включён" : "Выключен"
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.updateLayout(size: size, safeInsets: .zero, transition: transition)
    }

    func updateLayout(size: CGSize, safeInsets: UIEdgeInsets, transition: ContainedViewLayoutTransition) {
        self.lastSize = size
        let expandedChrome = self.isExpanded || self.isFocusMode
        let overlay = expandedChrome
        let canPlay = self.previewNode?.canPlay ?? false

        self.refreshPlayButtonVisibility()

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

        let playSize: CGFloat = expandedChrome ? 24.0 : 48.0
        if expandedChrome {
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
        self.toggleHitButton.frame = self.toggleSwitch.frame.insetBy(dx: -10.0, dy: -10.0)

        self.dateLabel.font = overlay ? UIFont.systemFont(ofSize: self.isFocusMode ? 9.0 : 14.0, weight: .regular) : UIFont.systemFont(ofSize: 15.0, weight: .regular)
        let dateDotSize: CGFloat = 10.0
        let dateAttributes: [NSAttributedString.Key: Any] = [.font: self.dateLabel.font as Any]
        let dateTextWidth = ((self.dateLabel.text ?? "") as NSString).size(withAttributes: dateAttributes).width
        let dateLabelWidth = ceil(dateTextWidth) + 2.0
        let dateBlockWidth = dateLabelWidth + 6.0 + dateDotSize

        if overlay {
            self.fileNameLabel.font = UIFont.systemFont(ofSize: self.isFocusMode ? 14.0 : 28.0, weight: .regular)
            self.fileNameLabel.textAlignment = .right
            self.dateLabel.textAlignment = .right
            let titleHeight = self.fileNameLabel.font.lineHeight * (self.isFocusMode ? 1.2 : 2.0)
            let titleTop = self.isFocusMode ? max(topInset + muteSize + 12.0, innerHeight * 0.34) : topInset + muteSize + 16.0
            let titleRight = innerWidth - rightInset
            let titleLeft = max(leftInset + muteSize + 16.0, innerWidth * (self.isFocusMode ? 0.58 : 0.40))
            let titleWidth = max(120.0, titleRight - titleLeft)
            self.fileNameLabel.frame = CGRect(x: titleLeft, y: titleTop, width: titleWidth, height: titleHeight)

            let dateY = self.fileNameLabel.frame.maxY + (self.isFocusMode ? 1.0 : 6.0)
            self.dateLabel.frame = CGRect(x: titleRight - dateBlockWidth, y: dateY, width: dateLabelWidth, height: 20.0)
            self.senderAvatarNode.view.frame = CGRect(x: self.dateLabel.frame.maxX + 6.0, y: dateY + (20.0 - dateDotSize) / 2.0, width: dateDotSize, height: dateDotSize)
            self.senderAvatarNode.updateSize(size: CGSize(width: dateDotSize, height: dateDotSize))
        } else {
            self.fileNameLabel.font = UIFont.systemFont(ofSize: 24.0, weight: .regular)
            self.fileNameLabel.textAlignment = .left
            self.dateLabel.textAlignment = .left
            let titleGap: CGFloat = 16.0
            let titleLeft = max(16.0, previewFrame.maxX + titleGap)
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
        self.listButton.isHidden = self.isFocusMode
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

        if canPlay && !expandedChrome {
            self.block2ProgressTrack.isHidden = false
            let progressHeight: CGFloat = 3.0
            let progressY = min(innerHeight - progressHeight - 4.0, previewFrame.maxY + 4.0)
            self.block2ProgressTrack.frame = CGRect(
                x: previewFrame.minX,
                y: progressY,
                width: previewFrame.width,
                height: progressHeight
            )
            self.block2ProgressTrack.layer.cornerRadius = progressHeight / 2.0
            self.block2ProgressFill.layer.cornerRadius = progressHeight / 2.0
            self.updateBlock2Progress(self.expandStatusValue ?? MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: .zero, timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: !self.isMuted))
        } else {
            self.block2ProgressTrack.isHidden = true
            self.block2ProgressFill.frame = .zero
        }

        let scrubberVisible = expandedChrome && canPlay
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

        let countSize = (self.participantsCountLabel.text ?? "").size(withAttributes: [.font: self.participantsCountLabel.font as Any])
        let countWidth = ceil(countSize.width)
        let statusBaseY = scrubberVisible ? self.expandScrubbingNode.view.frame.minY : iconsY
        let statusY = statusBaseY - 34.0
        let countX = iconsRight - countWidth
        self.participantsCountLabel.frame = CGRect(x: countX, y: statusY, width: countWidth, height: ceil(countSize.height))

        if canPlay && !expandedChrome {
            self.participantsCountLabel.isHidden = true
            self.block3TimeLabel.isHidden = false
            let timeText = self.block3TimeLabel.text ?? ""
            let timeAttrs: [NSAttributedString.Key: Any] = [.font: self.block3TimeLabel.font as Any]
            let timeSize = (timeText as NSString).size(withAttributes: timeAttrs)
            let timeWidth = max(106.0, ceil(timeSize.width) + 4.0)
            let timeHeight = ceil(timeSize.height)
            self.block3TimeLabel.frame = CGRect(x: iconsRight - timeWidth, y: statusY, width: timeWidth, height: timeHeight)

            self.fitScrubbingNode.isHidden = false
            let scrubberHeight: CGFloat = 22.0
            let scrubberRight = self.block3TimeLabel.frame.minX - 10.0
            let scrubberY = statusY + (timeHeight - scrubberHeight) / 2.0
            self.fitScrubbingNode.view.frame = CGRect(x: leftInset, y: scrubberY, width: max(40.0, scrubberRight - leftInset), height: scrubberHeight)
        } else {
            self.participantsCountLabel.isHidden = countWidth <= 0.0
            self.block3TimeLabel.isHidden = true
            self.fitScrubbingNode.isHidden = true
        }
    }
}
