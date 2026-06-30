# PRPeek

macOS menubar watcher for open GitHub PRs. Swift 6, SwiftPM. UI builds against macOS 26 (Tahoe); core logic builds 14+.

## Build / test

```bash
swift build              # debug build
swift test               # run PRPeekCoreTests (the only test target)
swift build -c release   # release binary at .build/release/PRPeek
./Scripts/make-app.sh    # bundle release binary into PRPeek.app (needed for notifications + Keychain)
./Scripts/make-dmg.sh    # build distributable PRPeek.dmg
```

CI (`.github/workflows/ci.yml`) runs `swift test` on `macos-latest`.

## Architecture

Two targets — keep the split:

- **`PRPeekCore`** — all logic, no AppKit. Pure, testable. Put business logic here.
- **`PRPeek`** — macOS UI (AppKit/SwiftUI), depends on Core. No business logic.

If you can write it without importing AppKit, it belongs in Core (and gets a test).

### PRPeekCore map

| File | Owns |
|------|------|
| `Transport.swift` | The network seam every call goes through. |
| `GitHubClient.swift` | Conditional-request engine (ETag/304) all endpoints ride. |
| `GitHubError.swift` | Typed errors; failure-state UI keys on these. |
| `Auth.swift` | `GET /user` — drives "waiting on me". |
| `Search.swift` | `/search/issues` wire wrapper. |
| `Classifier.swift` | `GET /pulls/{n}` — richer per-PR detail. |
| `Commits.swift` / `Models.swift` | CI/checks rollup for a PR's head commit. |
| `ReviewComments.swift` | Reviewer verdicts from PR review `state`. |
| `RefreshEngine.swift` | ONE coalesced refresh pass (not per-repo timers). |
| `Notifications.swift` | Diffs previous pass vs current to decide what fires. |
| `Concurrency.swift` | Order-preserving concurrent map with in-flight cap. |
| `JSONStore.swift` | Atomic JSON persistence for `PRPeekState`. |

### PRPeek (UI) map

| File | Owns |
|------|------|
| `AppModel.swift` | The brain — state, refresh loop, auth, lifecycle wiring. |
| `StatusController.swift` | `NSStatusItem` — paints badge, rebuilds menu. Largest file; use its `MARK:` anchors. |
| `DesktopPanel.swift` | Floating PRPeek panel with native controls. |
| `SearchWindow.swift` | Keyboard-first search across all loaded PRs. |
| `NotificationService.swift` | Delivers `NotificationEvent`s; first-run permission. |
| `BadgeRenderer.swift` | Menubar icon (color path, `isTemplate=false`). |
| `Theme.swift` | System/Light/Dark → `NSApp.appearance`. |
| `LifecycleMonitor.swift` | Sleep/wake + network reachability. |
| `PerPRLazyCache.swift` | Per-PR fetch-once cache with in-flight dedup. |

## Conventions

- Top of each source file carries a `///` doc line stating its job — keep it accurate when you change the file.
- Big files use `// MARK:` section anchors — read those first to locate code before grepping.
- Deliberate simplifications are marked with `ponytail:` comments naming the ceiling.
- Update `README.md` when you change user-facing behavior, install steps, or features.
