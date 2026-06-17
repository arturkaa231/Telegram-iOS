import Foundation
import CoreGraphics
import Postbox
import SwiftSignalKit
import TelegramCore

struct MediaBrowserProgressRecord: Codable, Equatable {
    private static let currentSchemaVersion: Int32 = 1
    private static let minimumVisiblePosition: Double = 2.0
    private static let minimumVisibleProgress: Double = 0.01

    let schemaVersion: Int32
    let chatId: Int64
    let fileId: String
    let position: Double
    let progress: Double
    let updatedAt: Double
    let endedAt: Double?
    let fileName: String
    let fileSize: Int64
    let mediaType: String
    let timestamp: Int32

    var messageId: EngineMessage.Id? {
        return OnTVRemotePlaybackContext(
            sessionId: self.sessionId,
            chatId: EnginePeer.Id(self.chatId),
            fileId: self.fileId,
            fileName: self.fileName,
            fileSize: self.fileSize,
            mediaType: self.mediaType,
            timestamp: self.timestamp,
            position: self.position,
            progress: CGFloat(self.progress),
            pulseUserId: nil,
            status: .ended,
            endedAt: self.endedAt.flatMap { Date(timeIntervalSince1970: $0) },
            participantCount: 0
        ).messageId(localChatId: EnginePeer.Id(self.chatId))
    }

    var sessionId: String {
        return "local-progress-\(self.chatId)-\(self.fileId)"
    }

    var hasVisibleProgress: Bool {
        return self.position >= Self.minimumVisiblePosition || self.progress >= Self.minimumVisibleProgress
    }

    var normalizedProgress: Double {
        return max(0.0, min(1.0, self.progress))
    }

    static func make(item: MediaBrowserItem, chatId: EnginePeer.Id, position: Double, progress: CGFloat, endedAt: Date?) -> MediaBrowserProgressRecord? {
        let normalizedPosition = max(0.0, position)
        let normalizedProgress = Self.normalizedProgress(progress)
        guard normalizedPosition >= Self.minimumVisiblePosition || normalizedProgress >= Self.minimumVisibleProgress || endedAt != nil else {
            return nil
        }

        return MediaBrowserProgressRecord(
            schemaVersion: Self.currentSchemaVersion,
            chatId: chatId.toInt64(),
            fileId: MediaBrowserProgressStore.fileId(for: item.messageId),
            position: normalizedPosition,
            progress: normalizedProgress,
            updatedAt: Date().timeIntervalSince1970,
            endedAt: endedAt?.timeIntervalSince1970,
            fileName: item.fileName,
            fileSize: item.fileSize,
            mediaType: Self.mediaTypeString(for: item.mediaType),
            timestamp: item.timestamp
        )
    }

    private static func normalizedProgress(_ progress: CGFloat) -> Double {
        return Double(max(0.0, min(1.0, progress)))
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

    func remoteContext() -> OnTVRemotePlaybackContext {
        return OnTVRemotePlaybackContext(
            sessionId: self.sessionId,
            chatId: EnginePeer.Id(self.chatId),
            fileId: self.fileId,
            fileName: self.fileName,
            fileSize: self.fileSize,
            mediaType: self.mediaType,
            timestamp: self.timestamp,
            position: self.position,
            progress: CGFloat(self.progress),
            pulseUserId: nil,
            status: .ended,
            endedAt: self.endedAt.flatMap { Date(timeIntervalSince1970: $0) },
            participantCount: 0
        )
    }
}

private struct MediaBrowserProgressRecordList: Codable {
    var records: [MediaBrowserProgressRecord]
}

final class MediaBrowserProgressStore {
    private static let collectionId: ItemCacheCollectionId = 120
    private static let schemaVersion: Int32 = 1
    private static let maxRecordsPerChat = 100

    private let postbox: Postbox
    private let operationDisposablesLock = NSLock()
    private var operationDisposables: [Int: Disposable] = [:]
    private var completedOperationIds = Set<Int>()
    private var nextOperationDisposableId: Int = 0

    init(postbox: Postbox) {
        self.postbox = postbox
    }

    deinit {
        let disposables: [Disposable]
        self.operationDisposablesLock.lock()
        disposables = Array(self.operationDisposables.values)
        self.operationDisposables.removeAll()
        self.completedOperationIds.removeAll()
        self.operationDisposablesLock.unlock()

        for disposable in disposables {
            disposable.dispose()
        }
    }

    func load(chatId: EnginePeer.Id, completion: @escaping ([MediaBrowserProgressRecord]) -> Void) {
        let entryId = Self.entryId(chatId: chatId)
        let signal = self.postbox.transaction { transaction -> [MediaBrowserProgressRecord] in
            return transaction.retrieveItemCacheEntry(id: entryId)?.get(MediaBrowserProgressRecordList.self)?.records ?? []
        }
        |> deliverOnMainQueue
        let operationId = self.makeOperationDisposableId()
        let disposable = signal.start(next: { records in
            completion(records)
        }, completed: { [weak self] in
            self?.releaseOperationDisposable(operationId)
        })
        self.retainOperationDisposable(disposable, id: operationId)
    }

    func savedPosition(for item: MediaBrowserItem, chatId: EnginePeer.Id, completion: @escaping (Double?) -> Void) {
        let entryId = Self.entryId(chatId: chatId)
        let fileId = Self.fileId(for: item.messageId)
        let signal = self.postbox.transaction { transaction -> Double? in
            guard let records = transaction.retrieveItemCacheEntry(id: entryId)?.get(MediaBrowserProgressRecordList.self)?.records else {
                return nil
            }
            guard let record = records.first(where: { $0.fileId == fileId }) else {
                return nil
            }
            guard record.hasVisibleProgress else {
                return nil
            }
            return max(0.0, record.position)
        }
        |> deliverOnMainQueue
        let operationId = self.makeOperationDisposableId()
        let disposable = signal.start(next: { position in
            completion(position)
        }, completed: { [weak self] in
            self?.releaseOperationDisposable(operationId)
        })
        self.retainOperationDisposable(disposable, id: operationId)
    }

    func upsert(item: MediaBrowserItem, chatId: EnginePeer.Id, position: Double, progress: CGFloat, endedAt: Date?, completion: (() -> Void)? = nil) {
        guard let record = MediaBrowserProgressRecord.make(item: item, chatId: chatId, position: position, progress: progress, endedAt: endedAt) else {
            return
        }
        self.upsert(record: record, completion: completion)
    }

    func upsert(context: OnTVPlaybackContext, completion: (() -> Void)? = nil) {
        let record = MediaBrowserProgressRecord(
            schemaVersion: Self.schemaVersion,
            chatId: context.chatId.toInt64(),
            fileId: Self.fileId(for: context.fileId),
            position: max(0.0, context.position),
            progress: Self.normalizedProgress(context.progress),
            updatedAt: Date().timeIntervalSince1970,
            endedAt: context.endedAt?.timeIntervalSince1970,
            fileName: context.item.fileName,
            fileSize: context.item.fileSize,
            mediaType: Self.mediaTypeString(for: context.item.mediaType),
            timestamp: context.item.timestamp
        )
        self.upsert(record: record, completion: completion)
    }

    func upsert(record: MediaBrowserProgressRecord, completion: (() -> Void)? = nil) {
        let entryId = Self.entryId(chatId: EnginePeer.Id(record.chatId))
        let signal = self.postbox.transaction { transaction -> Void in
            var records = transaction.retrieveItemCacheEntry(id: entryId)?.get(MediaBrowserProgressRecordList.self)?.records ?? []
            records.removeAll { $0.fileId == record.fileId }
            records.insert(record, at: 0)
            records = Self.trim(records)
            if let entry = CodableEntry(MediaBrowserProgressRecordList(records: records)) {
                transaction.putItemCacheEntry(id: entryId, entry: entry)
            }
        }
        let operationId = self.makeOperationDisposableId()
        let disposable = (signal |> deliverOnMainQueue).start(completed: { [weak self] in
            completion?()
            self?.releaseOperationDisposable(operationId)
        })
        self.retainOperationDisposable(disposable, id: operationId)
    }

    func mergeRemoteContexts(_ contexts: [OnTVPlaybackContext], chatId: EnginePeer.Id) {
        guard !contexts.isEmpty else {
            return
        }
        let entryId = Self.entryId(chatId: chatId)
        let records = contexts.map { context in
            return MediaBrowserProgressRecord(
                schemaVersion: Self.schemaVersion,
                chatId: context.chatId.toInt64(),
                fileId: Self.fileId(for: context.fileId),
                position: max(0.0, context.position),
                progress: Self.normalizedProgress(context.progress),
                updatedAt: Date().timeIntervalSince1970,
                endedAt: context.endedAt?.timeIntervalSince1970,
                fileName: context.item.fileName,
                fileSize: context.item.fileSize,
                mediaType: Self.mediaTypeString(for: context.item.mediaType),
                timestamp: context.item.timestamp
            )
        }
        let signal = self.postbox.transaction { transaction -> Void in
            var existing = transaction.retrieveItemCacheEntry(id: entryId)?.get(MediaBrowserProgressRecordList.self)?.records ?? []
            let incomingFileIds = Set(records.map { $0.fileId })
            existing.removeAll { incomingFileIds.contains($0.fileId) }
            let merged = Self.trim(records + existing)
            if let entry = CodableEntry(MediaBrowserProgressRecordList(records: merged)) {
                transaction.putItemCacheEntry(id: entryId, entry: entry)
            }
        }
        let operationId = self.makeOperationDisposableId()
        let disposable = signal.start(completed: { [weak self] in
            self?.releaseOperationDisposable(operationId)
        })
        self.retainOperationDisposable(disposable, id: operationId)
    }

    static func fileId(for messageId: EngineMessage.Id) -> String {
        return "\(messageId.peerId.toInt64()):\(messageId.namespace):\(messageId.id)"
    }

    private static func entryId(chatId: EnginePeer.Id) -> ItemCacheEntryId {
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: chatId.toInt64())
        return ItemCacheEntryId(collectionId: Self.collectionId, key: key)
    }

    private static func normalizedProgress(_ progress: CGFloat) -> Double {
        return Double(max(0.0, min(1.0, progress)))
    }

    private static func trim(_ records: [MediaBrowserProgressRecord]) -> [MediaBrowserProgressRecord] {
        return Array(records.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(Self.maxRecordsPerChat))
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

    private func makeOperationDisposableId() -> Int {
        self.operationDisposablesLock.lock()
        let id = self.nextOperationDisposableId
        self.nextOperationDisposableId += 1
        self.operationDisposablesLock.unlock()
        return id
    }

    private func retainOperationDisposable(_ disposable: Disposable, id: Int) {
        var shouldRetain = true
        self.operationDisposablesLock.lock()
        if self.completedOperationIds.remove(id) != nil {
            shouldRetain = false
        } else {
            self.operationDisposables[id] = disposable
        }
        self.operationDisposablesLock.unlock()

        if !shouldRetain {
            withExtendedLifetime(disposable, {})
        }
    }

    private func releaseOperationDisposable(_ id: Int) {
        self.operationDisposablesLock.lock()
        if self.operationDisposables.removeValue(forKey: id) == nil {
            self.completedOperationIds.insert(id)
        }
        self.operationDisposablesLock.unlock()
    }
}
