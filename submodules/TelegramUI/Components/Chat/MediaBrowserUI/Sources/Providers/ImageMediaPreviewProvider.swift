import Foundation
import UIKit
import Display
import AsyncDisplayKit
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData

public final class ImageMediaPreviewProvider: MediaPreviewProvider {
    public let identifier = "image"

    public init() {}

    public func canHandle(item: MediaBrowserItem) -> Bool {
        for media in item.message.media {
            if media is TelegramMediaImage {
                return true
            }
            if let file = media as? TelegramMediaFile, !file.isVideo, file.mimeType.hasPrefix("image/") {
                return true
            }
        }
        return false
    }

    public func makePreviewNode(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) -> MediaPreviewNode {
        return ImagePreviewNode(item: item, context: context, presentationData: presentationData)
    }
}

final class ImagePreviewNode: ASDisplayNode, MediaPreviewNode {
    private let context: AccountContext
    private let item: MediaBrowserItem

    private let imageView: UIImageView
    private var disposable = MetaDisposable()
    private(set) var naturalAspectRatio: CGFloat?

    var statusUpdated: ((MediaPreviewPlaybackStatus) -> Void)?
    var aspectRatioUpdated: ((CGFloat) -> Void)?

    var displayNode: ASDisplayNode { return self }

    init(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) {
        self.context = context
        self.item = item

        self.imageView = UIImageView()
        self.imageView.contentMode = .scaleAspectFit
        self.imageView.clipsToBounds = true
        self.imageView.layer.cornerRadius = 10.0

        super.init()

        self.statusUpdated = nil
    }

    override func didLoad() {
        super.didLoad()
        self.view.addSubview(self.imageView)
        self.publishInitialAspectRatio()
        self.loadImage()
    }

    private func publishInitialAspectRatio() {
        for media in self.item.message.media {
            if let image = media as? TelegramMediaImage, let representation = image.representations.last {
                let dims = representation.dimensions
                if dims.width > 0 && dims.height > 0 {
                    let ratio = CGFloat(dims.width) / CGFloat(dims.height)
                    self.naturalAspectRatio = ratio
                    self.aspectRatioUpdated?(ratio)
                    return
                }
            }
            if let file = media as? TelegramMediaFile, let dims = file.dimensions, dims.width > 0 && dims.height > 0 {
                let ratio = CGFloat(dims.width) / CGFloat(dims.height)
                self.naturalAspectRatio = ratio
                self.aspectRatioUpdated?(ratio)
                return
            }
        }
    }

    deinit {
        self.disposable.dispose()
    }

    private func loadImage() {
        self.statusUpdated?(.loading)
        let message = self.item.message
        for media in message.media {
            if let image = media as? TelegramMediaImage, let representation = image.representations.last {
                self.fetch(resource: representation.resource, fetch: {
                    let _ = messageMediaImageInteractiveFetched(
                        fetchManager: self.context.fetchManager,
                        messageId: message.id,
                        messageReference: MessageReference(message),
                        image: image,
                        resource: representation.resource,
                        userInitiated: true,
                        priority: .userInitiated,
                        storeToDownloadsPeerId: nil
                    ).startStandalone()
                })
                return
            }
            if let file = media as? TelegramMediaFile, file.mimeType.hasPrefix("image/") {
                self.fetch(resource: file.resource, fetch: {
                    let _ = messageMediaFileInteractiveFetched(
                        fetchManager: self.context.fetchManager,
                        messageId: message.id,
                        messageReference: MessageReference(message),
                        file: file,
                        userInitiated: true,
                        priority: .userInitiated,
                        storeToDownloadsPeerId: nil
                    ).startStandalone()
                })
                return
            }
        }
        self.statusUpdated?(.error("No image"))
    }

    private func fetch(resource: MediaResource, fetch: () -> Void) {
        let signal = self.context.account.postbox.mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: false)
            |> deliverOnMainQueue
        self.disposable.set(signal.startStrict(next: { [weak self] data in
            guard let self = self else { return }
            if data.complete, let uiImage = UIImage(contentsOfFile: data.path) {
                self.imageView.image = uiImage
                if self.naturalAspectRatio == nil, uiImage.size.height > 0 {
                    let ratio = uiImage.size.width / uiImage.size.height
                    self.naturalAspectRatio = ratio
                    self.aspectRatioUpdated?(ratio)
                }
                self.statusUpdated?(.idle)
            }
        }))
        fetch()
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.imageView.frame = CGRect(origin: .zero, size: size)
    }
}
