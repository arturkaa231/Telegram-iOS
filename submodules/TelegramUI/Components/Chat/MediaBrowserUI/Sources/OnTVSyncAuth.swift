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
        session.prefersEphemeralWebBrowserSession = true
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
    private var cache: [String: CachedToken] = [:]
    private var pendingCompletions: [String: [(String?) -> Void]] = [:]

    init?(syncEndpoint: URL, identityProvider: OnTVTelegramIdentityProvider) {
        guard let tokenEndpoint = Self.tokenEndpoint(from: syncEndpoint) else {
            return nil
        }
        self.tokenEndpoint = tokenEndpoint
        self.identityProvider = identityProvider
    }

    func token(forChatScope chatScope: String, completion: @escaping (String?) -> Void) {
        if let cached = self.cache[chatScope], cached.isValid {
            completion(cached.token)
            return
        }
        if self.pendingCompletions[chatScope] != nil {
            self.pendingCompletions[chatScope]?.append(completion)
            return
        }
        self.pendingCompletions[chatScope] = [completion]

        self.identityProvider.requestTelegramIDToken { [weak self] result in
            guard let self = self else {
                return
            }
            switch result {
            case let .success(idToken):
                self.exchange(idToken: idToken, chatScope: chatScope)
            case let .failure(error):
                NSLog("[MultigramOnTV] Telegram login failed: %@", String(describing: error))
                self.finish(chatScope: chatScope, token: nil)
            }
        }
    }

    private func exchange(idToken: String, chatScope: String) {
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
                self.finish(chatScope: chatScope, token: nil)
                return
            }
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200 ..< 300).contains(httpResponse.statusCode),
                let data = data
            else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                NSLog("[MultigramOnTV] Sync token request rejected status=%d", status)
                self.finish(chatScope: chatScope, token: nil)
                return
            }
            do {
                let issued = try JSONDecoder().decode(IssuedToken.self, from: data)
                let cached = CachedToken(token: issued.token, expiresAt: Date(timeIntervalSince1970: issued.expiresAt / 1000.0))
                DispatchQueue.main.async {
                    self.cache[chatScope] = cached
                    self.finish(chatScope: chatScope, token: issued.token)
                }
            } catch {
                NSLog("[MultigramOnTV] Sync token response decode failed: %@", String(describing: error))
                self.finish(chatScope: chatScope, token: nil)
            }
        }.resume()
    }

    private func finish(chatScope: String, token: String?) {
        DispatchQueue.main.async {
            let completions = self.pendingCompletions.removeValue(forKey: chatScope) ?? []
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
}
