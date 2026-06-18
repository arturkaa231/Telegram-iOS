import Foundation
import TelegramCore

enum MediaStatisticsTargetType: String {
    case file
    case link
    case chat
    case folder
}

struct MediaStatisticsTarget {
    let chatId: EnginePeer.Id
    let targetType: MediaStatisticsTargetType
    let targetId: String
    let title: String
    let mediaType: String?
    let fileSize: Int64?

    static func file(item: MediaBrowserItem, chatId: EnginePeer.Id) -> MediaStatisticsTarget {
        return MediaStatisticsTarget(
            chatId: chatId,
            targetType: item.playableSource.statisticsTargetType,
            targetId: "\(item.messageId.peerId.toInt64()):\(item.messageId.namespace):\(item.messageId.id)",
            title: item.fileName.isEmpty ? "Без названия" : item.fileName,
            mediaType: item.mediaType.statisticsValue,
            fileSize: item.fileSize > 0 ? item.fileSize : nil
        )
    }

    static func chat(_ item: MediaBrowserChatItem) -> MediaStatisticsTarget {
        return MediaStatisticsTarget(
            chatId: item.peerId,
            targetType: .chat,
            targetId: String(item.peerId.toInt64()),
            title: item.title,
            mediaType: nil,
            fileSize: nil
        )
    }
}

struct MediaStatisticsSummary {
    let totalOpenCount: Int
    let lastOpenedAt: Date?
    let topUsers: [MediaStatisticsUserRow]
}

struct MediaStatisticsUserRow {
    let userId: String
    let openCount: Int
    let lastOpenedAt: Date?
}

final class MediaStatisticsService {
    private let endpoint: URL
    private let authToken: String?
    private let accountPeerId: EnginePeer.Id
    private let authTokenProvider: ((String, @escaping (String?) -> Void) -> Void)?
    private let session: URLSession

    init(endpoint: URL, authToken: String?, accountPeerId: EnginePeer.Id, authTokenProvider: ((String, @escaping (String?) -> Void) -> Void)?) {
        self.endpoint = endpoint
        self.authToken = authToken
        self.accountPeerId = accountPeerId
        self.authTokenProvider = authTokenProvider
        self.session = URLSession(configuration: .default)
    }

    func recordOpen(target: MediaStatisticsTarget) {
        self.authorizedRequest(chatId: target.chatId, path: "statistics/open", queryItems: []) { [weak self] request in
            guard let self = self else { return }
            var request = request
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var payload: [String: Any] = [
                "targetType": target.targetType.rawValue,
                "targetId": target.targetId,
                "openedAt": Date().timeIntervalSince1970 * 1000.0
            ]
            var metadata: [String: Any] = [:]
            if let mediaType = target.mediaType {
                metadata["mediaType"] = mediaType
            }
            if let fileSize = target.fileSize {
                metadata["fileSize"] = fileSize
            }
            if !metadata.isEmpty {
                payload["metadata"] = metadata
            }
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                return
            }
            request.httpBody = data
            self.session.dataTask(with: request) { _, response, error in
                if let error = error {
                    NSLog("[MultigramStats] Open event failed: %@", String(describing: error))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if !(200 ..< 300).contains(status) {
                    NSLog("[MultigramStats] Open event rejected status=%d", status)
                }
            }.resume()
        }
    }

    func loadSummary(target: MediaStatisticsTarget, completion: @escaping (Result<MediaStatisticsSummary, Error>) -> Void) {
        let queryItems = [
            URLQueryItem(name: "targetType", value: target.targetType.rawValue),
            URLQueryItem(name: "targetId", value: target.targetId),
            URLQueryItem(name: "limit", value: "5")
        ]
        self.authorizedRequest(chatId: target.chatId, path: "statistics/summary", queryItems: queryItems) { [weak self] request in
            guard let self = self else { return }
            self.session.dataTask(with: request) { data, response, error in
                if let error = error {
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse,
                      (200 ..< 300).contains(httpResponse.statusCode),
                      let data = data else {
                    DispatchQueue.main.async {
                        completion(.failure(MediaStatisticsError.unavailable))
                    }
                    return
                }
                do {
                    let summary = try JSONDecoder().decode(DecodedSummary.self, from: data).summary
                    DispatchQueue.main.async {
                        completion(.success(summary))
                    }
                } catch {
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }.resume()
        }
    }

    private func authorizedRequest(chatId: EnginePeer.Id, path: String, queryItems: [URLQueryItem], completion: @escaping (URLRequest) -> Void) {
        let chatScope = Self.syncScopeId(chatId: chatId, accountPeerId: self.accountPeerId)
        let finish: (String?) -> Void = { [weak self] token in
            guard let self = self, let url = self.statisticsURL(chatScope: chatScope, path: path, queryItems: queryItems) else {
                return
            }
            var request = URLRequest(url: url)
            request.setValue(String(self.accountPeerId.toInt64()), forHTTPHeaderField: "X-PlayGram-User-Id")
            if let token = token, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            completion(request)
        }
        if let authToken = self.authToken {
            finish(authToken)
        } else if let authTokenProvider = self.authTokenProvider {
            authTokenProvider(chatScope, finish)
        } else {
            finish(nil)
        }
    }

    private func statisticsURL(chatScope: String, path: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: self.endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if components.scheme == "ws" {
            components.scheme = "http"
        } else if components.scheme == "wss" {
            components.scheme = "https"
        }
        components.percentEncodedPath = "/v1/chats/\(Self.percentEncodePathSegment(chatScope))/\(path)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private static func syncScopeId(chatId: EnginePeer.Id, accountPeerId: EnginePeer.Id) -> String {
        if chatId.namespace == Namespaces.Peer.CloudUser, chatId != accountPeerId {
            let ids = [accountPeerId.toInt64(), chatId.toInt64()].sorted()
            return "private:\(ids[0]):\(ids[1])"
        }
        return String(chatId.toInt64())
    }

    private static func percentEncodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private enum MediaStatisticsError: Error {
    case unavailable
}

private struct DecodedSummary: Decodable {
    let totalOpenCount: Int
    let lastOpenedAt: Double?
    let topUsers: [DecodedUserRow]

    var summary: MediaStatisticsSummary {
        return MediaStatisticsSummary(
            totalOpenCount: self.totalOpenCount,
            lastOpenedAt: self.lastOpenedAt.map { Date(timeIntervalSince1970: $0 / 1000.0) },
            topUsers: self.topUsers.map(\.row)
        )
    }
}

private struct DecodedUserRow: Decodable {
    let userId: String
    let openCount: Int
    let lastOpenedAt: Double?

    var row: MediaStatisticsUserRow {
        return MediaStatisticsUserRow(
            userId: self.userId,
            openCount: self.openCount,
            lastOpenedAt: self.lastOpenedAt.map { Date(timeIntervalSince1970: $0 / 1000.0) }
        )
    }
}

private extension MediaBrowserPlayableSource {
    var statisticsTargetType: MediaStatisticsTargetType {
        switch self {
        case .telegramMedia:
            return .file
        case .directStream, .youtube, .unsupportedUrl:
            return .link
        }
    }
}

private extension MediaBrowserMediaType {
    var statisticsValue: String {
        switch self {
        case .photo:
            return "photo"
        case .video:
            return "video"
        case .file:
            return "file"
        case .audio:
            return "audio"
        }
    }
}
