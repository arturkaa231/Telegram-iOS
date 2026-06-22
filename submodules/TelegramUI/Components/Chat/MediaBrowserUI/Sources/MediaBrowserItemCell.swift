import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import AvatarNode

func mediaBrowserDateString(_ timestamp: Int32, locale: Locale) -> String {
    let date = Date(timeIntervalSince1970: Double(timestamp))
    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.locale = locale
    if calendar.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
    } else {
        formatter.dateFormat = "d MMM yyyy"
    }
    return formatter.string(from: date)
}

final class MediaBrowserItemCell: UITableViewCell {
    static let reuseIdentifier = "MediaBrowserItemCell"

    private let thumbnailView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.layer.cornerRadius = 6
        view.clipsToBounds = true
        return view
    }()

    private var thumbnailDisposable: Disposable?

    private let formatLabel: UILabel = {
        let l = UILabel()
        l.font = UIFont.systemFont(ofSize: 10.0, weight: .semibold)
        l.textAlignment = .center
        l.isHidden = true
        return l
    }()

    private let fileNameLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 15.0, weight: .regular)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let senderAvatarNode = AvatarNode(font: avatarPlaceholderFont(size: 9.0))

    private let senderLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12.0, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12.0, weight: .regular)
        label.textAlignment = .right
        return label
    }()

    private let dualScenarioIcon: UIImageView = {
        let v = UIImageView()
        v.image = UIImage(systemName: "rectangle.on.rectangle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .regular))
        v.contentMode = .center
        v.isHidden = true
        return v
    }()

    private let sizeLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12.0, weight: .regular)
        label.textAlignment = .right
        return label
    }()

    private let progressTrackView: UIView = {
        let view = UIView()
        view.layer.cornerRadius = 1.5
        view.clipsToBounds = true
        view.isHidden = true
        return view
    }()

    private let progressFillView: UIView = {
        let view = UIView()
        view.layer.cornerRadius = 1.5
        view.clipsToBounds = true
        return view
    }()

    private var visiblePlaybackProgress: CGFloat?

    private let highlightBackgroundView: UIView = {
        let v = UIView()
        v.isHidden = true
        v.layer.cornerRadius = 10
        return v
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.selectionStyle = .default
        self.backgroundColor = .clear

        contentView.addSubview(highlightBackgroundView)
        contentView.addSubview(thumbnailView)
        thumbnailView.addSubview(formatLabel)
        contentView.addSubview(fileNameLabel)
        contentView.addSubview(dualScenarioIcon)
        contentView.addSubview(senderAvatarNode.view)
        contentView.addSubview(senderLabel)
        contentView.addSubview(timeLabel)
        contentView.addSubview(sizeLabel)
        contentView.addSubview(progressTrackView)
        progressTrackView.addSubview(progressFillView)
    }

    func setItemHighlighted(_ flag: Bool, theme: PresentationTheme) {
        self.highlightBackgroundView.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        self.highlightBackgroundView.isHidden = !flag
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.thumbnailDisposable?.dispose()
        self.thumbnailDisposable = nil
        self.thumbnailFetchDisposable?.dispose()
        self.thumbnailFetchDisposable = nil
        self.thumbnailView.image = nil
        self.highlightBackgroundView.isHidden = true
        self.visiblePlaybackProgress = nil
        self.progressTrackView.isHidden = true
        self.progressFillView.frame = .zero
    }

    deinit {
        self.thumbnailDisposable?.dispose()
        self.thumbnailFetchDisposable?.dispose()
    }

    private var thumbnailFetchDisposable: Disposable?

    override func layoutSubviews() {
        super.layoutSubviews()

        let h = contentView.bounds.height
        let w = contentView.bounds.width
        let padding: CGFloat = 16.0
        let thumbSize: CGFloat = 44.0

        let highlightInsetX: CGFloat = 12.0
        let highlightInsetY: CGFloat = 3.0
        self.highlightBackgroundView.frame = CGRect(x: highlightInsetX, y: highlightInsetY, width: w - highlightInsetX * 2.0, height: h - highlightInsetY * 2.0)

        thumbnailView.frame = CGRect(x: padding, y: (h - thumbSize) / 2.0, width: thumbSize, height: thumbSize)
        formatLabel.frame = CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize)

        let textLeft = thumbnailView.frame.maxX + 12.0
        let textRight = w - padding
        let fullTextWidth = max(40.0, textRight - textLeft)

        let fileNameHeight: CGFloat = 20.0
        let senderHeight: CGFloat = 16.0
        let blockHeight = fileNameHeight + senderHeight + 2.0
        let blockY = (h - blockHeight) / 2.0

        let iconSize: CGFloat = 18.0
        let nameWidth: CGFloat
        if !dualScenarioIcon.isHidden {
            nameWidth = max(40.0, fullTextWidth - iconSize - 6.0)
        } else {
            nameWidth = fullTextWidth
        }
        fileNameLabel.frame = CGRect(x: textLeft, y: blockY, width: nameWidth, height: fileNameHeight)
        let textSize = (fileNameLabel.text ?? "").size(withAttributes: [.font: fileNameLabel.font as Any])
        let nameRenderedWidth = min(nameWidth, ceil(textSize.width))
        dualScenarioIcon.frame = CGRect(x: textLeft + nameRenderedWidth + 6.0, y: blockY + (fileNameHeight - iconSize) / 2.0, width: iconSize, height: iconSize)

        let timeSize = (timeLabel.text ?? "").size(withAttributes: [.font: timeLabel.font as Any])
        let sizeSize = (sizeLabel.text ?? "").size(withAttributes: [.font: sizeLabel.font as Any])
        let timeWidth = ceil(timeSize.width)
        let sizeWidth = ceil(sizeSize.width)
        let rightGap: CGFloat = 12.0

        let sizeX = textRight - sizeWidth
        let timeX = sizeX - rightGap - timeWidth
        let senderRight = timeX - rightGap

        let secondRowY = blockY + fileNameHeight + 2.0
        let avatarBoxSize: CGFloat = 0.0
        senderAvatarNode.view.frame = CGRect(x: textLeft, y: secondRowY + (senderHeight - avatarBoxSize) / 2.0, width: avatarBoxSize, height: avatarBoxSize)
        let senderLabelLeft = textLeft
        senderLabel.frame = CGRect(x: senderLabelLeft, y: secondRowY, width: max(40.0, senderRight - senderLabelLeft), height: senderHeight)
        timeLabel.frame = CGRect(x: timeX, y: secondRowY, width: timeWidth, height: senderHeight)
        sizeLabel.frame = CGRect(x: sizeX, y: secondRowY, width: sizeWidth, height: senderHeight)

        if let visiblePlaybackProgress {
            let progressY = min(h - 7.0, secondRowY + senderHeight + 5.0)
            let progressFrame = CGRect(x: textLeft, y: progressY, width: fullTextWidth, height: 2.0)
            self.progressTrackView.frame = progressFrame
            self.progressFillView.frame = CGRect(x: 0.0, y: 0.0, width: progressFrame.width * visiblePlaybackProgress, height: progressFrame.height)
        } else {
            self.progressTrackView.frame = .zero
            self.progressFillView.frame = .zero
        }
    }

    func configure(with item: MediaBrowserItem, playbackProgress: CGFloat?, context: AccountContext, presentationData: PresentationData) {
        let theme = presentationData.theme

        self.fileNameLabel.text = item.fileName.isEmpty ? "Без названия" : item.fileName
        self.fileNameLabel.textColor = .white

        self.senderLabel.text = item.senderName
        self.senderLabel.textColor = UIColor.white.withAlphaComponent(0.58)

        if let author = item.message.author {
            self.senderAvatarNode.setPeer(
                context: context,
                theme: theme,
                peer: EnginePeer(author),
                displayDimensions: CGSize(width: 18.0, height: 18.0)
            )
            self.senderAvatarNode.isHidden = true
        } else {
            self.senderAvatarNode.isHidden = true
        }

        let locale = Locale(identifier: presentationData.strings.baseLanguageCode)
        self.timeLabel.text = mediaBrowserDateString(item.timestamp, locale: locale)
        self.timeLabel.textColor = UIColor.white.withAlphaComponent(0.50)

        if item.fileSize > 0 {
            self.sizeLabel.text = Self.formatFileSize(item.fileSize)
            self.sizeLabel.isHidden = false
        } else {
            self.sizeLabel.text = ""
            self.sizeLabel.isHidden = true
        }
        self.sizeLabel.textColor = UIColor.white.withAlphaComponent(0.50)
        self.updatePlaybackProgress(playbackProgress, for: item, presentationData: presentationData)

        let placeholderColor = UIColor.white.withAlphaComponent(0.12)
        self.thumbnailView.backgroundColor = placeholderColor
        self.thumbnailDisposable?.dispose()
        self.thumbnailDisposable = nil
        self.thumbnailFetchDisposable?.dispose()
        self.thumbnailFetchDisposable = nil
        self.thumbnailView.image = nil

        var thumbResource: MediaResource?
        var thumbMediaReference: AnyMediaReference?
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
        if let resource = thumbResource {
            self.formatLabel.isHidden = true
            let signal = context.account.postbox.mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: false)
                |> deliverOnMainQueue
            self.thumbnailDisposable = signal.startStrict(next: { [weak self] data in
                guard let self = self else { return }
                if data.complete, let image = UIImage(contentsOfFile: data.path) {
                    self.thumbnailView.image = image
                }
            })
            if let mediaRef = thumbMediaReference {
                let resourceRef = MediaResourceReference.media(media: mediaRef, resource: resource)
                let fetchSignal = fetchedMediaResource(mediaBox: context.account.postbox.mediaBox, userLocation: .other, userContentType: .image, reference: resourceRef)
                self.thumbnailFetchDisposable = fetchSignal.startStrict(next: { _ in })
            }
        } else if let format = Self.extractFormat(from: item) {
            self.formatLabel.text = format
            self.formatLabel.textColor = UIColor.white.withAlphaComponent(0.72)
            self.formatLabel.isHidden = false
        } else {
            self.formatLabel.isHidden = true
        }

        let isDualScenario = item.message.media.contains { media in
            if let file = media as? TelegramMediaFile {
                if file.mimeType == "application/pdf" {
                    return true
                }
                if let name = file.fileName?.lowercased(), name.hasSuffix(".pdf") || name.hasSuffix(".epub") {
                    return true
                }
            }
            return false
        }
        self.dualScenarioIcon.isHidden = !isDualScenario
        self.dualScenarioIcon.tintColor = UIColor.white.withAlphaComponent(0.72)

        setNeedsLayout()
    }

    func updatePlaybackProgress(_ progress: CGFloat?, for item: MediaBrowserItem, presentationData: PresentationData) {
        guard item.mediaType != .photo, let progress else {
            self.visiblePlaybackProgress = nil
            self.progressTrackView.isHidden = true
            self.progressFillView.frame = .zero
            setNeedsLayout()
            return
        }
        let normalizedProgress = max(0.0, min(1.0, progress))
        guard normalizedProgress >= 0.01 else {
            self.visiblePlaybackProgress = nil
            self.progressTrackView.isHidden = true
            self.progressFillView.frame = .zero
            setNeedsLayout()
            return
        }
        self.visiblePlaybackProgress = normalizedProgress
        self.progressTrackView.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        self.progressFillView.backgroundColor = UIColor(red: 10.0 / 255.0, green: 132.0 / 255.0, blue: 1.0, alpha: 1.0)
        self.progressTrackView.isHidden = false
        setNeedsLayout()
    }

    private static func extractFormat(from item: MediaBrowserItem) -> String? {
        switch item.playableSource {
        case .youtube:
            return "YT"
        case .directStream:
            return "STREAM"
        case .unsupportedUrl:
            return "LINK"
        case .telegramMedia:
            break
        }
        for media in item.message.media {
            if let file = media as? TelegramMediaFile {
                if let name = file.fileName, let dotIndex = name.lastIndex(of: ".") {
                    let ext = String(name[name.index(after: dotIndex)...])
                    if !ext.isEmpty && ext.count <= 6 {
                        return ext.uppercased()
                    }
                }
                let mime = file.mimeType
                if let slashIdx = mime.firstIndex(of: "/") {
                    let sub = String(mime[mime.index(after: slashIdx)...])
                    let cleaned = sub.replacingOccurrences(of: "x-", with: "").components(separatedBy: ";").first ?? sub
                    if !cleaned.isEmpty {
                        return cleaned.uppercased()
                    }
                }
            }
        }
        return nil
    }

    private static func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) Б"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f Кб", Double(bytes) / 1024.0)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.2f Мб", Double(bytes) / (1024.0 * 1024.0))
        } else {
            return String(format: "%.2f Гб", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
        }
    }
}
