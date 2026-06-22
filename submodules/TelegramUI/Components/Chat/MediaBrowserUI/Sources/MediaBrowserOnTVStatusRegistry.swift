import Foundation
import SwiftSignalKit
import TelegramCore

public final class MediaBrowserOnTVStatusRegistry {
    public static let shared = MediaBrowserOnTVStatusRegistry()

    private var values: [EnginePeer.Id: Bool] = [:]
    private var promises: [EnginePeer.Id: ValuePromise<Bool>] = [:]

    private init() {
    }

    public func isLive(peerId: EnginePeer.Id) -> Signal<Bool, NoError> {
        return self.promise(peerId: peerId).get()
    }

    public func update(peerId: EnginePeer.Id, isLive: Bool) {
        self.values[peerId] = isLive
        self.promise(peerId: peerId).set(isLive)
    }

    private func promise(peerId: EnginePeer.Id) -> ValuePromise<Bool> {
        if let promise = self.promises[peerId] {
            return promise
        }
        let promise = ValuePromise<Bool>(self.values[peerId] ?? false, ignoreRepeated: true)
        self.promises[peerId] = promise
        return promise
    }
}
