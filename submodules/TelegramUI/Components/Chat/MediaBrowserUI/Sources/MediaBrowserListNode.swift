import Foundation
import UIKit
import Display
import AsyncDisplayKit
import AccountContext
import TelegramPresentationData

final class MediaBrowserListNode: ASDisplayNode, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private var presentationData: PresentationData
    private let tableView: UITableView
    private let emptyLabel: UILabel
    private let loadingIndicator: UIActivityIndicatorView
    private let retryButton: UIButton

    private var items: [MediaBrowserItem] = []
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

    func updateItems(_ items: [MediaBrowserItem]) {
        self.items = items
        self.emptyLabel.isHidden = !items.isEmpty || loadingState == .loading
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
        cell.configure(with: item, context: self.context, presentationData: self.presentationData)
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
