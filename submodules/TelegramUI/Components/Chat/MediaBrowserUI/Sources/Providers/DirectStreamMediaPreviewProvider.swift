import Foundation
import UIKit
import AVFoundation
import Display
import AsyncDisplayKit
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import UniversalMediaPlayer
import RangeSet

public final class DirectStreamMediaPreviewProvider: MediaPreviewProvider {
    public let identifier = "direct-stream"

    public init() {}

    public func canHandle(item: MediaBrowserItem) -> Bool {
        if case .directStream = item.playableSource {
            return true
        }
        return false
    }

    public func makePreviewNode(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) -> MediaPreviewNode {
        return DirectStreamPreviewNode(item: item, presentationData: presentationData)
    }
}

private final class DirectStreamPlayerView: UIView {
    override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        return self.layer as! AVPlayerLayer
    }
}

final class DirectStreamPreviewNode: ASDisplayNode, MediaPreviewNode {
    private let item: MediaBrowserItem
    private var presentationData: PresentationData
    private let player: AVPlayer
    private let playerItem: AVPlayerItem
    private let playerView: DirectStreamPlayerView
    private let placeholderLabel: UILabel
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var didPlayToEndObserver: NSObjectProtocol?
    private var isMuted: Bool = false

    private let statusPromise = Promise<MediaPlayerStatus>(MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: .zero, timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true))

    var statusUpdated: ((MediaPreviewPlaybackStatus) -> Void)?
    var aspectRatioUpdated: ((CGFloat) -> Void)?

    var naturalAspectRatio: CGFloat? {
        return 16.0 / 9.0
    }

    var canPlay: Bool {
        return true
    }

    var playbackStatus: Signal<MediaPlayerStatus, NoError>? {
        return self.statusPromise.get()
    }

    var bufferingStatus: Signal<(RangeSet<Int64>, Int64)?, NoError>? {
        return nil
    }

    var displayNode: ASDisplayNode {
        return self
    }

    init(item: MediaBrowserItem, presentationData: PresentationData) {
        self.item = item
        self.presentationData = presentationData

        let url: URL
        if case let .directStream(streamUrl) = item.playableSource {
            url = streamUrl
        } else {
            url = URL(string: "https://example.com")!
        }
        self.playerItem = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: self.playerItem)
        self.playerView = DirectStreamPlayerView()
        self.placeholderLabel = UILabel()
        self.placeholderLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
        self.placeholderLabel.textAlignment = .center
        self.placeholderLabel.numberOfLines = 2

        super.init()

        self.clipsToBounds = true
        self.cornerRadius = 10.0
        self.aspectRatioUpdated?(16.0 / 9.0)
        self.applyTheme()
    }

    override func didLoad() {
        super.didLoad()

        self.view.addSubview(self.playerView)
        self.view.addSubview(self.placeholderLabel)
        self.playerView.playerLayer.player = self.player
        self.playerView.playerLayer.videoGravity = .resizeAspect

        self.statusObservation = self.playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Queue.mainQueue().async {
                self?.handlePlayerItemStatus(item.status)
            }
        }
        self.timeControlObservation = self.player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Queue.mainQueue().async {
                self?.publishStatus(playbackStatus: self?.playbackStatus(for: player.timeControlStatus))
            }
        }
        self.timeObserver = self.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.35, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.publishStatus(playbackStatus: nil)
        }
        self.didPlayToEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: self.playerItem, queue: .main) { [weak self] _ in
            guard let self = self else {
                return
            }
            self.publishStatus(playbackStatus: .paused)
            self.statusUpdated?(.ended)
        }
    }

    deinit {
        if let timeObserver = self.timeObserver {
            self.player.removeTimeObserver(timeObserver)
        }
        if let observer = self.didPlayToEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        self.player.pause()
    }

    func play() {
        self.player.play()
        self.statusUpdated?(.loading)
    }

    func pause() {
        self.player.pause()
    }

    func togglePlayPause() {
        if self.player.rate.isZero {
            self.play()
        } else {
            self.pause()
        }
    }

    func seek(to timestamp: Double) {
        guard timestamp.isFinite else {
            return
        }
        self.player.seek(to: CMTime(seconds: max(0.0, timestamp), preferredTimescale: 600))
    }

    func setSoundMuted(_ muted: Bool) {
        self.isMuted = muted
        self.player.isMuted = muted
        self.publishStatus(playbackStatus: nil)
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.applyTheme()
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.playerView.frame = CGRect(origin: .zero, size: size)
        self.placeholderLabel.frame = CGRect(x: 12.0, y: floor((size.height - 44.0) / 2.0), width: max(0.0, size.width - 24.0), height: 44.0)
    }

    func detach() {
        self.player.pause()
    }

    private func applyTheme() {
        self.backgroundColor = .black
        self.placeholderLabel.textColor = .white.withAlphaComponent(0.7)
        self.placeholderLabel.text = "Загрузка потока"
    }

    private func handlePlayerItemStatus(_ status: AVPlayerItem.Status) {
        switch status {
        case .unknown:
            self.placeholderLabel.isHidden = false
            self.statusUpdated?(.loading)
        case .readyToPlay:
            self.placeholderLabel.isHidden = true
            self.publishStatus(playbackStatus: self.playbackStatus(for: self.player.timeControlStatus))
        case .failed:
            self.placeholderLabel.isHidden = false
            self.placeholderLabel.text = "Не удалось открыть поток"
            self.statusUpdated?(.error("Не удалось открыть поток"))
            self.publishStatus(playbackStatus: .paused)
        @unknown default:
            self.placeholderLabel.isHidden = false
            self.placeholderLabel.text = "Поток не поддерживается"
            self.statusUpdated?(.error("Поток не поддерживается"))
            self.publishStatus(playbackStatus: .paused)
        }
    }

    private func playbackStatus(for timeControlStatus: AVPlayer.TimeControlStatus) -> MediaPlayerPlaybackStatus {
        switch timeControlStatus {
        case .playing:
            return .playing
        case .waitingToPlayAtSpecifiedRate:
            return .buffering(initial: false, whilePlaying: true, progress: 0.0, display: true)
        case .paused:
            return .paused
        @unknown default:
            return .paused
        }
    }

    private func publishStatus(playbackStatus explicitStatus: MediaPlayerPlaybackStatus?) {
        let durationSeconds = self.seconds(self.playerItem.duration)
        let timestamp = self.seconds(self.player.currentTime())
        let status = explicitStatus ?? self.playbackStatus(for: self.player.timeControlStatus)
        let mediaStatus = MediaPlayerStatus(
            generationTimestamp: CACurrentMediaTime(),
            duration: durationSeconds,
            dimensions: CGSize(width: 16.0, height: 9.0),
            timestamp: timestamp,
            baseRate: 1.0,
            seekId: 0,
            status: status,
            soundEnabled: !self.isMuted
        )
        self.statusPromise.set(.single(mediaStatus))

        switch status {
        case .playing:
            self.statusUpdated?(.playing)
        case .paused:
            self.statusUpdated?(.paused)
        case .buffering:
            self.statusUpdated?(.loading)
        }
    }

    private func seconds(_ time: CMTime) -> Double {
        let seconds = CMTimeGetSeconds(time)
        if seconds.isFinite && !seconds.isNaN {
            return max(0.0, seconds)
        }
        return 0.0
    }
}
