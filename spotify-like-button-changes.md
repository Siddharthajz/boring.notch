# Spotify Like Button — Implementation Notes

**Date:** 2026-06-17  
**Branch:** main (personal fork of TheBoredTeam/boring.notch)  
**Related upstream issue:** #929

---

## Problem

The heart/like button in boring.notch's media controls was invisible and inert for Spotify. Spotify's macOS client publishes playback metadata over the MediaRemote framework but exposes no liked-songs state or like command through it, and its AppleScript dictionary has no such verb either. The only viable path is the Spotify Web API.

---

## Files Changed

### New: `SpotifyLikeManager.swift`

Self-contained `@MainActor ObservableObject` that owns all Spotify auth and like-state logic. Currently lives at the project root — **move it to `boringNotch/managers/`** alongside `MusicManager.swift`.

Key design decisions:
- **Auth flow:** Authorization Code + PKCE (no client secret). Mandatory for native apps after Spotify's Nov 2025 OAuth migration — implicit grant and localhost redirects were removed.
- **Callback:** `ASWebAuthenticationSession` with custom URL scheme `boring-notch://spotify-callback`. Avoids loopback HTTP server complexity.
- **Track identity:** Resolved from `GET /v1/me/player/currently-playing`, not by searching title+artist (unreliable for remixes/live tracks).
- **Like state:** `GET /v1/me/tracks/contains?ids={id}` → Bool
- **Toggle:** `PUT /me/tracks` (save) / `DELETE /me/tracks` (unsave)
- **Scopes:** `user-library-read user-library-modify user-read-currently-playing`
- **Token storage:** Refresh token in Keychain; access token in memory with 30s expiry safety margin.
- **Client ID:** Per-user, entered in settings — not baked in. Avoids the 25-user Dev Mode quota cap.

Public surface used by the UI:
```swift
@Published isAuthorized: Bool
@Published isLiked: Bool
@Published canLike: Bool      // true when current item is a likeable track

authorize() async throws       // runs PKCE/ASWebAuthenticationSession flow
signOut()
refreshState() async           // call on track change; resolves ID + liked state
toggleLike() async             // optimistic update, reverts on failure
```

---

### Modified: `boringNotch/managers/MusicManager.swift`

Added a track-change hook that fires `SpotifyLikeManager.shared.refreshState()` whenever the now-playing state changes and the active source is Spotify (`com.spotify.client`). Uses a 300ms debounce so rapid skips don't spam the API.

```swift
if state.bundleIdentifier == "com.spotify.client" {
    Task {
        try? await Task.sleep(for: .milliseconds(300))
        await SpotifyLikeManager.shared.refreshState()
    }
}
```

---

### Modified: `boringNotch/components/Notch/NotchHomeView.swift`

`FavoriteControlButton` now branches on the active source:

- **Spotify + authorized:** uses `SpotifyLikeManager` — green heart when liked, calls `toggleLike()`, disabled when `canLike` is false.
- **Any other source:** unchanged — uses `MusicManager.toggleFavoriteTrack()` with the existing red heart.
- **Spotify + not authorized:** button is hidden (neither branch renders).

---

### Modified: `boringNotch/components/Settings/SettingsView.swift`

Added a **Spotify** section inside the existing Media settings pane:

- `SecureField` bound to `@AppStorage("spotifyClientID")` — disabled once connected.
- **Connect Spotify** button (disabled if Client ID is empty) — calls `spotify.authorize()`.
- When connected: shows a green checkmark + "Connected" label and a red **Disconnect** button calling `spotify.signOut()`.
- Footer explains the setup requirement and the exact redirect URI to register.

---

### Modified: `boringNotch/Info.plist`

Registered the `boring-notch` custom URL scheme under `CFBundleURLTypes` so `ASWebAuthenticationSession` can hand the OAuth callback back to the app.

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>boring-notch</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>boring-notch</string>
        </array>
    </dict>
</array>
```

---

### Modified: `boringNotch/boringNotch.entitlements`

Added `com.apple.security.cs.disable-library-validation` to allow loading of unsigned frameworks (needed for MediaRemote private API usage alongside the sandbox).

---

### Modified: `boringNotch/Localizable.xcstrings`

Added localization entries (English base strings, auto-comment) for all new UI text:

- `"Client ID"`
- `"Connect Spotify"`
- `"Connected"`
- `"Disconnect"`
- `"Paste your Spotify Client ID"`
- `"Required for the like/save button to work with Spotify..."`
- `"Spotify"` (section header)

Bumped `version` from `1.0` to `1.1`.

---

## Setup Required (one-time, per user)

1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) and create a free app.
2. In the app's settings, add redirect URI **exactly**: `boring-notch://spotify-callback`
3. Copy the Client ID and paste it into boring.notch Settings → Media → Spotify.
4. Click **Connect Spotify** — a browser sheet will appear; grant access.
5. Play a track in Spotify — the heart should appear and reflect saved state.

> **Note:** As of Feb 2026, development-mode apps require the app owner to have an active Spotify Premium subscription.

---

## Known Limitations / Edge Cases

- **Nothing playing / free account:** `currently-playing` returns 204 → `canLike` stays false → button hidden. Expected, not a bug.
- **Podcasts / ads:** `currently_playing_type != "track"` → button hidden. Expected.
- **Rapid skips:** The 300ms debounce means the like state resolves for the track playing at the time the debounce settles. If the debounce needs tuning, adjust the `Task.sleep` value in `MusicManager.swift`.
- **Token expiry:** Access tokens auto-refresh via the stored Keychain refresh token; no user action needed.
