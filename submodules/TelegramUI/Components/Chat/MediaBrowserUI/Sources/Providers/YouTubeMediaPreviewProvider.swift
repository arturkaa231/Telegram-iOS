import Foundation
import UIKit
import WebKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import TelegramUniversalVideoContent
import GalleryUI
import UniversalMediaPlayer
import RangeSet

public final class YouTubeMediaPreviewProvider: MediaPreviewProvider {
    public let identifier = "youtube"

    public init() {}

    public func canHandle(item: MediaBrowserItem) -> Bool {
        if case .youtube = item.playableSource {
            return true
        }
        return false
    }

    public func makePreviewNode(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) -> MediaPreviewNode {
        if let node = TelegramWebEmbedPreviewNode(item: item, context: context) {
            return node
        }
        return YouTubePreviewNode(item: item, context: context, presentationData: presentationData)
    }
}

final class TelegramWebEmbedPreviewNode: ASDisplayNode, MediaPreviewNode {
    private let item: MediaBrowserItem
    private let context: AccountContext
    private let content: WebEmbedVideoContent
    private var videoNode: UniversalVideoNode?
    private var statusDisposable = MetaDisposable()
    private let statusPromise = Promise<MediaPlayerStatus>(MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: .zero, timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true))
    private let bufferingPromise = Promise<(RangeSet<Int64>, Int64)?>(nil)
    private var isMuted: Bool = false

    var statusUpdated: ((MediaPreviewPlaybackStatus) -> Void)?
    var aspectRatioUpdated: ((CGFloat) -> Void)?

    var naturalAspectRatio: CGFloat? {
        let size = self.content.dimensions
        if size.width > 0.0 && size.height > 0.0 {
            return size.width / size.height
        }
        return 16.0 / 9.0
    }

    var canPlay: Bool {
        return true
    }

    var playbackStatus: Signal<MediaPlayerStatus, NoError>? {
        return self.statusPromise.get()
    }

    var bufferingStatus: Signal<(RangeSet<Int64>, Int64)?, NoError>? {
        return self.bufferingPromise.get()
    }

    var displayNode: ASDisplayNode {
        return self
    }

    init?(item: MediaBrowserItem, context: AccountContext) {
        guard let webpage = item.message.media.compactMap({ $0 as? TelegramMediaWebpage }).first,
              case let .Loaded(webpageContent) = webpage.content,
              let content = WebEmbedVideoContent(
                userLocation: .peer(item.message.id.peerId),
                webPage: webpage,
                webpageContent: webpageContent,
                forcedTimestamp: Self.forcedTimestamp(from: item),
                openUrl: { url in
                    context.sharedContext.applicationBindings.openUrl(url.absoluteString)
                }
              ) else {
            return nil
        }
        self.item = item
        self.context = context
        self.content = content

        super.init()

        self.clipsToBounds = true
        self.cornerRadius = 10.0
        if let aspectRatio = self.naturalAspectRatio {
            self.aspectRatioUpdated?(aspectRatio)
        }
    }

    deinit {
        self.statusDisposable.dispose()
        self.videoNode?.pause()
    }

    override func didLoad() {
        super.didLoad()
        self.attachVideoNode()
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

    func seek(to timestamp: Double) {
        self.videoNode?.seek(timestamp)
    }

    func setSoundMuted(_ muted: Bool) {
        self.isMuted = muted
        self.videoNode?.setSoundMuted(soundMuted: muted)
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        if let videoNode = self.videoNode {
            videoNode.frame = CGRect(origin: .zero, size: size)
            videoNode.updateLayout(size: size, transition: transition)
        }
    }

    func detach() {
        self.videoNode?.pause()
    }

    private func attachVideoNode() {
        guard self.videoNode == nil else {
            return
        }
        let mediaManager = self.context.sharedContext.mediaManager
        let videoNode = UniversalVideoNode(
            context: self.context,
            postbox: self.context.account.postbox,
            audioSession: mediaManager.audioSession,
            manager: mediaManager.universalVideoManager,
            decoration: GalleryVideoDecoration(),
            content: self.content,
            priority: .embedded,
            autoplay: false
        )
        videoNode.isUserInteractionEnabled = true
        videoNode.frame = self.bounds
        videoNode.canAttachContent = true
        videoNode.updateLayout(size: self.bounds.size, transition: .immediate)
        videoNode.setSoundMuted(soundMuted: self.isMuted)

        self.addSubnode(videoNode)
        self.videoNode = videoNode
        self.statusPromise.set(videoNode.status |> map { $0 ?? MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: .zero, timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true) })
        self.bufferingPromise.set(videoNode.bufferingStatus)
        self.statusDisposable.set((videoNode.status
        |> deliverOnMainQueue).startStrict(next: { [weak self] status in
            guard let self = self, let status = status else {
                return
            }
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
                self?.statusUpdated?(.ended)
            }
        }
    }

    private static func forcedTimestamp(from item: MediaBrowserItem) -> Int? {
        guard case let .youtube(_, url) = item.playableSource,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "t" })?.value else {
            return nil
        }
        if let seconds = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) {
            return seconds
        }
        return nil
    }
}

final class YouTubePreviewNode: ASDisplayNode, MediaPreviewNode, WKScriptMessageHandler, WKNavigationDelegate {
    private let item: MediaBrowserItem
    private let context: AccountContext
    private var presentationData: PresentationData
    private let webView: WKWebView
    private let statusLabel: UILabel
    private let openExternallyButton: UIButton
    private let statusPromise = Promise<MediaPlayerStatus>(MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: .zero, timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true))
    private var lastDuration: Double = 0.0
    private var lastTimestamp: Double = 0.0
    private var currentPlaybackStatus: MediaPlayerPlaybackStatus = .paused
    private var isMuted: Bool = false

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

    init(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) {
        self.item = item
        self.context = context
        self.presentationData = presentationData

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        if #available(iOS 10.0, *) {
            configuration.mediaTypesRequiringUserActionForPlayback = []
        }
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.statusLabel = UILabel()
        self.statusLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
        self.statusLabel.textAlignment = .center
        self.statusLabel.numberOfLines = 2
        self.openExternallyButton = UIButton(type: .system)
        self.openExternallyButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
        self.openExternallyButton.setTitle("Открыть на YouTube", for: .normal)
        self.openExternallyButton.layer.cornerRadius = 14.0
        self.openExternallyButton.contentEdgeInsets = UIEdgeInsets(top: 6.0, left: 12.0, bottom: 6.0, right: 12.0)
        self.openExternallyButton.isHidden = true

        super.init()

        configuration.userContentController.add(WeakScriptMessageHandler(target: self), name: "multigramYouTube")

        self.clipsToBounds = true
        self.cornerRadius = 10.0
        self.aspectRatioUpdated?(16.0 / 9.0)
        self.applyTheme()
    }

    override func didLoad() {
        super.didLoad()

        self.webView.navigationDelegate = self
        self.webView.scrollView.isScrollEnabled = false
        self.webView.isOpaque = false
        self.webView.backgroundColor = .black
        self.view.addSubview(self.webView)
        self.view.addSubview(self.statusLabel)
        self.view.addSubview(self.openExternallyButton)
        self.openExternallyButton.addTarget(self, action: #selector(self.openExternallyPressed), for: .touchUpInside)
        self.loadPlayer()
    }

    deinit {
        self.webView.configuration.userContentController.removeScriptMessageHandler(forName: "multigramYouTube")
        self.webView.stopLoading()
    }

    func play() {
        self.evaluate("if (window.player && player.playVideo) { player.playVideo(); }")
    }

    func pause() {
        self.evaluate("if (window.player && player.pauseVideo) { player.pauseVideo(); }")
    }

    func togglePlayPause() {
        self.evaluate("""
        if (window.player && player.getPlayerState) {
          var state = player.getPlayerState();
          if (state === 1) { player.pauseVideo(); } else { player.playVideo(); }
        }
        """)
    }

    func seek(to timestamp: Double) {
        guard timestamp.isFinite else {
            return
        }
        self.evaluate("if (window.player && player.seekTo) { player.seekTo(\(max(0.0, timestamp)), true); }")
    }

    func setSoundMuted(_ muted: Bool) {
        self.isMuted = muted
        self.evaluate(muted ? "if (window.player && player.mute) { player.mute(); }" : "if (window.player && player.unMute) { player.unMute(); }")
        self.publishStatus(nil)
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.applyTheme()
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.webView.frame = CGRect(origin: .zero, size: size)
        let labelHeight: CGFloat = 44.0
        let buttonSize = self.openExternallyButton.sizeThatFits(CGSize(width: max(0.0, size.width - 32.0), height: 32.0))
        let buttonHeight: CGFloat = 32.0
        let totalHeight = labelHeight + (self.openExternallyButton.isHidden ? 0.0 : buttonHeight + 8.0)
        let top = floor((size.height - totalHeight) / 2.0)
        self.statusLabel.frame = CGRect(x: 12.0, y: top, width: max(0.0, size.width - 24.0), height: labelHeight)
        self.openExternallyButton.frame = CGRect(
            x: floor((size.width - min(size.width - 32.0, buttonSize.width + 24.0)) / 2.0),
            y: self.statusLabel.frame.maxY + 8.0,
            width: min(size.width - 32.0, buttonSize.width + 24.0),
            height: buttonHeight
        )
    }

    func detach() {
        self.pause()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "multigramYouTube" else {
            return
        }
        if let body = message.body as? [String: Any] {
            self.handleBridgeMessage(body)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !Self.isIgnorableNavigationError(error) else {
            return
        }
        self.showError()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !Self.isIgnorableNavigationError(error) else {
            return
        }
        self.showError()
    }

    private func loadPlayer() {
        guard case let .youtube(videoId, _) = self.item.playableSource else {
            self.showError()
            return
        }
        self.statusLabel.text = "Загрузка YouTube"
        self.statusLabel.isHidden = false
        self.openExternallyButton.isHidden = true
        self.statusUpdated?(.loading)
        self.webView.loadHTMLString(Self.html(videoId: videoId), baseURL: URL(string: "https://www.youtube.com"))
    }

    private func handleBridgeMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else {
            return
        }
        switch type {
        case "ready":
            self.statusLabel.isHidden = true
            self.openExternallyButton.isHidden = true
            self.publishStatus(.paused)
            self.statusUpdated?(.paused)
        case "state":
            let state = body["state"] as? Int ?? 0
            switch state {
            case 1:
                self.publishStatus(.playing)
                self.statusUpdated?(.playing)
            case 2, 5:
                self.publishStatus(.paused)
                self.statusUpdated?(.paused)
            case 0:
                self.publishStatus(.paused)
                self.statusUpdated?(.ended)
            case 3:
                self.publishStatus(.buffering(initial: false, whilePlaying: true, progress: 0.0, display: true))
                self.statusUpdated?(.loading)
            default:
                break
            }
        case "time":
            self.lastTimestamp = body["currentTime"] as? Double ?? self.lastTimestamp
            self.lastDuration = body["duration"] as? Double ?? self.lastDuration
            self.publishStatus(nil)
        case "error":
            self.showError()
        default:
            break
        }
    }

    private func publishStatus(_ explicitStatus: MediaPlayerPlaybackStatus?) {
        if let explicitStatus = explicitStatus {
            self.currentPlaybackStatus = explicitStatus
        }
        let status = self.currentPlaybackStatus
        self.statusPromise.set(.single(MediaPlayerStatus(
            generationTimestamp: CACurrentMediaTime(),
            duration: max(0.0, self.lastDuration),
            dimensions: CGSize(width: 16.0, height: 9.0),
            timestamp: max(0.0, self.lastTimestamp),
            baseRate: 1.0,
            seekId: 0,
            status: status,
            soundEnabled: !self.isMuted
        )))
    }

    private func showError() {
        self.statusLabel.text = "YouTube недоступен"
        self.statusLabel.isHidden = false
        self.openExternallyButton.isHidden = false
        if self.bounds.width > 0 && self.bounds.height > 0 {
            self.updateLayout(size: self.bounds.size, transition: .immediate)
        }
        self.statusUpdated?(.error("YouTube недоступен"))
        self.publishStatus(.paused)
    }

    private func applyTheme() {
        self.backgroundColor = .black
        self.statusLabel.textColor = .white.withAlphaComponent(0.75)
        self.openExternallyButton.tintColor = .white
        self.openExternallyButton.backgroundColor = UIColor(rgb: 0xFF383C)
    }

    @objc private func openExternallyPressed() {
        guard case let .youtube(_, url) = self.item.playableSource else {
            return
        }
        self.context.sharedContext.applicationBindings.openUrl(url.absoluteString)
    }

    private func evaluate(_ script: String) {
        self.webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private static func html(videoId: String) -> String {
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <style>
            html, body, #player { margin: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
          </style>
        </head>
        <body>
          <div id="player"></div>
          <script src="https://www.youtube.com/iframe_api"></script>
          <script>
            var player;
            function post(payload) {
              window.webkit.messageHandlers.multigramYouTube.postMessage(payload);
            }
            function onYouTubeIframeAPIReady() {
              player = new YT.Player('player', {
                width: '100%',
                height: '100%',
                videoId: '\(videoId)',
                playerVars: { playsinline: 1, enablejsapi: 1, rel: 0, modestbranding: 1 },
                events: {
                  onReady: function() {
                    post({ type: 'ready' });
                    setInterval(function() {
                      if (!player || !player.getCurrentTime) { return; }
                      post({ type: 'time', currentTime: player.getCurrentTime() || 0, duration: player.getDuration() || 0 });
                    }, 500);
                  },
                  onStateChange: function(event) { post({ type: 'state', state: event.data }); },
                  onError: function(event) { post({ type: 'error', code: event.data }); }
                }
              });
            }
          </script>
        </body>
        </html>
        """
    }

    private static func isIgnorableNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        return false
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        self.target?.userContentController(userContentController, didReceive: message)
    }
}
