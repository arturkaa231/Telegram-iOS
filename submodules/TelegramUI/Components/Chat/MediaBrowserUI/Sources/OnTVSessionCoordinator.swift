import Foundation
import CoreGraphics
import TelegramCore
import SwiftSignalKit

final class OnTVSessionCoordinator {
    private let store: OnTVSessionsStore
    private let accountPeerId: EnginePeer.Id

    private var activeSessionId: String?
    private var activeSessionIsHolder: Bool = false
    private var activePlaybackStarted: Bool = false
    private var suppressViewerLeaveForRemotePlayback: Bool = false
    private var lastSentPlaybackIsPlaying: Bool?
    private var lastLocalProgressUpdateAt: Double = 0.0
    private var lastLocalProgressPosition: Double = 0.0
    private var lastRemoteStateSentAt: Double = 0.0
    private var lastRemoteStatePosition: Double = 0.0
    private var pendingHolderSessionId: String?
    private var ignorePulseOffUntil: Double = 0.0

    var onSessionsUpdated: (([OnTVPlaybackContext]) -> Void)? {
        didSet {
            self.store.onSessionsUpdated = self.onSessionsUpdated
        }
    }
    var onUnresolvedSessionsUpdated: (([OnTVRemotePlaybackContext]) -> Void)? {
        didSet {
            self.store.onUnresolvedSessionsUpdated = self.onUnresolvedSessionsUpdated
        }
    }
    var onResolvingSessionsChanged: ((Bool) -> Void)? {
        didSet {
            self.store.onResolvingSessionsChanged = self.onResolvingSessionsChanged
        }
    }
    var onResolveMediaItems: (([EngineMessage.Id]) -> Void)? {
        didSet {
            self.store.onResolveMediaItems = self.onResolveMediaItems
        }
    }
    var onNeedsMoreMediaItems: (() -> Void)? {
        didSet {
            self.store.onNeedsMoreMediaItems = self.onNeedsMoreMediaItems
        }
    }

    var onActiveHeldSessionChanged: ((String?) -> Void)?
    var onPulseActiveChanged: ((Bool, Bool) -> Void)?
    var onAudienceChanged: ((Int) -> Void)?
    var onFlashLockedSession: ((String) -> Void)?
    var onShowNotice: ((String) -> Void)?
    var onOpenSession: ((OnTVPlaybackContext, Bool) -> Void)?
    var onApplyRemotePlaybackAction: ((Double, CGFloat, Bool) -> Void)?
    var onApplyRemotePlaybackState: ((Double, CGFloat) -> Void)?
    var currentPlaybackState: (() -> (position: Double, progress: CGFloat))?
    var currentPlaybackIsPlaying: (() -> Bool)?

    init(store: OnTVSessionsStore, accountPeerId: EnginePeer.Id) {
        self.store = store
        self.accountPeerId = accountPeerId

        self.store.onPlayerEvent = { [weak self] event in
            self?.handleRemotePlayerEvent(event)
        }
        self.store.onSessionEvent = { [weak self] event in
            self?.handleRemoteSessionEvent(event)
        }
        self.store.onStateConflict = { [weak self] in
            guard let self = self else { return }
            self.clearActiveSession()
            self.onPulseActiveChanged?(false, true)
            self.onShowNotice?("Пульт занят")
        }
    }

    func switchPeer(_ peerId: EnginePeer.Id) {
        self.leaveActiveViewerSessionIfNeeded()
        self.clearActiveSession()
        self.store.switchPeer(peerId)
    }

    func registerLoadedItems(_ items: [MediaBrowserItem]) {
        self.store.registerLoadedItems(items)
    }

    func reload() {
        self.store.reload()
    }

    func prepareForLocalItemChange(isPulseActive: Bool, displayedItem: MediaBrowserItem?, position: Double, progress: CGFloat) -> Bool {
        let shouldCarryPulse = self.activeSessionIsHolder && isPulseActive
        if shouldCarryPulse {
            _ = self.store.endHeldPulses(for: displayedItem, position: position, progress: progress)
            self.clearActiveSession()
        } else {
            self.leaveActiveViewerSessionIfNeeded()
        }
        return shouldCarryPulse
    }

    func stopForLocalItemSelection(isPulseActive: Bool, displayedItem: MediaBrowserItem?, position: Double, progress: CGFloat) {
        if isPulseActive || self.activeSessionIsHolder {
            _ = self.store.endHeldPulses(for: displayedItem, position: position, progress: progress)
            self.onPulseActiveChanged?(false, true)
            self.onAudienceChanged?(0)
            self.clearActiveSession()
        } else {
            self.leaveActiveViewerSessionIfNeeded()
        }
    }

    func startPulse(item: MediaBrowserItem, position: Double, progress: CGFloat) -> OnTVPlaybackContext {
        let session = self.store.startPulse(item: item, position: position, progress: progress)
        self.pendingHolderSessionId = session.sessionId
        self.ignorePulseOffUntil = Date().timeIntervalSince1970 + 1.0
        self.setActiveSession(session.sessionId, isHolder: true)
        self.onPulseActiveChanged?(true, true)
        self.onAudienceChanged?(session.participantCount)
        if self.currentPlaybackIsPlaying?() == true {
            self.sendActivePlayerAction(isPlaying: true)
        }
        return session
    }

    func handlePulseChanged(_ isOn: Bool, displayedItem: MediaBrowserItem?, position: Double, progress: CGFloat) {
        if isOn {
            guard self.store.isReady else {
                self.onPulseActiveChanged?(false, true)
                self.onShowNotice?("Сначала подключи На телике")
                return
            }
            guard let item = displayedItem else {
                self.onPulseActiveChanged?(false, true)
                return
            }
            guard item.playableSource.supportsRemoteSync else {
                self.onPulseActiveChanged?(false, true)
                self.onShowNotice?("Пульт для этого источника пока недоступен")
                return
            }
            _ = self.startPulse(item: item, position: position, progress: progress)
        } else {
            if self.activeSessionIsHolder && Date().timeIntervalSince1970 < self.ignorePulseOffUntil {
                self.onPulseActiveChanged?(true, false)
                return
            }
            self.pendingHolderSessionId = nil
            self.ignorePulseOffUntil = 0.0
            let sessions = self.store.endHeldPulses(for: displayedItem, position: position, progress: progress)
            self.clearActiveSession()
            self.onAudienceChanged?(sessions.first?.participantCount ?? 0)
        }
    }

    func handlePlaybackStatusChanged(_ status: MediaPreviewPlaybackStatus) {
        if self.activeSessionIsHolder {
            switch status {
            case .playing:
                self.sendActivePlayerAction(isPlaying: true)
            case .paused, .ended:
                self.sendActivePlayerAction(isPlaying: false)
            case .idle, .loading, .error:
                break
            }
            return
        }

        guard self.activeSessionId != nil else {
            return
        }
        switch status {
        case .playing:
            self.activePlaybackStarted = true
        case .paused:
            guard !self.suppressViewerLeaveForRemotePlayback else {
                return
            }
            if self.activePlaybackStarted {
                self.leaveActiveViewerSessionIfNeeded()
            }
        case .ended, .error:
            self.leaveActiveViewerSessionIfNeeded()
        case .idle, .loading:
            break
        }
    }

    func handleSeekRequested(position: Double, progress: CGFloat) {
        guard let sessionId = self.activeSessionId, self.activeSessionIsHolder else {
            return
        }
        self.store.sendPlayerEvent(.state(sessionId: sessionId, position: position, progress: progress))
    }

    func handlePlaybackPositionUpdated(position: Double, progress: CGFloat, isPlaying: Bool) {
        guard let sessionId = self.activeSessionId else {
            return
        }
        let now = Date().timeIntervalSince1970
        if now - self.lastLocalProgressUpdateAt > 0.35 || abs(position - self.lastLocalProgressPosition) > 0.35 {
            self.lastLocalProgressUpdateAt = now
            self.lastLocalProgressPosition = position
            self.store.updatePlaybackProgress(sessionId: sessionId, position: position, progress: progress)
        }
        guard self.activeSessionIsHolder, isPlaying else {
            return
        }
        if now - self.lastRemoteStateSentAt > 1.0 || abs(position - self.lastRemoteStatePosition) > 2.0 {
            self.lastRemoteStateSentAt = now
            self.lastRemoteStatePosition = position
            self.store.sendPlayerEvent(.state(sessionId: sessionId, position: position, progress: progress))
        }
    }

    func activateSession(_ session: OnTVPlaybackContext, displayedItem: MediaBrowserItem?, position: Double, progress: CGFloat) {
        if self.activeSessionId == session.sessionId && self.activeSessionIsHolder {
            self.onFlashLockedSession?(session.sessionId)
            return
        }

        if self.activeSessionIsHolder {
            _ = self.store.endHeldPulses(for: displayedItem, position: position, progress: progress)
            self.onPulseActiveChanged?(false, true)
            self.onAudienceChanged?(0)
            self.clearActiveSession()
        } else {
            self.leaveActiveViewerSessionIfNeeded()
        }

        guard let activation = self.store.activate(session.sessionId) else {
            return
        }
        switch activation {
        case let .locked(context):
            self.onFlashLockedSession?(context.sessionId)
        case let .joined(context):
            self.onOpenSession?(context, false)
            self.onPulseActiveChanged?(false, true)
            self.onAudienceChanged?(context.participantCount)
            self.setActiveSession(context.sessionId, isHolder: false)
        case let .resumed(context):
            self.onOpenSession?(context, true)
            self.onPulseActiveChanged?(true, true)
            self.onAudienceChanged?(context.participantCount)
            self.setActiveSession(context.sessionId, isHolder: true)
        }
    }

    func leaveActiveViewerSessionIfNeeded() {
        guard let sessionId = self.activeSessionId, !self.activeSessionIsHolder else {
            return
        }
        let session = self.store.leave(sessionId)
        self.clearActiveSession()
        self.onAudienceChanged?(session?.participantCount ?? 0)
    }

    private func setActiveSession(_ sessionId: String, isHolder: Bool) {
        self.activeSessionId = sessionId
        self.activeSessionIsHolder = isHolder
        self.activePlaybackStarted = false
        self.lastSentPlaybackIsPlaying = nil
        self.lastLocalProgressUpdateAt = 0.0
        self.lastLocalProgressPosition = 0.0
        self.lastRemoteStateSentAt = 0.0
        self.lastRemoteStatePosition = 0.0
        self.onActiveHeldSessionChanged?(isHolder ? sessionId : nil)
    }

    private func clearActiveSession() {
        self.activeSessionId = nil
        self.activeSessionIsHolder = false
        self.activePlaybackStarted = false
        self.lastSentPlaybackIsPlaying = nil
        self.lastLocalProgressUpdateAt = 0.0
        self.lastLocalProgressPosition = 0.0
        self.lastRemoteStateSentAt = 0.0
        self.lastRemoteStatePosition = 0.0
        self.pendingHolderSessionId = nil
        self.ignorePulseOffUntil = 0.0
        self.onActiveHeldSessionChanged?(nil)
    }

    private func sendActivePlayerAction(isPlaying: Bool) {
        guard let sessionId = self.activeSessionId, self.activeSessionIsHolder else {
            return
        }
        if self.lastSentPlaybackIsPlaying == isPlaying {
            return
        }
        self.lastSentPlaybackIsPlaying = isPlaying
        let playbackState = self.currentPlaybackState?() ?? (position: 0.0, progress: 0.0)
        self.store.sendPlayerEvent(.action(
            sessionId: sessionId,
            position: playbackState.position,
            progress: playbackState.progress,
            isPlaying: isPlaying
        ))
    }

    private func handleRemotePlayerEvent(_ event: OnTVPlayerEvent) {
        let sessionId: String
        switch event {
        case let .action(id, _, _, _):
            sessionId = id
        case let .state(id, _, _):
            sessionId = id
        }
        guard self.activeSessionId == sessionId, !self.activeSessionIsHolder else {
            return
        }

        self.suppressViewerLeaveForRemotePlayback = true
        switch event {
        case let .action(_, position, progress, isPlaying):
            self.onApplyRemotePlaybackAction?(position, progress, isPlaying)
            if isPlaying {
                self.activePlaybackStarted = true
            }
        case let .state(_, position, progress):
            self.onApplyRemotePlaybackState?(position, progress)
        }
        Queue.mainQueue().after(1.5) { [weak self] in
            self?.suppressViewerLeaveForRemotePlayback = false
        }
    }

    private func handleRemoteSessionEvent(_ event: OnTVSessionEvent) {
        switch event {
        case let .pulseTaken(sessionId, pulseUserId):
            if self.activeSessionId == sessionId && pulseUserId == self.accountPeerId {
                self.pendingHolderSessionId = nil
                if !self.activeSessionIsHolder {
                    self.setActiveSession(sessionId, isHolder: true)
                }
                self.onPulseActiveChanged?(true, false)
                return
            }
            guard self.activeSessionId == sessionId, self.activeSessionIsHolder, pulseUserId != self.accountPeerId else {
                return
            }
            self.pendingHolderSessionId = nil
            self.ignorePulseOffUntil = 0.0
            self.clearActiveSession()
            self.onPulseActiveChanged?(false, true)
            self.onShowNotice?("Пульт забрал другой участник")
        case let .pulseEnded(sessionId, _, _, _):
            guard self.activeSessionId == sessionId else {
                return
            }
            if self.pendingHolderSessionId == sessionId && Date().timeIntervalSince1970 < self.ignorePulseOffUntil {
                self.onPulseActiveChanged?(true, false)
                return
            }
            self.clearActiveSession()
            self.onPulseActiveChanged?(false, true)
        case .participantJoined, .participantLeft:
            break
        }
    }
}
