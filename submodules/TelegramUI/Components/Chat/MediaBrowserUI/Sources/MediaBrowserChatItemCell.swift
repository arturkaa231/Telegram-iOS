import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import AvatarNode

final class MediaBrowserChatItemCell: UITableViewCell {
    static let reuseIdentifier = "MediaBrowserChatItemCell"

    private let folderView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(rgb: 0x008BFF)
        v.layer.cornerRadius = 8.0
        v.clipsToBounds = true
        return v
    }()

    private let folderTabView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(rgb: 0x008BFF)
        v.layer.cornerRadius = 3.0
        v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        return v
    }()

    private let avatarNode: AvatarNode = AvatarNode(font: avatarPlaceholderFont(size: 13.0))

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = UIFont.systemFont(ofSize: 17.0, weight: .regular)
        return l
    }()

    private let mediaThumbView: UIImageView = {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.layer.cornerRadius = 8.0
        v.isHidden = true
        return v
    }()

    private var mediaDisposable: Disposable?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.selectionStyle = .default
        self.backgroundColor = .clear

        self.contentView.addSubview(self.folderTabView)
        self.contentView.addSubview(self.folderView)
        self.contentView.addSubview(self.avatarNode.view)
        self.contentView.addSubview(self.titleLabel)
        self.contentView.addSubview(self.mediaThumbView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.mediaDisposable?.dispose()
        self.mediaDisposable = nil
        self.mediaThumbView.image = nil
        self.mediaThumbView.isHidden = true
    }

    deinit {
        self.mediaDisposable?.dispose()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = contentView.bounds.height
        let w = contentView.bounds.width
        let padding: CGFloat = 16.0
        let folderWidth: CGFloat = 40.0
        let folderHeight: CGFloat = 36.0
        let folderY = (h - folderHeight) / 2.0

        let tabWidth: CGFloat = 16.0
        let tabHeight: CGFloat = 5.0
        self.folderTabView.frame = CGRect(x: padding + 3.0, y: folderY - tabHeight + 3.0, width: tabWidth, height: tabHeight + 4.0)
        self.folderView.frame = CGRect(x: padding, y: folderY, width: folderWidth, height: folderHeight)

        let avatarSize: CGFloat = 28.0
        let avatarX = self.folderView.frame.midX - avatarSize / 2.0
        let avatarY = self.folderView.frame.midY - avatarSize / 2.0
        self.avatarNode.view.frame = CGRect(x: avatarX, y: avatarY, width: avatarSize, height: avatarSize)
        self.avatarNode.updateSize(size: CGSize(width: avatarSize, height: avatarSize))

        let textLeft = self.folderView.frame.maxX + 12.0
        let thumbSize: CGFloat = 18.0
        let titleHeight: CGFloat = 22.0
        let blockTop = folderY - 2.0
        self.titleLabel.frame = CGRect(x: textLeft, y: blockTop, width: w - textLeft - padding, height: titleHeight)

        let thumbY = self.titleLabel.frame.maxY + 4.0
        self.mediaThumbView.frame = CGRect(x: textLeft, y: thumbY, width: thumbSize, height: thumbSize)
    }

    func configure(with item: MediaBrowserChatItem, context: AccountContext, presentationData: PresentationData) {
        let theme = presentationData.theme
        self.titleLabel.text = item.title
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor

        self.avatarNode.setPeer(
            context: context,
            theme: theme,
            peer: item.peer,
            displayDimensions: CGSize(width: 28.0, height: 28.0)
        )

        if let message = item.recentMessageWithMedia {
            self.mediaThumbView.isHidden = false
            self.loadThumbnail(from: message, context: context)
        } else {
            self.mediaThumbView.isHidden = true
        }

        setNeedsLayout()
    }

    private func loadThumbnail(from message: EngineMessage, context: AccountContext) {
        var resource: MediaResource?
        for media in message.media {
            if let image = media as? TelegramMediaImage {
                resource = image.representations.first?.resource
                break
            }
            if let file = media as? TelegramMediaFile, let preview = file.previewRepresentations.first {
                resource = preview.resource
                break
            }
        }
        guard let resource = resource else { return }

        let signal = context.account.postbox.mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: false)
            |> deliverOnMainQueue
        self.mediaDisposable?.dispose()
        self.mediaDisposable = signal.startStrict(next: { [weak self] data in
            guard let self = self else { return }
            if data.complete, let image = UIImage(contentsOfFile: data.path) {
                self.mediaThumbView.image = image
            }
        })
    }
}
