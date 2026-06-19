import Foundation
import Postbox
import TelegramCore

enum MediaBrowserURLClassifier {
    static func playableSource(in message: Message) -> MediaBrowserPlayableSource? {
        for urlString in self.candidateURLStrings(in: message) {
            if let source = self.playableSource(for: urlString) {
                return source
            }
        }
        return nil
    }

    static func playableSource(for urlString: String) -> MediaBrowserPlayableSource? {
        guard let url = self.normalizedURL(from: urlString) else {
            return nil
        }
        if let videoId = self.youtubeVideoId(from: url) {
            return .youtube(videoId: videoId, url: url)
        }
        if self.isSupportedDirectStream(url) {
            return .directStream(url: url)
        }
        if self.isSupportedWebPage(url) {
            return .unsupportedUrl(url: url)
        }
        return nil
    }

    static func displayTitle(in message: Message, for url: URL, fallback: String) -> String {
        if let title = self.webpageTitle(in: message, matching: url) {
            return title
        }
        return self.displayTitle(for: url, fallback: fallback)
    }

    static func displayTitle(for url: URL, fallback: String) -> String {
        if self.youtubeVideoId(from: url) != nil {
            return fallback
        }
        let lastPath = url.lastPathComponent
        if !lastPath.isEmpty && lastPath != "/" {
            return lastPath
        }
        return url.host ?? fallback
    }

    private static func webpageTitle(in message: Message, matching url: URL) -> String? {
        var firstLoadedTitle: String?

        for media in message.media {
            guard let webpage = media as? TelegramMediaWebpage else {
                continue
            }
            guard case let .Loaded(content) = webpage.content else {
                continue
            }

            let title = self.bestWebpageTitle(content)
            if firstLoadedTitle == nil {
                firstLoadedTitle = title
            }

            if self.webpageContent(content, matches: url), let title = title {
                return title
            }
        }

        return firstLoadedTitle
    }

    private static func bestWebpageTitle(_ content: TelegramMediaWebpageLoadedContent) -> String? {
        for value in [content.title, content.websiteName, content.displayUrl, content.url] {
            if let title = self.cleanedTitle(value) {
                return title
            }
        }
        return nil
    }

    private static func cleanedTitle(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func webpageContent(_ content: TelegramMediaWebpageLoadedContent, matches url: URL) -> Bool {
        for value in [content.url, content.displayUrl, content.embedUrl].compactMap({ $0 }) {
            guard let candidate = self.normalizedURL(from: value) else {
                continue
            }
            if self.urlsMatch(candidate, url) {
                return true
            }
        }
        return false
    }

    private static func urlsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.absoluteString == rhs.absoluteString {
            return true
        }
        guard let lhsHost = lhs.host?.lowercased(), let rhsHost = rhs.host?.lowercased() else {
            return false
        }
        let lhsPath = lhs.path.isEmpty ? "/" : lhs.path
        let rhsPath = rhs.path.isEmpty ? "/" : rhs.path
        return lhsHost == rhsHost && lhsPath == rhsPath
    }

    private static func candidateURLStrings(in message: Message) -> [String] {
        var result: [String] = []
        for media in message.media {
            guard let webpage = media as? TelegramMediaWebpage else {
                continue
            }
            switch webpage.content {
            case let .Loaded(content):
                result.append(content.url)
                result.append(content.displayUrl)
                if let embedUrl = content.embedUrl {
                    result.append(embedUrl)
                }
            case let .Pending(_, url):
                if let url = url {
                    result.append(url)
                }
            }
        }

        let nsText = message.text as NSString
        for attribute in message.attributes {
            guard let textAttribute = attribute as? TextEntitiesMessageAttribute else {
                continue
            }
            for entity in textAttribute.entities {
                switch entity.type {
                case .Url:
                    let range = NSRange(location: entity.range.lowerBound, length: entity.range.upperBound - entity.range.lowerBound)
                    guard range.location >= 0, range.location + range.length <= nsText.length else {
                        continue
                    }
                    result.append(nsText.substring(with: range))
                case let .TextUrl(url):
                    result.append(url)
                default:
                    break
                }
            }
        }

        return result.filter { !$0.isEmpty }
    }

    private static func normalizedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private static func youtubeVideoId(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else {
            return nil
        }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        if normalizedHost == "youtu.be" {
            return self.sanitizedYouTubeVideoId(url.pathComponents.dropFirst().first)
        }

        guard normalizedHost == "youtube.com" || normalizedHost.hasSuffix(".youtube.com") else {
            return nil
        }

        if url.path == "/watch" {
            return self.sanitizedYouTubeVideoId(components?.queryItems?.first(where: { $0.name == "v" })?.value)
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        if pathComponents.count >= 2 {
            if pathComponents[0] == "shorts" || pathComponents[0] == "embed" {
                return self.sanitizedYouTubeVideoId(pathComponents[1])
            }
        }

        return nil
    }

    private static func sanitizedYouTubeVideoId(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard value.rangeOfCharacter(from: allowed.inverted) == nil else {
            return nil
        }
        return value
    }

    private static func isSupportedDirectStream(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else {
            return false
        }
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || ext == "mp4" || ext == "mov" || ext == "m4v" {
            return true
        }
        return false
    }

    private static func isSupportedWebPage(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return url.host?.isEmpty == false
    }
}
