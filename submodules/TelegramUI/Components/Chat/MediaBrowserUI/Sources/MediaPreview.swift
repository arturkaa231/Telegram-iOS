import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import UniversalMediaPlayer
import RangeSet

public enum MediaPreviewPlaybackStatus {
    case idle
    case loading
    case playing
    case paused
    case ended
    case error(String)
}

public protocol MediaPreviewNode: AnyObject {
    var displayNode: ASDisplayNode { get }
    var statusUpdated: ((MediaPreviewPlaybackStatus) -> Void)? { get set }
    var aspectRatioUpdated: ((CGFloat) -> Void)? { get set }
    var naturalAspectRatio: CGFloat? { get }
    var canPlay: Bool { get }
    var playbackStatus: Signal<MediaPlayerStatus, NoError>? { get }
    var bufferingStatus: Signal<(RangeSet<Int64>, Int64)?, NoError>? { get }
    func play()
    func pause()
    func togglePlayPause()
    func seek(to timestamp: Double)
    func setSoundMuted(_ muted: Bool)
    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition)
    func updatePresentationData(_ presentationData: PresentationData)
    func detach()
}

public extension MediaPreviewNode {
    var canPlay: Bool { return false }
    var naturalAspectRatio: CGFloat? { return nil }
    var playbackStatus: Signal<MediaPlayerStatus, NoError>? { return nil }
    var bufferingStatus: Signal<(RangeSet<Int64>, Int64)?, NoError>? { return nil }
    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func seek(to timestamp: Double) {}
    func setSoundMuted(_ muted: Bool) {}
    func updatePresentationData(_ presentationData: PresentationData) {}
    func detach() {}
}

public protocol MediaPreviewProvider: AnyObject {
    var identifier: String { get }
    func canHandle(item: MediaBrowserItem) -> Bool
    func makePreviewNode(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) -> MediaPreviewNode
}

public final class MediaPreviewProviderRegistry {
    public static let shared = MediaPreviewProviderRegistry()

    private var providers: [MediaPreviewProvider] = []
    private let fallback: MediaPreviewProvider = UnsupportedMediaPreviewProvider()

    public init() {
        self.register(YouTubeMediaPreviewProvider())
        self.register(DirectStreamMediaPreviewProvider())
        self.register(VideoMediaPreviewProvider())
        self.register(AudioMediaPreviewProvider())
        self.register(ImageMediaPreviewProvider())
        self.register(PDFMediaPreviewProvider())
    }

    public func register(_ provider: MediaPreviewProvider) {
        self.providers.removeAll { $0.identifier == provider.identifier }
        self.providers.append(provider)
    }

    public func unregister(identifier: String) {
        self.providers.removeAll { $0.identifier == identifier }
    }

    public func provider(for item: MediaBrowserItem) -> MediaPreviewProvider {
        for provider in self.providers {
            if provider.canHandle(item: item) {
                return provider
            }
        }
        return self.fallback
    }
}
