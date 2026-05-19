import Foundation
import UIKit
import Display
import AsyncDisplayKit
import AccountContext
import TelegramPresentationData

public final class UnsupportedMediaPreviewProvider: MediaPreviewProvider {
    public let identifier = "unsupported"

    public init() {}

    public func canHandle(item: MediaBrowserItem) -> Bool {
        return true
    }

    public func makePreviewNode(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) -> MediaPreviewNode {
        return UnsupportedPreviewNode(presentationData: presentationData)
    }
}

final class UnsupportedPreviewNode: ASDisplayNode, MediaPreviewNode {
    private let label: UILabel

    var statusUpdated: ((MediaPreviewPlaybackStatus) -> Void)?
    var aspectRatioUpdated: ((CGFloat) -> Void)?

    var displayNode: ASDisplayNode { return self }

    init(presentationData: PresentationData) {
        self.label = UILabel()
        self.label.font = UIFont.systemFont(ofSize: 14.0)
        self.label.textColor = presentationData.theme.list.itemSecondaryTextColor
        self.label.textAlignment = .center
        self.label.text = "Нет превью"

        super.init()

        self.clipsToBounds = true
        self.cornerRadius = 10.0
    }

    override func didLoad() {
        super.didLoad()
        self.view.addSubview(self.label)
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.label.frame = CGRect(origin: .zero, size: size)
    }
}
