# Contributing to PRPeek

PRPeek is a native macOS menubar app that watches your open GitHub PRs. Logic
lives in a fully-tested `PRPeekCore` library; the AppKit shell is a thin layer
on top. Contributions welcome.

## Prerequisites
- macOS 26 (Tahoe) or later
- Xcode 26+ (Swift 6.2 toolchain)

## Build, test, run
```bash
swift test                 # PRPeekCore unit/integration tests (run this before any PR)
swift build                # debug build
bash Scripts/make-app.sh   # package PRPeek.app (dev-signed) and run it: open PRPeek.app
bash Scripts/make-dmg.sh   # package a distributable PRPeek.dmg
```

Sign in via **Paste token…** (a PAT with `repo` + `read:org`) or **Sign in with
GitHub** (set `PRPEEK_CLIENT_ID` to a registered OAuth App — see `README.md`).

## Project layout
- `Sources/PRPeekCore/` — all logic, no UI. Must stay testable:
  - `GitHubClient` (actor): conditional requests (ETag/304), pagination, typed errors
  - `JSONStore`: atomic persistence with schema recovery
  - `Auth`: OAuth device flow + Keychain
  - `SearchService`, `Classifier`, `RefreshEngine`, `NotificationPlanner`
- `Sources/PRPeek/` — AppKit menubar shell (`AppModel`, `StatusController`, …)
- `Tests/PRPeekCoreTests/` — XCTest. Network is stubbed via `URLProtocolStub`
  (client integration tests) and `Transport` fakes (unit tests).

## Pull requests
- One logical change per PR. Keep commits bisectable.
- Every new code path gets a test. Network behavior is tested without hitting
  GitHub (see the stub/fake helpers in `Tests/`).
- Swift 6 strict concurrency is on — keep types `Sendable`, respect the
  actor / `@MainActor` boundary (network off-main, UI on-main).
- `swift test` must be green. CI runs it on every PR.

## Releases
Push a `vX.Y.Z` tag → the release workflow builds and attaches `PRPeek.dmg` to a
GitHub Release. The DMG is currently **ad-hoc signed** (not notarized), so first
launch needs right-click ▸ Open (Gatekeeper). Notarization is a tracked follow-up
(needs an Apple Developer ID — see commented stub in `.github/workflows/release.yml`).
