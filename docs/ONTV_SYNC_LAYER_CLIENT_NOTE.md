# OnTV SyncLayer Client Note

Status: client contract prepared, WebSocket transport implemented for the current prototype backend, production hardening still pending.

## Current Client Boundary

`MediaBrowserUI` now treats `На телике` as a session surface, not as a Telegram shared-media filter.

The UI talks to `OnTVSessionsStore`:

- `LocalOnTVSessionsStore` is the current in-memory adapter.
- `SyncedOnTVSessionsStore` wraps the local cache and a transport.
- `ServerOnTVSessionsTransport` maps typed client events to WebSocket JSON messages.
- `MediaBrowserDataSource` remains responsible only for Telegram shared-media queries.
- Remote `context.snapshot` / `context.upsert` messages are kept as lightweight DTOs first, then hydrated into visible cards only when the matching local `MediaBrowserItem` is loaded.
- If a remote context is unresolved, the synced store first asks `MediaBrowserDataSource` to resolve the exact Telegram message id through `getMessagesLoadIfNecessary`; paging through shared media remains a fallback.
- While remote contexts are unresolved, the `На телике` list shows a resolving state instead of a false empty "no sessions" state.

Server mode is configured through `UserDefaults` or launch arguments:

- `MultigramOnTVSyncEndpoint`: preferred HTTP(S) or WebSocket endpoint.
- `MultigramOnTVSyncToken`: optional bearer token.
- `MultigramTelegramLoginClientId`: optional Telegram OpenID Connect client id override.
- `MultigramTelegramLoginRedirectURI`: optional Telegram OpenID Connect redirect URI override.
- `PlayGramOnTVSyncEndpoint`: legacy alias kept for existing local setups.
- `PlayGramOnTVSyncToken`: legacy token alias.
- `PlayGramTelegramLoginClientId`: legacy Telegram client id alias.
- `PlayGramTelegramLoginRedirectURI`: legacy Telegram redirect URI alias.

If no explicit endpoint is configured:

- Debug simulator builds use the local backend at `http://127.0.0.1:4010` with the prototype token `dev-local-token`.
- Release builds use the Render backend at `https://multigram-sync-layer.onrender.com` and request scoped tokens through Telegram OpenID Connect.
- Debug builds on a physical device stay local-only unless `MultigramOnTVSyncEndpoint` is set to the Mac's LAN URL, because `127.0.0.1` on device points to the device itself.

Production auth defaults:

- Telegram Client ID: `8908892975`.
- Redirect URI: `multigram://tglogin`.

Before a production login can finish, the bot's BotFather Login Widget / OpenID Connect settings must allow `multigram://tglogin`.

The WebSocket handshake sends:

- `X-PlayGram-Chat-Id`: current chat id.
- `X-PlayGram-User-Id`: current account peer id, used by the prototype server to compute active participant counts.
- `Authorization: Bearer <sync-token>` in production, where the token is minted by `/v1/auth/sync-token` for the current chat scope.

Production auth chain:

1. The client computes the same chat scope that it sends as `X-PlayGram-Chat-Id`.
2. If no valid cached token exists for that scope, the client opens Telegram OAuth through `ASWebAuthenticationSession`.
3. Telegram redirects back to `multigram://tglogin` with an authorization code.
4. The client exchanges the code with Telegram for an `id_token`.
5. The client posts `{ "idToken": "...", "chatId": "<scope>" }` to `https://multigram-sync-layer.onrender.com/v1/auth/sync-token`.
6. Render verifies the Telegram identity and returns a short-lived SyncLayer token scoped to that chat.
7. The WebSocket connects with `Authorization: Bearer <sync-token>`.

To smoke-test the production auth chain from a Debug simulator build, launch the app with explicit overrides because Debug simulator builds default to the local backend:

```text
-MultigramOnTVSyncEndpoint https://multigram-sync-layer.onrender.com
-MultigramOnTVSyncToken __clear__
-MultigramTelegramLoginClientId 8908892975
-MultigramTelegramLoginRedirectURI multigram://tglogin
```

`__clear__` removes any previously saved static token override. The absence of a static token is what makes the client request a Telegram-backed SyncLayer token.

## PlaybackContext

The client model mirrors the architecture document:

```swift
OnTVPlaybackContext(
    sessionId,
    chatId,
    fileId,
    item,
    position,
    progress,
    pulseUserId,
    status,
    endedAt,
    participantCount
)
```

`LOCKED` is not persisted. It is derived locally when `status == .live && pulseUserId == accountPeerId`.

## Events

The client has typed server-boundary events:

- `OnTVPlayerEvent.action`
- `OnTVPlayerEvent.state`
- `OnTVSessionEvent.pulseTaken`
- `OnTVSessionEvent.pulseEnded`
- `OnTVSessionEvent.participantJoined`
- `OnTVSessionEvent.participantLeft`

The local adapter applies these state transitions directly. The synced adapter sends them over WebSocket and applies inbound `SessionEvent`s to the local cache.

Inbound server messages currently handled by iOS:

- `context.snapshot`
- `context.upsert`
- `player.action`
- `player.state`
- `session.pulseTaken`
- `session.pulseEnded`
- `session.participantJoined`
- `session.participantLeft`
- `error/state_conflict`

`state_conflict` turns the local pulse toggle off, shows a prototype "Пульт занят" notice, and triggers reconnect/snapshot refresh. The final conflict treatment still needs Figma alignment.

A viewer joined to a LIVE session sends `session.participantLeft` when leaving the shared playback surface: pause after playback has started, select another media item, switch chat context, or close the media browser. A pulse holder still ends the session through `session.pulseEnded`.

When the current user is the pulse holder, local play/pause status changes are sent as `player.action`, and seek/scrub/skip changes are sent as `player.state`. Joined viewers apply inbound `player.action` / `player.state` to the local player without treating a remote pause as a voluntary viewer leave.

When the pulse holder uses previous/next media navigation, the client ends the old LIVE session and starts a new LIVE session for the neighboring item, so `На телике` does not leave the old file marked as active.

## Privacy Rule

The SyncLayer must not send Telegram message text, file contents, contacts, private media bytes, or raw chat history.

Allowed server state is limited to identifiers and playback/session state needed for shared viewing:

- `sessionId`
- `chatId`
- `fileId` / message id equivalent
- playback position/progress
- pulse holder id
- participant presence/count
- LIVE/ENDED timestamps

## Verified Local Flow

The current local adapter supports:

- empty `На телике` state;
- pulse on -> `LIVE` context shown as local `LOCKED`;
- pulse off -> `ENDED`;
- tap `ENDED` -> resume from stored position and take pulse;
- tap `LOCKED` -> blocked locally with red stripe flash.

Backend prototype exists in the root `services/sync-layer` directory. Remaining client work: real two-device app verification, final Figma conflict UI, and deeper resolver UX for deleted/private messages or media that Telegram cannot fetch for the current user.
