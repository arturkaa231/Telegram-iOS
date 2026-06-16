import Foundation
import UIKit
import AuthenticationServices
import CryptoKit
import Security

private enum OnTVSyncAuthError: Error {
    case authURL
    case callbackMissingCode
    case tokenEndpoint
    case tokenResponse
    case invalidResponse
}

protocol OnTVTelegramIdentityProvider: AnyObject {
    func requestTelegramIDToken(completion: @escaping (Result<String, Error>) -> Void)
}

final class OnTVTelegramLoginIdentityProvider: NSObject, OnTVTelegramIdentityProvider, ASWebAuthenticationPresentationContextProviding {
    private let clientId: String
    private let redirectURI: String
    private let scopes: [String]
    private var session: ASWebAuthenticationSession?

    init(clientId: String, redirectURI: String, scopes: [String] = ["openid", "profile"]) {
        self.clientId = clientId
        self.redirectURI = redirectURI
        self.scopes = scopes
        super.init()
    }

    func requestTelegramIDToken(completion: @escaping (Result<String, Error>) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.requestTelegramIDToken(completion: completion)
            }
            return
        }

        let codeVerifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Self.codeChallenge(for: codeVerifier)
        guard let authURL = Self.authorizationURL(clientId: self.clientId, redirectURI: self.redirectURI, scopes: self.scopes, codeChallenge: challenge) else {
            completion(.failure(OnTVSyncAuthError.authURL))
            return
        }

        let callbackScheme = URLComponents(string: self.redirectURI)?.scheme.flatMap { scheme -> String? in
            if scheme == "http" || scheme == "https" {
                return nil
            }
            return scheme
        }

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
            NSLog("[MultigramOnTV] Telegram OAuth callback received success=%@", callbackURL == nil ? "false" : "true")
            guard let self = self else {
                return
            }
            self.session = nil
            if let error = error {
                completion(.failure(error))
                return
            }
            guard
                let callbackURL = callbackURL,
                let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                !code.isEmpty
            else {
                completion(.failure(OnTVSyncAuthError.callbackMissingCode))
                return
            }
            Self.exchangeCodeForIDToken(clientId: self.clientId, redirectURI: self.redirectURI, code: code, codeVerifier: codeVerifier, completion: completion)
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        NSLog("[MultigramOnTV] Starting Telegram OAuth clientId=%@ redirectURI=%@ callbackScheme=%@", self.clientId, self.redirectURI, callbackScheme ?? "universal-link")
        if !session.start() {
            self.session = nil
            NSLog("[MultigramOnTV] Telegram OAuth session failed to start")
            completion(.failure(OnTVSyncAuthError.authURL))
        } else {
            NSLog("[MultigramOnTV] Telegram OAuth session started")
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }

    private static func authorizationURL(clientId: String, redirectURI: String, scopes: [String], codeChallenge: String) -> URL? {
        var components = URLComponents(string: "https://oauth.telegram.org/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "ios_sdk", value: "1"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components?.url
    }

    private static func exchangeCodeForIDToken(clientId: String, redirectURI: String, code: String, codeVerifier: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://oauth.telegram.org/token") else {
            completion(.failure(OnTVSyncAuthError.tokenEndpoint))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded([
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200 ..< 300).contains(httpResponse.statusCode),
                let data = data
            else {
                completion(.failure(OnTVSyncAuthError.tokenResponse))
                return
            }
            do {
                let response = try JSONDecoder().decode(TokenResponse.self, from: data)
                completion(.success(response.idToken))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func formEncoded(_ items: [URLQueryItem]) -> Data? {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Self.base64URL(Data(digest))
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Self.base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct TokenResponse: Decodable {
        let idToken: String

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
        }
    }
}

final class OnTVSyncTokenService {
    private let tokenEndpoint: URL
    private let identityProvider: OnTVTelegramIdentityProvider
    private static var cache: [String: CachedToken] = [:]
    private static var idTokenCache: [String: CachedToken] = [:]
    private static var pendingCompletions: [String: [(String?) -> Void]] = [:]
    private static var authRetryAfter: [String: Date] = [:]
    private static let keychainService = "multigram.sync-layer.sync-token"
    private static let idTokenKeychainService = "multigram.sync-layer.telegram-id-token"

    init?(syncEndpoint: URL, identityProvider: OnTVTelegramIdentityProvider) {
        guard let tokenEndpoint = Self.tokenEndpoint(from: syncEndpoint) else {
            return nil
        }
        self.tokenEndpoint = tokenEndpoint
        self.identityProvider = identityProvider
    }

    func token(forChatScope chatScope: String, completion: @escaping (String?) -> Void) {
        let cacheKey = self.cacheKey(forChatScope: chatScope)
        let identityCacheKey = self.identityCacheKey()
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
        if let cachedIdentity = Self.idTokenCache[identityCacheKey], cachedIdentity.isValid {
            self.exchange(idToken: cachedIdentity.token, chatScope: chatScope, cacheKey: cacheKey)
            return
        }
        if let persistedIdentity = Self.persistedIDToken(for: identityCacheKey), persistedIdentity.isValid {
            Self.idTokenCache[identityCacheKey] = persistedIdentity
            self.exchange(idToken: persistedIdentity.token, chatScope: chatScope, cacheKey: cacheKey)
            return
        }

        self.identityProvider.requestTelegramIDToken { [weak self] result in
            guard let self = self else {
                return
            }
            switch result {
            case let .success(idToken):
                if let cachedIdentity = Self.cachedIDToken(idToken) {
                    Self.idTokenCache[identityCacheKey] = cachedIdentity
                    Self.savePersistedIDToken(cachedIdentity, for: identityCacheKey)
                }
                self.exchange(idToken: idToken, chatScope: chatScope, cacheKey: cacheKey)
            case let .failure(error):
                NSLog("[MultigramOnTV] Telegram login failed: %@", String(describing: error))
                Self.authRetryAfter[cacheKey] = Date(timeIntervalSinceNow: 60.0)
                self.finish(cacheKey: cacheKey, token: nil)
            }
        }
    }

    private func cacheKey(forChatScope chatScope: String) -> String {
        return "\(self.tokenEndpoint.absoluteString)|\(chatScope)"
    }

    private func identityCacheKey() -> String {
        return self.tokenEndpoint.absoluteString
    }

    private func exchange(idToken: String, chatScope: String, cacheKey: String) {
        var request = URLRequest(url: self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "idToken": idToken,
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

    private static func persistedIDToken(for cacheKey: String) -> CachedToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.idTokenKeychainService,
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
        Self.deletePersistedIDToken(for: cacheKey)
        return nil
    }

    private static func savePersistedIDToken(_ token: CachedToken, for cacheKey: String) {
        let persisted = PersistedCachedToken(token: token.token, expiresAt: token.expiresAt.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(persisted) else {
            return
        }
        Self.deletePersistedIDToken(for: cacheKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.idTokenKeychainService,
            kSecAttrAccount as String: cacheKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func deletePersistedIDToken(for cacheKey: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.idTokenKeychainService,
            kSecAttrAccount as String: cacheKey
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func cachedIDToken(_ token: String) -> CachedToken? {
        guard let expiresAt = Self.jwtExpiration(token), expiresAt.timeIntervalSinceNow > 60.0 else {
            return nil
        }
        return CachedToken(token: token, expiresAt: expiresAt)
    }

    private static func jwtExpiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = Self.base64URLDecode(String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData, options: []) as? [String: Any],
              let exp = payload["exp"] as? NSNumber else {
            return nil
        }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64.append(String(repeating: "=", count: padding))
        }
        return Data(base64Encoded: base64)
    }
}
