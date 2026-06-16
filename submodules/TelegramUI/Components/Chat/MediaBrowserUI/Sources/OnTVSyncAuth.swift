import Foundation
import Security

final class OnTVSyncTokenService {
    private let tokenEndpoint: URL
    private let telegramUserId: String
    private static var cache: [String: CachedToken] = [:]
    private static var pendingCompletions: [String: [(String?) -> Void]] = [:]
    private static var authRetryAfter: [String: Date] = [:]
    private static let keychainService = "multigram.sync-layer.sync-token"

    init?(syncEndpoint: URL, telegramUserId: String) {
        guard let tokenEndpoint = Self.tokenEndpoint(from: syncEndpoint) else {
            return nil
        }
        self.tokenEndpoint = tokenEndpoint
        self.telegramUserId = telegramUserId
    }

    func token(forChatScope chatScope: String, completion: @escaping (String?) -> Void) {
        let cacheKey = self.cacheKey(forChatScope: chatScope)
        if let cached = Self.cache[cacheKey], cached.isValid {
            completion(cached.token)
            return
        }
        if let persisted = Self.persistedToken(for: cacheKey), persisted.isValid {
            Self.cache[cacheKey] = persisted
            completion(persisted.token)
            return
        }
        if let retryAfter = Self.authRetryAfter[cacheKey], retryAfter.timeIntervalSinceNow > 0 {
            completion(nil)
            return
        }
        if Self.pendingCompletions[cacheKey] != nil {
            Self.pendingCompletions[cacheKey]?.append(completion)
            return
        }
        Self.pendingCompletions[cacheKey] = [completion]
        self.exchange(chatScope: chatScope, cacheKey: cacheKey)
    }

    private func cacheKey(forChatScope chatScope: String) -> String {
        return "\(self.tokenEndpoint.absoluteString)|\(chatScope)"
    }

    private func exchange(chatScope: String, cacheKey: String) {
        var request = URLRequest(url: self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "telegramAuth": [
                "type": "nativeClient",
                "telegramUserId": self.telegramUserId,
                "authDate": Int(Date().timeIntervalSince1970)
            ],
            "chatId": chatScope
        ], options: [])

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                return
            }
            if let error = error {
                NSLog("[MultigramOnTV] Sync token request failed: %@", String(describing: error))
                self.finish(cacheKey: cacheKey, token: nil)
                return
            }
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200 ..< 300).contains(httpResponse.statusCode),
                let data = data
            else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                NSLog("[MultigramOnTV] Sync token request rejected status=%d", status)
                self.finish(cacheKey: cacheKey, token: nil)
                return
            }
            do {
                let issued = try JSONDecoder().decode(IssuedToken.self, from: data)
                let cached = CachedToken(token: issued.token, expiresAt: Date(timeIntervalSince1970: issued.expiresAt / 1000.0))
                DispatchQueue.main.async {
                    Self.cache[cacheKey] = cached
                    Self.savePersistedToken(cached, for: cacheKey)
                    self.finish(cacheKey: cacheKey, token: issued.token)
                }
            } catch {
                NSLog("[MultigramOnTV] Sync token response decode failed: %@", String(describing: error))
                self.finish(cacheKey: cacheKey, token: nil)
            }
        }.resume()
    }

    private func finish(cacheKey: String, token: String?) {
        DispatchQueue.main.async {
            let completions = Self.pendingCompletions.removeValue(forKey: cacheKey) ?? []
            for completion in completions {
                completion(token)
            }
        }
    }

    private static func tokenEndpoint(from endpoint: URL) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if components.scheme == "ws" {
            components.scheme = "http"
        } else if components.scheme == "wss" {
            components.scheme = "https"
        }
        components.path = "/v1/auth/sync-token"
        components.query = nil
        return components.url
    }

    private struct IssuedToken: Decodable {
        let token: String
        let expiresAt: Double
    }

    private struct CachedToken {
        let token: String
        let expiresAt: Date

        var isValid: Bool {
            return self.expiresAt.timeIntervalSinceNow > 60.0
        }
    }

    private struct PersistedCachedToken: Codable {
        let token: String
        let expiresAt: TimeInterval
    }

    private static func persistedToken(for cacheKey: String) -> CachedToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: cacheKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let persisted = try? JSONDecoder().decode(PersistedCachedToken.self, from: data) else {
            return nil
        }
        let cached = CachedToken(token: persisted.token, expiresAt: Date(timeIntervalSince1970: persisted.expiresAt))
        if cached.isValid {
            return cached
        }
        Self.deletePersistedToken(for: cacheKey)
        return nil
    }

    private static func savePersistedToken(_ token: CachedToken, for cacheKey: String) {
        let persisted = PersistedCachedToken(token: token.token, expiresAt: token.expiresAt.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(persisted) else {
            return
        }
        Self.deletePersistedToken(for: cacheKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: cacheKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func deletePersistedToken(for cacheKey: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: cacheKey
        ]
        SecItemDelete(query as CFDictionary)
    }
}
