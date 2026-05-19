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

public final class VideoMediaPreviewProvider: MediaPreviewProvider {
    public let identifier = "video"

    public init() {}

    public func canHandle(item: MediaBrowserItem) -> Bool {
        for media in item.message.media {
            if let file = media as? TelegramMediaFile, file.isVideo {
                return true
            }
        }
        return false
    }

    public func makePreviewNode(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) -> MediaPreviewNode {
        return VideoPreviewNode(item: item, context: context, presentationData: presentationData)
    }
}

final class VideoPreviewNode: ASDisplayNode, MediaPreviewNode {
    private let context: AccountContext
    private let item: MediaBrowserItem

    private let thumbnailView: UIImageView
    private var thumbnailDisposable = MetaDisposable()
    private var videoNode: UniversalVideoNode?
    private var statusDisposable = MetaDisposable()
    private var isMuted: Bool = false
    private var lastSize: CGSize = .zero
    private(set) var naturalAspectRatio: CGFloat?

    private let statusPromise = Promise<MediaPlayerStatus>(MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: .zero, timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true))
    private let bufferingPromise = Promise<(RangeSet<Int64>, Int64)?>(nil)

    var playbackStatus: Signal<MediaPlayerStatus, NoError>? { return self.statusPromise.get() }
    var bufferingStatus: Signal<(RangeSet<Int64>, Int64)?, NoError>? { return self.bufferingPromise.get() }

    var statusUpdated: ((MediaPreviewPlaybackStatus) -> Void)?
    var aspectRatioUpdated: ((CGFloat) -> Void)?

    var canPlay: Bool { return true }

    var displayNode: ASDisplayNode { return self }

    init(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) {
        self.context = context
        self.item = item

        self.thumbnailView = UIImageView()
        self.thumbnailView.contentMode = .scaleAspectFit
        self.thumbnailView.clipsToBounds = true
        self.thumbnailView.layer.cornerRadius = 10.0

        super.init()

        self.clipsToBounds = true
        self.cornerRadius = 10.0
    }

    override func didLoad() {
        super.didLoad()
        self.view.addSubview(self.thumbnailView)
        self.publishAspectRatio()
        self.loadThumbnail()
    }

    private func publishAspectRatio() {
        if let file = self.file(), let dims = file.dimensions, dims.width > 0 && dims.height > 0 {
            let ratio = CGFloat(dims.width) / CGFloat(dims.height)
            self.naturalAspectRatio = ratio
            self.aspectRatioUpdated?(ratio)
        }
    }

    deinit {
        self.thumbnailDisposable.dispose()
        self.statusDisposable.dispose()
        self.videoNode?.pause()
    }

    private func file() -> TelegramMediaFile? {
        for media in self.item.message.media {
            if let file = media as? TelegramMediaFile, file.isVideo {
                return file
            }
        }
        return nil
    }

    private func loadThumbnail() {
        guard let file = self.file(), let representation = file.previewRepresentations.last else { return }
        let signal = self.context.account.postbox.mediaBox.resourceData(representation.resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: false)
            |> deliverOnMainQueue
        self.thumbnailDisposable.set(signal.startStrict(next: { [weak self] data in
            guard let self = self else { return }
            if data.complete, let uiImage = UIImage(contentsOfFile: data.path) {
                self.thumbnailView.image = uiImage
            }
        }))
    }

    func play() {
        if self.videoNode == nil {
            self.attachVideoNode()
        }
        self.videoNode?.play()
    }

    func pause() {
        self.videoNode?.pause()
    }

    func togglePlayPause() {
        if self.videoNode == nil {
            self.attachVideoNode()
        }
        self.videoNode?.togglePlayPause()
    }

    func setSoundMuted(_ muted: Bool) {
        self.isMuted = muted
        self.videoNode?.setSoundMuted(soundMuted: muted)
    }

    func seek(to timestamp: Double) {
        self.videoNode?.seek(timestamp)
    }

    private func attachVideoNode() {
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
        videoNode.frame = self.bounds
        videoNode.canAttachContent = true
        videoNode.updateLayout(size: self.bounds.size, transition: .immediate)

        self.view.insertSubview(videoNode.view, aboveSubview: self.thumbnailView)
        self.videoNode = videoNode

        self.statusPromise.set(videoNode.status |> map { $0 ?? MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: .zero, timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true) })
        self.bufferingPromise.set(videoNode.bufferingStatus)

        self.statusDisposable.set((videoNode.status
        |> deliverOnMainQueue).startStrict(next: { [weak self] status in
            guard let self = self, let status = status else { return }
            switch status.status {
            case .playing:
                self.statusUpdated?(.playing)
            case .paused:
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

        self.statusUpdated?(.loading)
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.lastSize = size
        self.thumbnailView.frame = CGRect(origin: .zero, size: size)
        if let videoNode = self.videoNode {
            let fitted = self.fittedSize(in: size)
            let origin = CGPoint(x: floor((size.width - fitted.width) / 2.0), y: floor((size.height - fitted.height) / 2.0))
            videoNode.frame = CGRect(origin: origin, size: fitted)
            videoNode.updateLayout(size: fitted, transition: transition)
        }
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        guard let ratio = self.naturalAspectRatio, ratio > 0, container.width > 0, container.height > 0 else {
            return container
        }
        let containerAspect = container.width / container.height
        if ratio > containerAspect {
            return CGSize(width: container.width, height: floor(container.width / ratio))
        } else {
            return CGSize(width: floor(container.height * ratio), height: container.height)
        }
    }

    func detach() {
        self.videoNode?.pause()
    }
}
