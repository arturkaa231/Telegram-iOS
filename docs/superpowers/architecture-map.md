# Architecture map — load-bearing submodules

Cheat sheet to orient quickly in this 273-submodule project. Only describes layers that recur in most feature work. Not exhaustive.

## Layer order (bottom to top)

| Layer | Module(s) | What lives here |
|---|---|---|
| Reactive primitives | `SwiftSignalKit` | `Signal<T, E>`, `Queue`, `Promise`, `MetaDisposable`. Pervasive — every async API returns one. |
| Network | `MtProtoKit`, `TelegramApi` | Low-level Telegram protocol + generated API types. Rarely touched in UI work. |
| Storage | `Postbox` | Local SQLite-ish DB. `MediaBox` (resource cache), `MessageHistory`, transactions, message tags, search. **Being phased out of consumer modules — see CLAUDE.md "Postbox → TelegramEngine refactor".** |
| Domain API | `TelegramCore` | The `TelegramEngine` facade — `EngineMessage`, `EnginePeer`, `engine.messages.*`, `engine.resources.*`. Bridges Postbox details into clean public API. Cannot import UIKit. |
| Account session | `AccountContext` | `AccountContext` holds the current account: `context.account`, `context.sharedContext`, `context.engine`, `context.fetchManager`, `context.sharedContext.mediaManager`. **Almost every UI initializer takes this.** |
| UI primitives | `Display`, `AsyncDisplayKit` | `ASDisplayNode`, `ViewController` (TG's own, not UIKit's), `NavigationController` + `NavigationContainer` (custom pop gesture via `InteractiveTransitionGestureRecognizer`, see below), `ContainedViewLayoutTransition`. |
| Theming/strings | `TelegramPresentationData` | `PresentationData` = `theme + strings + dateTimeFormat`. `theme.list.itemPrimaryTextColor` etc. Live updates via `context.sharedContext.presentationData` signal. |
| App | `TelegramUI` | Giant umbrella module with the actual screens (`ChatControllerImpl`, settings, chat list, etc.). Imports everything below. |

## Media playback stack

| Module | Role |
|---|---|
| `TelegramUniversalVideoContent` | `UniversalVideoNode` + content types: `NativeVideoContent` (FFmpeg-decoded), `HLSVideoContent`, `SystemVideoContent`, `WebEmbedVideoContent` (YouTube/Vimeo/Twitch). Pluggable. |
| `GalleryUI` | Fullscreen media viewer infra. `GalleryVideoDecoration` — standard chrome wrapper for `UniversalVideoNode`. |
| `MediaPlayer` | Audio/video pipeline (FFmpeg-based) under `UniversalVideoNode`. Internal. |
| `MediaBrowserUI` (project-specific, under `TelegramUI/Components/Chat/`) | New media browser modal — provider registry (`MediaPreviewProviderRegistry`) for swappable preview nodes per file type. |

**Recipe for video playback in any new UI:** never use raw `AVPlayer` directly — TG files are encrypted/blob on disk. Use `UniversalVideoNode` with `NativeVideoContent`, message-based `FileMediaReference`, and `streamVideo: .conservative` for progressive streaming.

## Gesture / navigation gotchas

- **`UIView.disablesInteractiveTransitionGestureRecognizer = true`** — the canonical way to stop the swipe-back / horizontal pop gesture for a presented view. TG walks the superview chain and bails when this flag is found. UIKit's `interactivePopGestureRecognizer.isEnabled = false` does **nothing** because TG uses a custom recognizer on `NavigationContainer`.
- **`ViewController.interactiveNavivationGestureEdgeWidth`** — override on a `Display.ViewController` if you need a narrower-than-full-width pop-trigger zone.

## Submodule organisation

- `submodules/Postbox`, `submodules/TelegramCore`, `submodules/AccountContext`, `submodules/Display` — the foundational layers above. Single-target swift_library each.
- `submodules/TelegramUI/Components/<Area>/<Module>/` — modern feature-specific UI lives here (e.g. `Chat/MediaBrowserUI`). Preferred location for new components.
- `submodules/<Module>/` (flat) — older feature modules (e.g. `GalleryUI`, `ChatListUI`). Both layouts are valid.

## Discovery commands

See [`project_bazel_queries.md`](../../../.claude/projects/-Users-aleksey-Documents-experemental-multigram/memory/project_bazel_queries.md) memory for `bazel query` recipes. Quick examples:

```sh
# What does MediaBrowserUI import?
./build-input/bazel-8.4.2-darwin-arm64 query --keep_going 'deps(//submodules/TelegramUI/Components/Chat/MediaBrowserUI:MediaBrowserUI, 1)'

# Who consumes AccountContext (1 hop)?
./build-input/bazel-8.4.2-darwin-arm64 query --keep_going 'rdeps(//submodules/..., //submodules/AccountContext:AccountContext, 1)'
```
