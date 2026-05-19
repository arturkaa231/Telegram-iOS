import Foundation
import UIKit
import PDFKit
import Display
import AsyncDisplayKit
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData

public final class PDFMediaPreviewProvider: MediaPreviewProvider {
    public let identifier = "pdf"

    public init() {}

    public func canHandle(item: MediaBrowserItem) -> Bool {
        for media in item.message.media {
            if let file = media as? TelegramMediaFile {
                if file.mimeType == "application/pdf" {
                    return true
                }
                if let fileName = file.fileName, fileName.lowercased().hasSuffix(".pdf") {
                    return true
                }
            }
        }
        return false
    }

    public func makePreviewNode(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) -> MediaPreviewNode {
        return PDFPreviewNode(item: item, context: context, presentationData: presentationData)
    }
}

final class PDFPreviewNode: ASDisplayNode, MediaPreviewNode {
    private let context: AccountContext
    private let item: MediaBrowserItem

    private let pdfView: PDFView
    private var disposable = MetaDisposable()
    private(set) var naturalAspectRatio: CGFloat?

    var statusUpdated: ((MediaPreviewPlaybackStatus) -> Void)?
    var aspectRatioUpdated: ((CGFloat) -> Void)?

    var displayNode: ASDisplayNode { return self }

    init(item: MediaBrowserItem, context: AccountContext, presentationData: PresentationData) {
        self.context = context
        self.item = item

        self.pdfView = PDFView()
        self.pdfView.autoScales = true
        self.pdfView.displayMode = .singlePage
        self.pdfView.displayDirection = .vertical
        self.pdfView.backgroundColor = .clear

        super.init()

        self.clipsToBounds = true
        self.cornerRadius = 10.0
    }

    override func didLoad() {
        super.didLoad()
        self.view.addSubview(self.pdfView)
        self.load()
    }

    deinit {
        self.disposable.dispose()
    }

    private func load() {
        guard let file = self.item.message.media.compactMap({ $0 as? TelegramMediaFile }).first else {
            self.statusUpdated?(.error("No file"))
            return
        }
        let message = self.item.message
        let resource = file.resource

        self.statusUpdated?(.loading)

        let signal = self.context.account.postbox.mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: false)
            |> deliverOnMainQueue

        self.disposable.set(signal.startStrict(next: { [weak self] data in
            guard let self = self else { return }
            if data.complete {
                let url = URL(fileURLWithPath: data.path)
                if let document = PDFDocument(url: url) {
                    self.pdfView.document = document
                    if let firstPage = document.page(at: 0) {
                        let pageRect = firstPage.bounds(for: .mediaBox)
                        if pageRect.height > 0 {
                            let ratio = pageRect.width / pageRect.height
                            self.naturalAspectRatio = ratio
                            self.aspectRatioUpdated?(ratio)
                        }
                    }
                    self.statusUpdated?(.idle)
                } else {
                    self.statusUpdated?(.error("Cannot open PDF"))
                }
            }
        }))

        let _ = messageMediaFileInteractiveFetched(
            fetchManager: self.context.fetchManager,
            messageId: message.id,
            messageReference: MessageReference(message),
            file: file,
            userInitiated: true,
            priority: .userInitiated,
            storeToDownloadsPeerId: nil
        ).startStandalone()
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.pdfView.frame = CGRect(origin: .zero, size: size)
    }
}
