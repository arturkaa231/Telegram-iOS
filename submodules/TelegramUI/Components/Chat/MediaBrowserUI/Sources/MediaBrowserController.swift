import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import ShareController

public final class MediaBrowserController: ViewController {
    private let context: AccountContext
    private var peerId: EnginePeer.Id

    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    public var dismissed: (() -> Void)?
    public var onJumpToMessageRequested: ((EngineMessage.Id) -> Void)?

    public init(context: AccountContext, peerId: EnginePeer.Id) {
        self.context = context
        self.peerId = peerId
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
        node.onItemLongPressed = { [weak self] item in
            self?.showLongPressMenu(for: item)
        }
        self.displayNode = node
        self.displayNodeDidLoad()
    }

    private func showLongPressMenu(for item: MediaBrowserItem) {
        let isDualScenario = item.message.media.contains { media in
            if let file = media as? TelegramMediaFile {
                if file.mimeType == "application/pdf" { return true }
                if let name = file.fileName?.lowercased(), name.hasSuffix(".pdf") || name.hasSuffix(".epub") { return true }
            }
            return false
        }
        guard isDualScenario else { return }
        let alert = UIAlertController(title: item.fileName, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Открыть в PDF-плеере", style: .default, handler: { [weak self] _ in
            self?.presentGallery(for: item)
        }))
        alert.addAction(UIAlertAction(title: "Открыть в читалке", style: .default, handler: { _ in }))
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
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
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.disablesInteractiveTransitionGestureRecognizer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result ?? self
    }
}

final class MediaBrowserControllerNode: ASDisplayNode {
    private let context: AccountContext
    private var peerId: EnginePeer.Id
    private var presentationData: PresentationData
    private let dismiss: () -> Void

    private let dimNode: ASDisplayNode
    private let contentNode: ASDisplayNode
    private let playerNode: MediaBrowserPlayerNode
    private let tabBarNode: MediaBrowserTabBarNode
    private let listNode: MediaBrowserListNode
    private let chatListNode: MediaBrowserChatListNode

    private let dataSource: MediaBrowserDataSource

    private var validLayout: ContainerViewLayout?
    private var isExpanded: Bool = false
    private var basePresentationData: PresentationData
    private var mode: Mode
    private var loadedItems: [MediaBrowserItem] = []
    private var currentItemIndex: Int?

    enum Mode {
        case files
        case chatPicker
    }

    init(context: AccountContext, peerId: EnginePeer.Id, presentationData: PresentationData, dismiss: @escaping () -> Void) {
        self.context = context
        self.peerId = peerId
        self.presentationData = presentationData
        self.basePresentationData = presentationData
        self.dismiss = dismiss
        self.mode = .files

        self.dimNode = ASDisplayNode()
        self.dimNode.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        self.contentNode = ASDisplayNode()
        self.contentNode.backgroundColor = presentationData.theme.list.plainBackgroundColor
        self.contentNode.cornerRadius = 16.0
        self.contentNode.clipsToBounds = true

        self.playerNode = MediaBrowserPlayerNode(context: context, presentationData: presentationData)

        self.dataSource = MediaBrowserDataSource(context: context, peerId: peerId)

        var onBackHandlerPlaceholder: (() -> Void)?
        self.tabBarNode = MediaBrowserTabBarNode(presentationData: presentationData, onBack: { onBackHandlerPlaceholder?() })

        self.listNode = MediaBrowserListNode(context: context, presentationData: presentationData)
        self.chatListNode = MediaBrowserChatListNode(context: context, presentationData: presentationData)

        super.init()

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
        self.contentNode.addSubnode(self.chatListNode)
        self.chatListNode.isHidden = true

        self.chatListNode.onItemSelected = { [weak self] item in
            self?.switchToFiles(peerId: item.peerId)
        }

        self.setupDimDismiss()
        self.setupDataSource()

        self.playerNode.onToggleExpanded = { [weak self] in
            guard let self = self else { return }
            self.isExpanded.toggle()
            if let layout = self.validLayout {
                self.containerLayoutUpdated(layout: layout, transition: .animated(duration: 0.3, curve: .easeInOut))
            }
        }
        self.playerNode.onPresentGallery = { [weak self] item in
            self?.onPresentGallery?(item)
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
    }

    private func navigateNeighbor(_ offset: Int) {
        guard let idx = self.currentItemIndex else { return }
        let newIdx = idx + offset
        guard newIdx >= 0, newIdx < self.loadedItems.count else { return }
        self.currentItemIndex = newIdx
        self.playerNode.showItem(self.loadedItems[newIdx])
        self.listNode.setSelectedItemIndex(newIdx)
    }

    var onPresentGallery: ((MediaBrowserItem) -> Void)?
    var onShareMessage: ((MediaBrowserItem) -> Void)?
    var onJumpToMessage: ((MediaBrowserItem) -> Void)?
    var onDeleteMessage: ((MediaBrowserItem) -> Void)?
    var onItemLongPressed: ((MediaBrowserItem) -> Void)?

    func applySenderFilter(_ peerId: EnginePeer.Id?, name: String?) {
        self.dataSource.setSenderFilter(peerId)
        self.listNode.refreshSenderFilterTitle(name)
    }

    private func switchToChatPicker() {
        guard self.mode != .chatPicker else { return }
        self.mode = .chatPicker
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout: layout, transition: .animated(duration: 0.25, curve: .easeInOut))
        }
    }

    private func switchToFiles(peerId: EnginePeer.Id) {
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
        self.contentNode.backgroundColor = presentationData.theme.list.plainBackgroundColor
        self.playerNode.updatePresentationData(presentationData)
        self.tabBarNode.updatePresentationData(presentationData)
        self.listNode.updatePresentationData(presentationData)
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
        self.dismiss()
    }

    private func setupDataSource() {
        self.tabBarNode.onTabChanged = { [weak self] filter in
            self?.dataSource.switchFilter(filter)
        }

        self.dataSource.onItemsUpdated = { [weak self] items in
            guard let self = self else { return }
            self.loadedItems = items
            self.listNode.updateItems(items)
            self.listNode.setAvailableSenders(self.dataSource.uniqueSenders())
            if self.currentItemIndex == nil, let first = items.first {
                self.currentItemIndex = 0
                self.playerNode.showItem(first)
            } else if let id = self.currentItemIndex, id >= items.count {
                self.currentItemIndex = items.isEmpty ? nil : 0
                if let firstItem = items.first {
                    self.playerNode.showItem(firstItem)
                }
            }
            self.listNode.setSelectedItemIndex(self.currentItemIndex)
        }

        self.dataSource.onLoadingStateChanged = { [weak self] state in
            self?.listNode.updateLoadingState(state)
        }

        self.listNode.onNearEnd = { [weak self] in
            self?.dataSource.loadNextBatch()
        }

        self.listNode.onRetry = { [weak self] in
            self?.dataSource.loadNextBatch()
        }

        self.listNode.onItemSelected = { [weak self] item in
            guard let self = self else { return }
            self.currentItemIndex = self.loadedItems.firstIndex(where: { $0.messageId == item.messageId })
            self.playerNode.showItem(item)
            self.listNode.setSelectedItemIndex(self.currentItemIndex)
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

        self.dataSource.loadInitialBatch()
    }

    func containerLayoutUpdated(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.validLayout = layout

        let bounds = CGRect(origin: .zero, size: layout.size)
        transition.updateFrame(node: self.dimNode, frame: bounds)

        let verticalPadding: CGFloat = 76.0
        let horizontalPadding: CGFloat = 16.0
        let cornerRadius: CGFloat = 16.0
        transition.updateCornerRadius(node: self.contentNode, cornerRadius: cornerRadius)
        let contentFrame = CGRect(x: horizontalPadding, y: verticalPadding, width: layout.size.width - horizontalPadding * 2, height: layout.size.height - verticalPadding * 2)
        transition.updateFrame(node: self.contentNode, frame: contentFrame)

        let isChatPicker = self.mode == .chatPicker
        let listVisible = !self.isExpanded && !isChatPicker
        let tabBarHeight: CGFloat = 44.0

        let playerHeight: CGFloat
        if isChatPicker {
            playerHeight = 0.0
        } else if listVisible {
            playerHeight = contentFrame.height * 0.35
        } else {
            playerHeight = contentFrame.height
        }
        let playerFrame = CGRect(x: 0, y: 0, width: contentFrame.width, height: playerHeight)
        transition.updateFrame(node: self.playerNode, frame: playerFrame)
        self.playerNode.updateLayout(size: playerFrame.size, safeInsets: .zero, transition: transition)
        transition.updateAlpha(node: self.playerNode, alpha: isChatPicker ? 0.0 : 1.0)

        let tabBarFrame = CGRect(x: 0, y: playerHeight, width: contentFrame.width, height: tabBarHeight)
        transition.updateFrame(node: self.tabBarNode, frame: tabBarFrame)
        self.tabBarNode.updateLayout(width: contentFrame.width, transition: transition)
        transition.updateAlpha(node: self.tabBarNode, alpha: listVisible ? 1.0 : 0.0)

        let listTop = playerHeight + tabBarHeight
        let listFrame = CGRect(x: 0, y: listTop, width: contentFrame.width, height: max(0.0, contentFrame.height - listTop))
        transition.updateFrame(node: self.listNode, frame: listFrame)
        self.listNode.updateLayout(size: listFrame.size, transition: transition)
        transition.updateAlpha(node: self.listNode, alpha: listVisible ? 1.0 : 0.0)

        let chatListFrame = CGRect(origin: .zero, size: contentFrame.size)
        transition.updateFrame(node: self.chatListNode, frame: chatListFrame)
        self.chatListNode.updateLayout(size: contentFrame.size, transition: transition)
        self.chatListNode.isHidden = !isChatPicker
        transition.updateAlpha(node: self.chatListNode, alpha: isChatPicker ? 1.0 : 0.0)
    }
}
