import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext

public enum MediaBrowserTab: Int, CaseIterable {
    case allFiles
    case pinned
    case onTV
    case video
    case photo
    case audio

    var title: String {
        switch self {
        case .allFiles: return "Все файлы"
        case .pinned: return "Закреп"
        case .onTV: return "На телике"
        case .video: return "Видео"
        case .photo: return "Фото"
        case .audio: return "Аудио"
        }
    }
}

public enum MediaBrowserLoadingState: Equatable {
    case idle
    case loading
    case error(String)
    case exhausted
}

public struct MediaBrowserItem {
    public let messageId: EngineMessage.Id
    public let fileName: String
    public let senderName: String
    public let timestamp: Int32
    public let fileSize: Int64
    public let mediaType: MediaBrowserMediaType
    public let message: Message
}

public enum MediaBrowserMediaType {
    case photo
    case video
    case file
    case audio
}

final class MediaBrowserDataSource {
    private let context: AccountContext
    private var peerId: EnginePeer.Id
    private let pageSize: Int = 20

    private var currentFilter: MediaBrowserTab = .allFiles
    private var items: [MediaBrowserItem] = []
    private var rawItems: [MediaBrowserItem] = []
    private var senderFilter: EnginePeer.Id?
    private var loadingState: MediaBrowserLoadingState = .idle
    private var lastSearchState: SearchMessagesState?
    private var disposable = MetaDisposable()

    var onItemsUpdated: (([MediaBrowserItem]) -> Void)?
    var onLoadingStateChanged: ((MediaBrowserLoadingState) -> Void)?

    func setSenderFilter(_ peerId: EnginePeer.Id?) {
        self.senderFilter = peerId
        self.applySenderFilter()
    }

    private func applySenderFilter() {
        if let senderId = self.senderFilter {
            self.items = self.rawItems.filter { $0.message.author?.id == senderId }
        } else {
            self.items = self.rawItems
        }
        self.onItemsUpdated?(self.items)
    }

    func uniqueSenders() -> [SenderInfo] {
        var seen = Set<EnginePeer.Id>()
        var result: [SenderInfo] = []
        for item in self.rawItems {
            guard let author = item.message.author else { continue }
            if seen.insert(author.id).inserted {
                var username: String? = nil
                if let user = author as? TelegramUser {
                    username = user.username
                }
                result.append(SenderInfo(peerId: author.id, name: item.senderName, username: username, peer: EnginePeer(author)))
            }
        }
        return result
    }

    init(context: AccountContext, peerId: EnginePeer.Id) {
        self.context = context
        self.peerId = peerId
    }

    deinit {
        self.disposable.dispose()
    }

    func switchFilter(_ filter: MediaBrowserTab) {
        self.currentFilter = filter
        self.items = []
        self.rawItems = []
        self.lastSearchState = nil
        self.loadingState = .idle
        self.onItemsUpdated?(self.items)
        self.loadInitialBatch()
    }

    func switchPeer(_ newPeerId: EnginePeer.Id) {
        guard newPeerId != self.peerId else { return }
        self.peerId = newPeerId
        self.items = []
        self.rawItems = []
        self.lastSearchState = nil
        self.loadingState = .idle
        self.disposable.set(nil)
        self.onItemsUpdated?(self.items)
        self.loadInitialBatch()
    }

    func loadInitialBatch() {
        self.items = []
        self.rawItems = []
        self.lastSearchState = nil
        self.load()
    }

    func loadNextBatch() {
        guard case .idle = self.loadingState, self.lastSearchState != nil else { return }
        self.load()
    }

    private func load() {
        self.loadingState = .loading
        self.onLoadingStateChanged?(self.loadingState)

        let tagList = self.messageTagsList(for: self.currentFilter)
        if tagList.count <= 1 {
            self.loadSingle(tag: tagList.first ?? nil)
        } else {
            self.loadParallel(tags: tagList.compactMap { $0 })
        }
    }

    private func loadSingle(tag: MessageTags?) {
        let signal = self.context.engine.messages.searchMessages(
            location: .peer(peerId: self.peerId, fromId: nil, tags: tag, reactions: nil, threadId: nil, minDate: nil, maxDate: nil),
            query: "",
            state: self.lastSearchState,
            limit: Int32(self.pageSize)
        )

        let deliveredSignal: Signal<(SearchMessagesResult, SearchMessagesState), NoError> = signal |> deliverOnMainQueue
        self.disposable.set(deliveredSignal.startStrict(next: { [weak self] result, state in
                guard let self = self else { return }
                let allItems = result.messages.compactMap { self.mapMessage($0) }

                self.lastSearchState = state

                if allItems.count <= self.rawItems.count && !self.rawItems.isEmpty {
                    self.loadingState = .exhausted
                } else {
                    self.rawItems = allItems
                    self.applySenderFilter()
                    self.loadingState = result.completed ? .exhausted : .idle
                }

                self.onLoadingStateChanged?(self.loadingState)
            }))
    }

    private func loadParallel(tags: [MessageTags]) {
        let signals: [Signal<SearchMessagesResult, NoError>] = tags.map { tag in
            self.context.engine.messages.searchMessages(
                location: .peer(peerId: self.peerId, fromId: nil, tags: tag, reactions: nil, threadId: nil, minDate: nil, maxDate: nil),
                query: "",
                state: nil,
                limit: Int32(self.pageSize)
            )
            |> map { result, _ in result }
        }
        let combined = combineLatest(signals) |> deliverOnMainQueue
        self.disposable.set(combined.startStrict(next: { [weak self] results in
            guard let self = self else { return }
            var seenIds = Set<EngineMessage.Id>()
            var allMessages: [Message] = []
            for result in results {
                for message in result.messages {
                    if seenIds.insert(message.id).inserted {
                        allMessages.append(message)
                    }
                }
            }
            let sorted = allMessages.sorted { $0.timestamp > $1.timestamp }
            self.rawItems = sorted.compactMap { self.mapMessage($0) }
            self.applySenderFilter()
            self.lastSearchState = nil
            self.loadingState = .exhausted
            self.onLoadingStateChanged?(self.loadingState)
        }))
    }

    private func messageTagsList(for tab: MediaBrowserTab) -> [MessageTags?] {
        switch tab {
        case .allFiles: return [.photoOrVideo, .file, .music, .voiceOrInstantVideo]
        case .photo: return [.photo]
        case .video: return [.video]
        case .audio: return [.music]
        case .pinned: return [nil]
        case .onTV: return [.video]
        }
    }

    private func mapMessage(_ message: Message) -> MediaBrowserItem? {
        var fileName = ""
        var fileSize: Int64 = 0
        var mediaType: MediaBrowserMediaType = .file
        var foundMedia = false

        for media in message.media {
            if let file = media as? TelegramMediaFile {
                fileName = file.fileName ?? ""
                fileSize = file.size ?? 0
                if file.isVideo {
                    mediaType = .video
                } else if file.isMusic || file.isVoice {
                    mediaType = .audio
                } else {
                    mediaType = .file
                }
                foundMedia = true
                break
            } else if media is TelegramMediaImage {
                fileName = "Photo"
                mediaType = .photo
                foundMedia = true
                break
            }
        }

        guard foundMedia else { return nil }

        let senderName: String
        if let author = message.author {
            if let user = author as? TelegramUser {
                senderName = [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
            } else {
                senderName = author.debugDisplayTitle
            }
        } else {
            senderName = ""
        }

        return MediaBrowserItem(
            messageId: message.id,
            fileName: fileName,
            senderName: senderName,
            timestamp: message.timestamp,
            fileSize: fileSize,
            mediaType: mediaType,
            message: message
        )
    }
}
