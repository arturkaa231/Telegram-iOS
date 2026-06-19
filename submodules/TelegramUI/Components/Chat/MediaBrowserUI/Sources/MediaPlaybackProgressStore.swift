import Foundation
import CoreGraphics
import TelegramCore

struct MediaPlaybackProgress {
    let position: Double
    let progress: CGFloat
    let updatedAt: TimeInterval
}

final class MediaPlaybackProgressStore {
    private let storageKey: String
    private let defaults: UserDefaults
    private let maxStoredItems = 500

    init(accountPeerId: EnginePeer.Id, defaults: UserDefaults = .standard) {
        self.storageKey = "Multigram.MediaPlaybackProgress.\(accountPeerId.toInt64())"
        self.defaults = defaults
    }

    func progress(for item: MediaBrowserItem) -> MediaPlaybackProgress? {
        return self.progress(for: item.messageId)
    }

    func progress(for messageId: EngineMessage.Id) -> MediaPlaybackProgress? {
        guard let record = self.records()[Self.key(for: messageId)] else {
            return nil
        }
        let progress = CGFloat(max(0.0, min(1.0, record.progress)))
        guard progress >= 0.01 else {
            return nil
        }
        return MediaPlaybackProgress(
            position: max(0.0, record.position),
            progress: progress,
            updatedAt: record.updatedAt
        )
    }

    func progressMap(for items: [MediaBrowserItem]) -> [EngineMessage.Id: CGFloat] {
        var result: [EngineMessage.Id: CGFloat] = [:]
        for item in items {
            if item.mediaType != .photo, let progress = self.progress(for: item)?.progress {
                result[item.messageId] = progress
            }
        }
        return result
    }

    func update(item: MediaBrowserItem?, position: Double, progress: CGFloat) {
        guard let item = item, item.mediaType != .photo else {
            return
        }
        self.update(messageId: item.messageId, position: position, progress: progress)
    }

    func update(sessions: [OnTVPlaybackContext]) {
        for session in sessions {
            self.update(messageId: session.fileId, position: session.position, progress: session.progress)
        }
    }

    private func update(messageId: EngineMessage.Id, position: Double, progress: CGFloat) {
        var records = self.records()
        let key = Self.key(for: messageId)
        let normalizedProgress = max(0.0, min(1.0, Double(progress)))
        if normalizedProgress < 0.01 {
            return
        }
        records[key] = Record(
            position: max(0.0, position),
            progress: normalizedProgress,
            updatedAt: Date().timeIntervalSince1970
        )
        if records.count > self.maxStoredItems {
            let sortedKeys = records.sorted { lhs, rhs in
                lhs.value.updatedAt > rhs.value.updatedAt
            }.map(\.key)
            for staleKey in sortedKeys.dropFirst(self.maxStoredItems) {
                records.removeValue(forKey: staleKey)
            }
        }
        self.save(records)
    }

    private static func key(for messageId: EngineMessage.Id) -> String {
        return "\(messageId.peerId.toInt64())-\(messageId.namespace)-\(messageId.id)"
    }

    private func records() -> [String: Record] {
        guard let rawRecords = self.defaults.dictionary(forKey: self.storageKey) as? [String: [String: Double]] else {
            return [:]
        }
        var records: [String: Record] = [:]
        for (key, rawRecord) in rawRecords {
            guard let position = rawRecord["position"], let progress = rawRecord["progress"] else {
                continue
            }
            records[key] = Record(
                position: position,
                progress: progress,
                updatedAt: rawRecord["updatedAt"] ?? 0.0
            )
        }
        return records
    }

    private func save(_ records: [String: Record]) {
        var rawRecords: [String: [String: Double]] = [:]
        for (key, record) in records {
            rawRecords[key] = [
                "position": record.position,
                "progress": record.progress,
                "updatedAt": record.updatedAt
            ]
        }
        self.defaults.set(rawRecords, forKey: self.storageKey)
    }

    private struct Record {
        let position: Double
        let progress: Double
        let updatedAt: TimeInterval
    }
}
