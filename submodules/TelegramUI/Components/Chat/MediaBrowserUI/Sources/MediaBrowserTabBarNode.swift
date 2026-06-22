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
    private let segmentedBackgroundView: UIView
    private var tabButtons: [UIButton] = []
    private var selectedIndex: Int = MediaBrowserTab.allFiles.rawValue

    var onTabChanged: ((MediaBrowserTab) -> Void)?

    init(presentationData: PresentationData, onBack: @escaping () -> Void) {
        self.presentationData = presentationData
        self.backAction = onBack
        self.scrollView = UIScrollView()
        self.scrollView.showsHorizontalScrollIndicator = false
        self.backButton = UIButton(type: .system)
        self.segmentedBackgroundView = UIView()

        super.init()

        self.backgroundColor = .black
    }

    override func didLoad() {
        super.didLoad()

        self.backButton.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20.0, weight: .semibold)), for: .normal)
        self.backButton.tintColor = .white
        self.backButton.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        self.backButton.layer.cornerRadius = 20.0
        self.backButton.clipsToBounds = true
        self.backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        self.view.addSubview(self.backButton)

        self.scrollView.alwaysBounceHorizontal = true
        self.segmentedBackgroundView.backgroundColor = UIColor.black.withAlphaComponent(0.64)
        self.segmentedBackgroundView.layer.borderWidth = 1.0
        self.segmentedBackgroundView.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        self.segmentedBackgroundView.layer.cornerRadius = 19.0
        self.segmentedBackgroundView.clipsToBounds = true
        self.view.addSubview(self.segmentedBackgroundView)
        self.view.addSubview(self.scrollView)

        let tabs = MediaBrowserTab.allCases
        for (index, tab) in tabs.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(tab.title, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
            button.tag = index
            button.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            button.layer.cornerRadius = 17
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
        self.backgroundColor = .black
        self.backButton.tintColor = .white
        updateTabAppearance()
    }

    func setSelectedTab(_ tab: MediaBrowserTab) {
        self.selectedIndex = tab.rawValue
        self.updateTabAppearance()
        self.scrollSelectedTabIntoView(animated: false)
    }

    @objc private func tabTapped(_ sender: UIButton) {
        self.selectedIndex = sender.tag
        updateTabAppearance()
        self.scrollSelectedTabIntoView(animated: true)
        let tab = MediaBrowserTab.allCases[sender.tag]
        self.onTabChanged?(tab)
    }

    private func updateTabAppearance() {
        for (index, button) in self.tabButtons.enumerated() {
            if index == self.selectedIndex {
                button.backgroundColor = UIColor.white.withAlphaComponent(0.15)
                button.setTitleColor(.white, for: .normal)
            } else {
                button.backgroundColor = .clear
                button.setTitleColor(UIColor.white.withAlphaComponent(0.92), for: .normal)
            }
        }
    }

    func updateLayout(width: CGFloat, transition: ContainedViewLayoutTransition) {
        let backWidth: CGFloat = 52.0
        self.backButton.frame = CGRect(x: 12.0, y: 4.0, width: 40.0, height: 40.0)

        let scrollX = backWidth + 8.0
        let scrollWidth = max(0.0, width - scrollX - 12.0)
        self.segmentedBackgroundView.frame = CGRect(x: scrollX, y: 4.0, width: scrollWidth, height: 40.0)
        self.scrollView.frame = self.segmentedBackgroundView.frame

        var x: CGFloat = 4.0
        for button in self.tabButtons {
            let title = button.title(for: .normal) ?? ""
            let font = button.titleLabel?.font ?? UIFont.systemFont(ofSize: 14.0, weight: .medium)
            let titleWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
            let buttonWidth = max(44.0, titleWidth + button.contentEdgeInsets.left + button.contentEdgeInsets.right)
            button.frame = CGRect(x: x, y: 3.0, width: buttonWidth, height: 34.0)
            x += buttonWidth + 2.0
        }
        self.scrollView.contentSize = CGSize(width: x + 4.0, height: 40.0)
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
