import Foundation
import UIKit
import TelegramCore

enum OnTVPlaybackStatus {
    case live
    case ended
}

enum OnTVCardVisualStatus {
    case live
    case ended
    case locked
}

struct OnTVPlaybackContext {
    let sessionId: String
    let chatId: EnginePeer.Id
    let fileId: EngineMessage.Id
    var item: MediaBrowserItem
    var position: Double
    var progress: CGFloat
    var pulseUserId: EnginePeer.Id?
    var status: OnTVPlaybackStatus
    var endedAt: Date?
    var participantCount: Int

    func visualStatus(accountPeerId: EnginePeer.Id, activeSessionId: String?) -> OnTVCardVisualStatus {
        if self.status == .live && self.pulseUserId == accountPeerId && self.sessionId == activeSessionId {
            return .locked
        }
        switch self.status {
        case .live:
            return .live
        case .ended:
            return .ended
        }
    }
}

struct OnTVRemotePlaybackContext {
    let sessionId: String
    let chatId: EnginePeer.Id
    let fileId: String
    let fileName: String?
    let fileSize: Int64?
    let mediaType: String?
    let timestamp: Int32?
    let position: Double
    let progress: CGFloat
    let pulseUserId: EnginePeer.Id?
    let status: OnTVPlaybackStatus
    let endedAt: Date?
    let participantCount: Int

    func visualStatus(accountPeerId: EnginePeer.Id, activeSessionId: String?) -> OnTVCardVisualStatus {
        if self.status == .live && self.pulseUserId == accountPeerId && self.sessionId == activeSessionId {
            return .locked
        }
        switch self.status {
        case .live:
            return .live
        case .ended:
            return .ended
        }
    }

    var messageId: EngineMessage.Id? {
        return self.messageId(localChatId: nil)
    }

    func messageId(localChatId: EnginePeer.Id?) -> EngineMessage.Id? {
        let parts = self.fileId.split(separator: ":")
        guard parts.count == 3,
              let peerRawId = Int64(parts[0]),
              let namespace = Int32(parts[1]),
              let id = Int32(parts[2]) else {
            return nil
        }
        var peerId = EnginePeer.Id(peerRawId)
        if let localChatId = localChatId, localChatId.namespace == Namespaces.Peer.CloudUser, peerId != localChatId {
            peerId = localChatId
        }
        return EngineMessage.Id(peerId: peerId, namespace: namespace, id: id)
    }

    func playbackContext(item: MediaBrowserItem) -> OnTVPlaybackContext {
        return OnTVPlaybackContext(
            sessionId: self.sessionId,
            chatId: self.chatId,
            fileId: item.messageId,
            item: item,
            position: self.position,
            progress: self.progress,
            pulseUserId: self.pulseUserId,
            status: self.status,
            endedAt: self.endedAt,
            participantCount: self.participantCount
        )
    }
}

enum OnTVSessionActivation {
    case locked(OnTVPlaybackContext)
    case joined(OnTVPlaybackContext)
    case resumed(OnTVPlaybackContext)
}

enum OnTVPlayerEvent {
    case action(sessionId: String, position: Double, progress: CGFloat, isPlaying: Bool)
    case state(sessionId: String, position: Double, progress: CGFloat)

    var sessionId: String {
        switch self {
        case let .action(sessionId, _, _, _):
            return sessionId
        case let .state(sessionId, _, _):
            return sessionId
        }
    }
}

enum OnTVSessionEvent {
    case pulseTaken(sessionId: String, pulseUserId: EnginePeer.Id)
    case pulseEnded(sessionId: String, endedAt: Date, position: Double, progress: CGFloat)
    case participantJoined(sessionId: String, participantCount: Int)
    case participantLeft(sessionId: String, participantCount: Int)

    var sessionId: String {
        switch self {
        case let .pulseTaken(sessionId, _):
            return sessionId
        case let .pulseEnded(sessionId, _, _, _):
            return sessionId
        case let .participantJoined(sessionId, _):
            return sessionId
        case let .participantLeft(sessionId, _):
            return sessionId
        }
    }
}

protocol OnTVSessionsStore: AnyObject {
    var isReady: Bool { get }
    var onSessionsUpdated: (([OnTVPlaybackContext]) -> Void)? { get set }
    var onUnresolvedSessionsUpdated: (([OnTVRemotePlaybackContext]) -> Void)? { get set }
    var onResolvingSessionsChanged: ((Bool) -> Void)? { get set }
    var onPlayerEvent: ((OnTVPlayerEvent) -> Void)? { get set }
    var onSessionEvent: ((OnTVSessionEvent) -> Void)? { get set }
    var onResolveMediaItems: (([EngineMessage.Id]) -> Void)? { get set }
    var onNeedsMoreMediaItems: (() -> Void)? { get set }
    var onStateConflict: (() -> Void)? { get set }

    func switchPeer(_ peerId: EnginePeer.Id)
    func registerLoadedItems(_ items: [MediaBrowserItem])
    func reload()
    func startPulse(item: MediaBrowserItem, position: Double, progress: CGFloat) -> OnTVPlaybackContext
    func endPulse(for item: MediaBrowserItem?, position: Double, progress: CGFloat) -> OnTVPlaybackContext?
    func endHeldPulses(for item: MediaBrowserItem?, position: Double, progress: CGFloat) -> [OnTVPlaybackContext]
    func leave(_ sessionId: String) -> OnTVPlaybackContext?
    func activate(_ sessionId: String) -> OnTVSessionActivation?
    func updatePlaybackProgress(sessionId: String, position: Double, progress: CGFloat)
    func sendPlayerEvent(_ event: OnTVPlayerEvent)
}

protocol OnTVSessionsTransport: AnyObject {
    var isReady: Bool { get }
    var onSessionEvent: ((OnTVSessionEvent) -> Void)? { get set }
    var onPlayerEvent: ((OnTVPlayerEvent) -> Void)? { get set }
    var onRemoteContexts: ((EnginePeer.Id, [OnTVRemotePlaybackContext]) -> Void)? { get set }
    var onStateConflict: ((String) -> Void)? { get set }

    func connect(chatId: EnginePeer.Id)
    func disconnect()
    func sendPlaybackContext(_ context: OnTVPlaybackContext)
    func sendPlayerEvent(_ event: OnTVPlayerEvent)
    func sendSessionEvent(_ event: OnTVSessionEvent)
}

final class LocalOnTVSessionsStore: OnTVSessionsStore {
    private var peerId: EnginePeer.Id
    private let accountPeerId: EnginePeer.Id
    private var sessionsByPeer: [EnginePeer.Id: [OnTVPlaybackContext]] = [:]

    var onSessionsUpdated: (([OnTVPlaybackContext]) -> Void)?
    var onUnresolvedSessionsUpdated: (([OnTVRemotePlaybackContext]) -> Void)?
    var onResolvingSessionsChanged: ((Bool) -> Void)?
    var onPlayerEvent: ((OnTVPlayerEvent) -> Void)?
    var onSessionEvent: ((OnTVSessionEvent) -> Void)?
    var onResolveMediaItems: (([EngineMessage.Id]) -> Void)?
    var onNeedsMoreMediaItems: (() -> Void)?
    var onStateConflict: (() -> Void)?
    var isReady: Bool {
        return true
    }

    init(peerId: EnginePeer.Id, accountPeerId: EnginePeer.Id) {
        self.peerId = peerId
        self.accountPeerId = accountPeerId
    }

    func switchPeer(_ peerId: EnginePeer.Id) {
        self.peerId = peerId
        self.emit()
    }

    func registerLoadedItems(_ items: [MediaBrowserItem]) {
    }

    func reload() {
        self.emit()
    }

    func startPulse(item: MediaBrowserItem, position: Double, progress: CGFloat) -> OnTVPlaybackContext {
        var sessions = self.sessionsByPeer[self.peerId] ?? []
        sessions = self.endingHeldPulses(in: sessions, matching: nil, excluding: item.messageId, position: position, progress: progress).sessions
        sessions = self.endingLivePulses(in: sessions, excluding: item.messageId)
        if let index = sessions.firstIndex(where: { $0.fileId == item.messageId }) {
            sessions[index].item = item
            sessions[index].position = position
            sessions[index].progress = progress
            sessions[index].pulseUserId = self.accountPeerId
            sessions[index].status = .live
            sessions[index].endedAt = nil
            sessions[index].participantCount = max(1, sessions[index].participantCount)
            let session = sessions.remove(at: index)
            sessions.insert(session, at: 0)
        } else {
            let session = OnTVPlaybackContext(
                sessionId: "\(item.messageId.peerId.toInt64())-\(item.messageId.namespace)-\(item.messageId.id)",
                chatId: self.peerId,
                fileId: item.messageId,
                item: item,
                position: position,
                progress: progress,
                pulseUserId: self.accountPeerId,
                status: .live,
                endedAt: nil,
                participantCount: 1
            )
            sessions.insert(session, at: 0)
        }
        self.sessionsByPeer[self.peerId] = self.trimEndedHistory(sessions)
        self.emit()
        return self.sessionsByPeer[self.peerId]?.first(where: { $0.fileId == item.messageId }) ?? sessions[0]
    }

    func endPulse(for item: MediaBrowserItem?, position: Double, progress: CGFloat) -> OnTVPlaybackContext? {
        return self.endHeldPulses(for: item, position: position, progress: progress).first
    }

    func endHeldPulses(for item: MediaBrowserItem?, position: Double, progress: CGFloat) -> [OnTVPlaybackContext] {
        let sessions = self.sessionsByPeer[self.peerId] ?? []
        let result = self.endingHeldPulses(in: sessions, matching: item?.messageId, excluding: nil, position: position, progress: progress)
        guard !result.ended.isEmpty else {
            return []
        }
        self.sessionsByPeer[self.peerId] = self.trimEndedHistory(result.sessions)
        self.emit()
        return result.ended
    }

    func leave(_ sessionId: String) -> OnTVPlaybackContext? {
        var sessions = self.sessionsByPeer[self.peerId] ?? []
        guard let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return nil }
        guard sessions[index].pulseUserId != self.accountPeerId else { return sessions[index] }
        sessions[index].participantCount = max(0, sessions[index].participantCount - 1)
        self.sessionsByPeer[self.peerId] = self.trimEndedHistory(sessions)
        self.emit()
        return self.sessionsByPeer[self.peerId]?[index]
    }

    func activate(_ sessionId: String) -> OnTVSessionActivation? {
        var sessions = self.sessionsByPeer[self.peerId] ?? []
        guard let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return nil }
        if sessions[index].status == .live && sessions[index].pulseUserId == self.accountPeerId {
            return .resumed(sessions[index])
        }
        if sessions[index].status == .ended {
            sessions[index].status = .live
            sessions[index].pulseUserId = self.accountPeerId
            sessions[index].endedAt = nil
            sessions[index].participantCount = 1
            let session = sessions.remove(at: index)
            sessions.insert(session, at: 0)
            self.sessionsByPeer[self.peerId] = self.trimEndedHistory(sessions)
            self.emit()
            return .resumed(session)
        } else {
            sessions[index].participantCount = max(2, sessions[index].participantCount + 1)
            self.sessionsByPeer[self.peerId] = self.trimEndedHistory(sessions)
            self.emit()
            return .joined(sessions[index])
        }
    }

    func updatePlaybackProgress(sessionId: String, position: Double, progress: CGFloat) {
        var changedCurrentPeer = false
        for peerKey in Array(self.sessionsByPeer.keys) {
            guard var sessions = self.sessionsByPeer[peerKey], let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) else {
                continue
            }
            sessions[index].position = position
            sessions[index].progress = progress
            self.sessionsByPeer[peerKey] = self.trimEndedHistory(sessions)
            if peerKey == self.peerId {
                changedCurrentPeer = true
            }
        }
        if changedCurrentPeer {
            self.emit()
        }
    }

    func sendPlayerEvent(_ event: OnTVPlayerEvent) {
        self.apply(event)
    }

    func apply(_ event: OnTVPlayerEvent) {
        var changedCurrentPeer = false
        for peerKey in Array(self.sessionsByPeer.keys) {
            guard var sessions = self.sessionsByPeer[peerKey], let index = sessions.firstIndex(where: { $0.sessionId == event.sessionId }) else {
                continue
            }
            switch event {
            case let .action(_, position, progress, _), let .state(_, position, progress):
                sessions[index].position = position
                sessions[index].progress = progress
            }
            self.sessionsByPeer[peerKey] = self.trimEndedHistory(sessions)
            if peerKey == self.peerId {
                changedCurrentPeer = true
            }
        }
        if changedCurrentPeer {
            self.emit()
        }
    }

    func apply(_ event: OnTVSessionEvent) {
        var changedCurrentPeer = false
        for peerKey in Array(self.sessionsByPeer.keys) {
            guard var sessions = self.sessionsByPeer[peerKey], let index = sessions.firstIndex(where: { $0.sessionId == event.sessionId }) else {
                continue
            }
            switch event {
            case let .pulseTaken(_, pulseUserId):
                sessions[index].pulseUserId = pulseUserId
                sessions[index].status = .live
                sessions[index].endedAt = nil
                sessions[index].participantCount = max(1, sessions[index].participantCount)
            case let .pulseEnded(_, endedAt, position, progress):
                sessions[index].pulseUserId = nil
                sessions[index].status = .ended
                sessions[index].endedAt = endedAt
                sessions[index].position = position
                sessions[index].progress = progress
                sessions[index].participantCount = 0
            case let .participantJoined(_, participantCount):
                sessions[index].participantCount = max(1, participantCount)
            case let .participantLeft(_, participantCount):
                sessions[index].participantCount = max(0, participantCount)
            }
            self.sessionsByPeer[peerKey] = self.trimEndedHistory(sessions)
            if peerKey == self.peerId {
                changedCurrentPeer = true
            }
        }
        if changedCurrentPeer {
            self.emit()
        }
    }

    func mergeRemoteContexts(_ contexts: [OnTVPlaybackContext], peerId: EnginePeer.Id) {
        guard !contexts.isEmpty else {
            if peerId == self.peerId {
                self.emit()
            }
            return
        }
        let remoteSessionIds = Set(contexts.map { $0.sessionId })
        let existing = (self.sessionsByPeer[peerId] ?? []).filter { !remoteSessionIds.contains($0.sessionId) }
        self.sessionsByPeer[peerId] = self.trimEndedHistory(contexts + existing)
        if peerId == self.peerId {
            self.emit()
        }
    }

    private func emit() {
        self.onSessionsUpdated?(self.sessionsByPeer[self.peerId] ?? [])
    }

    private func endingHeldPulses(in sessions: [OnTVPlaybackContext], matching itemId: EngineMessage.Id?, excluding excludedItemId: EngineMessage.Id?, position: Double, progress: CGFloat) -> (sessions: [OnTVPlaybackContext], ended: [OnTVPlaybackContext]) {
        var updatedSessions = sessions
        var ended: [OnTVPlaybackContext] = []
        let endedAt = Date()
        for index in updatedSessions.indices {
            guard updatedSessions[index].status == .live && updatedSessions[index].pulseUserId == self.accountPeerId else {
                continue
            }
            if let excludedItemId = excludedItemId, updatedSessions[index].fileId == excludedItemId {
                continue
            }
            let useCurrentPosition = itemId == nil || updatedSessions[index].fileId == itemId
            if useCurrentPosition {
                updatedSessions[index].position = position
                updatedSessions[index].progress = progress
            }
            updatedSessions[index].pulseUserId = nil
            updatedSessions[index].status = .ended
            updatedSessions[index].endedAt = endedAt
            updatedSessions[index].participantCount = 0
            ended.append(updatedSessions[index])
        }
        return (updatedSessions, ended)
    }

    private func endingLivePulses(in sessions: [OnTVPlaybackContext], excluding excludedItemId: EngineMessage.Id?) -> [OnTVPlaybackContext] {
        var updatedSessions = sessions
        let endedAt = Date()
        for index in updatedSessions.indices {
            guard updatedSessions[index].status == .live else {
                continue
            }
            if let excludedItemId = excludedItemId, updatedSessions[index].fileId == excludedItemId {
                continue
            }
            updatedSessions[index].pulseUserId = nil
            updatedSessions[index].status = .ended
            updatedSessions[index].endedAt = endedAt
            updatedSessions[index].participantCount = 0
        }
        return updatedSessions
    }

    private func trimEndedHistory(_ sessions: [OnTVPlaybackContext]) -> [OnTVPlaybackContext] {
        var endedCount = 0
        return sessions.filter { session in
            if session.status == .ended {
                endedCount += 1
                return endedCount <= 100
            }
            return true
        }
    }
}

final class SyncedOnTVSessionsStore: OnTVSessionsStore {
    private let localStore: LocalOnTVSessionsStore
    private let transport: OnTVSessionsTransport
    private var peerId: EnginePeer.Id
    private let accountPeerId: EnginePeer.Id
    private var loadedItemsByMessageId: [EngineMessage.Id: MediaBrowserItem] = [:]
    private var pendingRemoteContextsByPeer: [EnginePeer.Id: [OnTVRemotePlaybackContext]] = [:]
    private var unresolvedRemoteContextIdsByPeer: [EnginePeer.Id: Set<String>] = [:]
    private var requestedDirectMessageIds = Set<EngineMessage.Id>()
    private var requestedMoreMediaForPeer: Set<EnginePeer.Id> = []

    var onSessionsUpdated: (([OnTVPlaybackContext]) -> Void)? {
        didSet {
            self.localStore.onSessionsUpdated = self.onSessionsUpdated
        }
    }
    var onUnresolvedSessionsUpdated: (([OnTVRemotePlaybackContext]) -> Void)?
    var onResolvingSessionsChanged: ((Bool) -> Void)?
    var onPlayerEvent: ((OnTVPlayerEvent) -> Void)?
    var onSessionEvent: ((OnTVSessionEvent) -> Void)?
    var onResolveMediaItems: (([EngineMessage.Id]) -> Void)?
    var onNeedsMoreMediaItems: (() -> Void)?
    var onStateConflict: (() -> Void)?
    var isReady: Bool {
        return true
    }

    init(peerId: EnginePeer.Id, accountPeerId: EnginePeer.Id, transport: OnTVSessionsTransport) {
        self.peerId = peerId
        self.accountPeerId = accountPeerId
        self.transport = transport
        self.localStore = LocalOnTVSessionsStore(peerId: peerId, accountPeerId: accountPeerId)
        self.transport.onSessionEvent = { [weak self] event in
            guard let self = self else { return }
            self.localStore.apply(event)
            self.onSessionEvent?(event)
        }
        self.transport.onPlayerEvent = { [weak self] event in
            self?.localStore.apply(event)
            self?.onPlayerEvent?(event)
        }
        self.transport.onRemoteContexts = { [weak self] chatId, contexts in
            self?.applyRemoteContexts(contexts, chatId: chatId)
        }
        self.transport.onStateConflict = { [weak self] _ in
            guard let self = self else { return }
            self.onStateConflict?()
            self.transport.connect(chatId: self.peerId)
        }
    }

    deinit {
        self.transport.disconnect()
    }

    func switchPeer(_ peerId: EnginePeer.Id) {
        self.peerId = peerId
        self.localStore.switchPeer(peerId)
        self.hydrateRemoteContexts(for: peerId)
        self.emitUnresolvedRemoteContexts(for: peerId)
    }

    func registerLoadedItems(_ items: [MediaBrowserItem]) {
        self.localStore.registerLoadedItems(items)
        for item in items {
            self.loadedItemsByMessageId[item.messageId] = item
        }
        self.requestedMoreMediaForPeer.remove(self.peerId)
        self.hydrateRemoteContexts(for: self.peerId)
    }

    func reload() {
        self.transport.connect(chatId: self.peerId)
        self.localStore.reload()
    }

    func startPulse(item: MediaBrowserItem, position: Double, progress: CGFloat) -> OnTVPlaybackContext {
        let endedSessions = self.localStore.endHeldPulses(for: nil, position: position, progress: progress).filter { $0.fileId != item.messageId }
        for endedSession in endedSessions {
            self.transport.sendPlaybackContext(endedSession)
            self.transport.sendSessionEvent(.pulseEnded(sessionId: endedSession.sessionId, endedAt: endedSession.endedAt ?? Date(), position: endedSession.position, progress: endedSession.progress))
        }
        let session = self.localStore.startPulse(item: item, position: position, progress: progress)
        self.transport.sendPlaybackContext(session)
        self.transport.sendSessionEvent(.pulseTaken(sessionId: session.sessionId, pulseUserId: self.accountPeerId))
        self.transport.sendPlayerEvent(.state(sessionId: session.sessionId, position: position, progress: progress))
        return session
    }

    func endPulse(for item: MediaBrowserItem?, position: Double, progress: CGFloat) -> OnTVPlaybackContext? {
        return self.endHeldPulses(for: item, position: position, progress: progress).first
    }

    func endHeldPulses(for item: MediaBrowserItem?, position: Double, progress: CGFloat) -> [OnTVPlaybackContext] {
        let sessions = self.localStore.endHeldPulses(for: item, position: position, progress: progress)
        for session in sessions {
            self.transport.sendPlaybackContext(session)
            self.transport.sendSessionEvent(.pulseEnded(sessionId: session.sessionId, endedAt: session.endedAt ?? Date(), position: session.position, progress: session.progress))
        }
        return sessions
    }

    func leave(_ sessionId: String) -> OnTVPlaybackContext? {
        let session = self.localStore.leave(sessionId)
        if let session = session {
            self.transport.sendSessionEvent(.participantLeft(sessionId: session.sessionId, participantCount: session.participantCount))
        }
        return session
    }

    func activate(_ sessionId: String) -> OnTVSessionActivation? {
        let activation = self.localStore.activate(sessionId)
        switch activation {
        case let .locked(context):
            return .locked(context)
        case let .joined(context):
            self.transport.sendSessionEvent(.participantJoined(sessionId: context.sessionId, participantCount: context.participantCount))
            return .joined(context)
        case let .resumed(context):
            self.transport.sendPlaybackContext(context)
            self.transport.sendSessionEvent(.pulseTaken(sessionId: context.sessionId, pulseUserId: self.accountPeerId))
            self.transport.sendPlayerEvent(.state(sessionId: context.sessionId, position: context.position, progress: context.progress))
            return .resumed(context)
        case .none:
            return nil
        }
    }

    func updatePlaybackProgress(sessionId: String, position: Double, progress: CGFloat) {
        self.localStore.updatePlaybackProgress(sessionId: sessionId, position: position, progress: progress)
    }

    func sendPlayerEvent(_ event: OnTVPlayerEvent) {
        self.localStore.apply(event)
        self.transport.sendPlayerEvent(event)
    }

    private func applyRemoteContexts(_ contexts: [OnTVRemotePlaybackContext], chatId: EnginePeer.Id) {
        self.pendingRemoteContextsByPeer[chatId] = contexts
        self.requestedMoreMediaForPeer.remove(chatId)
        if contexts.isEmpty {
            self.unresolvedRemoteContextIdsByPeer[chatId] = []
            self.updateResolvingState(for: chatId)
            self.emitUnresolvedRemoteContexts(for: chatId)
        }
        self.hydrateRemoteContexts(for: chatId)
    }

    private func hydrateRemoteContexts(for chatId: EnginePeer.Id) {
        guard let remoteContexts = self.pendingRemoteContextsByPeer[chatId], !remoteContexts.isEmpty else {
            self.updateResolvingState(for: chatId)
            return
        }
        let hydratedContexts = remoteContexts.compactMap { remoteContext -> OnTVPlaybackContext? in
            guard let item = self.matchingLoadedItem(for: remoteContext, chatId: chatId) else {
                return nil
            }
            return remoteContext.playbackContext(item: item)
        }
        self.localStore.mergeRemoteContexts(hydratedContexts, peerId: chatId)

        let hydratedIds = Set(hydratedContexts.map { $0.sessionId })
        let unresolvedIds = Set(remoteContexts.map { $0.sessionId }).subtracting(hydratedIds)
        self.unresolvedRemoteContextIdsByPeer[chatId] = unresolvedIds
        self.emitUnresolvedRemoteContexts(for: chatId)
        let unresolvedMessageIds = remoteContexts.compactMap { remoteContext -> EngineMessage.Id? in
            guard unresolvedIds.contains(remoteContext.sessionId) else {
                return nil
            }
            return remoteContext.messageId(localChatId: chatId)
        }
        let directMessageIds = unresolvedMessageIds.filter { !self.requestedDirectMessageIds.contains($0) }
        if !directMessageIds.isEmpty {
            self.requestedDirectMessageIds.formUnion(directMessageIds)
            self.onResolveMediaItems?(directMessageIds)
            return
        }
        if chatId == self.peerId && !unresolvedIds.isEmpty && !self.requestedMoreMediaForPeer.contains(chatId) {
            self.requestedMoreMediaForPeer.insert(chatId)
            self.onNeedsMoreMediaItems?()
        }
        self.updateResolvingState(for: chatId)
    }

    private func updateResolvingState(for chatId: EnginePeer.Id) {
        guard chatId == self.peerId else {
            return
        }
        let isResolving = !(self.unresolvedRemoteContextIdsByPeer[chatId] ?? []).isEmpty
        self.onResolvingSessionsChanged?(isResolving)
    }

    private func emitUnresolvedRemoteContexts(for chatId: EnginePeer.Id) {
        guard chatId == self.peerId else {
            return
        }
        let unresolvedIds = self.unresolvedRemoteContextIdsByPeer[chatId] ?? []
        let unresolvedContexts = (self.pendingRemoteContextsByPeer[chatId] ?? []).filter { unresolvedIds.contains($0.sessionId) }
        self.onUnresolvedSessionsUpdated?(unresolvedContexts)
    }

    private func matchingLoadedItem(for remoteContext: OnTVRemotePlaybackContext, chatId: EnginePeer.Id) -> MediaBrowserItem? {
        if let messageId = remoteContext.messageId(localChatId: chatId), let item = self.loadedItemsByMessageId[messageId] {
            return item
        }

        let loadedItems = Array(self.loadedItemsByMessageId.values)
        if let fileName = remoteContext.fileName, !fileName.isEmpty {
            let normalizedFileName = fileName.lowercased()
            let mediaType = remoteContext.mediaType
            let fileSize = remoteContext.fileSize
            if let exact = loadedItems.first(where: { item in
                item.fileName.lowercased() == normalizedFileName &&
                (mediaType == nil || Self.mediaTypeString(for: item.mediaType) == mediaType) &&
                (fileSize == nil || item.fileSize == fileSize)
            }) {
                return exact
            }
            if let fuzzy = loadedItems.first(where: { item in
                item.fileName.lowercased() == normalizedFileName &&
                (mediaType == nil || Self.mediaTypeString(for: item.mediaType) == mediaType)
            }) {
                return fuzzy
            }
        }

        return nil
    }

    private static func mediaTypeString(for mediaType: MediaBrowserMediaType) -> String {
        switch mediaType {
        case .photo:
            return "photo"
        case .video:
            return "video"
        case .file:
            return "file"
        case .audio:
            return "audio"
        }
    }
}

final class ServerOnTVSessionsTransport: NSObject, OnTVSessionsTransport, URLSessionWebSocketDelegate {
    private let endpoint: URL
    private let authToken: String?
    private let authTokenProvider: ((String, @escaping (String?) -> Void) -> Void)?
    private let accountPeerId: EnginePeer.Id
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var chatId: EnginePeer.Id?
    private var syncChatId: String?
    private var isDisconnecting = false
    private var isSocketOpen = false
    private var reconnectAttempts = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var pendingPayloads: [[String: Any]] = []

    var onSessionEvent: ((OnTVSessionEvent) -> Void)?
    var onPlayerEvent: ((OnTVPlayerEvent) -> Void)?
    var onRemoteContexts: ((EnginePeer.Id, [OnTVRemotePlaybackContext]) -> Void)?
    var onStateConflict: ((String) -> Void)?
    var isReady: Bool {
        return self.isSocketOpen
    }

    init(endpoint: URL, authToken: String?, accountPeerId: EnginePeer.Id, authTokenProvider: ((String, @escaping (String?) -> Void) -> Void)? = nil) {
        self.endpoint = Self.webSocketEndpoint(from: endpoint)
        self.authToken = authToken
        self.authTokenProvider = authTokenProvider
        self.accountPeerId = accountPeerId
        super.init()
    }

    func connect(chatId: EnginePeer.Id) {
        let syncChatId = Self.syncScopeId(chatId: chatId, accountPeerId: self.accountPeerId)
        if self.chatId == chatId, self.syncChatId == syncChatId, self.task != nil, !self.isDisconnecting {
            return
        }
        self.chatId = chatId
        self.syncChatId = syncChatId
        self.disconnect()
        self.isDisconnecting = false

        if let authToken = self.authToken, !authToken.isEmpty {
            self.openSocket(chatId: chatId, syncChatId: syncChatId, authToken: authToken)
        } else if let authTokenProvider = self.authTokenProvider {
            NSLog("[MultigramOnTV] Requesting sync token endpoint=%@ chatScope=%@", self.endpoint.absoluteString, syncChatId)
            authTokenProvider(syncChatId) { [weak self] token in
                guard let self = self, self.chatId == chatId, !self.isDisconnecting else {
                    return
                }
                guard let token = token, !token.isEmpty else {
                    NSLog("[MultigramOnTV] Sync token unavailable chatScope=%@", syncChatId)
                    return
                }
                self.openSocket(chatId: chatId, syncChatId: syncChatId, authToken: token)
            }
        } else {
            self.openSocket(chatId: chatId, syncChatId: syncChatId, authToken: nil)
        }
    }

    private func openSocket(chatId: EnginePeer.Id, syncChatId: String, authToken: String?) {
        var request = URLRequest(url: self.endpoint)
        if let authToken = authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(syncChatId, forHTTPHeaderField: "X-PlayGram-Chat-Id")
        request.setValue(String(self.accountPeerId.toInt64()), forHTTPHeaderField: "X-PlayGram-User-Id")

        NSLog("[MultigramOnTV] Connecting WebSocket endpoint=%@ chatScope=%@ userId=%lld tokenPresent=%@", self.endpoint.absoluteString, syncChatId, self.accountPeerId.toInt64(), authToken == nil ? "false" : "true")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        self.isSocketOpen = false
        task.resume()
        self.receiveNext()
    }

    func disconnect() {
        self.isDisconnecting = true
        self.reconnectWorkItem?.cancel()
        self.reconnectWorkItem = nil
        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = nil
        self.isSocketOpen = false
        self.session?.invalidateAndCancel()
        self.session = nil
    }

    func sendPlaybackContext(_ context: OnTVPlaybackContext) {
        self.send(payload: self.payload(for: context))
    }

    func sendPlayerEvent(_ event: OnTVPlayerEvent) {
        self.send(payload: self.payload(for: event))
    }

    func sendSessionEvent(_ event: OnTVSessionEvent) {
        self.send(payload: self.payload(for: event))
    }

    private func send(payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload) else {
            return
        }
        guard let task = self.task, self.isSocketOpen, let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            self.enqueuePendingPayload(payload)
            return
        }
        let text = String(data: data, encoding: .utf8) ?? "{}"
        task.send(.string(text)) { [weak self] error in
            if error != nil {
                self?.enqueuePendingPayload(payload)
                self?.scheduleReconnect()
            }
        }
    }

    private func enqueuePendingPayload(_ payload: [String: Any]) {
        self.pendingPayloads.append(payload)
        if self.pendingPayloads.count > 30 {
            self.pendingPayloads.removeFirst(self.pendingPayloads.count - 30)
        }
    }

    private func flushPendingPayloads() {
        guard self.isSocketOpen, let task = self.task, !self.pendingPayloads.isEmpty else {
            return
        }
        let payloads = self.pendingPayloads
        self.pendingPayloads.removeAll()
        for payload in payloads {
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                continue
            }
            let text = String(data: data, encoding: .utf8) ?? "{}"
            task.send(.string(text)) { [weak self] error in
                if error != nil {
                    self?.enqueuePendingPayload(payload)
                    self?.scheduleReconnect()
                }
            }
        }
    }

    private func receiveNext() {
        guard let currentTask = self.task else {
            return
        }
        currentTask.receive { [weak self, weak currentTask] result in
            guard let self = self else { return }
            guard currentTask === self.task else {
                return
            }
            switch result {
            case let .success(message):
                if let remoteContexts = self.decodeRemoteContexts(message) {
                    DispatchQueue.main.async {
                        self.onRemoteContexts?(remoteContexts.0, remoteContexts.1)
                    }
                } else if let event = self.decodeSessionEvent(message) {
                    DispatchQueue.main.async {
                        self.onSessionEvent?(event)
                    }
                } else if let event = self.decodePlayerEvent(message) {
                    DispatchQueue.main.async {
                        self.onPlayerEvent?(event)
                    }
                } else if let errorCode = self.decodeErrorCode(message), errorCode == "state_conflict" {
                    DispatchQueue.main.async {
                        self.onStateConflict?(errorCode)
                    }
                }
                self.receiveNext()
            case .failure:
                NSLog("[MultigramOnTV] WebSocket receive failed, scheduling reconnect")
                self.scheduleReconnect()
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        NSLog("[MultigramOnTV] WebSocket opened endpoint=%@", self.endpoint.absoluteString)
        self.isSocketOpen = true
        self.reconnectAttempts = 0
        self.flushPendingPayloads()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === self.task else {
            return
        }
        NSLog("[MultigramOnTV] WebSocket closed code=%ld", closeCode.rawValue)
        self.isSocketOpen = false
        self.scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !self.isDisconnecting, let chatId = self.chatId else {
            return
        }
        if self.reconnectWorkItem != nil {
            return
        }
        self.task = nil
        self.isSocketOpen = false
        self.session?.invalidateAndCancel()
        self.session = nil
        self.reconnectAttempts += 1
        let delay = min(5.0, 0.35 * Double(self.reconnectAttempts))
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isDisconnecting, self.chatId == chatId else {
                return
            }
            self.reconnectWorkItem = nil
            self.connect(chatId: chatId)
        }
        self.reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func decodeRemoteContexts(_ message: URLSessionWebSocketTask.Message) -> (EnginePeer.Id, [OnTVRemotePlaybackContext])? {
        guard let object = self.decodeObject(message),
              let type = object["type"] as? String else {
            return nil
        }

        switch type {
        case "context.snapshot":
            guard let chatId = self.effectiveLocalChatId(from: object["chatId"]),
                  let rawSessions = object["sessions"] as? [[String: Any]] else {
                return nil
            }
            let contexts = rawSessions.compactMap { Self.remoteContext(from: $0, fallbackChatId: chatId) }
            return (chatId, contexts)
        case "context.upsert":
            let fallbackChatId = self.effectiveLocalChatId(from: object["chatId"])
            guard let context = Self.remoteContext(from: object, fallbackChatId: fallbackChatId) else {
                return nil
            }
            return (context.chatId, [context])
        default:
            return nil
        }
    }

    private func decodeSessionEvent(_ message: URLSessionWebSocketTask.Message) -> OnTVSessionEvent? {
        guard let object = self.decodeObject(message),
              let type = object["type"] as? String,
              let sessionId = object["sessionId"] as? String else {
            return nil
        }

        switch type {
        case "session.pulseTaken":
            guard let pulseUserId = Self.peerId(from: object["pulseUserId"]) else { return nil }
            return .pulseTaken(sessionId: sessionId, pulseUserId: pulseUserId)
        case "session.pulseEnded":
            let endedAt = Self.dateFromMilliseconds(object["endedAt"]) ?? Date()
            let position = Self.doubleValue(object["position"]) ?? 0.0
            let progress = CGFloat(Self.doubleValue(object["progress"]) ?? 0.0)
            return .pulseEnded(sessionId: sessionId, endedAt: endedAt, position: position, progress: progress)
        case "session.participantJoined":
            let participantCount = Self.intValue(object["participantCount"]) ?? 1
            return .participantJoined(sessionId: sessionId, participantCount: participantCount)
        case "session.participantLeft":
            let participantCount = Self.intValue(object["participantCount"]) ?? 0
            return .participantLeft(sessionId: sessionId, participantCount: participantCount)
        default:
            return nil
        }
    }

    private func decodePlayerEvent(_ message: URLSessionWebSocketTask.Message) -> OnTVPlayerEvent? {
        guard let object = self.decodeObject(message),
              let type = object["type"] as? String,
              let sessionId = object["sessionId"] as? String else {
            return nil
        }
        let position = Self.doubleValue(object["position"]) ?? 0.0
        let progress = CGFloat(Self.doubleValue(object["progress"]) ?? 0.0)
        switch type {
        case "player.action":
            return .action(sessionId: sessionId, position: position, progress: progress, isPlaying: (object["isPlaying"] as? Bool) ?? false)
        case "player.state":
            return .state(sessionId: sessionId, position: position, progress: progress)
        default:
            return nil
        }
    }

    private func decodeErrorCode(_ message: URLSessionWebSocketTask.Message) -> String? {
        guard let object = self.decodeObject(message),
              let type = object["type"] as? String,
              type == "error" else {
            return nil
        }
        return object["code"] as? String
    }

    private func decodeObject(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data?
        switch message {
        case let .data(value):
            data = value
        case let .string(value):
            data = value.data(using: .utf8)
        @unknown default:
            data = nil
        }
        guard let data = data,
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func remoteContext(from object: [String: Any], fallbackChatId: EnginePeer.Id?) -> OnTVRemotePlaybackContext? {
        guard let sessionId = object["sessionId"] as? String,
              let chatId = Self.peerId(from: object["chatId"]) ?? fallbackChatId,
              let fileId = object["fileId"] as? String else {
            return nil
        }
        let status: OnTVPlaybackStatus = (object["status"] as? String) == "ENDED" ? .ended : .live
        let endedAt = Self.dateFromMilliseconds(object["endedAt"])
        return OnTVRemotePlaybackContext(
            sessionId: sessionId,
            chatId: chatId,
            fileId: fileId,
            fileName: object["fileName"] as? String,
            fileSize: Self.int64Value(object["fileSize"]),
            mediaType: object["mediaType"] as? String,
            timestamp: Self.intValue(object["timestamp"]).flatMap { Int32(exactly: $0) },
            position: Self.doubleValue(object["position"]) ?? 0.0,
            progress: CGFloat(Self.doubleValue(object["progress"]) ?? 0.0),
            pulseUserId: Self.peerId(from: object["pulseUserId"]),
            status: status,
            endedAt: endedAt,
            participantCount: max(0, Self.intValue(object["participantCount"]) ?? 0)
        )
    }

    private static func peerId(from value: Any?) -> EnginePeer.Id? {
        guard let rawValue = Self.int64Value(value) else {
            return nil
        }
        return EnginePeer.Id(rawValue)
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        if let value = value as? String {
            return Int64(value)
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    private static func webSocketEndpoint(from endpoint: URL) -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }
        if components.scheme == "http" {
            components.scheme = "ws"
        } else if components.scheme == "https" {
            components.scheme = "wss"
        }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1/sync"
        }
        return components.url ?? endpoint
    }

    private static func syncScopeId(chatId: EnginePeer.Id, accountPeerId: EnginePeer.Id) -> String {
        if chatId.namespace == Namespaces.Peer.CloudUser, chatId != accountPeerId {
            let ids = [accountPeerId.toInt64(), chatId.toInt64()].sorted()
            return "private:\(ids[0]):\(ids[1])"
        }
        return String(chatId.toInt64())
    }

    private func effectiveLocalChatId(from value: Any?) -> EnginePeer.Id? {
        if let string = value as? String, string == self.syncChatId {
            return self.chatId
        }
        if let number = Self.int64Value(value), String(number) == self.syncChatId {
            return self.chatId
        }
        return Self.peerId(from: value)
    }

    private static func millisecondsSince1970(_ date: Date) -> Double {
        return date.timeIntervalSince1970 * 1000.0
    }

    private static func dateFromMilliseconds(_ value: Any?) -> Date? {
        guard let milliseconds = Self.doubleValue(value) else {
            return nil
        }
        return Date(timeIntervalSince1970: milliseconds / 1000.0)
    }

    private func payload(for event: OnTVPlayerEvent) -> [String: Any] {
        switch event {
        case let .action(sessionId, position, progress, isPlaying):
            return [
                "type": "player.action",
                "sessionId": sessionId,
                "chatId": self.syncChatId ?? String(self.chatId?.toInt64() ?? 0),
                "position": position,
                "progress": Double(progress),
                "isPlaying": isPlaying
            ]
        case let .state(sessionId, position, progress):
            return [
                "type": "player.state",
                "sessionId": sessionId,
                "chatId": self.syncChatId ?? String(self.chatId?.toInt64() ?? 0),
                "position": position,
                "progress": Double(progress)
            ]
        }
    }

    private func payload(for context: OnTVPlaybackContext) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "context.upsert",
            "sessionId": context.sessionId,
            "chatId": self.syncChatId ?? String(context.chatId.toInt64()),
            "fileId": "\(context.fileId.peerId.toInt64()):\(context.fileId.namespace):\(context.fileId.id)",
            "fileName": context.item.fileName,
            "fileSize": context.item.fileSize,
            "mediaType": Self.mediaTypeString(for: context.item.mediaType),
            "timestamp": context.item.timestamp,
            "position": context.position,
            "progress": Double(context.progress),
            "status": context.status == .live ? "LIVE" : "ENDED",
            "participantCount": context.participantCount
        ]
        if let pulseUserId = context.pulseUserId {
            payload["pulseUserId"] = pulseUserId.toInt64()
        }
        if let endedAt = context.endedAt {
            payload["endedAt"] = Self.millisecondsSince1970(endedAt)
        }
        return payload
    }

    private static func mediaTypeString(for mediaType: MediaBrowserMediaType) -> String {
        switch mediaType {
        case .photo:
            return "photo"
        case .video:
            return "video"
        case .file:
            return "file"
        case .audio:
            return "audio"
        }
    }

    private func payload(for event: OnTVSessionEvent) -> [String: Any] {
        switch event {
        case let .pulseTaken(sessionId, pulseUserId):
            return [
                "type": "session.pulseTaken",
                "sessionId": sessionId,
                "chatId": self.syncChatId ?? String(self.chatId?.toInt64() ?? 0),
                "pulseUserId": pulseUserId.toInt64()
            ]
        case let .pulseEnded(sessionId, endedAt, position, progress):
            return [
                "type": "session.pulseEnded",
                "sessionId": sessionId,
                "chatId": self.syncChatId ?? String(self.chatId?.toInt64() ?? 0),
                "endedAt": Self.millisecondsSince1970(endedAt),
                "position": position,
                "progress": Double(progress)
            ]
        case let .participantJoined(sessionId, participantCount):
            return [
                "type": "session.participantJoined",
                "sessionId": sessionId,
                "chatId": self.syncChatId ?? String(self.chatId?.toInt64() ?? 0),
                "participantCount": participantCount
            ]
        case let .participantLeft(sessionId, participantCount):
            return [
                "type": "session.participantLeft",
                "sessionId": sessionId,
                "chatId": self.syncChatId ?? String(self.chatId?.toInt64() ?? 0),
                "participantCount": participantCount
            ]
        }
    }
}
