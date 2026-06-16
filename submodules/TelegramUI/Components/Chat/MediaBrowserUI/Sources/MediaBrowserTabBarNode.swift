import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramPresentationData

final class MediaBrowserTabBarNode: ASDisplayNode {
    private var presentationData: PresentationData
    private let backAction: () -> Void
    private let scrollView: UIScrollView
    private let backButton: UIButton
    private var tabButtons: [UIButton] = []
    private var selectedIndex: Int = MediaBrowserTab.allFiles.rawValue

    var onTabChanged: ((MediaBrowserTab) -> Void)?

    init(presentationData: PresentationData, onBack: @escaping () -> Void) {
        self.presentationData = presentationData
        self.backAction = onBack
        self.scrollView = UIScrollView()
        self.scrollView.showsHorizontalScrollIndicator = false
        self.backButton = UIButton(type: .system)

        super.init()

        self.backgroundColor = presentationData.theme.list.plainBackgroundColor
    }

    override func didLoad() {
        super.didLoad()

        self.backButton.setTitle("‹", for: .normal)
        self.backButton.titleLabel?.font = UIFont.systemFont(ofSize: 28, weight: .medium)
        self.backButton.tintColor = presentationData.theme.list.itemAccentColor
        self.backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        self.view.addSubview(self.backButton)

        self.scrollView.alwaysBounceHorizontal = true
        self.view.addSubview(self.scrollView)

        let tabs = MediaBrowserTab.allCases
        for (index, tab) in tabs.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(tab.title, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            button.tag = index
            button.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            button.layer.cornerRadius = 16
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
            self.scrollView.addSubview(button)
            self.tabButtons.append(button)
        }

        updateTabAppearance()
    }

    @objc private func backTapped() {
        self.backAction()
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.backgroundColor = presentationData.theme.list.plainBackgroundColor
        self.backButton.tintColor = presentationData.theme.list.itemAccentColor
        updateTabAppearance()
    }

    @objc private func tabTapped(_ sender: UIButton) {
        self.selectedIndex = sender.tag
        updateTabAppearance()
        self.scrollSelectedTabIntoView(animated: true)
        let tab = MediaBrowserTab.allCases[sender.tag]
        self.onTabChanged?(tab)
    }

    private func updateTabAppearance() {
        let theme = self.presentationData.theme
        for (index, button) in self.tabButtons.enumerated() {
            if index == self.selectedIndex {
                button.backgroundColor = theme.list.itemAccentColor.withAlphaComponent(0.2)
                button.setTitleColor(theme.list.itemAccentColor, for: .normal)
            } else {
                button.backgroundColor = theme.list.itemBlocksBackgroundColor.withAlphaComponent(0.3)
                button.setTitleColor(theme.list.itemPrimaryTextColor, for: .normal)
            }
        }
    }

    func updateLayout(width: CGFloat, transition: ContainedViewLayoutTransition) {
        let backWidth: CGFloat = 44.0
        self.backButton.frame = CGRect(x: 0, y: 0, width: backWidth, height: 44)

        self.scrollView.frame = CGRect(x: backWidth, y: 0, width: width - backWidth, height: 44)

        var x: CGFloat = 8
        for button in self.tabButtons {
            let title = button.title(for: .normal) ?? ""
            let font = button.titleLabel?.font ?? UIFont.systemFont(ofSize: 14.0, weight: .medium)
            let titleWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
            let buttonWidth = max(44.0, titleWidth + button.contentEdgeInsets.left + button.contentEdgeInsets.right)
            button.frame = CGRect(x: x, y: 5, width: buttonWidth, height: 34)
            x += buttonWidth + 8
        }
        self.scrollView.contentSize = CGSize(width: x, height: 44)
        self.scrollSelectedTabIntoView(animated: false)
    }

    private func scrollSelectedTabIntoView(animated: Bool) {
        guard self.selectedIndex >= 0 && self.selectedIndex < self.tabButtons.count else { return }
        if self.selectedIndex <= MediaBrowserTab.allFiles.rawValue {
            self.scrollView.setContentOffset(.zero, animated: animated)
            return
        }
        let selectedFrame = self.tabButtons[self.selectedIndex].frame.insetBy(dx: -8.0, dy: 0.0)
        self.scrollView.scrollRectToVisible(selectedFrame, animated: animated)
    }
}
