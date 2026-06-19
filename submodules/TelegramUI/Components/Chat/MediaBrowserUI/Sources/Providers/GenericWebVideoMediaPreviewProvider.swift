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
        self.evaluate(Self.videoCommand("video.play();"))
    }

    func pause() {
        self.evaluate(Self.videoCommand("video.pause();"))
    }

    func togglePlayPause() {
        self.evaluate(Self.videoCommand("if (video.paused) { video.play(); } else { video.pause(); }"))
    }

    func seek(to timestamp: Double) {
        guard timestamp.isFinite else {
            return
        }
        self.evaluate(Self.videoCommand("video.currentTime = \(max(0.0, timestamp));"))
    }

    func setSoundMuted(_ muted: Bool) {
        self.isMuted = muted
        self.evaluate(Self.videoCommand("video.muted = \(muted ? "true" : "false");"))
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
        self.publishStatus(.paused)
        self.statusUpdated?(.paused)
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
            self.lastTimestamp = body["currentTime"] as? Double ?? self.lastTimestamp
            self.lastDuration = body["duration"] as? Double ?? self.lastDuration
            self.publishStatus(nil)
        default:
            break
        }
    }

    private func publishStatus(_ explicitStatus: MediaPlayerPlaybackStatus?) {
        if let explicitStatus = explicitStatus {
            self.currentPlaybackStatus = explicitStatus
        }
        self.statusPromise.set(.single(MediaPlayerStatus(
            generationTimestamp: CACurrentMediaTime(),
            duration: max(0.0, self.lastDuration),
            dimensions: CGSize(width: 16.0, height: 9.0),
            timestamp: max(0.0, self.lastTimestamp),
            baseRate: 1.0,
            seekId: 0,
            status: self.currentPlaybackStatus,
            soundEnabled: !self.isMuted
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

    private static func videoCommand(_ command: String) -> String {
        return """
        (function() {
          var video = document.querySelector('video');
          if (!video) { return false; }
          \(command)
          return true;
        })();
        """
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
          attach(document.querySelector('video'));
          var root = document.documentElement || document.body;
          if (root) {
            var observer = new MutationObserver(function() {
              attach(document.querySelector('video'));
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
