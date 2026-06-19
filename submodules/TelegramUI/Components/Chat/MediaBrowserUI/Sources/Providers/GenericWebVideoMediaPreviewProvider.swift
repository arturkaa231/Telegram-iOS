import Foundation
import UIKit
import WebKit
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

final class GenericWebVideoPreviewNode: ASDisplayNode, MediaPreviewNode, WKScriptMessageHandler, WKNavigationDelegate {
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
    private var lastPublishedDuration: Double = -1.0
    private var lastPublishedTimestamp: Double = -1.0
    private var lastPublishedPlaybackStatus: MediaPlayerPlaybackStatus?
    private var lastPublishedSoundEnabled: Bool?
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
        configuration.userContentController.addUserScript(WKUserScript(source: Self.bridgeScript(), injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        self.webView = WKWebView(frame: .zero, configuration: configuration)
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
        self.view.addSubview(self.statusLabel)
        self.view.addSubview(self.openExternallyButton)
        self.openExternallyButton.addTarget(self, action: #selector(self.openExternallyPressed), for: .touchUpInside)
        self.loadPage()
    }

    deinit {
        self.webView.configuration.userContentController.removeScriptMessageHandler(forName: "multigramWebVideo")
        self.webView.stopLoading()
    }

    func play() {
        self.evaluate(Self.videoCommand(action: "play"))
    }

    func pause() {
        self.evaluate(Self.videoCommand(action: "pause"))
    }

    func togglePlayPause() {
        self.evaluate(Self.videoCommand(action: "toggle"))
    }

    func seek(to timestamp: Double) {
        guard timestamp.isFinite else {
            return
        }
        self.evaluate(Self.videoCommand(action: "seek", value: max(0.0, timestamp)))
    }

    func setSoundMuted(_ muted: Bool) {
        self.isMuted = muted
        self.evaluate(Self.videoCommand(action: "muted", value: muted))
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
        case "time":
            let timestamp = Self.normalizedDouble(body["currentTime"], fallback: self.lastTimestamp)
            let duration = Self.normalizedDouble(body["duration"], fallback: self.lastDuration)
            let timestampChanged = abs(timestamp - self.lastTimestamp) >= 0.05
            let durationChanged = abs(duration - self.lastDuration) >= 0.05
            guard timestampChanged || durationChanged || duration > 0.0 else {
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

    private func publishStatus(_ explicitStatus: MediaPlayerPlaybackStatus?) {
        if let explicitStatus = explicitStatus {
            self.currentPlaybackStatus = explicitStatus
        }
        let duration = max(0.0, self.lastDuration)
        let timestamp = max(0.0, self.lastTimestamp)
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
          function isVisible(node) {
            if (!node || !node.getBoundingClientRect) { return false; }
            var style = window.getComputedStyle(node);
            if (!style || style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) {
              return false;
            }
            var rect = node.getBoundingClientRect();
            return rect.width >= 8 && rect.height >= 8 && rect.bottom > 0 && rect.right > 0 && rect.top < window.innerHeight && rect.left < window.innerWidth;
          }
          function findVideo() {
            var videos = Array.prototype.slice.call(document.querySelectorAll('video'));
            for (var i = 0; i < videos.length; i++) {
              if (isVisible(videos[i])) {
                return videos[i];
              }
            }
            return videos[0] || null;
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
            video.addEventListener('play', function() { post({ type: 'playing' }); });
            video.addEventListener('playing', function() { post({ type: 'playing' }); });
            video.addEventListener('pause', function() { post({ type: 'paused' }); });
            video.addEventListener('waiting', function() { post({ type: 'waiting' }); });
            video.addEventListener('ended', function() { post({ type: 'ended' }); });
            setInterval(function() {
              post({ type: 'time', currentTime: finite(video.currentTime), duration: finite(video.duration) });
            }, 500);
          }
          window.__multigramWebVideoControl = control;
          window.addEventListener('message', function(event) {
            var data = event.data;
            if (data && data.__multigramWebVideoCommand) {
              control(data.__multigramWebVideoCommand);
            }
          });
          document.addEventListener('click', function() {
            setTimeout(function() {
              attach(findVideo());
            }, 120);
          }, true);
          attach(findVideo());
          var root = document.documentElement || document.body;
          if (root) {
            var observer = new MutationObserver(function() {
              attach(findVideo());
            });
            observer.observe(root, { childList: true, subtree: true });
          }
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
