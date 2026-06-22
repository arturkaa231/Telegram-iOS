import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import ShareController

public enum MediaBrowserInitialDisplayMode {
    case playerOnly
    case library
}

public final class MediaBrowserController: ViewController {
    private let context: AccountContext
    private var peerId: EnginePeer.Id
    private let initialMessageId: EngineMessage.Id?
    private let initialPosition: Double?
    private let initialTab: MediaBrowserTab
    private let initialDisplayMode: MediaBrowserInitialDisplayMode

    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    public var dismissed: (() -> Void)?
    public var onJumpToMessageRequested: ((EngineMessage.Id) -> Void)?

    public init(context: AccountContext, peerId: EnginePeer.Id, initialMessageId: EngineMessage.Id? = nil, initialPosition: Double? = nil, initialTab: MediaBrowserTab = .allFiles, initialDisplayMode: MediaBrowserInitialDisplayMode = .library) {
        self.context = context
        self.peerId = peerId
        self.initialMessageId = initialMessageId
        self.initialPosition = initialPosition
        self.initialTab = initialTab
        self.initialDisplayMode = initialDisplayMode
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        super.init(navigationBarPresentationData: nil)

        self.modalPresentationStyle = .overCurrentContext

        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).startStrict(next: { [weak self] presentationData in
            guard let self = self else { return }
            self.presentationData = presentationData
            if self.isNodeLoaded {
                (self.displayNode as? MediaBrowserControllerNode)?.updatePresentationData(presentationData)
            }
        })
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.presentationDataDisposable?.dispose()
    }

    override public func loadDisplayNode() {
        let node = MediaBrowserControllerNode(
            context: self.context,
            peerId: self.peerId,
            presentationData: self.presentationData,
            initialMessageId: self.initialMessageId,
            initialPosition: self.initialPosition,
            initialTab: self.initialTab,
            initialDisplayMode: self.initialDisplayMode,
            dismiss: { [weak self] in
                self?.dismissed?()
                self?.dismiss(animated: true)
            }
        )
        node.onPresentGallery = { [weak self] item in
            self?.presentGallery(for: item)
        }
        node.onShareMessage = { [weak self] item in
            self?.shareMessage(item)
        }
        node.onJumpToMessage = { [weak self] item in
            self?.jumpToMessage(item)
        }
        node.onDeleteMessage = { [weak self] item in
            self?.deleteMessage(item)
        }
        node.onItemLongPressed = { [weak self, weak node] item in
            self?.showLongPressMenu(for: item, statisticsService: node?.statisticsServiceForCurrentPeer())
        }
        node.onChatLongPressed = { [weak self, weak node] item in
            self?.showStatistics(for: item, statisticsService: node?.statisticsServiceForCurrentPeer())
        }
        self.displayNode = node
        self.displayNodeDidLoad()
    }

    private func showLongPressMenu(for item: MediaBrowserItem, statisticsService: MediaStatisticsService?) {
        let isDualScenario = item.message.media.contains { media in
            if let file = media as? TelegramMediaFile {
                if file.mimeType == "application/pdf" { return true }
                if let name = file.fileName?.lowercased(), name.hasSuffix(".pdf") || name.hasSuffix(".epub") { return true }
            }
            return false
        }
        let alert = UIAlertController(title: item.fileName, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Статистика", style: .default, handler: { [weak self] _ in
            self?.showStatistics(for: item, statisticsService: statisticsService)
        }))
        if isDualScenario {
            alert.addAction(UIAlertAction(title: "Открыть в PDF-плеере", style: .default, handler: { [weak self] _ in
                self?.presentGallery(for: item)
            }))
            alert.addAction(UIAlertAction(title: "Открыть в читалке", style: .default, handler: { _ in }))
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        self.presentUIKitAlert(alert)
    }

    private func showStatistics(for item: MediaBrowserItem, statisticsService: MediaStatisticsService?) {
        guard let statisticsService = statisticsService else {
            self.showStatisticsAlert(title: item.fileName, message: "Статистика недоступна")
            return
        }
        let target = MediaStatisticsTarget.file(item: item, chatId: self.peerId)
        statisticsService.loadSummary(target: target) { [weak self] result in
            switch result {
            case let .success(summary):
                self?.showStatisticsAlert(title: target.title, message: self?.statisticsMessage(summary) ?? "Нет статистики")
            case .failure:
                self?.showStatisticsAlert(title: target.title, message: "Статистика недоступна")
            }
        }
    }

    private func showStatistics(for item: MediaBrowserChatItem, statisticsService: MediaStatisticsService?) {
        guard let statisticsService = statisticsService else {
            self.showStatisticsAlert(title: item.title, message: "Статистика недоступна")
            return
        }
        let target = MediaStatisticsTarget.chat(item)
        statisticsService.loadSummary(target: target) { [weak self] result in
            switch result {
            case let .success(summary):
                self?.showStatisticsAlert(title: target.title, message: self?.statisticsMessage(summary) ?? "Нет статистики")
            case .failure:
                self?.showStatisticsAlert(title: target.title, message: "Статистика недоступна")
            }
        }
    }

    private func statisticsMessage(_ summary: MediaStatisticsSummary) -> String {
        guard summary.totalOpenCount > 0 else {
            return "Открытий пока нет"
        }
        var lines: [String] = ["Открытий: \(summary.totalOpenCount)"]
        if let lastOpenedAt = summary.lastOpenedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: self.presentationData.strings.baseLanguageCode)
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            lines.append("Последний раз: \(formatter.string(from: lastOpenedAt))")
        }
        if !summary.topUsers.isEmpty {
            lines.append("")
            lines.append("Топ пользователей:")
            for row in summary.topUsers {
                lines.append("Пользователь \(row.userId): \(row.openCount)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func showStatisticsAlert(title: String, message: String) {
        let alert = UIAlertController(title: title.isEmpty ? "Статистика" : title, message: message, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "ОК", style: .cancel))
        self.presentUIKitAlert(alert)
    }

    private func presentUIKitAlert(_ alert: UIAlertController) {
        let topWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
        if let topVC = topWindow?.rootViewController {
            var presenter = topVC
            while let presented = presenter.presentedViewController { presenter = presented }
            presenter.present(alert, animated: true)
        }
    }

    private func presentGallery(for item: MediaBrowserItem) {
        let source: GalleryControllerItemSource = .standaloneMessage(item.message, nil)
        let gallery = self.context.sharedContext.makeGalleryController(
            context: self.context,
            source: source,
            streamSingleVideo: true,
            isPreview: false
        )
        self.present(gallery, in: .window(.root))
    }

    private func shareMessage(_ item: MediaBrowserItem) {
        let shareController = ShareController(context: self.context, subject: .messages([item.message]))
        self.present(shareController, in: .window(.root))
    }

    private func jumpToMessage(_ item: MediaBrowserItem) {
        let messageId = item.messageId
        self.dismissed?()
        self.dismiss(animated: true)
        Queue.mainQueue().after(0.3) { [weak self] in
            self?.onJumpToMessageRequested?(messageId)
        }
    }

    private func deleteMessage(_ item: MediaBrowserItem) {
        let context = self.context
        let messageId = item.messageId
        let alert = UIAlertController(title: nil, message: "Удалить сообщение?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive, handler: { _ in
            let _ = context.engine.messages.deleteMessagesInteractively(messageIds: [messageId], type: .forEveryone).startStandalone()
        }))
        let topWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
        if let topVC = topWindow?.rootViewController {
            var presenter = topVC
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            presenter.present(alert, animated: true)
        }
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        (self.displayNode as! MediaBrowserControllerNode).containerLayoutUpdated(layout: layout, transition: transition)
    }
}

private class TouchBlockingView: UIView {
    var passThroughOutsideFrame: CGRect?
    var passThroughAllTouches: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.disablesInteractiveTransitionGestureRecognizer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.passThroughAllTouches {
            return nil
        }
        if let passThroughOutsideFrame = self.passThroughOutsideFrame, !passThroughOutsideFrame.contains(point) {
            return nil
        }
        let result = super.hitTest(point, with: event)
        return result ?? self
    }
}

private final class MediaBrowserFocusOverlayWindow: UIWindow {
    var interactiveFrame: CGRect?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let interactiveFrame = self.interactiveFrame, !interactiveFrame.contains(point) {
            return nil
        }
        let result = super.hitTest(point, with: event)
        if result === self.rootViewController?.view {
            return nil
        }
        return result
    }
}

private final class MediaBrowserFocusOverlay {
    private let window: MediaBrowserFocusOverlayWindow
    private let rootViewController: UIViewController
    private let rootNode: ASDisplayNode
    private var playerNode: MediaBrowserPlayerNode?

    init(windowScene: UIWindowScene) {
        self.window = MediaBrowserFocusOverlayWindow(windowScene: windowScene)
        self.rootViewController = UIViewController()
        self.rootNode = ASDisplayNode()

        self.window.frame = windowScene.coordinateSpace.bounds
        self.window.windowLevel = .alert + 100.0
        self.window.backgroundColor = .clear
        self.window.isOpaque = false
        self.window.rootViewController = self.rootViewController
        self.rootViewController.view.backgroundColor = .clear
        self.rootViewController.view.isOpaque = false
        self.rootViewController.view.addSubview(self.rootNode.view)
    }

    func show(playerNode: MediaBrowserPlayerNode, transition: ContainedViewLayoutTransition) {
        self.playerNode = playerNode
        self.rootNode.addSubnode(playerNode)
        self.window.isHidden = false
        self.updateLayout(transition: transition)
    }

    func updateLayout(transition: ContainedViewLayoutTransition) {
        let bounds = self.window.bounds
        self.rootNode.frame = bounds

        guard let playerNode = self.playerNode, bounds.width > 0.0, bounds.height > 0.0 else {
            self.window.interactiveFrame = nil
            return
        }

        let safeInsets = self.window.safeAreaInsets
        let focusWidth = min(bounds.width - 24.0, 430.0)
        let focusHeight = min(270.0, max(196.0, floor(focusWidth * 0.56)))
        let focusX = floor((bounds.width - focusWidth) / 2.0)
        let focusY = max(safeInsets.top + 64.0, 92.0)
        let playerFrame = CGRect(x: focusX, y: focusY, width: focusWidth, height: focusHeight)

        self.window.interactiveFrame = playerFrame
        transition.updateFrame(node: playerNode, frame: playerFrame)
        playerNode.updateLayout(size: playerFrame.size, safeInsets: .zero, transition: transition)
    }

    func hide() {
        self.window.interactiveFrame = nil
        self.window.isHidden = true
        self.playerNode?.removeFromSupernode()
        self.playerNode = nil
    }
}

final class MediaBrowserControllerNode: ASDisplayNode {
    private static var detachedFocusOverlay: MediaBrowserFocusOverlay?
    private static let windowCornerRadius: CGFloat = 18.0

    private let context: AccountContext
    private var peerId: EnginePeer.Id
    private var presentationData: PresentationData
    private let dismiss: () -> Void
    private let initialMessageId: EngineMessage.Id?
    private let initialPosition: Double?
    private let initialTab: MediaBrowserTab
    private let initialDisplayMode: MediaBrowserInitialDisplayMode
    private var didApplyInitialSelection: Bool = false

    private let dimNode: ASDisplayNode
    private let contentNode: ASDisplayNode
    private let playerNode: MediaBrowserPlayerNode
    private let tabBarNode: MediaBrowserTabBarNode
    private let listNode: MediaBrowserListNode
    private let onTVListNode: OnTVSessionsListNode
    private let chatListNode: MediaBrowserChatListNode
    private var focusOverlay: MediaBrowserFocusOverlay?

    private let dataSource: MediaBrowserDataSource
    private let onTVSessionCoordinator: OnTVSessionCoordinator
    private let playbackProgressStore: MediaPlaybackProgressStore
    private let statisticsService: MediaStatisticsService?
    private let progressStore: MediaBrowserProgressStore

    private var validLayout: ContainerViewLayout?
    private var isExpanded: Bool = false
    private var isFocusMode: Bool = false
    private var isLibraryVisible: Bool
    private var basePresentationData: PresentationData
    private var mode: Mode
    private var selectedTab: MediaBrowserTab = .allFiles
    private var loadedItems: [MediaBrowserItem] = []
    private var currentItemIndex: Int?
    private var mediaLoadingState: MediaBrowserLoadingState = .idle
    private var pendingOnTVResolverLoad: Bool = false
    private var autoOpenedRemoteOnTVSessionId: String?
    private var currentOnTVSessions: [OnTVPlaybackContext] = []
    private var currentUnresolvedOnTVSessions: [OnTVRemotePlaybackContext] = []
    private var lastProgressRecordsReloadAt: Double = 0.0
    private var progressRecordsReloadScheduled: Bool = false
    private var focusModeToggleLocked: Bool = false

    enum Mode {
        case files
        case chatPicker
    }

    init(context: AccountContext, peerId: EnginePeer.Id, presentationData: PresentationData, initialMessageId: EngineMessage.Id?, initialPosition: Double?, initialTab: MediaBrowserTab, initialDisplayMode: MediaBrowserInitialDisplayMode, dismiss: @escaping () -> Void) {
        self.context = context
        self.peerId = peerId
        self.presentationData = presentationData
        self.basePresentationData = presentationData
        self.dismiss = dismiss
        self.initialMessageId = initialMessageId
        self.initialPosition = initialPosition
        self.initialTab = initialTab
        self.initialDisplayMode = initialDisplayMode
        self.isLibraryVisible = initialDisplayMode == .library
        self.mode = .files

        self.dimNode = ASDisplayNode()
        self.dimNode.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        self.contentNode = ASDisplayNode()
        self.contentNode.backgroundColor = presentationData.theme.list.plainBackgroundColor
        self.contentNode.cornerRadius = Self.windowCornerRadius
        self.contentNode.clipsToBounds = true
        if #available(iOS 13.0, *) {
            self.contentNode.layer.cornerCurve = .continuous
        }

        self.playerNode = MediaBrowserPlayerNode(context: context, presentationData: presentationData)
        self.playbackProgressStore = MediaPlaybackProgressStore(accountPeerId: context.account.peerId)

        self.dataSource = MediaBrowserDataSource(context: context, peerId: peerId)
        self.progressStore = MediaBrowserProgressStore(postbox: context.account.postbox)
        let syncConfiguration = Self.onTVSyncConfiguration()
        let syncTokenService = Self.syncTokenService(configuration: syncConfiguration, accountPeerId: context.account.peerId)
        if let endpoint = syncConfiguration.endpoint {
            self.statisticsService = MediaStatisticsService(
                endpoint: endpoint,
                authToken: syncConfiguration.authToken,
                accountPeerId: context.account.peerId,
                authTokenProvider: syncTokenService.map { service in
                    return { chatScope, completion in
                        service.token(forChatScope: chatScope, completion: completion)
                    }
                }
            )
        } else {
            self.statisticsService = nil
        }
        let onTVSessionsStore: OnTVSessionsStore
        if let endpoint = syncConfiguration.endpoint {
            NSLog("[MultigramOnTV] Using synced store endpoint=%@ peerId=%lld accountPeerId=%lld", endpoint.absoluteString, peerId.toInt64(), context.account.peerId.toInt64())
            onTVSessionsStore = SyncedOnTVSessionsStore(
                peerId: peerId,
                accountPeerId: context.account.peerId,
                transport: ServerOnTVSessionsTransport(
                    endpoint: endpoint,
                    authToken: syncConfiguration.authToken,
                    accountPeerId: context.account.peerId,
                    authTokenProvider: syncTokenService.map { service in
                        return { chatScope, completion in
                            service.token(forChatScope: chatScope, completion: completion)
                        }
                    }
                ),
                progressStore: self.progressStore
            )
        } else {
            NSLog("[MultigramOnTV] Using local store peerId=%lld accountPeerId=%lld", peerId.toInt64(), context.account.peerId.toInt64())
            onTVSessionsStore = LocalOnTVSessionsStore(peerId: peerId, accountPeerId: context.account.peerId, progressStore: self.progressStore)
        }
        self.onTVSessionCoordinator = OnTVSessionCoordinator(store: onTVSessionsStore, accountPeerId: context.account.peerId)

        var onBackHandlerPlaceholder: (() -> Void)?
        self.tabBarNode = MediaBrowserTabBarNode(presentationData: presentationData, onBack: { onBackHandlerPlaceholder?() })

        self.listNode = MediaBrowserListNode(context: context, presentationData: presentationData)
        self.onTVListNode = OnTVSessionsListNode(presentationData: presentationData, accountPeerId: context.account.peerId)
        self.chatListNode = MediaBrowserChatListNode(context: context, presentationData: presentationData)

        super.init()

        self.selectedTab = initialTab
        self.playerNode.setPrefersCompactOverlay(true)

        onBackHandlerPlaceholder = { [weak self] in
            self?.switchToChatPicker()
        }

        self.setViewBlock({
            return TouchBlockingView()
        })

        self.addSubnode(self.dimNode)
        self.addSubnode(self.contentNode)
        self.contentNode.addSubnode(self.playerNode)
        self.contentNode.addSubnode(self.tabBarNode)
        self.contentNode.addSubnode(self.listNode)
        self.contentNode.addSubnode(self.onTVListNode)
        self.contentNode.addSubnode(self.chatListNode)
        self.chatListNode.isHidden = true

        self.chatListNode.onItemSelected = { [weak self] item in
            self?.recordOpen(target: .chat(item))
            self?.switchToFiles(peerId: item.peerId)
        }
        self.chatListNode.onItemLongPressed = { [weak self] item in
            self?.onChatLongPressed?(item)
        }

        self.setupDimDismiss()
        self.setupDataSource()

        self.playerNode.onToggleExpanded = { [weak self] isExpanded in
            guard let self = self else { return }
            self.isExpanded = isExpanded
            if let layout = self.validLayout {
                self.containerLayoutUpdated(layout: layout, transition: .animated(duration: 0.3, curve: .easeInOut))
            }
        }
        self.playerNode.onToggleFocusMode = { [weak self] in
            guard let self = self else { return }
            self.requestFocusMode(!self.isFocusMode)
        }
        self.playerNode.onToggleMediaLibrary = { [weak self] in
            guard let self = self else { return }
            self.isLibraryVisible = !self.isLibraryVisible
            if let layout = self.validLayout {
                self.containerLayoutUpdated(layout: layout, transition: .animated(duration: 0.25, curve: .easeInOut))
            }
        }
        self.playerNode.onPresentGallery = { [weak self] item in
            guard let self = self else { return }
            if self.isFocusMode {
                self.applyFocusMode(false, transition: .immediate)
            }
            self.onPresentGallery?(item)
        }
        self.playerNode.onShareMessage = { [weak self] item in
            self?.onShareMessage?(item)
        }
        self.playerNode.onJumpToMessage = { [weak self] item in
            self?.onJumpToMessage?(item)
        }
        self.playerNode.onDeleteMessage = { [weak self] item in
            self?.onDeleteMessage?(item)
        }
        self.playerNode.onPrevItem = { [weak self] in
            self?.navigateNeighbor(-1)
        }
        self.playerNode.onNextItem = { [weak self] in
            self?.navigateNeighbor(1)
        }
        self.playerNode.onPulseChanged = { [weak self] isOn in
            guard let self = self else { return }
            let displayedItem = self.currentPulseItem()
            self.onTVSessionCoordinator.handlePulseChanged(
                isOn,
                displayedItem: displayedItem,
                position: self.playerNode.currentPlaybackPosition(),
                progress: self.playerNode.currentPlaybackProgress()
            )
        }
        self.playerNode.onPlaybackStatusChanged = { [weak self] status in
            self?.onTVSessionCoordinator.handlePlaybackStatusChanged(status)
        }
        self.playerNode.onSeekRequested = { [weak self] position, progress in
            guard let self = self else { return }
            let item = self.playerNode.displayedItem
            self.playbackProgressStore.update(item: item, position: position, progress: progress)
            self.onTVSessionCoordinator.handleSeekRequested(position: position, progress: progress)
            self.listNode.updatePlaybackProgress(for: item, progress: progress)
        }
        self.playerNode.onPlaybackPositionUpdated = { [weak self] position, progress, isPlaying in
            guard let self = self else { return }
            let item = self.playerNode.displayedItem
            self.playbackProgressStore.update(item: item, position: position, progress: progress)
            self.listNode.updatePlaybackProgress(for: item, progress: progress)
            self.onTVSessionCoordinator.handlePlaybackPositionUpdated(position: position, progress: progress, isPlaying: isPlaying)
        }
    }

    private func requestFocusMode(_ enabled: Bool) {
        guard !self.focusModeToggleLocked else {
            return
        }
        self.focusModeToggleLocked = true
        Queue.mainQueue().after(0.02) { [weak self] in
            guard let self = self else { return }
            self.applyFocusMode(enabled, transition: .animated(duration: 0.3, curve: .easeInOut))
            Queue.mainQueue().after(0.35) { [weak self] in
                self?.focusModeToggleLocked = false
            }
        }
    }

    deinit {
        if self.isFocusMode, let focusOverlay = self.focusOverlay {
            let context = self.context
            let peerId = self.peerId
            let messageId = self.playerNode.displayedItem?.messageId ?? self.initialMessageId
            let position = self.playerNode.currentPlaybackPosition()
            let selectedTab = self.selectedTab
            Self.detachedFocusOverlay = focusOverlay
            self.playerNode.onToggleFocusMode = {
                Self.detachedFocusOverlay?.hide()
                Self.detachedFocusOverlay = nil
                Self.presentRestoredMediaBrowser(
                    context: context,
                    peerId: peerId,
                    messageId: messageId,
                    position: position,
                    selectedTab: selectedTab
                )
            }
            self.playerNode.onPresentGallery = { item in
                Self.detachedFocusOverlay?.hide()
                Self.detachedFocusOverlay = nil
                Self.presentGallery(context: context, item: item)
            }
        } else {
            self.updateFocusOverlay(enabled: false, transition: .immediate)
        }
        self.flushCurrentLocalProgress()
        self.stopActiveOnTVSessionForExit()
    }

    private func currentWindowScene() -> UIWindowScene? {
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { scene in
                scene.activationState == .foregroundActive && scene.windows.contains(where: { $0.isKeyWindow })
            })
    }

    private func updateFocusOverlay(transition: ContainedViewLayoutTransition) {
        self.updateFocusOverlay(enabled: self.isFocusMode, transition: transition)
    }

    private static func presentRestoredMediaBrowser(context: AccountContext, peerId: EnginePeer.Id, messageId: EngineMessage.Id?, position: Double, selectedTab: MediaBrowserTab) {
        let controller = MediaBrowserController(
            context: context,
            peerId: peerId,
            initialMessageId: messageId,
            initialPosition: position,
            initialTab: selectedTab == .onTV ? .allFiles : selectedTab,
            initialDisplayMode: .library
        )
        controller.modalPresentationStyle = .overCurrentContext
        context.sharedContext.applicationBindings.getWindowHost()?.present(controller, on: .root, blockInteraction: false, completion: {})
    }

    private static func presentGallery(context: AccountContext, item: MediaBrowserItem) {
        let source: GalleryControllerItemSource = .standaloneMessage(item.message, nil)
        let gallery = context.sharedContext.makeGalleryController(
            context: context,
            source: source,
            streamSingleVideo: true,
            isPreview: false
        )
        context.sharedContext.applicationBindings.getWindowHost()?.present(gallery, on: .root, blockInteraction: false, completion: {})
    }

    private func applyFocusMode(_ enabled: Bool, transition: ContainedViewLayoutTransition) {
        self.isFocusMode = enabled
        if !self.updateFocusOverlay(enabled: enabled, transition: transition) {
            self.isFocusMode = false
            let _ = self.updateFocusOverlay(enabled: false, transition: .immediate)
        }
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout: layout, transition: transition)
        }
    }

    @discardableResult
    private func updateFocusOverlay(enabled: Bool, transition: ContainedViewLayoutTransition) -> Bool {
        self.playerNode.setFocusMode(enabled)

        if enabled {
            guard let windowScene = self.currentWindowScene() else {
                return false
            }
            let overlay: MediaBrowserFocusOverlay
            if let current = self.focusOverlay {
                overlay = current
            } else {
                overlay = MediaBrowserFocusOverlay(windowScene: windowScene)
                self.focusOverlay = overlay
            }
            if let detachedOverlay = Self.detachedFocusOverlay, detachedOverlay !== overlay {
                detachedOverlay.hide()
            }
            Self.detachedFocusOverlay = overlay
            self.playerNode.removeFromSupernode()
            overlay.show(playerNode: self.playerNode, transition: transition)
        } else {
            self.focusOverlay?.hide()
            if Self.detachedFocusOverlay === self.focusOverlay {
                Self.detachedFocusOverlay = nil
            }
            if self.playerNode.supernode !== self.contentNode {
                self.playerNode.removeFromSupernode()
                self.contentNode.addSubnode(self.playerNode)
            }
            self.focusOverlay = nil
        }
        return true
    }

    private static let defaultDevelopmentOnTVSyncEndpoint = "http://192.168.1.76:4010"
    private static let defaultDevelopmentOnTVSyncToken = "dev-local-token"
    private static let defaultProductionOnTVSyncEndpoint = "https://multigram-sync-layer.onrender.com"

    private static func onTVSyncConfiguration() -> (endpoint: URL?, authToken: String?) {
        let endpointKeys = ["MultigramOnTVSyncEndpoint", "PlayGramOnTVSyncEndpoint"]
        let tokenKeys = ["MultigramOnTVSyncToken", "PlayGramOnTVSyncToken"]
        let arguments = ProcessInfo.processInfo.arguments
        var didUpdateDefaults = false
        var launchAuthToken: String?
        var didPassAuthTokenArgument = false

        for key in endpointKeys {
            if let value = Self.launchArgumentValue(named: key, arguments: arguments), !value.isEmpty {
                UserDefaults.standard.set(value, forKey: "MultigramOnTVSyncEndpoint")
                UserDefaults.standard.set(value, forKey: "PlayGramOnTVSyncEndpoint")
                didUpdateDefaults = true
            }
        }
        for key in tokenKeys {
            if let value = Self.launchArgumentValue(named: key, arguments: arguments) {
                didPassAuthTokenArgument = true
                if Self.shouldClearLaunchValue(value) {
                    UserDefaults.standard.removeObject(forKey: "MultigramOnTVSyncToken")
                    UserDefaults.standard.removeObject(forKey: "PlayGramOnTVSyncToken")
                    launchAuthToken = nil
                } else if !value.isEmpty {
                    UserDefaults.standard.set(value, forKey: "MultigramOnTVSyncToken")
                    UserDefaults.standard.set(value, forKey: "PlayGramOnTVSyncToken")
                    launchAuthToken = value
                }
                didUpdateDefaults = true
            }
        }
        if didUpdateDefaults {
            UserDefaults.standard.synchronize()
        }

        let endpointString = endpointKeys.compactMap { UserDefaults.standard.string(forKey: $0) }.first
        let storedAuthToken = tokenKeys.compactMap { UserDefaults.standard.string(forKey: $0) }.first
        let authToken = didPassAuthTokenArgument ? launchAuthToken : storedAuthToken

        #if DEBUG
        if ProcessInfo.processInfo.environment["MULTIGRAM_ALLOW_STORED_SYNC_ENDPOINT"] != "1",
           let endpoint = URL(string: Self.defaultDevelopmentOnTVSyncEndpoint) {
            let localAuthToken = authToken ?? Self.defaultDevelopmentOnTVSyncToken
            UserDefaults.standard.set(Self.defaultDevelopmentOnTVSyncEndpoint, forKey: "MultigramOnTVSyncEndpoint")
            UserDefaults.standard.set(Self.defaultDevelopmentOnTVSyncEndpoint, forKey: "PlayGramOnTVSyncEndpoint")
            UserDefaults.standard.set(localAuthToken, forKey: "MultigramOnTVSyncToken")
            UserDefaults.standard.set(localAuthToken, forKey: "PlayGramOnTVSyncToken")
            UserDefaults.standard.synchronize()
            NSLog("[MultigramOnTV] Sync configuration forced local endpoint=%@ tokenPresent=true", endpoint.absoluteString)
            return (endpoint, localAuthToken)
        }
        #endif

        if let endpointString = endpointString, let endpoint = URL(string: endpointString) {
            NSLog("[MultigramOnTV] Sync configuration endpoint=%@ tokenPresent=%@", endpointString, authToken == nil ? "false" : "true")
            return (endpoint, authToken)
        }

        if let defaultConfiguration = Self.defaultOnTVSyncConfiguration(authToken: authToken) {
            NSLog("[MultigramOnTV] Sync configuration default endpoint=%@ tokenPresent=%@", defaultConfiguration.endpoint.absoluteString, defaultConfiguration.authToken == nil ? "false" : "true")
            return defaultConfiguration
        }

        NSLog("[MultigramOnTV] Sync configuration missing endpoint tokenPresent=%@", authToken == nil ? "false" : "true")
        return (nil, authToken)
    }

    private static func defaultOnTVSyncConfiguration(authToken: String?) -> (endpoint: URL, authToken: String?)? {
        #if DEBUG
        guard let endpoint = URL(string: Self.defaultDevelopmentOnTVSyncEndpoint) else {
            return nil
        }
        return (endpoint, authToken ?? Self.defaultDevelopmentOnTVSyncToken)
        #else
        guard let endpoint = URL(string: Self.defaultProductionOnTVSyncEndpoint) else {
            return nil
        }
        return (endpoint, authToken)
        #endif
    }

    private static func syncTokenService(configuration: (endpoint: URL?, authToken: String?), accountPeerId: EnginePeer.Id) -> OnTVSyncTokenService? {
        guard
            configuration.authToken == nil,
            let endpoint = configuration.endpoint
        else {
            return nil
        }
        return OnTVSyncTokenService(syncEndpoint: endpoint, telegramUserId: String(accountPeerId.toInt64()))
    }

    private static func launchArgumentValue(named name: String, arguments: [String]) -> String? {
        let dashName = "-\(name)"
        for index in arguments.indices {
            let argument = arguments[index]
            if argument == dashName {
                let valueIndex = arguments.index(after: index)
                guard valueIndex < arguments.endIndex else {
                    return nil
                }
                return arguments[valueIndex]
            }
            let prefix = "\(dashName)="
            if argument.hasPrefix(prefix) {
                return String(argument.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func shouldClearLaunchValue(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "__clear__" || normalized == "none" || normalized == "null"
    }

    private func currentPulseItem() -> MediaBrowserItem? {
        if let displayedItem = self.playerNode.displayedItem {
            return displayedItem
        }
        if let currentItemIndex = self.currentItemIndex, currentItemIndex >= 0, currentItemIndex < self.loadedItems.count {
            let item = self.loadedItems[currentItemIndex]
            self.showItem(item)
            self.listNode.setSelectedItemIndex(currentItemIndex)
            return item
        }
        if let firstItem = self.loadedItems.first {
            self.currentItemIndex = 0
            self.showItem(firstItem)
            self.listNode.setSelectedItemIndex(0)
            return firstItem
        }
        self.onTVListNode.showNotice("Сначала выбери файл")
        return nil
    }

    private func showItem(_ item: MediaBrowserItem, explicitPosition: Double? = nil) {
        let savedProgress = self.playbackProgressStore.progress(for: item)
        if let explicitPosition = explicitPosition {
            self.playerNode.showItem(item, seekTo: explicitPosition)
            self.listNode.updatePlaybackProgress(for: item, progress: savedProgress?.progress ?? 0.0)
            return
        }

        self.playerNode.showItem(item, seekTo: savedProgress?.position)
        self.listNode.updatePlaybackProgress(for: item, progress: savedProgress?.progress ?? 0.0)
    }

    private func flushCurrentLocalProgress(endedAt: Date? = nil) {
        self.onTVSessionCoordinator.flushLocalProgress(
            displayedItem: self.playerNode.displayedItem,
            position: self.playerNode.currentPlaybackPosition(),
            progress: self.playerNode.currentPlaybackProgress(),
            endedAt: endedAt
        )
    }

    private func stopActiveOnTVSessionForExit() {
        self.onTVSessionCoordinator.stopActiveSessionForExit(
            displayedItem: self.playerNode.displayedItem,
            position: self.playerNode.currentPlaybackPosition(),
            progress: self.playerNode.currentPlaybackProgress()
        )
    }

    private func updateSharedOnTVLiveStatus() {
        let hasLiveSession = self.currentOnTVSessions.contains(where: { $0.status == .live }) || self.currentUnresolvedOnTVSessions.contains(where: { $0.status == .live })
        MediaBrowserOnTVStatusRegistry.shared.update(peerId: self.peerId, isLive: hasLiveSession)
    }

    private func scheduleProgressRecordsReload(immediate: Bool = false) {
        self.reloadVisibleProgressRecords()
    }

    private func reloadVisibleProgressRecords() {
        self.listNode.mergePlaybackProgress(self.playbackProgressStore.progressMap(for: self.loadedItems))
    }

    private func navigateNeighbor(_ offset: Int) {
        guard let idx = self.currentItemIndex else { return }
        let newIdx = idx + offset
        guard newIdx >= 0, newIdx < self.loadedItems.count else { return }
        let shouldCarryPulse = self.onTVSessionCoordinator.prepareForLocalItemChange(
            isPulseActive: self.playerNode.isPulseActive(),
            displayedItem: self.playerNode.displayedItem,
            position: self.playerNode.currentPlaybackPosition(),
            progress: self.playerNode.currentPlaybackProgress()
        )
        let nextItem = self.loadedItems[newIdx]
        self.currentItemIndex = newIdx
        self.showItem(nextItem, explicitPosition: shouldCarryPulse ? 0.0 : nil)
        self.listNode.setSelectedItemIndex(newIdx)
        self.recordOpen(target: .file(item: nextItem, chatId: self.peerId))
        if shouldCarryPulse {
            _ = self.onTVSessionCoordinator.startPulse(item: nextItem, position: 0.0, progress: 0.0)
        }
    }

    var onPresentGallery: ((MediaBrowserItem) -> Void)?
    var onShareMessage: ((MediaBrowserItem) -> Void)?
    var onJumpToMessage: ((MediaBrowserItem) -> Void)?
    var onDeleteMessage: ((MediaBrowserItem) -> Void)?
    var onItemLongPressed: ((MediaBrowserItem) -> Void)?
    var onChatLongPressed: ((MediaBrowserChatItem) -> Void)?

    func statisticsServiceForCurrentPeer() -> MediaStatisticsService? {
        return self.statisticsService
    }

    private func recordOpen(target: MediaStatisticsTarget) {
        self.statisticsService?.recordOpen(target: target)
    }

    func applySenderFilter(_ peerId: EnginePeer.Id?, name: String?) {
        self.dataSource.setSenderFilter(peerId)
        self.listNode.refreshSenderFilterTitle(name)
    }

    private func switchToChatPicker() {
        guard self.mode != .chatPicker else { return }
        self.flushCurrentLocalProgress()
        self.stopActiveOnTVSessionForExit()
        self.mode = .chatPicker
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout: layout, transition: .animated(duration: 0.25, curve: .easeInOut))
        }
    }

    private func switchToFiles(peerId: EnginePeer.Id) {
        self.flushCurrentLocalProgress()
        self.onTVSessionCoordinator.switchPeer(peerId)
        self.peerId = peerId
        self.currentItemIndex = nil
        self.loadedItems = []
        self.dataSource.switchPeer(peerId)
        self.mode = .files
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout: layout, transition: .animated(duration: 0.25, curve: .easeInOut))
        }
    }

    private func applyPresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.contentNode.backgroundColor = self.isFocusMode ? .clear : presentationData.theme.list.plainBackgroundColor
        self.playerNode.updatePresentationData(presentationData)
        self.tabBarNode.updatePresentationData(presentationData)
        self.listNode.updatePresentationData(presentationData)
        self.onTVListNode.updatePresentationData(presentationData)
        self.chatListNode.updatePresentationData(presentationData)
    }

    private func setupDimDismiss() {
        self.dimNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTapped)))
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.basePresentationData = presentationData
        self.applyPresentationData(presentationData)
    }

    @objc private func dimTapped() {
        self.flushCurrentLocalProgress()
        self.stopActiveOnTVSessionForExit()
        self.dismiss()
    }

    private func setupDataSource() {
        self.tabBarNode.onTabChanged = { [weak self] filter in
            guard let self = self else { return }
            self.selectedTab = filter
            if filter == .onTV {
                self.onTVSessionCoordinator.reload()
            } else if filter == .pinned {
                self.listNode.setEmptyText("Нет закреплённых файлов")
            } else if filter == .documents {
                self.listNode.setEmptyText("Нет документов")
            } else if filter == .addCustomFilter {
                self.listNode.setEmptyText("Нет пользовательских фильтров")
            } else {
                self.listNode.setEmptyText("Нет медиафайлов")
            }
            if filter != .onTV {
                self.dataSource.switchFilter(filter)
            }
            if let layout = self.validLayout {
                self.containerLayoutUpdated(layout: layout, transition: .animated(duration: 0.2, curve: .easeInOut))
            }
        }

        self.dataSource.onItemsUpdated = { [weak self] items in
            guard let self = self else { return }
            self.loadedItems = items
            self.onTVSessionCoordinator.registerLoadedItems(items)
            self.listNode.updateItems(items)
            self.listNode.mergePlaybackProgress(self.playbackProgressStore.progressMap(for: items))
            self.listNode.setAvailableSenders(self.dataSource.uniqueSenders())
            if !self.didApplyInitialSelection, let initialMessageId = self.initialMessageId, let initialIndex = items.firstIndex(where: { $0.messageId == initialMessageId }) {
                self.didApplyInitialSelection = true
                self.currentItemIndex = initialIndex
                self.showItem(items[initialIndex], explicitPosition: self.initialPosition)
            } else if let displayedItem = self.playerNode.displayedItem {
                self.didApplyInitialSelection = true
                self.currentItemIndex = items.firstIndex(where: { $0.messageId == displayedItem.messageId })
            } else if let currentItemIndex = self.currentItemIndex, currentItemIndex >= 0, currentItemIndex < items.count {
                self.didApplyInitialSelection = true
                self.showItem(items[currentItemIndex])
            } else if let first = items.first {
                self.didApplyInitialSelection = true
                self.currentItemIndex = 0
                self.showItem(first)
            } else {
                self.currentItemIndex = nil
            }
            self.listNode.setSelectedItemIndex(self.currentItemIndex)
        }

        self.dataSource.onLoadingStateChanged = { [weak self] state in
            guard let self = self else { return }
            self.mediaLoadingState = state
            self.listNode.updateLoadingState(state)
            self.flushPendingOnTVResolverLoad()
        }

        self.onTVSessionCoordinator.onSessionsUpdated = { [weak self] sessions in
            guard let self = self else { return }
            self.currentOnTVSessions = sessions
            self.updateSharedOnTVLiveStatus()
            self.playbackProgressStore.update(sessions: sessions)
            self.onTVListNode.updateSessions(sessions)
            self.listNode.mergePlaybackProgress(self.playbackProgressStore.progressMap(for: self.loadedItems))
            self.autoOpenRemoteLiveSessionIfNeeded(sessions)
        }
        self.onTVSessionCoordinator.onUnresolvedSessionsUpdated = { [weak self] sessions in
            guard let self = self else { return }
            self.currentUnresolvedOnTVSessions = sessions
            self.updateSharedOnTVLiveStatus()
            self.onTVListNode.updateUnresolvedSessions(sessions)
        }
        self.onTVSessionCoordinator.onResolvingSessionsChanged = { [weak self] isResolving in
            self?.onTVListNode.updateResolvingSessions(isResolving)
        }
        self.onTVSessionCoordinator.onResolveMediaItems = { [weak self] messageIds in
            guard let self = self else { return }
            self.dataSource.loadItems(messageIds: messageIds, completion: { [weak self] items in
                self?.onTVSessionCoordinator.registerLoadedItems(items)
            })
        }
        self.onTVSessionCoordinator.onNeedsMoreMediaItems = { [weak self] in
            self?.requestMoreMediaForOnTVHydration()
        }
        self.onTVSessionCoordinator.onActiveHeldSessionChanged = { [weak self] sessionId in
            self?.onTVListNode.updateActiveSessionId(sessionId)
        }
        self.onTVSessionCoordinator.onPulseActiveChanged = { [weak self] isActive, animated in
            guard let self = self else { return }
            if isActive {
                MediaBrowserOnTVStatusRegistry.shared.update(peerId: self.peerId, isLive: true)
            }
            self.playerNode.setPulseActive(isActive, animated: animated)
        }
        self.onTVSessionCoordinator.onAudienceChanged = { [weak self] participantCount in
            self?.playerNode.updateSessionAudience(participantCount: participantCount)
        }
        self.onTVSessionCoordinator.onFlashLockedSession = { [weak self] sessionId in
            self?.onTVListNode.flashLockedSession(sessionId)
        }
        self.onTVSessionCoordinator.onShowNotice = { [weak self] text in
            self?.onTVListNode.showNotice(text)
        }
        self.onTVSessionCoordinator.onOpenSession = { [weak self] context, _ in
            guard let self = self else { return }
            self.currentItemIndex = self.loadedItems.firstIndex(where: { $0.messageId == context.fileId })
            self.showItem(context.item, explicitPosition: context.position)
            self.listNode.setSelectedItemIndex(self.currentItemIndex)
        }
        self.onTVSessionCoordinator.onApplyRemotePlaybackAction = { [weak self] position, progress, isPlaying in
            self?.playerNode.applyRemotePlaybackAction(position: position, progress: progress, isPlaying: isPlaying)
        }
        self.onTVSessionCoordinator.onApplyRemotePlaybackState = { [weak self] position, progress in
            self?.playerNode.applyRemotePlaybackState(position: position, progress: progress)
        }
        self.onTVSessionCoordinator.onLocalProgressSaved = { [weak self] in
            self?.scheduleProgressRecordsReload()
        }
        self.onTVSessionCoordinator.currentPlaybackState = { [weak self] in
            guard let self = self else {
                return (position: 0.0, progress: 0.0)
            }
            return (
                position: self.playerNode.currentPlaybackPosition(),
                progress: self.playerNode.currentPlaybackProgress()
            )
        }
        self.onTVSessionCoordinator.currentPlaybackIsPlaying = { [weak self] in
            return self?.playerNode.isPlaybackActive() ?? false
        }
        self.onTVSessionCoordinator.currentDisplayedItem = { [weak self] in
            return self?.playerNode.displayedItem
        }

        self.listNode.onNearEnd = { [weak self] in
            self?.dataSource.loadNextBatch()
        }

        self.listNode.onRetry = { [weak self] in
            self?.dataSource.loadNextBatch()
        }

        self.listNode.onItemSelected = { [weak self] item in
            guard let self = self else { return }
            let shouldCarryPulse = self.onTVSessionCoordinator.prepareForLocalItemChange(
                isPulseActive: self.playerNode.isPulseActive(),
                displayedItem: self.playerNode.displayedItem,
                position: self.playerNode.currentPlaybackPosition(),
                progress: self.playerNode.currentPlaybackProgress()
            )
            self.currentItemIndex = self.loadedItems.firstIndex(where: { $0.messageId == item.messageId })
            self.showItem(item, explicitPosition: shouldCarryPulse ? 0.0 : nil)
            self.listNode.setSelectedItemIndex(self.currentItemIndex)
            self.recordOpen(target: .file(item: item, chatId: self.peerId))
            if shouldCarryPulse {
                _ = self.onTVSessionCoordinator.startPulse(item: item, position: 0.0, progress: 0.0)
            }
        }
        self.listNode.onItemLongPressed = { [weak self] item in
            self?.onItemLongPressed?(item)
        }
        self.listNode.onResetSenderFilter = { [weak self] in
            self?.applySenderFilter(nil, name: nil)
        }
        self.listNode.onSelectSender = { [weak self] sender in
            self?.applySenderFilter(sender.peerId, name: sender.name)
        }

        self.onTVListNode.onSessionSelected = { [weak self] session in
            guard let self = self else { return }
            self.recordOpen(target: .file(item: session.item, chatId: session.chatId))
            self.onTVSessionCoordinator.activateSession(
                session,
                displayedItem: self.playerNode.displayedItem,
                position: self.playerNode.currentPlaybackPosition(),
                progress: self.playerNode.currentPlaybackProgress()
            )
        }

        self.tabBarNode.setSelectedTab(self.selectedTab)
        if self.selectedTab == .allFiles || self.selectedTab == .onTV || self.selectedTab == .addCustomFilter {
            self.dataSource.loadInitialBatch()
        } else {
            self.dataSource.switchFilter(self.selectedTab)
        }
    }

    private func requestMoreMediaForOnTVHydration() {
        self.pendingOnTVResolverLoad = true
        self.flushPendingOnTVResolverLoad()
    }

    private func flushPendingOnTVResolverLoad() {
        guard self.pendingOnTVResolverLoad else { return }
        guard case .idle = self.mediaLoadingState else { return }
        self.pendingOnTVResolverLoad = false
        self.dataSource.loadNextBatch()
    }

    private func autoOpenRemoteLiveSessionIfNeeded(_ sessions: [OnTVPlaybackContext]) {
        guard let session = sessions.first(where: { context in
            guard context.status == .live, let pulseUserId = context.pulseUserId else {
                return false
            }
            return pulseUserId != self.context.account.peerId
        }) else {
            self.autoOpenedRemoteOnTVSessionId = nil
            return
        }
        guard self.autoOpenedRemoteOnTVSessionId != session.sessionId else {
            return
        }
        guard !self.playerNode.isPulseActive() else {
            return
        }
        self.autoOpenedRemoteOnTVSessionId = session.sessionId
        NSLog("[MultigramOnTV] Auto opening remote live sessionId=%@ pulseUserId=%lld", session.sessionId, session.pulseUserId?.toInt64() ?? 0)
        self.onTVSessionCoordinator.activateSession(
            session,
            displayedItem: self.playerNode.displayedItem,
            position: self.playerNode.currentPlaybackPosition(),
            progress: self.playerNode.currentPlaybackProgress()
        )
    }

    func containerLayoutUpdated(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.validLayout = layout

        let bounds = CGRect(origin: .zero, size: layout.size)
        transition.updateFrame(node: self.dimNode, frame: bounds)
        transition.updateAlpha(node: self.dimNode, alpha: self.isFocusMode ? 0.0 : 0.4)
        self.dimNode.backgroundColor = UIColor.black

        let isChatPicker = self.mode == .chatPicker
        let showLibrary = self.isLibraryVisible || isChatPicker
        let horizontalPadding: CGFloat = self.isFocusMode ? 0.0 : 16.0
        let expandedTopPadding: CGFloat = max(layout.safeInsets.top + 92.0, 132.0)
        let expandedBottomPadding: CGFloat = max(layout.safeInsets.bottom + 12.0, 20.0)
        let cornerRadius: CGFloat = self.isFocusMode ? 0.0 : Self.windowCornerRadius
        transition.updateCornerRadius(node: self.contentNode, cornerRadius: cornerRadius)
        if #available(iOS 13.0, *) {
            self.contentNode.layer.cornerCurve = .continuous
        }
        let contentFrame: CGRect
        if self.isFocusMode {
            contentFrame = CGRect(origin: .zero, size: layout.size)
        } else if showLibrary {
            contentFrame = CGRect(
                x: horizontalPadding,
                y: expandedTopPadding,
                width: layout.size.width - horizontalPadding * 2.0,
                height: max(0.0, layout.size.height - expandedTopPadding - expandedBottomPadding)
            )
        } else {
            let compactWidth = layout.size.width - horizontalPadding * 2.0
            let compactHeight = min(270.0, max(196.0, floor(compactWidth * 0.56)))
            let compactY = max(layout.safeInsets.top + 64.0, 92.0)
            contentFrame = CGRect(
                x: horizontalPadding,
                y: compactY,
                width: compactWidth,
                height: compactHeight
            )
        }
        transition.updateFrame(node: self.contentNode, frame: contentFrame)
        self.contentNode.backgroundColor = self.isFocusMode ? .clear : self.presentationData.theme.list.plainBackgroundColor
        self.contentNode.clipsToBounds = !self.isFocusMode

        let listVisible = showLibrary && !self.isExpanded && !self.isFocusMode && !isChatPicker
        let onTVVisible = listVisible && self.selectedTab == .onTV
        let mediaListVisible = listVisible && self.selectedTab != .onTV
        let tabBarHeight: CGFloat = 44.0

        let playerFrame: CGRect
        if isChatPicker {
            playerFrame = .zero
        } else if self.isFocusMode {
            playerFrame = .zero
        } else if listVisible {
            playerFrame = CGRect(x: 0, y: 0, width: contentFrame.width, height: contentFrame.height * 0.35)
        } else {
            playerFrame = CGRect(x: 0, y: 0, width: contentFrame.width, height: contentFrame.height)
        }
        if self.isFocusMode {
            self.focusOverlay?.updateLayout(transition: transition)
        } else {
            self.playerNode.setAttachedToLibrary(listVisible)
            transition.updateFrame(node: self.playerNode, frame: playerFrame)
            self.playerNode.updateLayout(size: playerFrame.size, safeInsets: .zero, transition: transition)
            transition.updateAlpha(node: self.playerNode, alpha: isChatPicker ? 0.0 : 1.0)
        }

        if let touchView = self.view as? TouchBlockingView {
            touchView.passThroughAllTouches = self.isFocusMode
            touchView.passThroughOutsideFrame = nil
        }

        let playerHeight = playerFrame.height
        let tabBarFrame = CGRect(x: 0, y: playerHeight, width: contentFrame.width, height: tabBarHeight)
        transition.updateFrame(node: self.tabBarNode, frame: tabBarFrame)
        self.tabBarNode.updateLayout(width: contentFrame.width, transition: transition)
        self.tabBarNode.isHidden = !listVisible
        transition.updateAlpha(node: self.tabBarNode, alpha: listVisible ? 1.0 : 0.0)

        let listTop = playerHeight + tabBarHeight
        let listFrame = CGRect(x: 0, y: listTop, width: contentFrame.width, height: max(0.0, contentFrame.height - listTop))
        transition.updateFrame(node: self.listNode, frame: listFrame)
        self.listNode.updateLayout(size: listFrame.size, transition: transition)
        self.listNode.isHidden = !mediaListVisible
        transition.updateAlpha(node: self.listNode, alpha: mediaListVisible ? 1.0 : 0.0)

        transition.updateFrame(node: self.onTVListNode, frame: listFrame)
        self.onTVListNode.updateLayout(size: listFrame.size, transition: transition)
        self.onTVListNode.isHidden = !onTVVisible
        transition.updateAlpha(node: self.onTVListNode, alpha: onTVVisible ? 1.0 : 0.0)

        let chatListFrame = CGRect(origin: .zero, size: contentFrame.size)
        transition.updateFrame(node: self.chatListNode, frame: chatListFrame)
        self.chatListNode.updateLayout(size: contentFrame.size, transition: transition)
        self.chatListNode.isHidden = !isChatPicker
        transition.updateAlpha(node: self.chatListNode, alpha: isChatPicker ? 1.0 : 0.0)
    }
}
