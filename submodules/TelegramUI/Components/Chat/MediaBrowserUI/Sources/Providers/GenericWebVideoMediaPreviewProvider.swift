import Foundation
import UIKit
import WebKit
import AVFoundation
import Display
import AsyncDisplayKit
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import UniversalMediaPlayer
import RangeSet

public final class GenericWebVideoMediaPreviewProvider: MediaPreviewProvider {
    public let identifier = "generic-web-video"

    public init() {}

    public func canHandle(item: MediaBrowserItem) -> Bool {
        if case .unsupportedUrl = item.playableSource {
            return true
        }
        return false
    }

    public func makePreviewNode(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) -> MediaPreviewNode {
        return GenericWebVideoPreviewNode(item: item, context: context, presentationData: presentationData)
    }
}

private final class GenericWebVideoPlayerView: UIView {
    override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        return self.layer as! AVPlayerLayer
    }
}

final class GenericWebVideoPreviewNode: ASDisplayNode, MediaPreviewNode, WKScriptMessageHandler, WKNavigationDelegate {
    private static let minimumPlayableDuration: Double = 1.0
    private static let minimumDurationDelta: Double = 0.05

    private let item: MediaBrowserItem
    private let context: AccountContext
    private var presentationData: PresentationData
    private let webView: WKWebView
    private let playerView: GenericWebVideoPlayerView
    private let statusLabel: UILabel
    private let openExternallyButton: UIButton
    private let statusPromise = Promise<MediaPlayerStatus>(MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: .zero, timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true))
    private var streamPlayer: AVPlayer?
    private var streamPlayerItem: AVPlayerItem?
    private var streamStatusObservation: NSKeyValueObservation?
    private var streamTimeControlObservation: NSKeyValueObservation?
    private var streamTimeObserver: Any?
    private var streamDidPlayToEndObserver: NSObjectProtocol?
    private var activeStreamUrl: URL?
    private var pendingStreamPlayback: Bool = false
    private var lastDuration: Double = 0.0
    private var lastTimestamp: Double = 0.0
    private var currentPlaybackStatus: MediaPlayerPlaybackStatus = .paused
    private var lastPublishedDuration: Double = -1.0
    private var lastPublishedTimestamp: Double = -1.0
    private var lastPublishedPlaybackStatus: MediaPlayerPlaybackStatus?
    private var lastPublishedSoundEnabled: Bool?
    private var isMuted: Bool = false
    private var hasPlayableVideo: Bool = false

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
        configuration.userContentController.addUserScript(WKUserScript(source: Self.bridgeScript(), injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.playerView = GenericWebVideoPlayerView()
        self.statusLabel = UILabel()
        self.statusLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
        self.statusLabel.textAlignment = .center
        self.statusLabel.numberOfLines = 2
        self.openExternallyButton = UIButton(type: .system)
        self.openExternallyButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
        self.openExternallyButton.setTitle("Открыть снаружи", for: .normal)
        self.openExternallyButton.layer.cornerRadius = 14.0
        self.openExternallyButton.contentEdgeInsets = UIEdgeInsets(top: 6.0, left: 12.0, bottom: 6.0, right: 12.0)
        self.openExternallyButton.isHidden = true

        super.init()

        configuration.userContentController.add(GenericWebVideoWeakScriptMessageHandler(target: self), name: "multigramWebVideo")

        self.clipsToBounds = true
        self.cornerRadius = 10.0
        self.applyTheme()
    }

    override func didLoad() {
        super.didLoad()

        self.webView.navigationDelegate = self
        self.webView.scrollView.isScrollEnabled = false
        self.webView.isOpaque = false
        self.webView.backgroundColor = .black
        self.view.addSubview(self.webView)
        self.playerView.isHidden = true
        self.playerView.playerLayer.videoGravity = .resizeAspect
        self.view.addSubview(self.playerView)
        self.view.addSubview(self.statusLabel)
        self.view.addSubview(self.openExternallyButton)
        self.openExternallyButton.addTarget(self, action: #selector(self.openExternallyPressed), for: .touchUpInside)
        self.loadPage()
    }

    deinit {
        self.releaseStreamPlayer()
        self.webView.configuration.userContentController.removeScriptMessageHandler(forName: "multigramWebVideo")
        self.webView.stopLoading()
    }

    func play() {
        if let streamPlayer = self.streamPlayer {
            streamPlayer.play()
            self.statusUpdated?(.loading)
            return
        }
        self.pendingStreamPlayback = true
        self.evaluate(Self.videoCommand(action: "play"))
    }

    func pause() {
        if let streamPlayer = self.streamPlayer {
            self.pendingStreamPlayback = false
            streamPlayer.pause()
            return
        }
        self.pendingStreamPlayback = false
        self.evaluate(Self.videoCommand(action: "pause"))
    }

    func togglePlayPause() {
        if let streamPlayer = self.streamPlayer {
            if streamPlayer.rate.isZero {
                self.play()
            } else {
                self.pause()
            }
            return
        }
        self.pendingStreamPlayback = true
        self.evaluate(Self.videoCommand(action: "toggle"))
    }

    func seek(to timestamp: Double) {
        guard timestamp.isFinite else {
            return
        }
        if let streamPlayer = self.streamPlayer {
            streamPlayer.seek(to: CMTime(seconds: max(0.0, timestamp), preferredTimescale: 600))
            return
        }
        self.evaluate(Self.videoCommand(action: "seek", value: max(0.0, timestamp)))
    }

    func setSoundMuted(_ muted: Bool) {
        self.isMuted = muted
        self.streamPlayer?.isMuted = muted
        self.evaluate(Self.videoCommand(action: "muted", value: muted))
        self.publishStatus(nil)
        self.publishStreamStatus(playbackStatus: nil)
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.applyTheme()
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.webView.frame = CGRect(origin: .zero, size: size)
        self.playerView.frame = CGRect(origin: .zero, size: size)
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
        self.releaseStreamPlayer()
        self.pause()
        self.webView.stopLoading()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "multigramWebVideo", let body = message.body as? [String: Any] else {
            return
        }
        self.handleBridgeMessage(body)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.statusLabel.isHidden = true
        self.openExternallyButton.isHidden = true
        self.statusUpdated?(.idle)
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

    private func loadPage() {
        guard case let .unsupportedUrl(url) = self.item.playableSource else {
            self.showError()
            return
        }
        self.statusLabel.text = "Загрузка видео"
        self.statusLabel.isHidden = false
        self.openExternallyButton.isHidden = true
        self.statusUpdated?(.loading)
        self.webView.load(URLRequest(url: url))
    }

    private func handleBridgeMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else {
            return
        }
        switch type {
        case "playing":
            self.publishStatus(.playing)
            self.statusUpdated?(.playing)
        case "paused":
            self.publishStatus(.paused)
            self.statusUpdated?(.paused)
        case "waiting":
            self.publishStatus(.buffering(initial: false, whilePlaying: true, progress: 0.0, display: true))
            self.statusUpdated?(.loading)
        case "ended":
            self.publishStatus(.paused)
            self.statusUpdated?(.ended)
        case "video-found":
            self.hasPlayableVideo = true
            self.statusLabel.isHidden = true
            self.openExternallyButton.isHidden = true
        case "stream-found":
            self.handleStreamFound(body)
        case "time":
            let rawTimestamp = Self.normalizedDouble(body["currentTime"], fallback: self.lastTimestamp)
            let rawDuration = Self.normalizedDouble(body["duration"], fallback: self.lastDuration)
            let duration: Double
            if rawDuration >= Self.minimumPlayableDuration {
                duration = rawDuration
            } else if self.lastDuration >= Self.minimumPlayableDuration {
                duration = self.lastDuration
            } else {
                return
            }
            let timestamp = min(max(0.0, rawTimestamp), duration)
            let timestampChanged = abs(timestamp - self.lastTimestamp) >= Self.minimumDurationDelta
            let durationChanged = abs(duration - self.lastDuration) >= Self.minimumDurationDelta
            guard timestampChanged || durationChanged else {
                return
            }
            self.lastTimestamp = timestamp
            self.lastDuration = duration
            self.publishStatus(nil)
        case "unavailable":
            self.statusUpdated?(.error("Видео недоступно на этой странице"))
        default:
            break
        }
    }

    private func handleStreamFound(_ body: [String: Any]) {
        guard let urlString = body["url"] as? String else {
            return
        }
        guard let url = Self.streamUrl(from: urlString, baseUrl: body["baseUrl"] as? String) else {
            return
        }
        if self.activeStreamUrl == url {
            return
        }
        let referer = (body["referer"] as? String).flatMap { URL(string: $0) } ?? self.webView.url
        let userAgent = body["userAgent"] as? String
        let cookie = body["cookie"] as? String
        self.activateStream(url: url, referer: referer, userAgent: userAgent, cookie: cookie)
    }

    private func activateStream(url: URL, referer: URL?, userAgent: String?, cookie: String?) {
        self.releaseStreamPlayer()
        self.activeStreamUrl = url
        self.statusUpdated?(.loading)
        self.statusLabel.text = "Загрузка потока"
        self.statusLabel.isHidden = false
        self.openExternallyButton.isHidden = true

        var headers: [String: String] = [:]
        if let referer = referer {
            headers["Referer"] = referer.absoluteString
        }
        if let userAgent = userAgent, !userAgent.isEmpty {
            headers["User-Agent"] = userAgent
        }
        if let cookie = cookie, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }

        let asset: AVURLAsset
        if headers.isEmpty {
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = self.isMuted

        self.streamPlayerItem = item
        self.streamPlayer = player
        self.playerView.playerLayer.player = player
        self.playerView.isHidden = false
        self.webView.isHidden = true
        self.hasPlayableVideo = true

        self.streamStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Queue.mainQueue().async {
                self?.handleStreamItemStatus(item.status)
            }
        }
        self.streamTimeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Queue.mainQueue().async {
                self?.publishStreamStatus(playbackStatus: self?.playbackStatus(for: player.timeControlStatus))
            }
        }
        self.streamTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.35, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.publishStreamStatus(playbackStatus: nil)
        }
        self.streamDidPlayToEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self = self else {
                return
            }
            self.pendingStreamPlayback = false
            self.publishStreamStatus(playbackStatus: .paused)
            self.statusUpdated?(.ended)
        }

        if self.pendingStreamPlayback {
            player.play()
        }
    }

    private func releaseStreamPlayer() {
        if let timeObserver = self.streamTimeObserver, let player = self.streamPlayer {
            player.removeTimeObserver(timeObserver)
        }
        if let observer = self.streamDidPlayToEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        self.streamTimeObserver = nil
        self.streamDidPlayToEndObserver = nil
        self.streamStatusObservation = nil
        self.streamTimeControlObservation = nil
        self.streamPlayer?.pause()
        self.streamPlayer = nil
        self.streamPlayerItem = nil
        self.playerView.playerLayer.player = nil
        self.playerView.isHidden = true
        self.webView.isHidden = false
        self.activeStreamUrl = nil
    }

    private func handleStreamItemStatus(_ status: AVPlayerItem.Status) {
        switch status {
        case .unknown:
            self.statusLabel.text = "Загрузка потока"
            self.statusLabel.isHidden = false
            self.statusUpdated?(.loading)
        case .readyToPlay:
            self.statusLabel.isHidden = true
            self.openExternallyButton.isHidden = true
            self.publishStreamStatus(playbackStatus: self.streamPlayer.map { self.playbackStatus(for: $0.timeControlStatus) })
            if self.pendingStreamPlayback {
                self.streamPlayer?.play()
            }
        case .failed:
            self.statusLabel.text = "Не удалось открыть поток"
            self.statusLabel.isHidden = false
            self.openExternallyButton.isHidden = false
            self.statusUpdated?(.error("Не удалось открыть поток"))
            self.publishStreamStatus(playbackStatus: .paused)
        @unknown default:
            self.statusLabel.text = "Поток не поддерживается"
            self.statusLabel.isHidden = false
            self.openExternallyButton.isHidden = false
            self.statusUpdated?(.error("Поток не поддерживается"))
            self.publishStreamStatus(playbackStatus: .paused)
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

    private func publishStreamStatus(playbackStatus explicitStatus: MediaPlayerPlaybackStatus?) {
        guard let player = self.streamPlayer, let item = self.streamPlayerItem else {
            return
        }
        let duration = Self.seconds(item.duration)
        let timestamp = min(max(0.0, Self.seconds(player.currentTime())), duration > 0.0 ? duration : Double.greatestFiniteMagnitude)
        let status = explicitStatus ?? self.playbackStatus(for: player.timeControlStatus)
        self.currentPlaybackStatus = status
        self.lastDuration = duration
        self.lastTimestamp = timestamp
        self.statusPromise.set(.single(MediaPlayerStatus(
            generationTimestamp: CACurrentMediaTime(),
            duration: duration,
            dimensions: CGSize(width: 16.0, height: 9.0),
            timestamp: timestamp,
            baseRate: 1.0,
            seekId: 0,
            status: status,
            soundEnabled: !self.isMuted
        )))

        switch status {
        case .playing:
            self.pendingStreamPlayback = false
            self.statusUpdated?(.playing)
        case .paused:
            self.statusUpdated?(.paused)
        case .buffering:
            self.statusUpdated?(.loading)
        }
    }

    private func publishStatus(_ explicitStatus: MediaPlayerPlaybackStatus?) {
        if let explicitStatus = explicitStatus {
            self.currentPlaybackStatus = explicitStatus
        }
        if !self.hasPlayableVideo && self.lastDuration < Self.minimumPlayableDuration {
            return
        }
        guard self.lastDuration >= Self.minimumPlayableDuration else {
            return
        }
        let duration = self.lastDuration
        let timestamp = min(max(0.0, self.lastTimestamp), duration)
        let soundEnabled = !self.isMuted
        let statusChanged = self.lastPublishedPlaybackStatus != self.currentPlaybackStatus
        let durationChanged = abs(duration - self.lastPublishedDuration) >= 0.05
        let timestampChanged = abs(timestamp - self.lastPublishedTimestamp) >= 0.05
        let soundChanged = self.lastPublishedSoundEnabled != soundEnabled
        guard statusChanged || durationChanged || timestampChanged || soundChanged else {
            return
        }
        self.lastPublishedPlaybackStatus = self.currentPlaybackStatus
        self.lastPublishedDuration = duration
        self.lastPublishedTimestamp = timestamp
        self.lastPublishedSoundEnabled = soundEnabled
        self.statusPromise.set(.single(MediaPlayerStatus(
            generationTimestamp: CACurrentMediaTime(),
            duration: duration,
            dimensions: CGSize(width: 16.0, height: 9.0),
            timestamp: timestamp,
            baseRate: 1.0,
            seekId: 0,
            status: self.currentPlaybackStatus,
            soundEnabled: soundEnabled
        )))
    }

    private func showError() {
        self.statusLabel.text = "Не удалось открыть видео"
        self.statusLabel.isHidden = false
        self.openExternallyButton.isHidden = false
        if self.bounds.width > 0 && self.bounds.height > 0 {
            self.updateLayout(size: self.bounds.size, transition: .immediate)
        }
        self.statusUpdated?(.error("Не удалось открыть видео"))
        self.publishStatus(.paused)
    }

    private func applyTheme() {
        self.backgroundColor = .black
        self.statusLabel.textColor = .white.withAlphaComponent(0.75)
        self.openExternallyButton.tintColor = .white
        self.openExternallyButton.backgroundColor = UIColor(rgb: 0xFF383C)
    }

    @objc private func openExternallyPressed() {
        guard case let .unsupportedUrl(url) = self.item.playableSource else {
            return
        }
        self.context.sharedContext.applicationBindings.openUrl(url.absoluteString)
    }

    private func evaluate(_ script: String) {
        self.webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private static func videoCommand(action: String, value: Any? = nil) -> String {
        let valueString: String
        if let value = value as? Bool {
            valueString = value ? "true" : "false"
        } else if let value = value as? Double {
            valueString = "\(value)"
        } else {
            valueString = "null"
        }
        return """
        (function() {
          var payload = { action: '\(action)', value: \(valueString) };
          if (window.__multigramWebVideoControl) {
            window.__multigramWebVideoControl(payload);
          }
          var frames = document.querySelectorAll('iframe');
          for (var i = 0; i < frames.length; i++) {
            try {
              if (frames[i].contentWindow) {
                frames[i].contentWindow.postMessage({ __multigramWebVideoCommand: payload }, '*');
              }
            } catch (e) {}
          }
          return true;
        })();
        """
    }

    private static func normalizedDouble(_ value: Any?, fallback: Double) -> Double {
        let result: Double
        if let value = value as? Double {
            result = value
        } else if let value = value as? NSNumber {
            result = value.doubleValue
        } else {
            result = fallback
        }
        guard result.isFinite else {
            return fallback
        }
        return max(0.0, result)
    }

    private static func seconds(_ time: CMTime) -> Double {
        let seconds = CMTimeGetSeconds(time)
        if seconds.isFinite && !seconds.isNaN {
            return max(0.0, seconds)
        }
        return 0.0
    }

    private static func streamUrl(from urlString: String, baseUrl: String?) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let base = baseUrl.flatMap(URL.init(string:))
        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL else {
            return nil
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        let lower = url.absoluteString.lowercased()
        let supportedMarkers = [".m3u8", ".mp4", ".m4v", ".mov", ".webm"]
        guard supportedMarkers.contains(where: { lower.contains($0) }) else {
            return nil
        }
        return url
    }

    private static func bridgeScript() -> String {
        return """
        (function() {
          if (window.__multigramWebVideoBridgeInstalled) { return; }
          window.__multigramWebVideoBridgeInstalled = true;
          function post(payload) {
            try {
              window.webkit.messageHandlers.multigramWebVideo.postMessage(payload);
            } catch (e) {}
          }
          function finite(value) {
            return Number.isFinite(value) ? value : 0;
          }
          function finiteDuration(value) {
            return Number.isFinite(value) && value >= 1 ? value : 0;
          }
          function absoluteUrl(value) {
            if (!value || typeof value !== 'string') { return null; }
            try {
              return new URL(value, document.baseURI || window.location.href).href;
            } catch (e) {
              return null;
            }
          }
          function isStreamUrl(value) {
            var url = absoluteUrl(value);
            if (!url) { return false; }
            if (!/^https?:\\/\\//i.test(url)) { return false; }
            return /\\.(m3u8|mp4|m4v|mov|webm)([?#]|$)/i.test(url);
          }
          function streamPayload(url) {
            return {
              type: 'stream-found',
              url: absoluteUrl(url),
              baseUrl: window.location.href,
              referer: document.referrer || window.location.href,
              userAgent: navigator.userAgent || '',
              cookie: document.cookie || ''
            };
          }
          function reportStreamUrl(url) {
            if (!isStreamUrl(url)) { return false; }
            post(streamPayload(url));
            try {
              if (window.parent && window.parent !== window) {
                window.parent.postMessage({ __multigramWebVideoStreamFound: streamPayload(url) }, '*');
              }
            } catch (e) {}
            return true;
          }
          function reportVideoSources(video) {
            if (!video) { return false; }
            var didReport = false;
            if (video.currentSrc) { didReport = reportStreamUrl(video.currentSrc) || didReport; }
            if (video.src) { didReport = reportStreamUrl(video.src) || didReport; }
            try {
              var sources = video.querySelectorAll('source[src]');
              for (var i = 0; i < sources.length; i++) {
                didReport = reportStreamUrl(sources[i].src || sources[i].getAttribute('src')) || didReport;
              }
            } catch (e) {}
            return didReport;
          }
          function scanResourceStreams() {
            try {
              var entries = performance.getEntriesByType ? performance.getEntriesByType('resource') : [];
              for (var i = 0; i < entries.length; i++) {
                reportStreamUrl(entries[i].name);
              }
            } catch (e) {}
          }
          function installNetworkStreamHooks() {
            if (window.__multigramWebVideoNetworkHooksInstalled) { return; }
            window.__multigramWebVideoNetworkHooksInstalled = true;
            try {
              var originalFetch = window.fetch;
              if (originalFetch) {
                window.fetch = function(input, init) {
                  try {
                    var url = typeof input === 'string' ? input : (input && input.url);
                    reportStreamUrl(url);
                  } catch (e) {}
                  return originalFetch.apply(this, arguments).then(function(response) {
                    try { reportStreamUrl(response && response.url); } catch (e) {}
                    return response;
                  });
                };
              }
            } catch (e) {}
            try {
              var originalOpen = XMLHttpRequest.prototype.open;
              XMLHttpRequest.prototype.open = function(method, url) {
                try { reportStreamUrl(url); } catch (e) {}
                this.addEventListener('load', function() {
                  try { reportStreamUrl(this.responseURL); } catch (e) {}
                });
                return originalOpen.apply(this, arguments);
              };
            } catch (e) {}
          }
          function installIsolationStyles() {
            if (document.getElementById('__multigramVideoIsolationStyle')) { return; }
            var style = document.createElement('style');
            style.id = '__multigramVideoIsolationStyle';
            style.textContent = [
              'html, body { margin: 0 !important; padding: 0 !important; width: 100% !important; height: 100% !important; background: #000 !important; overflow: hidden !important; }',
              'body.__multigram-video-isolated { background: #000 !important; overflow: hidden !important; }',
              '#__multigramVideoBackdrop { position: fixed !important; left: 0 !important; top: 0 !important; right: 0 !important; bottom: 0 !important; width: 100vw !important; height: 100vh !important; background: #000 !important; z-index: 2147483646 !important; pointer-events: none !important; }',
              '.__multigram-video-root { position: fixed !important; left: 0 !important; top: 0 !important; right: auto !important; bottom: auto !important; width: 100vw !important; height: 100vh !important; max-width: none !important; max-height: none !important; min-width: 0 !important; min-height: 0 !important; margin: 0 !important; padding: 0 !important; border: 0 !important; transform: none !important; opacity: 1 !important; visibility: visible !important; display: block !important; background: #000 !important; z-index: 2147483647 !important; object-fit: contain !important; }',
              'video.__multigram-video-root, .__multigram-video-root video { width: 100% !important; height: 100% !important; object-fit: contain !important; background: #000 !important; }',
              'iframe.__multigram-video-root { border: 0 !important; }'
            ].join('\\n');
            (document.head || document.documentElement).appendChild(style);
          }
          function ensureBackdrop() {
            var body = document.body || document.documentElement;
            if (!body) { return; }
            try {
              body.classList.add('__multigram-video-isolated');
            } catch (e) {}
            if (!document.getElementById('__multigramVideoBackdrop')) {
              var backdrop = document.createElement('div');
              backdrop.id = '__multigramVideoBackdrop';
              body.appendChild(backdrop);
            }
          }
          function isolateElement(node) {
            if (!node || node.__multigramIsolated) { return; }
            installIsolationStyles();
            ensureBackdrop();
            node.__multigramIsolated = true;
            try {
              node.classList.add('__multigram-video-root');
              node.scrollIntoView({ block: 'center', inline: 'center' });
            } catch (e) {}
            post({ type: 'video-found' });
          }
          function isolateFrameForSource(source) {
            if (!source) { return false; }
            var frames = document.querySelectorAll('iframe');
            for (var i = 0; i < frames.length; i++) {
              try {
                if (frames[i].contentWindow === source) {
                  isolateElement(frames[i]);
                  return true;
                }
              } catch (e) {}
            }
            return false;
          }
          function notifyParentVideoFound() {
            try {
              if (window.parent && window.parent !== window) {
                window.parent.postMessage({ __multigramWebVideoFound: true }, '*');
              }
            } catch (e) {}
          }
          function isVisible(node) {
            if (!node || !node.getBoundingClientRect) { return false; }
            var style = window.getComputedStyle(node);
            if (!style || style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) {
              return false;
            }
            var rect = node.getBoundingClientRect();
            return rect.width >= 8 && rect.height >= 8 && rect.bottom > 0 && rect.right > 0 && rect.top < window.innerHeight && rect.left < window.innerWidth;
          }
          function hasVideoSource(video) {
            if (!video) { return false; }
            if (video.currentSrc || video.src) { return true; }
            try {
              return !!video.querySelector('source[src]');
            } catch (e) {
              return false;
            }
          }
          function isPlayableVideo(video) {
            if (!video) { return false; }
            if (!hasVideoSource(video)) { return false; }
            if (video.readyState >= 1) { return true; }
            if (Number.isFinite(video.duration) && video.duration > 0) { return true; }
            return false;
          }
          function videoScore(video) {
            if (!video || !hasVideoSource(video)) { return -1; }
            var score = 0;
            if (isVisible(video)) {
              var rect = video.getBoundingClientRect();
              score += Math.min(100000, rect.width * rect.height);
            }
            if (video.readyState >= 1) { score += 100000; }
            if (Number.isFinite(video.duration) && video.duration > 0) { score += 100000; }
            if (!video.paused) { score += 100000; }
            return score;
          }
          function findVideo() {
            var videos = Array.prototype.slice.call(document.querySelectorAll('video'));
            var best = null;
            var bestScore = -1;
            for (var i = 0; i < videos.length; i++) {
              var score = videoScore(videos[i]);
              if (score > bestScore) {
                bestScore = score;
                best = videos[i];
              }
            }
            return bestScore >= 0 ? best : null;
          }
          function activate(video) {
            if (!isPlayableVideo(video)) { return false; }
            reportVideoSources(video);
            if (!isVisible(video)) { return false; }
            isolateElement(video);
            notifyParentVideoFound();
            post({ type: 'time', currentTime: finite(video.currentTime), duration: finiteDuration(video.duration) });
            return true;
          }
          function attachKnownVideos() {
            var videos = Array.prototype.slice.call(document.querySelectorAll('video'));
            for (var i = 0; i < videos.length; i++) {
              attach(videos[i]);
            }
          }
          function dispatchClick(node) {
            if (!node) { return false; }
            try {
              var rect = node.getBoundingClientRect ? node.getBoundingClientRect() : null;
              var x = rect ? rect.left + rect.width / 2 : 0;
              var y = rect ? rect.top + rect.height / 2 : 0;
              ['pointerdown', 'mousedown', 'mouseup', 'click'].forEach(function(type) {
                var event;
                if (window.PointerEvent && type.indexOf('pointer') === 0) {
                  event = new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 1, pointerType: 'touch', clientX: x, clientY: y });
                } else {
                  event = new MouseEvent(type, { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y });
                }
                node.dispatchEvent(event);
              });
              if (typeof node.click === 'function') {
                node.click();
              }
              return true;
            } catch (e) {
              try {
                node.click();
                return true;
              } catch (inner) {}
            }
            return false;
          }
          function clickCandidate() {
            var selectors = [
              'button[aria-label*="Play" i]',
              'button[title*="Play" i]',
              '.vjs-big-play-button',
              '.vjs-poster',
              '.plyr__control--overlaid',
              '.plyr__poster',
              '.jw-display-icon-container',
              '.jw-icon-playback',
              '.jw-preview',
              '.jwplayer',
              '.mejs-overlay-button',
              '.mejs-overlay-play',
              '[role="button"][aria-label*="Play" i]',
              '[class*="play" i]',
              '[id*="play" i]',
              '[onclick]'
            ];
            var candidates = [];
            for (var i = 0; i < selectors.length; i++) {
              try {
                var nodes = document.querySelectorAll(selectors[i]);
                for (var j = 0; j < nodes.length; j++) {
                  if (isVisible(nodes[j])) {
                    candidates.push(nodes[j]);
                  }
                }
              } catch (e) {}
            }
            candidates.sort(function(a, b) {
              var ar = a.getBoundingClientRect();
              var br = b.getBoundingClientRect();
              return (br.width * br.height) - (ar.width * ar.height);
            });
            for (var k = 0; k < candidates.length; k++) {
              if (dispatchClick(candidates[k])) {
                return true;
              }
            }
            var video = findVideo();
            if (video && dispatchClick(video)) {
              return true;
            }
            return false;
          }
          function control(payload) {
            var video = findVideo();
            var action = payload && payload.action;
            if (!video) {
              if (action === 'play' || action === 'toggle') {
                if (clickCandidate()) {
                  setTimeout(function() {
                    var delayedVideo = findVideo();
                    if (delayedVideo) {
                      control(payload);
                    }
                  }, 250);
                  return true;
                }
              }
              if (window.top === window && document.querySelectorAll('iframe').length === 0) {
                post({ type: 'unavailable' });
              }
              return false;
            }
            video.setAttribute('playsinline', 'true');
            video.setAttribute('webkit-playsinline', 'true');
            activate(video);
            if (action === 'play') {
              var playPromise = video.play();
              if (playPromise && typeof playPromise.catch === 'function') {
                playPromise.catch(function() { clickCandidate(); });
              }
            } else if (action === 'pause') {
              video.pause();
            } else if (action === 'toggle') {
              if (video.paused) {
                var togglePromise = video.play();
                if (togglePromise && typeof togglePromise.catch === 'function') {
                  togglePromise.catch(function() { clickCandidate(); });
                }
              } else {
                video.pause();
              }
            } else if (action === 'seek') {
              var timestamp = Number(payload.value);
              if (Number.isFinite(timestamp)) {
                video.currentTime = Math.max(0, timestamp);
              }
            } else if (action === 'muted') {
              video.muted = !!payload.value;
            }
            return true;
          }
          function attach(video) {
            if (!video || video.__multigramAttached) { return; }
            video.__multigramAttached = true;
            video.setAttribute('playsinline', 'true');
            video.setAttribute('webkit-playsinline', 'true');
            reportVideoSources(video);
            activate(video);
            video.addEventListener('loadedmetadata', function() { activate(video); });
            video.addEventListener('loadeddata', function() { activate(video); });
            video.addEventListener('canplay', function() { activate(video); });
            video.addEventListener('durationchange', function() { reportVideoSources(video); });
            video.addEventListener('emptied', function() { reportVideoSources(video); });
            video.addEventListener('play', function() { activate(video); post({ type: 'playing' }); });
            video.addEventListener('playing', function() { activate(video); post({ type: 'playing' }); });
            video.addEventListener('pause', function() { post({ type: 'paused' }); });
            video.addEventListener('waiting', function() { post({ type: 'waiting' }); });
            video.addEventListener('ended', function() { post({ type: 'ended' }); });
            video.addEventListener('timeupdate', function() {
              post({ type: 'time', currentTime: finite(video.currentTime), duration: finiteDuration(video.duration) });
            });
            setInterval(function() {
              reportVideoSources(video);
              if (isPlayableVideo(video)) {
                post({ type: 'time', currentTime: finite(video.currentTime), duration: finiteDuration(video.duration) });
              }
            }, 500);
          }
          installNetworkStreamHooks();
          window.__multigramWebVideoControl = control;
          window.addEventListener('message', function(event) {
            var data = event.data;
            if (data && data.__multigramWebVideoFound && window.top === window) {
              isolateFrameForSource(event.source);
            }
            if (data && data.__multigramWebVideoStreamFound && data.__multigramWebVideoStreamFound.url) {
              post(data.__multigramWebVideoStreamFound);
            }
            if (data && data.__multigramWebVideoCommand) {
              control(data.__multigramWebVideoCommand);
            }
          });
          document.addEventListener('click', function() {
            setTimeout(function() {
              attach(findVideo());
            }, 120);
          }, true);
          attachKnownVideos();
          scanResourceStreams();
          var root = document.documentElement || document.body;
          if (root) {
            var observer = new MutationObserver(function() {
              attachKnownVideos();
              scanResourceStreams();
            });
            observer.observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'style', 'class'] });
          }
          setInterval(function() {
            attachKnownVideos();
            scanResourceStreams();
          }, 1200);
        })();
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

private final class GenericWebVideoWeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        self.target?.userContentController(userContentController, didReceive: message)
    }
}
