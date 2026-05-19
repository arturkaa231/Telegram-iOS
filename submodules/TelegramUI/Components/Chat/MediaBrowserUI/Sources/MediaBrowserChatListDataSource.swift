import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

public enum MediaBrowserChatCategory: Int, CaseIterable {
    case personal
    case groups
    case channels

    var title: String {
        switch self {
        case .personal: return "Личные чаты"
        case .groups: return "Группы"
        case .channels: return "Каналы"
        }
    }
}

public struct MediaBrowserChatItem {
    public let peerId: EnginePeer.Id
    public let peer: EnginePeer
    public let title: String
    public let recentMessageWithMedia: EngineMessage?
}

final class MediaBrowserChatListDataSource {
    private let context: AccountContext
    private let pageSize: Int = 200

    private var allItems: [MediaBrowserChatItem] = []
    private var currentCategory: MediaBrowserChatCategory = .personal
    private var disposable = MetaDisposable()

    var onItemsUpdated: (([MediaBrowserChatItem]) -> Void)?

    init(context: AccountContext) {
        self.context = context
    }

    deinit {
        self.disposable.dispose()
    }

    func switchCategory(_ category: MediaBrowserChatCategory) {
        self.currentCategory = category
        self.emitFiltered()
    }

    func load() {
        let signal = self.context.engine.messages.chatList(group: .root, count: self.pageSize)
            |> deliverOnMainQueue
        self.disposable.set(signal.startStrict(next: { [weak self] chatList in
            guard let self = self else { return }
            let sortedItems = chatList.items.sorted { $0.index > $1.index }
            self.allItems = sortedItems.compactMap { item -> MediaBrowserChatItem? in
                guard let peer = item.renderedPeer.peer else { return nil }
                let recentMedia = item.messages.first { msg in
                    msg.media.contains { m in
                        m is TelegramMediaImage || (m as? TelegramMediaFile) != nil
                    }
                }
                return MediaBrowserChatItem(
                    peerId: peer.id,
                    peer: peer,
                    title: peer.compactDisplayTitle,
                    recentMessageWithMedia: recentMedia
                )
            }
            self.emitFiltered()
        }))
    }

    private func emitFiltered() {
        let filtered = self.allItems.filter { matches(category: self.currentCategory, peer: $0.peer) }
        self.onItemsUpdated?(filtered)
    }

    private func matches(category: MediaBrowserChatCategory, peer: EnginePeer) -> Bool {
        switch category {
        case .personal:
            if case let .user(user) = peer {
                return !(user.botInfo != nil)
            }
            return false
        case .groups:
            if case .legacyGroup = peer { return true }
            if case let .channel(channel) = peer, case .group = channel.info { return true }
            return false
        case .channels:
            if case let .channel(channel) = peer, case .broadcast = channel.info { return true }
            return false
        }
    }
}
