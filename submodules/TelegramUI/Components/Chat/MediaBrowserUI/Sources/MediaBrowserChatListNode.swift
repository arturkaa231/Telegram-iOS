import Foundation
import UIKit
import Display
import AsyncDisplayKit
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData

final class MediaBrowserChatListNode: ASDisplayNode, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private var presentationData: PresentationData

    private let tabsScrollView = UIScrollView()
    private var tabButtons: [UIButton] = []
    private var selectedCategoryIndex: Int = 0

    private let tableView = UITableView(frame: .zero, style: .plain)

    private let dataSource: MediaBrowserChatListDataSource
    private var items: [MediaBrowserChatItem] = []

    var onItemSelected: ((MediaBrowserChatItem) -> Void)?

    init(context: AccountContext, presentationData: PresentationData) {
        self.context = context
        self.presentationData = presentationData
        self.dataSource = MediaBrowserChatListDataSource(context: context)

        super.init()

        self.applyTheme()
    }

    override func didLoad() {
        super.didLoad()

        self.tabsScrollView.showsHorizontalScrollIndicator = false
        self.view.addSubview(self.tabsScrollView)

        for (index, category) in MediaBrowserChatCategory.allCases.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(category.title, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .medium)
            button.tag = index
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
            button.layer.cornerRadius = 18
            button.addTarget(self, action: #selector(self.tabTapped(_:)), for: .touchUpInside)
            self.tabsScrollView.addSubview(button)
            self.tabButtons.append(button)
        }

        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.separatorStyle = .none
        self.tableView.backgroundColor = .clear
        self.tableView.rowHeight = 64.0
        self.tableView.register(MediaBrowserChatItemCell.self, forCellReuseIdentifier: MediaBrowserChatItemCell.reuseIdentifier)
        self.view.addSubview(self.tableView)

        self.dataSource.onItemsUpdated = { [weak self] items in
            guard let self = self else { return }
            self.items = items
            self.tableView.reloadData()
        }
        self.dataSource.load()

        self.refreshTabs()
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.applyTheme()
        self.refreshTabs()
        self.tableView.reloadData()
    }

    private func applyTheme() {
        self.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
    }

    @objc private func tabTapped(_ sender: UIButton) {
        self.selectedCategoryIndex = sender.tag
        let category = MediaBrowserChatCategory.allCases[sender.tag]
        self.dataSource.switchCategory(category)
        self.refreshTabs()
    }

    private func refreshTabs() {
        let theme = self.presentationData.theme
        for (index, button) in self.tabButtons.enumerated() {
            if index == self.selectedCategoryIndex {
                button.backgroundColor = theme.list.itemHighlightedBackgroundColor
                button.setTitleColor(theme.list.itemPrimaryTextColor, for: .normal)
            } else {
                button.backgroundColor = .clear
                button.setTitleColor(theme.list.itemSecondaryTextColor, for: .normal)
            }
        }
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        let tabHeight: CGFloat = 44.0
        self.tabsScrollView.frame = CGRect(x: 0, y: 8, width: size.width, height: tabHeight)
        var x: CGFloat = 12.0
        for button in self.tabButtons {
            button.sizeToFit()
            let width = button.frame.width
            button.frame = CGRect(x: x, y: 4, width: width, height: tabHeight - 8)
            x += width + 6
        }
        self.tabsScrollView.contentSize = CGSize(width: x + 12.0, height: tabHeight)

        let listY = tabHeight + 8 + 8
        self.tableView.frame = CGRect(x: 0, y: listY, width: size.width, height: size.height - listY)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: MediaBrowserChatItemCell.reuseIdentifier, for: indexPath) as! MediaBrowserChatItemCell
        let item = self.items[indexPath.row]
        cell.configure(with: item, context: self.context, presentationData: self.presentationData)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < self.items.count else { return }
        self.onItemSelected?(self.items[indexPath.row])
    }
}
