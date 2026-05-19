import Foundation
import UIKit
import Display
import AsyncDisplayKit
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import TelegramUniversalVideoContent
import GalleryUI
import UniversalMediaPlayer
import RangeSet

public final class AudioMediaPreviewProvider: MediaPreviewProvider {
    public let identifier = "audio"

    public init() {}

    public func canHandle(item: MediaBrowserItem) -> Bool {
        for media in item.message.media {
            if let file = media as? TelegramMediaFile {
                if file.isMusic || file.isVoice {
                    return true
                }
                if file.mimeType.hasPrefix("audio/") {
                    return true
                }
            }
        }
        return false
    }

    public func makePreviewNode(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) -> MediaPreviewNode {
        return AudioPreviewNode(item: item, context: context, presentationData: presentationData)
    }
}

final class AudioPreviewNode: ASDisplayNode, MediaPreviewNode {
    private let context: AccountContext
    private let item: MediaBrowserItem
    private var presentationData: PresentationData

    private let coverView: UIImageView
    private let placeholderView: UIImageView
    private let titleLabel: UILabel
    private let scrubbingNode: MediaPlayerScrubbingNode
    private let timeLabel: UILabel
    private let playButton: UIButton

    private var coverDisposable = MetaDisposable()
    private var statusDisposable = MetaDisposable()
    private var videoNode: UniversalVideoNode?

    private var isMuted: Bool = false
    private var isPlaying: Bool = false
    private var lastStatus: MediaPlayerStatus?
    private let statusPromise = Promise<MediaPlayerStatus>(MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: .zero, timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true))

    let naturalAspectRatio: CGFloat? = 1.0
    var statusUpdated: ((MediaPreviewPlaybackStatus) -> Void)?
    var aspectRatioUpdated: ((CGFloat) -> Void)?
    var canPlay: Bool { return true }
    var playbackStatus: Signal<MediaPlayerStatus, NoError>? { return self.statusPromise.get() }
    var bufferingStatus: Signal<(RangeSet<Int64>, Int64)?, NoError>? { return nil }

    func seek(to timestamp: Double) {
        self.videoNode?.seek(timestamp)
    }

    var displayNode: ASDisplayNode { return self }

    init(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) {
        self.context = context
        self.item = item
        self.presentationData = presentationData

        self.coverView = UIImageView()
        self.coverView.contentMode = .scaleAspectFill
        self.coverView.clipsToBounds = true

        self.placeholderView = UIImageView()
        self.placeholderView.contentMode = .center
        self.placeholderView.image = UIImage(systemName: "music.note", withConfiguration: UIImage.SymbolConfiguration(pointSize: 56.0, weight: .light))

        self.titleLabel = UILabel()
        self.titleLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .medium)
        self.titleLabel.textAlignment = .center
        self.titleLabel.numberOfLines = 1
        self.titleLabel.lineBreakMode = .byTruncatingTail

        self.scrubbingNode = MediaPlayerScrubbingNode(content: .standard(
            lineHeight: 3.0,
            lineCap: .round,
            scrubberHandle: .line,
            backgroundColor: .white.withAlphaComponent(0.3),
            foregroundColor: .white,
            bufferingColor: .white.withAlphaComponent(0.5),
            chapters: []
        ))

        self.timeLabel = UILabel()
        self.timeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .regular)
        self.timeLabel.textAlignment = .center
        self.timeLabel.text = "0:00 / 0:00"

        self.playButton = UIButton(type: .custom)
        self.playButton.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 56.0, weight: .regular)), for: .normal)

        super.init()

        self.clipsToBounds = true
        self.cornerRadius = 10.0

        self.applyTheme()
        self.populateTitle()
    }

    override func didLoad() {
        super.didLoad()
        self.view.addSubview(self.coverView)
        self.view.addSubview(self.placeholderView)
        self.view.addSubview(self.titleLabel)
        self.view.addSubview(self.scrubbingNode.view)
        self.view.addSubview(self.timeLabel)
        self.view.addSubview(self.playButton)

        self.playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)

        self.scrubbingNode.status = self.statusPromise.get()
        self.scrubbingNode.seek = { [weak self] timestamp in
            self?.videoNode?.seek(timestamp)
        }

        self.loadCover()
    }

    deinit {
        self.coverDisposable.dispose()
        self.statusDisposable.dispose()
        self.videoNode?.pause()
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.applyTheme()
    }

    private func applyTheme() {
        let theme = self.presentationData.theme
        let primary = theme.list.itemPrimaryTextColor
        let isDark = theme.overallDarkAppearance
        self.backgroundColor = isDark ? UIColor(white: 0.13, alpha: 1.0) : UIColor(white: 0.93, alpha: 1.0)
        self.placeholderView.tintColor = primary.withAlphaComponent(0.6)
        self.titleLabel.textColor = primary
        self.timeLabel.textColor = primary.withAlphaComponent(0.7)
        self.playButton.tintColor = primary
    }

    private func file() -> TelegramMediaFile? {
        for media in self.item.message.media {
            if let file = media as? TelegramMediaFile, file.isMusic || file.isVoice || file.mimeType.hasPrefix("audio/") {
                return file
            }
        }
        return nil
    }

    private func populateTitle() {
        guard let file = self.file() else {
            self.titleLabel.text = self.item.fileName
            return
        }
        for attribute in file.attributes {
            if case let .Audio(_, _, title, performer, _) = attribute {
                let t = title ?? self.item.fileName
                if let performer = performer, !performer.isEmpty {
                    self.titleLabel.text = "\(t) — \(performer)"
                } else {
                    self.titleLabel.text = t
                }
                return
            }
        }
        self.titleLabel.text = self.item.fileName
    }

    private func loadCover() {
        guard let file = self.file(), let representation = file.previewRepresentations.last else {
            self.placeholderView.isHidden = false
            return
        }
        self.placeholderView.isHidden = false
        let signal = self.context.account.postbox.mediaBox.resourceData(representation.resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: false)
            |> deliverOnMainQueue
        self.coverDisposable.set(signal.startStrict(next: { [weak self] data in
            guard let self = self else { return }
            if data.complete, let uiImage = UIImage(contentsOfFile: data.path) {
                self.coverView.image = uiImage
                self.placeholderView.isHidden = true
            }
        }))
    }

    func play() {
        if self.videoNode == nil {
            self.attach()
        }
        self.videoNode?.play()
    }

    func pause() {
        self.videoNode?.pause()
    }

    func togglePlayPause() {
        if self.videoNode == nil {
            self.attach()
        }
        self.videoNode?.togglePlayPause()
    }

    func setSoundMuted(_ muted: Bool) {
        self.isMuted = muted
        self.videoNode?.setSoundMuted(soundMuted: muted)
    }

    private func attach() {
        guard let file = self.file(), let fileId = file.id else { return }
        let message = self.item.message
        let mediaManager = self.context.sharedContext.mediaManager

        let content = NativeVideoContent(
            id: .message(UInt32(clamping: message.stableId), fileId),
            userLocation: .peer(message.id.peerId),
            fileReference: .message(message: MessageReference(message), media: file),
            streamVideo: .conservative,
            loopVideo: false,
            enableSound: true,
            soundMuted: self.isMuted,
            fetchAutomatically: true,
            placeholderColor: .clear,
            storeAfterDownload: nil
        )

        let videoNode = UniversalVideoNode(
            context: self.context,
            postbox: self.context.account.postbox,
            audioSession: mediaManager.audioSession,
            manager: mediaManager.universalVideoManager,
            decoration: GalleryVideoDecoration(),
            content: content,
            priority: .embedded,
            autoplay: false
        )
        videoNode.isUserInteractionEnabled = false
        videoNode.canAttachContent = true
        videoNode.isHidden = true
        self.view.addSubview(videoNode.view)
        self.videoNode = videoNode

        self.statusDisposable.set((videoNode.status
        |> deliverOnMainQueue).startStrict(next: { [weak self] status in
            guard let self = self, let status = status else { return }
            self.lastStatus = status
            self.statusPromise.set(.single(status))
            self.updateTimeLabel(status)
            switch status.status {
            case .playing:
                self.isPlaying = true
                self.refreshPlayButton()
                self.statusUpdated?(.playing)
            case .paused:
                self.isPlaying = false
                self.refreshPlayButton()
                self.statusUpdated?(.paused)
            case .buffering:
                self.statusUpdated?(.loading)
            }
        }))

        videoNode.playbackCompleted = { [weak self] in
            Queue.mainQueue().async {
                guard let self = self else { return }
                self.videoNode?.seek(0.0)
                self.videoNode?.pause()
                self.statusUpdated?(.ended)
            }
        }
    }

    private func updateTimeLabel(_ status: MediaPlayerStatus) {
        func fmt(_ seconds: Double) -> String {
            let total = Int(max(0.0, seconds.rounded()))
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        self.timeLabel.text = "\(fmt(status.timestamp)) / \(fmt(status.duration))"
    }

    @objc private func playTapped() {
        if self.isPlaying {
            self.pause()
        } else {
            self.play()
        }
    }

    private func refreshPlayButton() {
        let name = self.isPlaying ? "pause.circle.fill" : "play.circle.fill"
        self.playButton.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 56.0, weight: .regular)), for: .normal)
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        let frame = CGRect(origin: .zero, size: size)
        self.coverView.frame = frame
        self.placeholderView.frame = frame

        let playSize: CGFloat = 56.0
        self.playButton.frame = CGRect(x: (size.width - playSize) / 2.0, y: (size.height - playSize) / 2.0 - 18.0, width: playSize, height: playSize)

        let titleHeight: CGFloat = 18.0
        let scrubberHeight: CGFloat = 15.0
        let timeHeight: CGFloat = 14.0
        let bottomMargin: CGFloat = 12.0
        let timeY = size.height - bottomMargin - timeHeight
        let scrubberY = timeY - 4.0 - scrubberHeight
        let titleY = scrubberY - 4.0 - titleHeight
        self.titleLabel.frame = CGRect(x: 8.0, y: titleY, width: size.width - 16.0, height: titleHeight)
        self.scrubbingNode.view.frame = CGRect(x: 16.0, y: scrubberY, width: size.width - 32.0, height: scrubberHeight)
        self.timeLabel.frame = CGRect(x: 8.0, y: timeY, width: size.width - 16.0, height: timeHeight)

        self.videoNode?.frame = .zero
    }
}
