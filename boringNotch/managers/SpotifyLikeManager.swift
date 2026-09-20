//
//  SpotifyLikeManager.swift
//  boringNotch
//
//  Adds "Save to Liked Songs" support for Spotify via the Web API.
//  Auth: Authorization Code flow with PKCE (no client secret), the only
//  supported flow for native apps after Spotify's Nov 2025 OAuth migration.
//
//  Wiring (see notes at bottom):
//    - Call `refreshState(forSpotify:)` whenever the now-playing track changes
//      and the active source is Spotify.
//    - Bind the like button to `isLiked` / `canLike` and call `toggleLike()`.
//

import Foundation
import AuthenticationServices
import CryptoKit
import Combine

// MARK: - Configuration

enum SpotifyConfig {
    /// Each user registers their own free app at developer.spotify.com and
    /// pastes the Client ID into settings. (Avoids the 25-user Dev Mode quota
    /// cap that a single shipped client ID would hit.) Persist this yourself;
    /// here it reads from UserDefaults.
    static var clientID: String {
        UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
    }

    // Must be added verbatim to the app's Redirect URI allowlist in the
    // Spotify dashboard, AND registered as a URL scheme in Info.plist.
    static let redirectURI    = "boring-notch://spotify-callback"
    static let callbackScheme = "boring-notch"

    static let scopes = "user-library-read user-library-modify user-read-currently-playing"

    static let authorizeURL = "https://accounts.spotify.com/authorize"
    static let tokenURL     = URL(string: "https://accounts.spotify.com/api/token")!
    static let apiBase      = "https://api.spotify.com/v1"
}

// MARK: - PKCE helpers

private enum PKCE {
    /// 43–128 char high-entropy string. base64url of 64 random bytes ≈ 86 chars.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Minimal Keychain wrapper (refresh token only)

private enum Keychain {
    private static let account = "spotify.refreshToken"
    private static let service = "name.theboring.notch"

    static func save(_ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        // This app is ad-hoc signed, so every rebuild is a new identity to the
        // keychain: the item written by the previous build is unreadable and the
        // delete above can fail on its ACL. Overwrite it in place when that happens,
        // otherwise reconnecting appears to work but never persists a token.
        if SecItemAdd(add as CFDictionary, nil) == errSecDuplicateItem {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

enum SpotifyError: Error {
    case notAuthorized
    case noClientID
    case nothingPlaying
    case notATrack          // podcast episode / ad / local file
    case badResponse(Int)
}

// MARK: - Manager

@MainActor
final class SpotifyLikeManager: NSObject, ObservableObject {

    static let shared = SpotifyLikeManager()

    @Published private(set) var isAuthorized = false
    @Published private(set) var isLiked      = false
    @Published private(set) var canLike      = false   // current item is a likeable track
    /// Why the heart is inert, surfaced in Settings. nil when the last call succeeded.
    @Published private(set) var lastError: String?

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var currentTrackID: String?
    private var pendingVerifier: String?

    private override init() {
        super.init()
        isAuthorized = (Keychain.read() != nil)
    }

    // MARK: Authorization

    func authorize() async throws {
        guard !SpotifyConfig.clientID.isEmpty else { throw SpotifyError.noClientID }

        let verifier  = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        pendingVerifier = verifier

        var comps = URLComponents(string: SpotifyConfig.authorizeURL)!
        comps.queryItems = [
            .init(name: "client_id",             value: SpotifyConfig.clientID),
            .init(name: "response_type",         value: "code"),
            .init(name: "redirect_uri",          value: SpotifyConfig.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge",        value: challenge),
            .init(name: "scope",                 value: SpotifyConfig.scopes),
            .init(name: "state",                 value: UUID().uuidString),
        ]

        let callbackURL = try await runAuthSession(url: comps.url!)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw SpotifyError.badResponse(-1) }

        try await exchangeCode(code, verifier: verifier)
        isAuthorized = true
    }

    func signOut() {
        Keychain.clear()
        accessToken = nil
        accessTokenExpiry = .distantPast
        isAuthorized = false
        canLike = false
        isLiked = false
    }

    private func runAuthSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: SpotifyConfig.callbackScheme
            ) { callback, error in
                if let callback { cont.resume(returning: callback) }
                else { cont.resume(throwing: error ?? SpotifyError.badResponse(-1)) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    // MARK: Token lifecycle

    private func exchangeCode(_ code: String, verifier: String) async throws {
        let body = formBody([
            "grant_type":    "authorization_code",
            "code":          code,
            "redirect_uri":  SpotifyConfig.redirectURI,
            "client_id":     SpotifyConfig.clientID,
            "code_verifier": verifier,
        ])
        try await requestToken(body)
    }

    private func refreshAccessToken() async throws {
        guard let refresh = Keychain.read() else { throw SpotifyError.notAuthorized }
        let body = formBody([
            "grant_type":    "refresh_token",
            "refresh_token": refresh,
            "client_id":     SpotifyConfig.clientID,
        ])
        try await requestToken(body)
    }

    private func requestToken(_ body: Data) async throws {
        var req = URLRequest(url: SpotifyConfig.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpotifyError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
            let refresh_token: String?   // sometimes omitted on refresh
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = token.access_token
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expires_in - 30))
        if let newRefresh = token.refresh_token { Keychain.save(newRefresh) }
    }

    private func validToken() async throws -> String {
        if let t = accessToken, Date() < accessTokenExpiry { return t }
        try await refreshAccessToken()
        guard let t = accessToken else { throw SpotifyError.notAuthorized }
        return t
    }

    // MARK: API calls

    /// Call when the Spotify track changes. Resolves the current track ID and
    /// its saved state, driving `canLike` and `isLiked`.
    /// - Parameter expectedTitle: the title MediaRemote is showing. Spotify's Web API
    ///   lags a beat behind a track change, so a mismatch means we'd resolve — and
    ///   like — the *previous* track; retry briefly instead of trusting it.
    func refreshState(expectedTitle: String? = nil) async {
        guard isAuthorized else { canLike = false; return }
        do {
            let token = try await validToken()

            var current: (id: String, name: String)?
            for attempt in 0..<3 {
                current = try await fetchCurrentTrack(token: token)
                guard let expected = expectedTitle, !expected.isEmpty,
                      let name = current?.name, !matches(name, expected)
                else { break }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(600)) }
            }

            guard let current else {
                canLike = false
                currentTrackID = nil
                note("Spotify reports nothing playing (or the item is an ad/podcast/local file)")
                return
            }
            currentTrackID = current.id
            isLiked = try await fetchSaved(id: current.id, token: token)
            canLike = true
            note(nil)
        } catch {
            canLike = false
            currentTrackID = nil
            note(describe(error))
        }
    }

    /// Loose title comparison — MediaRemote and the Web API disagree on suffixes
    /// like "- Remastered 2011" and on case/punctuation.
    private func matches(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
        }
        let (x, y) = (key(a), key(b))
        guard !x.isEmpty, !y.isEmpty else { return true }
        return x.hasPrefix(y) || y.hasPrefix(x)
    }

    func toggleLike() async {
        guard let id = currentTrackID else { return }
        let target = !isLiked
        isLiked = target                              // optimistic
        do {
            let token = try await validToken()
            try await setSaved(target, id: id, token: token)
        } catch {
            isLiked = !target                         // revert on failure
            note(describe(error))
        }
    }

    private func fetchCurrentTrack(token: String) async throws -> (id: String, name: String)? {
        let url = URL(string: "\(SpotifyConfig.apiBase)/me/player/currently-playing")!
        let (data, resp) = try await get(url, token: token)
        guard let http = resp as? HTTPURLResponse else { throw SpotifyError.badResponse(-1) }
        if http.statusCode == 204 { return nil }      // nothing playing
        guard http.statusCode == 200 else { throw SpotifyError.badResponse(http.statusCode) }

        struct Playing: Decodable {
            struct Item: Decodable { let id: String?; let name: String? }
            let currently_playing_type: String?
            let item: Item?
        }
        let playing = try JSONDecoder().decode(Playing.self, from: data)
        guard playing.currently_playing_type == "track" else { return nil } // skip ads/podcasts
        guard let id = playing.item?.id else { return nil }
        return (id, playing.item?.name ?? "")
    }

    private func fetchSaved(id: String, token: String) async throws -> Bool {
        let url = URL(string: "\(SpotifyConfig.apiBase)/me/tracks/contains?ids=\(id)")!
        let (data, resp) = try await get(url, token: token)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw SpotifyError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return (try JSONDecoder().decode([Bool].self, from: data)).first ?? false
    }

    private func setSaved(_ saved: Bool, id: String, token: String) async throws {
        var req = URLRequest(url: URL(string: "\(SpotifyConfig.apiBase)/me/tracks?ids=\(id)")!)
        req.httpMethod = saved ? "PUT" : "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...204).contains(code) else { throw SpotifyError.badResponse(code) }
    }

    // MARK: Helpers

    private func get(_ url: URL, token: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await URLSession.shared.data(for: req)
    }

    private func note(_ message: String?) {
        lastError = message
        if let message { NSLog("SpotifyLike: \(message)") }
    }

    private func describe(_ error: Error) -> String {
        guard let spotify = error as? SpotifyError else { return error.localizedDescription }
        switch spotify {
        case .notAuthorized:      return "Not connected — the stored refresh token is missing or unreadable. Reconnect in Settings."
        case .noClientID:         return "No Client ID set in Settings."
        case .nothingPlaying:     return "Spotify reports nothing playing."
        case .notATrack:          return "Current item is not a track (ad, podcast or local file)."
        case .badResponse(401):   return "401 from Spotify — the refresh token was rejected. Reconnect in Settings."
        case .badResponse(403):   return "403 from Spotify — check the app's scopes, and that the app owner's account has Premium."
        case .badResponse(429):   return "429 from Spotify — rate limited, try again shortly."
        case .badResponse(let c): return "Spotify returned HTTP \(c)."
        }
    }

    private func formBody(_ params: [String: String]) -> Data {
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((comps.percentEncodedQuery ?? "").utf8)
    }
}

// MARK: - Presentation anchor for ASWebAuthenticationSession

extension SpotifyLikeManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
