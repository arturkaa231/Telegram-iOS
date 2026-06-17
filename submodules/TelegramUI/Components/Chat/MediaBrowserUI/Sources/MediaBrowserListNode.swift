import Foundation
import UIKit
import Display
import AsyncDisplayKit
import AccountContext
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

final class MediaBrowserListNode: ASDisplayNode, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private var presentationData: PresentationData
    private let tableView: UITableView
    private let emptyLabel: UILabel
    private let loadingIndicator: UIActivityIndicatorView
    private let retryButton: UIButton

    private var items: [MediaBrowserItem] = []
    private var progressRecordsByFileId: [String: MediaBrowserProgressRecord] = [:]
    private var loadingState: MediaBrowserLoadingState = .idle
    private var selectedItemIndex: Int?

    var onNearEnd: (() -> Void)?
    var onRetry: (() -> Void)?
    var onItemSelected: ((MediaBrowserItem) -> Void)?
    var onItemLongPressed: ((MediaBrowserItem) -> Void)?
    var onResetSenderFilter: (() -> Void)?
    var onSelectSender: ((SenderInfo) -> Void)?

    private let senderFilterChip = SenderFilterChipView()
    private let senderDropdown: SenderFilterDropdownView
    private let dropdownDimView = UIView()
    private var availableSenders: [SenderInfo] = []
    private var preSearchState: SenderFilterChipView.FilterState = .multi
    private var isDropdownVisible: Bool = false
    private var keyboardBottomInset: CGFloat = 0.0

    init(context: AccountContext, presentationData: PresentationData) {
        self.context = context
        self.presentationData = presentationData

        self.tableView = UITableView(frame: .zero, style: .plain)
        self.tableView.separatorStyle = .none
        self.tableView.backgroundColor = .clear

        self.emptyLabel = UILabel()
        self.emptyLabel.text = "Нет медиафайлов"
        self.emptyLabel.textAlignment = .center
        self.emptyLabel.textColor = presentationData.theme.list.itemSecondaryTextColor
        self.emptyLabel.font = UIFont.systemFont(ofSize: 16)
        self.emptyLabel.isHidden = true

        self.loadingIndicator = UIActivityIndicatorView(style: .medium)
        self.loadingIndicator.hidesWhenStopped = true

        self.retryButton = UIButton(type: .system)
        self.retryButton.setTitle("Повторить", for: .normal)
        self.retryButton.isHidden = true

        self.senderDropdown = SenderFilterDropdownView(context: context, presentationData: presentationData)

        super.init()

        self.backgroundColor = presentationData.theme.list.plainBackgroundColor
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func didLoad() {
        super.didLoad()

        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.register(MediaBrowserItemCell.self, forCellReuseIdentifier: MediaBrowserItemCell.reuseIdentifier)
        self.tableView.rowHeight = 76

        self.senderFilterChip.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        self.senderFilterChip.layer.cornerRadius = 22.0
        self.senderFilterChip.clipsToBounds = true
        self.senderFilterChip.onTapMulti = { [weak self] in
            self?.handleChipMultiTap()
        }
        self.senderFilterChip.onTapSingle = { [weak self] in
            self?.handleChipSingleTap()
        }
        self.senderFilterChip.onSearchTextChanged = { [weak self] text in
            self?.senderDropdown.applyFilter(text)
            self?.updateDropdownLayout(force: false)
        }
        self.refreshSenderFilterTitle(nil)

        self.dropdownDimView.backgroundColor = .clear
        self.dropdownDimView.isHidden = true
        let dimTap = UITapGestureRecognizer(target: self, action: #selector(self.dimTapped))
        self.dropdownDimView.addGestureRecognizer(dimTap)

        self.senderDropdown.isHidden = true
        self.senderDropdown.onSelect = { [weak self] sender in
            self?.handleDropdownSelection(sender)
        }

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(self.longPressHandler(_:)))
        longPress.minimumPressDuration = 0.5
        self.tableView.addGestureRecognizer(longPress)
        self.view.addSubview(self.tableView)
        self.view.addSubview(self.emptyLabel)
        self.view.addSubview(self.loadingIndicator)
        self.view.addSubview(self.retryButton)
        self.view.addSubview(self.dropdownDimView)
        self.view.addSubview(self.senderDropdown)
        self.view.addSubview(self.senderFilterChip)

        NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)

        self.retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
    }

    @objc private func retryTapped() {
        self.onRetry?()
    }

    @objc private func longPressHandler(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: self.tableView)
        guard let indexPath = self.tableView.indexPathForRow(at: point), indexPath.row < self.items.count else { return }
        self.onItemLongPressed?(self.items[indexPath.row])
    }

    func refreshSenderFilterTitle(_ name: String?) {
        if let name = name {
            self.senderFilterChip.setState(.selected(name: name, username: nil))
        } else {
            self.senderFilterChip.setState(.multi)
        }
    }

    func setAvailableSenders(_ senders: [SenderInfo]) {
        self.availableSenders = senders
        self.senderDropdown.setSenders(senders)
        if self.isDropdownVisible {
            self.updateDropdownLayout(force: true)
        }
    }

    private func handleChipMultiTap() {
        switch self.senderFilterChip.state {
        case .multi:
            break
        case .searching:
            self.dismissDropdown(restoreState: .multi)
            self.onResetSenderFilter?()
        case .selected:
            self.onResetSenderFilter?()
        }
    }

    private func handleChipSingleTap() {
        if self.isDropdownVisible {
            self.dismissDropdown(restoreState: self.preSearchState)
            return
        }
        self.preSearchState = self.senderFilterChip.state
        if case .searching = self.preSearchState {
            self.preSearchState = .multi
        }
        self.showDropdown()
    }

    private func showDropdown() {
        self.senderDropdown.setSenders(self.availableSenders)
        self.senderDropdown.applyFilter("")
        self.isDropdownVisible = true
        self.senderDropdown.isHidden = false
        self.dropdownDimView.isHidden = false
        self.senderFilterChip.activateSearch()
        self.updateDropdownLayout(force: true)
    }

    private func dismissDropdown(restoreState: SenderFilterChipView.FilterState) {
        self.isDropdownVisible = false
        self.senderDropdown.isHidden = true
        self.dropdownDimView.isHidden = true
        self.senderFilterChip.deactivateSearch()
        self.senderFilterChip.setState(restoreState)
        self.setNeedsLayout()
        if let _ = self.validLayoutSize {
            self.relayoutChipAndDropdown()
        }
    }

    private func handleDropdownSelection(_ sender: SenderInfo) {
        self.isDropdownVisible = false
        self.senderDropdown.isHidden = true
        self.dropdownDimView.isHidden = true
        self.senderFilterChip.deactivateSearch()
        self.senderFilterChip.setState(.selected(name: sender.name, username: sender.username))
        self.relayoutChipAndDropdown()
        self.onSelectSender?(sender)
    }

    @objc private func dimTapped() {
        self.dismissDropdown(restoreState: self.preSearchState)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let frameEnd = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let converted = self.view.convert(frameEnd, from: nil)
        self.keyboardBottomInset = max(0, self.view.bounds.height - converted.minY)
        self.relayoutChipAndDropdown()
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        self.keyboardBottomInset = 0
        self.relayoutChipAndDropdown()
    }

    private var validLayoutSize: CGSize?

    private func relayoutChipAndDropdown() {
        guard let size = self.validLayoutSize else { return }
        self.layoutChipAndDropdown(size: size)
    }

    private func layoutChipAndDropdown(size: CGSize) {
        self.senderFilterChip.invalidateIntrinsicContentSize()
        let chipSize = self.senderFilterChip.intrinsicContentSize
        let chipX = (size.width - chipSize.width) / 2.0
        let bottomGap: CGFloat = 12.0
        let chipY = size.height - chipSize.height - bottomGap - self.keyboardBottomInset
        self.senderFilterChip.frame = CGRect(x: chipX, y: max(0, chipY), width: chipSize.width, height: chipSize.height)

        if self.isDropdownVisible {
            self.dropdownDimView.frame = self.view.bounds

            let dropdownMinX: CGFloat = 16.0
            let dropdownMaxX: CGFloat = size.width - 16.0
            let dropdownWidth = max(200.0, dropdownMaxX - dropdownMinX)
            let availableHeight = max(80.0, self.senderFilterChip.frame.minY - 16.0)
            let dropdownHeight = self.senderDropdown.contentHeight(maxHeight: availableHeight)
            if dropdownHeight > 0 {
                let dropdownY = self.senderFilterChip.frame.minY - dropdownHeight - 6.0
                self.senderDropdown.frame = CGRect(x: dropdownMinX, y: max(8.0, dropdownY), width: dropdownWidth, height: dropdownHeight)
            } else {
                self.senderDropdown.frame = .zero
            }
        }

        var insets = self.tableView.contentInset
        let bottomInset = max(0, size.height - self.senderFilterChip.frame.minY) + 8.0
        insets.bottom = bottomInset
        self.tableView.contentInset = insets
        self.tableView.scrollIndicatorInsets = insets
    }

    private func updateDropdownLayout(force: Bool) {
        self.relayoutChipAndDropdown()
    }

    func setSelectedItemIndex(_ index: Int?) {
        let old = self.selectedItemIndex
        self.selectedItemIndex = index
        guard old != index else { return }
        for cell in self.tableView.visibleCells {
            guard let mediaCell = cell as? MediaBrowserItemCell, let indexPath = self.tableView.indexPath(for: cell) else { continue }
            mediaCell.setItemHighlighted(indexPath.row == index, theme: self.presentationData.theme)
        }
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.backgroundColor = presentationData.theme.list.plainBackgroundColor
        self.emptyLabel.textColor = presentationData.theme.list.itemSecondaryTextColor
        self.senderDropdown.updatePresentationData(presentationData)
        self.tableView.reloadData()
    }

    func setEmptyText(_ text: String) {
        self.emptyLabel.text = text
    }

    func updateItems(_ items: [MediaBrowserItem]) {
        self.items = items
        self.emptyLabel.isHidden = !items.isEmpty || loadingState == .loading
        self.tableView.reloadData()
    }

    func updateProgressRecords(_ records: [MediaBrowserProgressRecord]) {
        var progressRecordsByFileId: [String: MediaBrowserProgressRecord] = [:]
        for record in records where record.hasVisibleProgress {
            progressRecordsByFileId[record.fileId] = record
        }
        self.progressRecordsByFileId = progressRecordsByFileId
        self.tableView.reloadData()
    }

    func updateLoadingState(_ state: MediaBrowserLoadingState) {
        self.loadingState = state
        switch state {
        case .loading:
            if items.isEmpty {
                self.loadingIndicator.startAnimating()
            }
            self.retryButton.isHidden = true
        case .error:
            self.loadingIndicator.stopAnimating()
            self.retryButton.isHidden = false
        case .idle, .exhausted:
            self.loadingIndicator.stopAnimating()
            self.retryButton.isHidden = true
            self.emptyLabel.isHidden = !items.isEmpty
        }
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.validLayoutSize = size
        self.tableView.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        self.emptyLabel.frame = CGRect(x: 0, y: size.height / 3, width: size.width, height: 40)
        self.loadingIndicator.center = CGPoint(x: size.width / 2, y: size.height / 3)
        self.retryButton.frame = CGRect(x: size.width / 2 - 50, y: size.height / 3, width: 100, height: 40)
        self.dropdownDimView.frame = self.view.bounds
        self.layoutChipAndDropdown(size: size)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: MediaBrowserItemCell.reuseIdentifier, for: indexPath) as! MediaBrowserItemCell
        let item = self.items[indexPath.row]
        let progressRecord = self.progressRecordsByFileId[MediaBrowserProgressStore.fileId(for: item.messageId)]
        cell.configure(with: item, progressRecord: progressRecord, context: self.context, presentationData: self.presentationData)
        cell.setItemHighlighted(indexPath.row == self.selectedItemIndex, theme: self.presentationData.theme)
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < self.items.count else { return }
        self.onItemSelected?(self.items[indexPath.row])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offsetY = scrollView.contentOffset.y
        let contentHeight = scrollView.contentSize.height
        let frameHeight = scrollView.frame.height

        if contentHeight > 0 && offsetY > contentHeight - frameHeight * 1.25 {
            self.onNearEnd?()
        }
    }
}

private enum OnTVSessionListEntry {
    case resolved(OnTVPlaybackContext)
    case unresolved(OnTVRemotePlaybackContext)

    var sessionId: String {
        switch self {
        case let .resolved(session):
            return session.sessionId
        case let .unresolved(session):
            return session.sessionId
        }
    }
}

final class OnTVSessionsListNode: ASDisplayNode, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private var presentationData: PresentationData
    private let accountPeerId: EnginePeer.Id
    private let tableView: UITableView
    private let emptyLabel: UILabel
    private let loadingIndicator: UIActivityIndicatorView
    private let noticeLabel: UILabel
    private var sessions: [OnTVPlaybackContext] = []
    private var unresolvedSessions: [OnTVRemotePlaybackContext] = []
    private var entries: [OnTVSessionListEntry] = []
    private var isResolvingSessions: Bool = false
    private var activeSessionId: String?

    var onSessionSelected: ((OnTVPlaybackContext) -> Void)?

    init(context: AccountContext, presentationData: PresentationData, accountPeerId: EnginePeer.Id) {
        self.context = context
        self.presentationData = presentationData
        self.accountPeerId = accountPeerId
        self.tableView = UITableView(frame: .zero, style: .plain)
        self.tableView.separatorStyle = .none
        self.tableView.backgroundColor = .clear
        self.tableView.rowHeight = 104.0

        self.emptyLabel = UILabel()
        self.emptyLabel.text = "Нет сессий"
        self.emptyLabel.textAlignment = .center
        self.emptyLabel.textColor = presentationData.theme.list.itemSecondaryTextColor
        self.emptyLabel.font = UIFont.systemFont(ofSize: 16.0)
        self.emptyLabel.isHidden = true

        self.loadingIndicator = UIActivityIndicatorView(style: .medium)
        self.loadingIndicator.hidesWhenStopped = true

        self.noticeLabel = UILabel()
        self.noticeLabel.textAlignment = .center
        self.noticeLabel.textColor = .white
        self.noticeLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
        self.noticeLabel.backgroundColor = UIColor(rgb: 0xFF383C).withAlphaComponent(0.92)
        self.noticeLabel.layer.cornerRadius = 14.0
        self.noticeLabel.clipsToBounds = true
        self.noticeLabel.alpha = 0.0
        self.noticeLabel.isHidden = true

        super.init()

        self.backgroundColor = presentationData.theme.list.plainBackgroundColor
    }

    override func didLoad() {
        super.didLoad()

        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.register(OnTVSessionCell.self, forCellReuseIdentifier: OnTVSessionCell.reuseIdentifier)

        self.view.addSubview(self.tableView)
        self.view.addSubview(self.emptyLabel)
        self.view.addSubview(self.loadingIndicator)
        self.view.addSubview(self.noticeLabel)
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.backgroundColor = presentationData.theme.list.plainBackgroundColor
        self.emptyLabel.textColor = presentationData.theme.list.itemSecondaryTextColor
        self.tableView.reloadData()
    }

    func showNotice(_ text: String) {
        self.noticeLabel.text = text
        self.noticeLabel.isHidden = false
        self.noticeLabel.alpha = 0.0
        UIView.animate(withDuration: 0.18, animations: {
            self.noticeLabel.alpha = 1.0
        }, completion: { _ in
            UIView.animate(withDuration: 0.24, delay: 1.3, options: [], animations: {
                self.noticeLabel.alpha = 0.0
            }, completion: { _ in
                self.noticeLabel.isHidden = true
            })
        })
    }

    func updateSessions(_ sessions: [OnTVPlaybackContext]) {
        self.sessions = sessions
        self.rebuildEntries()
        self.updateEmptyState()
        self.tableView.reloadData()
    }

    func updateUnresolvedSessions(_ sessions: [OnTVRemotePlaybackContext]) {
        self.unresolvedSessions = sessions
        self.rebuildEntries()
        self.updateEmptyState()
        self.tableView.reloadData()
    }

    func updateActiveSessionId(_ sessionId: String?) {
        guard self.activeSessionId != sessionId else { return }
        self.activeSessionId = sessionId
        self.tableView.reloadData()
    }

    func updateResolvingSessions(_ isResolving: Bool) {
        self.isResolvingSessions = isResolving
        self.updateEmptyState()
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.tableView.frame = CGRect(origin: .zero, size: size)
        let emptyY = size.height / 3.0
        self.emptyLabel.frame = CGRect(x: 0.0, y: emptyY, width: size.width, height: 40.0)
        self.loadingIndicator.frame = CGRect(x: (size.width - 28.0) / 2.0, y: emptyY - 34.0, width: 28.0, height: 28.0)
        let noticeWidth = max(0.0, min(180.0, size.width - 24.0))
        self.noticeLabel.frame = CGRect(x: (size.width - noticeWidth) / 2.0, y: 10.0, width: noticeWidth, height: 28.0)
        self.tableView.contentInset = UIEdgeInsets(top: 8.0, left: 0.0, bottom: 16.0, right: 0.0)
        self.tableView.scrollIndicatorInsets = self.tableView.contentInset
    }

    private func updateEmptyState() {
        let shouldShowResolving = self.entries.isEmpty && self.isResolvingSessions
        let shouldShowEmpty = self.entries.isEmpty
        self.emptyLabel.text = shouldShowResolving ? "Загружаем сессии" : "Нет сессий"
        self.emptyLabel.isHidden = !shouldShowEmpty
        if shouldShowResolving {
            self.loadingIndicator.startAnimating()
        } else {
            self.loadingIndicator.stopAnimating()
        }
    }

    func flashLockedSession(_ sessionId: String) {
        guard let index = self.entries.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        guard let cell = self.tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? OnTVSessionCell else { return }
        cell.flashLockedStripe()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: OnTVSessionCell.reuseIdentifier, for: indexPath) as! OnTVSessionCell
        switch self.entries[indexPath.row] {
        case let .resolved(session):
            cell.configure(with: session, accountPeerId: self.accountPeerId, activeSessionId: self.activeSessionId, context: self.context, presentationData: self.presentationData)
        case let .unresolved(session):
            cell.configureUnresolved(with: session, accountPeerId: self.accountPeerId, activeSessionId: self.activeSessionId, presentationData: self.presentationData)
        }
        let sessionId = self.entries[indexPath.row].sessionId
        cell.onTap = { [weak self] in
            self?.selectEntry(sessionId: sessionId)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < self.entries.count else {
            return
        }
        self.selectEntry(sessionId: self.entries[indexPath.row].sessionId)
    }

    private func selectEntry(sessionId: String) {
        guard let entry = self.entries.first(where: { $0.sessionId == sessionId }) else {
            return
        }
        switch entry {
        case let .resolved(session):
            if session.visualStatus(accountPeerId: self.accountPeerId, activeSessionId: self.activeSessionId) == .locked {
                self.flashLockedSession(session.sessionId)
                return
            }
            self.onSessionSelected?(session)
        case let .unresolved(session):
            if session.visualStatus(accountPeerId: self.accountPeerId, activeSessionId: self.activeSessionId) == .locked {
                self.flashLockedSession(session.sessionId)
                return
            }
            self.showNotice("Ищем файл локально")
        }
    }

    private func rebuildEntries() {
        let resolvedIds = Set(self.sessions.map { $0.sessionId })
        self.entries = self.sessions.map(OnTVSessionListEntry.resolved)
        self.entries.append(contentsOf: self.unresolvedSessions.filter { !resolvedIds.contains($0.sessionId) }.map(OnTVSessionListEntry.unresolved))
    }
}

final class OnTVSessionCell: UITableViewCell {
    static let reuseIdentifier = "OnTVSessionCell"
    private static let thumbnailImageCache = NSCache<NSString, UIImage>()

    private let cardView = UIView()
    private let stripeView = UIView()
    private let thumbnailView = UIImageView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let statusLabel = UILabel()
    private let participantsLabel = UILabel()
    private let positionLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let tapButton = UIButton(type: .custom)
    private var thumbnailDisposable: Disposable?
    private var thumbnailFetchDisposable: Disposable?
    private var thumbnailItemId: EngineMessage.Id?
    private var thumbnailResourceKey: String?
    var onTap: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        self.selectionStyle = .default
        self.backgroundColor = .clear
        self.isAccessibilityElement = true
        self.accessibilityTraits = [.button]

        self.cardView.layer.cornerRadius = 12.0
        self.cardView.clipsToBounds = true
        self.cardView.isUserInteractionEnabled = false

        self.thumbnailView.layer.cornerRadius = 16.0
        self.thumbnailView.clipsToBounds = true
        self.thumbnailView.contentMode = .scaleAspectFill
        self.thumbnailView.isUserInteractionEnabled = false

        self.iconView.contentMode = .center
        self.iconView.isUserInteractionEnabled = false

        self.titleLabel.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
        self.titleLabel.numberOfLines = 1
        self.titleLabel.lineBreakMode = .byTruncatingTail
        self.titleLabel.isUserInteractionEnabled = false

        self.metaLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .regular)
        self.metaLabel.numberOfLines = 1
        self.metaLabel.lineBreakMode = .byTruncatingTail
        self.metaLabel.isUserInteractionEnabled = false

        self.statusLabel.font = UIFont.systemFont(ofSize: 11.0, weight: .bold)
        self.statusLabel.textAlignment = .center
        self.statusLabel.layer.cornerRadius = 10.0
        self.statusLabel.clipsToBounds = true
        self.statusLabel.isUserInteractionEnabled = false

        self.participantsLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .medium)
        self.participantsLabel.textAlignment = .right
        self.participantsLabel.isUserInteractionEnabled = false
        self.participantsLabel.isHidden = true

        self.positionLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .regular)
        self.positionLabel.textAlignment = .right
        self.positionLabel.adjustsFontSizeToFitWidth = true
        self.positionLabel.minimumScaleFactor = 0.78
        self.positionLabel.lineBreakMode = .byClipping
        self.positionLabel.isUserInteractionEnabled = false

        self.progressTrack.layer.cornerRadius = 2.0
        self.progressTrack.clipsToBounds = true
        self.progressTrack.isUserInteractionEnabled = false
        self.progressFill.isUserInteractionEnabled = false

        self.contentView.addSubview(self.cardView)
        self.cardView.addSubview(self.stripeView)
        self.cardView.addSubview(self.thumbnailView)
        self.thumbnailView.addSubview(self.iconView)
        self.cardView.addSubview(self.titleLabel)
        self.cardView.addSubview(self.metaLabel)
        self.cardView.addSubview(self.statusLabel)
        self.cardView.addSubview(self.participantsLabel)
        self.cardView.addSubview(self.positionLabel)
        self.cardView.addSubview(self.progressTrack)
        self.progressTrack.addSubview(self.progressFill)

        self.tapButton.backgroundColor = .clear
        self.tapButton.addTarget(self, action: #selector(self.tapped), for: .touchUpInside)
        self.contentView.addSubview(self.tapButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.onTap = nil
        self.thumbnailDisposable?.dispose()
        self.thumbnailDisposable = nil
        self.thumbnailFetchDisposable?.dispose()
        self.thumbnailFetchDisposable = nil
        self.thumbnailItemId = nil
        self.thumbnailResourceKey = nil
        self.thumbnailView.image = nil
        self.iconView.isHidden = false
        self.iconView.image = nil
        self.iconView.tintColor = nil
    }

    deinit {
        self.thumbnailDisposable?.dispose()
        self.thumbnailFetchDisposable?.dispose()
    }

    @objc private func tapped() {
        self.onTap?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let bounds = self.contentView.bounds
        self.cardView.frame = CGRect(x: 12.0, y: 6.0, width: bounds.width - 24.0, height: bounds.height - 12.0)
        let cardBounds = self.cardView.bounds
        self.stripeView.frame = CGRect(x: 0.0, y: 0.0, width: 4.0, height: cardBounds.height)

        let thumbSize: CGFloat = 56.0
        self.thumbnailView.frame = CGRect(x: 16.0, y: 16.0, width: thumbSize, height: thumbSize)
        self.iconView.frame = self.thumbnailView.bounds

        let statusSize = self.statusLabel.sizeThatFits(CGSize(width: 90.0, height: 20.0))
        let statusWidth = max(52.0, statusSize.width + 16.0)
        self.statusLabel.frame = CGRect(x: cardBounds.width - statusWidth - 14.0, y: 14.0, width: statusWidth, height: 20.0)

        let rightColumnWidth: CGFloat = 104.0
        self.participantsLabel.frame = CGRect(x: cardBounds.width - rightColumnWidth - 14.0, y: 40.0, width: rightColumnWidth, height: 18.0)
        self.positionLabel.frame = CGRect(x: cardBounds.width - rightColumnWidth - 14.0, y: 60.0, width: rightColumnWidth, height: 18.0)

        let textLeft = self.thumbnailView.frame.maxX + 12.0
        let textRight = min(self.statusLabel.frame.minX - 10.0, self.participantsLabel.frame.minX - 10.0)
        let textWidth = max(44.0, textRight - textLeft)
        self.titleLabel.frame = CGRect(x: textLeft, y: 17.0, width: textWidth, height: 22.0)
        self.metaLabel.frame = CGRect(x: textLeft, y: 43.0, width: textWidth, height: 18.0)

        let progressX = textLeft
        let progressY: CGFloat = cardBounds.height - 18.0
        let progressWidth = max(44.0, cardBounds.width - progressX - 14.0)
        self.progressTrack.frame = CGRect(x: progressX, y: progressY, width: progressWidth, height: 4.0)
        let progress = max(0.0, min(1.0, self.progressValue))
        self.progressFill.frame = CGRect(x: 0.0, y: 0.0, width: progressWidth * progress, height: 4.0)
        self.tapButton.frame = bounds
        self.contentView.bringSubviewToFront(self.tapButton)
    }

    private var progressValue: CGFloat = 0.0

    func configure(with session: OnTVPlaybackContext, accountPeerId: EnginePeer.Id, activeSessionId: String?, context: AccountContext, presentationData: PresentationData) {
        let visualStatus = session.visualStatus(accountPeerId: accountPeerId, activeSessionId: activeSessionId)

        self.configureCommon(
            title: session.item.fileName.isEmpty ? "Без названия" : session.item.fileName,
            meta: "\(session.item.senderName) · \(mediaBrowserDateString(session.item.timestamp, locale: Locale(identifier: presentationData.strings.baseLanguageCode)))",
            position: session.position,
            progress: session.progress,
            participantCount: session.participantCount,
            visualStatus: visualStatus,
            thumbnailItem: session.item,
            context: context,
            presentationData: presentationData
        )
    }

    func configureUnresolved(with session: OnTVRemotePlaybackContext, accountPeerId: EnginePeer.Id, activeSessionId: String?, presentationData: PresentationData) {
        let visualStatus = session.visualStatus(accountPeerId: accountPeerId, activeSessionId: activeSessionId)
        let title: String
        if let fileName = session.fileName, !fileName.isEmpty {
            title = fileName
        } else {
            title = "Сессия на телике"
        }

        self.configureCommon(
            title: title,
            meta: "Ищем файл локально",
            position: session.position,
            progress: session.progress,
            participantCount: session.participantCount,
            visualStatus: visualStatus,
            thumbnailItem: nil,
            context: nil,
            presentationData: presentationData
        )
    }

    private func configureCommon(title: String, meta: String, position: Double, progress: CGFloat, participantCount: Int, visualStatus: OnTVCardVisualStatus, thumbnailItem: MediaBrowserItem?, context: AccountContext?, presentationData: PresentationData) {
        let theme = presentationData.theme

        self.cardView.backgroundColor = theme.list.itemBlocksBackgroundColor.withAlphaComponent(0.68)
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.metaLabel.textColor = theme.list.itemSecondaryTextColor
        self.participantsLabel.textColor = theme.list.itemSecondaryTextColor
        self.positionLabel.textColor = theme.list.itemSecondaryTextColor
        self.progressTrack.backgroundColor = theme.list.itemSecondaryTextColor.withAlphaComponent(0.16)

        self.titleLabel.text = title
        self.metaLabel.text = meta
        self.participantsLabel.text = ""
        self.participantsLabel.isHidden = true
        self.positionLabel.text = Self.elapsedRemainingString(position: position, progress: progress)
        self.progressValue = progress

        let iconName: String
        let statusText: String
        let statusColor: UIColor
        switch visualStatus {
        case .live:
            iconName = "play.fill"
            statusText = "LIVE"
            statusColor = UIColor(rgb: 0x2DA547)
        case .ended:
            iconName = "clock.fill"
            statusText = "ENDED"
            statusColor = UIColor(rgb: 0x8E8E93)
        case .locked:
            iconName = "lock.fill"
            statusText = "LOCKED"
            statusColor = UIColor(rgb: 0x05614C)
        }

        self.statusLabel.text = statusText
        self.statusLabel.textColor = .white
        self.statusLabel.backgroundColor = statusColor
        self.stripeView.backgroundColor = statusColor
        self.progressFill.backgroundColor = statusColor
        self.configureThumbnail(item: thumbnailItem, context: context, theme: theme, placeholderIconName: iconName, statusColor: statusColor)
        self.accessibilityLabel = "\(statusText), \(title), \(meta), \(self.positionLabel.text ?? "")"

        self.setNeedsLayout()
    }

    private func configureThumbnail(item: MediaBrowserItem?, context: AccountContext?, theme: PresentationTheme, placeholderIconName: String, statusColor: UIColor) {
        var thumbResource: MediaResource?
        var thumbMediaReference: AnyMediaReference?
        if let item = item {
            let messageRef = MessageReference(item.message)
            for media in item.message.media {
                if let image = media as? TelegramMediaImage, let representation = image.representations.first {
                    thumbResource = representation.resource
                    thumbMediaReference = .message(message: messageRef, media: image)
                    break
                }
                if let file = media as? TelegramMediaFile, let preview = file.previewRepresentations.first {
                    thumbResource = preview.resource
                    thumbMediaReference = .message(message: messageRef, media: file)
                    break
                }
                if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
                    let webpageRef = WebpageReference(webpage)
                    if let image = content.image, let representation = image.representations.first {
                        thumbResource = representation.resource
                        thumbMediaReference = .webPage(webPage: webpageRef, media: image)
                        break
                    }
                    if let file = content.file, let preview = file.previewRepresentations.first {
                        thumbResource = preview.resource
                        thumbMediaReference = .webPage(webPage: webpageRef, media: file)
                        break
                    }
                }
            }
        }

        let thumbnailKey = thumbResource?.id.stringRepresentation
        let shouldReloadThumbnail = self.thumbnailResourceKey != thumbnailKey
        self.thumbnailItemId = item?.messageId
        self.thumbnailView.backgroundColor = statusColor.withAlphaComponent(0.16)
        self.iconView.image = UIImage(systemName: placeholderIconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22.0, weight: .semibold))
        self.iconView.tintColor = statusColor
        if shouldReloadThumbnail {
            self.thumbnailDisposable?.dispose()
            self.thumbnailDisposable = nil
            self.thumbnailFetchDisposable?.dispose()
            self.thumbnailFetchDisposable = nil
            self.thumbnailResourceKey = thumbnailKey
            if let thumbnailKey = thumbnailKey, let cachedImage = Self.thumbnailImageCache.object(forKey: thumbnailKey as NSString) {
                self.thumbnailView.image = cachedImage
                self.iconView.isHidden = true
            } else {
                self.thumbnailView.image = nil
                self.iconView.isHidden = false
            }
        } else if self.thumbnailView.image != nil {
            self.iconView.isHidden = true
        } else {
            self.iconView.isHidden = false
        }

        guard let item = item, let context = context, let resource = thumbResource else {
            return
        }

        let itemId = item.messageId
        if thumbnailKey.flatMap({ Self.thumbnailImageCache.object(forKey: $0 as NSString) }) == nil && (shouldReloadThumbnail || self.thumbnailDisposable == nil) {
            let signal = context.account.postbox.mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: false)
            |> deliverOnMainQueue
            self.thumbnailDisposable = signal.startStrict(next: { [weak self] data in
                guard let self = self, self.thumbnailItemId == itemId else {
                    return
                }
                guard self.thumbnailResourceKey == resource.id.stringRepresentation else {
                    return
                }
                if data.complete, let image = UIImage(contentsOfFile: data.path) {
                    Self.thumbnailImageCache.setObject(image, forKey: resource.id.stringRepresentation as NSString)
                    self.thumbnailView.image = image
                    self.iconView.isHidden = true
                }
            })
            if let mediaRef = thumbMediaReference {
                let resourceRef = MediaResourceReference.media(media: mediaRef, resource: resource)
                let fetchSignal = fetchedMediaResource(mediaBox: context.account.postbox.mediaBox, userLocation: .other, userContentType: .image, reference: resourceRef)
                self.thumbnailFetchDisposable = fetchSignal.startStrict(next: { _ in })
            }
        }
    }

    func flashLockedStripe() {
        let oldColor = self.stripeView.backgroundColor
        UIView.animate(withDuration: 0.1, animations: {
            self.stripeView.backgroundColor = UIColor(rgb: 0xFF383C)
        }, completion: { _ in
            UIView.animate(withDuration: 0.25) {
                self.stripeView.backgroundColor = oldColor
            }
        })
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0.0, seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func elapsedRemainingString(position: Double, progress: CGFloat) -> String {
        let elapsed = max(0.0, position)
        let normalizedProgress = max(0.0, min(1.0, Double(progress)))
        guard normalizedProgress > 0.001 else {
            return Self.formatTime(elapsed)
        }
        let duration = elapsed / normalizedProgress
        guard duration.isFinite, duration > elapsed else {
            return Self.formatTime(elapsed)
        }
        return "\(Self.formatTime(elapsed)) / -\(Self.formatTime(duration - elapsed))"
    }
}
